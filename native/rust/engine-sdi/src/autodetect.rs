use gstreamer as gst;

/// DeckLink mode table — C decklink_mode_table parity.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeckLinkModeEntry {
    pub width: i32,
    pub height: i32,
    pub fps_num: i32,
    pub fps_den: i32,
    pub interlaced: bool,
    pub mode_str: &'static str,
    pub caps_interlace_mode: Option<&'static str>,
}

const fn entry(
    width: i32,
    height: i32,
    fps_num: i32,
    fps_den: i32,
    interlaced: bool,
    mode_str: &'static str,
    caps_interlace_mode: Option<&'static str>,
) -> DeckLinkModeEntry {
    DeckLinkModeEntry {
        width,
        height,
        fps_num,
        fps_den,
        interlaced,
        mode_str,
        caps_interlace_mode,
    }
}

pub const DECKLINK_MODE_TABLE: [DeckLinkModeEntry; 15] = [
    entry(1920, 1080, 24, 1, false, "1080p24", None),
    entry(1920, 1080, 25, 1, false, "1080p25", None),
    entry(1920, 1080, 30, 1, false, "1080p30", None),
    entry(1920, 1080, 50, 1, false, "1080p50", None),
    entry(1920, 1080, 60, 1, false, "1080p60", None),
    entry(1920, 1080, 25, 1, true, "1080i50", Some("interleaved")),
    entry(1920, 1080, 30, 1, true, "1080i60", Some("interleaved")),
    entry(1280, 720, 50, 1, false, "720p50", None),
    entry(1280, 720, 60, 1, false, "720p60", None),
    entry(720, 576, 25, 1, true, "pal", Some("interleaved")),
    entry(720, 480, 30, 1, true, "ntsc", Some("interleaved")),
    entry(3840, 2160, 25, 1, false, "2160p25", None),
    entry(3840, 2160, 30, 1, false, "2160p30", None),
    entry(3840, 2160, 50, 1, false, "2160p50", None),
    entry(3840, 2160, 60, 1, false, "2160p60", None),
];

pub fn lookup_decklink_mode(
    width: i32,
    height: i32,
    fps_num: i32,
    fps_den: i32,
    interlaced: bool,
) -> Option<DeckLinkModeEntry> {
    DECKLINK_MODE_TABLE.iter().copied().find(|e| {
        e.width == width
            && e.height == height
            && e.fps_num == fps_num
            && e.fps_den == fps_den
            && e.interlaced == interlaced
    })
}

/// Normalize a decoded framerate fraction for table lookup.
/// NTSC 1001 denominators and non-standard rates get rounded (C parity).
pub fn normalize_framerate(fps_num: i32, fps_den: i32) -> (i32, i32) {
    if fps_den == 1001 && (fps_num == 24000 || fps_num == 30000 || fps_num == 60000) {
        (fps_num / 1000, 1)
    } else if fps_den == 1001 && fps_num == 50000 {
        (50, 1)
    } else if fps_den != 1 && fps_den != 0 {
        ((fps_num + fps_den / 2) / fps_den, 1)
    } else {
        (fps_num, if fps_den == 0 { 1 } else { fps_den })
    }
}

/// Result of auto-detect resolution: what to configure on the SDI branch.
#[derive(Debug, Clone, PartialEq)]
pub struct AutoDetectDecision {
    pub matched: bool,
    pub mode_str: String,
    pub width: i32,
    pub height: i32,
    pub framerate: String,
    pub need_interlace_element: bool,
    pub interlace_mode: Option<&'static str>,
}

/// C on_sdi_decodebin_video_pad_added_autodetect decision logic.
/// `caps` must be raw video caps from decodebin.
pub fn decide_from_caps(
    caps: &gst::Caps,
    fallback: &crate::FallbackConfig,
) -> Option<AutoDetectDecision> {
    let s = caps.structure(0)?;
    if !s.name().starts_with("video/x-raw") {
        return None;
    }

    let width = s.get::<i32>("width").unwrap_or(0);
    let height = s.get::<i32>("height").unwrap_or(0);
    let (fps_num, fps_den) = s
        .get::<gst::Fraction>("framerate")
        .map(|f| (f.numer(), f.denom()))
        .unwrap_or((0, 1));
    let interlaced = s
        .get::<&str>("interlace-mode")
        .map(|m| m == "interleaved")
        .unwrap_or(false);

    let (lookup_num, lookup_den) = normalize_framerate(fps_num, fps_den);

    match lookup_decklink_mode(width, height, lookup_num, lookup_den, interlaced) {
        Some(e) => Some(AutoDetectDecision {
            matched: true,
            mode_str: e.mode_str.to_string(),
            width: e.width,
            height: e.height,
            framerate: format!("{}/{}", e.fps_num, e.fps_den),
            need_interlace_element: e.caps_interlace_mode.is_some(),
            interlace_mode: e.caps_interlace_mode,
        }),
        None => {
            let mode_str = fallback.mode.clone();
            let need_interlace = mode_str.contains('i') || mode_str == "pal" || mode_str == "ntsc";
            Some(AutoDetectDecision {
                matched: false,
                mode_str,
                width: fallback.width,
                height: fallback.height,
                framerate: fallback.framerate.clone(),
                need_interlace_element: need_interlace,
                interlace_mode: if need_interlace {
                    Some("interleaved")
                } else {
                    None
                },
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ntsc_fractional_rates_normalize() {
        assert_eq!(normalize_framerate(30000, 1001), (30, 1));
        assert_eq!(normalize_framerate(24000, 1001), (24, 1));
        assert_eq!(normalize_framerate(60000, 1001), (60, 1));
        assert_eq!(normalize_framerate(50000, 1001), (50, 1));
    }

    #[test]
    fn nonstandard_rates_round() {
        assert_eq!(normalize_framerate(5000, 201), (25, 1));
        assert_eq!(normalize_framerate(25, 1), (25, 1));
        assert_eq!(normalize_framerate(25, 0), (25, 1));
    }

    #[test]
    fn table_lookup_interlace_is_distinct_mode() {
        let prog = lookup_decklink_mode(1920, 1080, 25, 1, false).unwrap();
        assert_eq!(prog.mode_str, "1080p25");
        let intc = lookup_decklink_mode(1920, 1080, 25, 1, true).unwrap();
        assert_eq!(intc.mode_str, "1080i50");
        assert_eq!(intc.caps_interlace_mode, Some("interleaved"));
    }

    #[test]
    fn mode_strings_are_gstreamer_nicks_not_numbers() {
        // The old broken code emitted "11".."20" — the C engine uses enum nicks.
        for e in DECKLINK_MODE_TABLE.iter() {
            assert!(e.mode_str.contains(|c: char| !c.is_ascii_digit()));
        }
    }

    #[test]
    fn pal_and_ntsc_are_interlaced() {
        let pal = lookup_decklink_mode(720, 576, 25, 1, true).unwrap();
        assert_eq!(pal.mode_str, "pal");
        let ntsc = lookup_decklink_mode(720, 480, 30, 1, true).unwrap();
        assert_eq!(ntsc.mode_str, "ntsc");
        // progressive SD variants do not exist in the table
        assert!(lookup_decklink_mode(720, 576, 25, 1, false).is_none());
    }
}
