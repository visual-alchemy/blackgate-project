pub mod audio;
pub mod autodetect;

pub use audio::{
    build_upmix_matrix, sdi_audio_caps, setup_audio_upmix, FallbackConfig, SDI_AUDIO_CAPS,
};
pub use autodetect::{
    decide_from_caps, lookup_decklink_mode, normalize_framerate, AutoDetectDecision,
    DeckLinkModeEntry, DECKLINK_MODE_TABLE,
};
