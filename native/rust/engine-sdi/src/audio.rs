use gst::glib;
use gst::prelude::*;
use gstreamer as gst;

/// Fallback SDI config when auto-detect can't match a broadcast standard.
#[derive(Debug, Clone)]
pub struct FallbackConfig {
    pub mode: String,
    pub width: i32,
    pub height: i32,
    pub framerate: String,
}

/// SDI audio caps: S16LE 48 kHz stereo interleaved.
///
/// The C engine asked for 8 channels with a 0xc3f mask after an audiomixmatrix 2→8 upmix. That chain
/// does not negotiate on this box: the AAC decoder delivers `F32LE, layout=non-interleaved, 2ch,
/// mask 0x3`, and demanding 8ch + mask 0xc3f back from audioconvert fails ("transform could not
/// transform … in anything we support"; asking for 8ch with no mask instead trips "invalid or
/// unexpected channel-positions"). The DeckLink audio sink itself accepts `channels {2, 8, 16}` with
/// **no channel-mask field**, so the upmix buys nothing — the driver embeds the stereo pair into the
/// SDI stream. Keep the chain stereo and drop the mask demand.
pub const SDI_AUDIO_CAPS: &str =
    "audio/x-raw, format=S16LE, rate=48000, channels=2, layout=interleaved";

/// Build the audiomixmatrix "matrix" property: 8x2 array duplicating the
/// stereo pair to all four SDI pairs (coef 1.0 when i%2==j, else 0.0).
///
/// Constructed via typed gst::Array values — a literal string
/// gst_util_set_object_arg SIGSEGVs on GStreamer 1.24+ (native/AGENTS.md).
///
/// No longer used by the SDI audio chain (see [`SDI_AUDIO_CAPS`]); kept because the upmix is still
/// the right tool if a deployment ever genuinely needs 8 discrete channels.
pub fn build_upmix_matrix() -> glib::Value {
    let rows: Vec<gst::Array> = (0..8i32)
        .map(|i| {
            let coefs: Vec<&f64> = (0..2i32)
                .map(|j| {
                    static ZERO: f64 = 0.0;
                    static ONE: f64 = 1.0;
                    if i % 2 == j {
                        &ONE
                    } else {
                        &ZERO
                    }
                })
                .collect();
            gst::Array::new(&coefs)
        })
        .collect();
    let row_refs: Vec<&gst::Array> = rows.iter().collect();
    gst::Array::new(&row_refs).to_value()
}

/// Configure a pre-created audiomixmatrix element for 2→8 channel upmix.
///
/// audiomixmatrix declares `in-channels`/`out-channels` as `guint`; passing an i32 makes
/// gstreamer-rs panic ("can't be set from the given type"), which took the whole engine down when
/// a route carried an SDI sink.
pub fn setup_audio_upmix(amix: &gst::Element) -> Result<(), String> {
    amix.set_property("in-channels", 2u32);
    amix.set_property("out-channels", 8u32);
    amix.set_property("channel-mask", 0xc3fu64);
    amix.set_property_from_str("mode", "manual");
    let matrix = build_upmix_matrix();
    amix.set_property("matrix", &matrix);
    Ok(())
}

pub fn sdi_audio_caps() -> gst::Caps {
    gst::Caps::builder("audio/x-raw")
        .field("format", "S16LE")
        .field("rate", 48000i32)
        .field("channels", 2i32)
        .field("layout", "interleaved")
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_caps_are_stereo_without_mask() {
        gstreamer::init().expect("gst init for caps test");
        let caps = sdi_audio_caps();
        let s = caps.structure(0).unwrap();
        assert_eq!(s.name(), "audio/x-raw");
        assert_eq!(s.get::<&str>("format").unwrap(), "S16LE");
        assert_eq!(s.get::<i32>("rate").unwrap(), 48000);
        assert_eq!(s.get::<i32>("channels").unwrap(), 2);
        assert_eq!(s.get::<&str>("layout").unwrap(), "interleaved");
        assert!(
            s.get::<u64>("channel-mask").is_err(),
            "no mask: the DeckLink audio sink caps carry none, and demanding one from audioconvert \
             is what broke the SDI audio chain"
        );
    }

    /// Regression: the caps we demand must be inside what decklinkaudiosink accepts, otherwise the
    /// audio branch fails negotiation and takes the route down with it.
    #[test]
    fn audio_caps_are_accepted_by_decklink_sink_template() {
        gstreamer::init().expect("gst init for sink caps test");
        let factory = gst::ElementFactory::find("decklinkaudiosink")
            .expect("decklinkaudiosink element (needs gst-plugins-bad decklink)");
        let template = factory
            .static_pad_templates()
            .into_iter()
            .find(|t| t.name_template() == "sink")
            .expect("decklinkaudiosink sink pad template");
        let sink_caps = template.caps();

        let demanded = sdi_audio_caps();
        assert!(
            sink_caps.can_intersect(&demanded) && demanded.can_intersect(&sink_caps),
            "SDI audio caps {} are not accepted by decklinkaudiosink's sink template {}",
            demanded,
            sink_caps
        );
    }

    /// Regression: audiomixmatrix declares `in-channels`/`out-channels` as `guint`, and passing
    /// i32 made gstreamer-rs panic — which killed the engine for any route carrying an SDI sink.
    #[test]
    fn audio_upmix_accepts_uint_channel_counts() {
        gstreamer::init().expect("gst init for upmix test");

        let amix = gst::ElementFactory::make("audiomixmatrix")
            .build()
            .expect("audiomixmatrix element (gst-plugins-bad) is required for SDI audio");

        setup_audio_upmix(&amix).expect("upmix setup");

        assert_eq!(amix.property::<u32>("in-channels"), 2);
        assert_eq!(amix.property::<u32>("out-channels"), 8);
        assert_eq!(amix.property::<u64>("channel-mask"), 0xc3f);
    }
}
