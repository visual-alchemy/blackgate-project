use gstreamer as gst;
use gst::glib;
use gst::prelude::*;

/// Fallback SDI config when auto-detect can't match a broadcast standard.
#[derive(Debug, Clone)]
pub struct FallbackConfig {
    pub mode: String,
    pub width: i32,
    pub height: i32,
    pub framerate: String,
}

/// C audio upmix chain caps: S16LE 48kHz 8ch interleaved, mask 0xc3f.
pub const SDI_AUDIO_CAPS: &str =
    "audio/x-raw, format=S16LE, rate=48000, channels=8, channel-mask=(bitmask)0x0000000000000c3f, layout=interleaved";

/// Build the audiomixmatrix "matrix" property: 8x2 array duplicating the
/// stereo pair to all four SDI pairs (coef 1.0 when i%2==j, else 0.0).
///
/// Constructed via typed gst::Array values — a literal string
/// gst_util_set_object_arg SIGSEGVs on GStreamer 1.24+ (native/AGENTS.md).
pub fn build_upmix_matrix() -> glib::Value {
    let rows: Vec<gst::Array> = (0..8i32)
        .map(|i| {
            let coefs: Vec<&f64> = (0..2i32)
                .map(|j| {
                    static ZERO: f64 = 0.0;
                    static ONE: f64 = 1.0;
                    if i % 2 == j { &ONE } else { &ZERO }
                })
                .collect();
            gst::Array::new(&coefs)
        })
        .collect();
    let row_refs: Vec<&gst::Array> = rows.iter().collect();
    gst::Array::new(&row_refs).to_value()
}

/// Configure a pre-created audiomixmatrix element for 2→8 channel upmix.
pub fn setup_audio_upmix(amix: &gst::Element) -> Result<(), String> {
    amix.set_property("in-channels", 2i32);
    amix.set_property("out-channels", 8i32);
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
        .field("channels", 8i32)
        .field("channel-mask", 0xc3fu64)
        .field("layout", "interleaved")
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_caps_match_c_string() {
        gstreamer::init().expect("gst init for caps test");
        let caps = sdi_audio_caps();
        let s = caps.structure(0).unwrap();
        assert_eq!(s.name(), "audio/x-raw");
        assert_eq!(s.get::<&str>("format").unwrap(), "S16LE");
        assert_eq!(s.get::<i32>("rate").unwrap(), 48000);
        assert_eq!(s.get::<i32>("channels").unwrap(), 8);
        assert_eq!(s.get::<&str>("layout").unwrap(), "interleaved");
    }
}
