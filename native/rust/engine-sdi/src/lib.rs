pub mod autodetect;
pub mod audio;

pub use audio::{
    build_upmix_matrix, setup_audio_upmix, sdi_audio_caps, FallbackConfig, SDI_AUDIO_CAPS,
};
pub use autodetect::{
    decide_from_caps, lookup_decklink_mode, normalize_framerate, AutoDetectDecision,
    DeckLinkModeEntry, DECKLINK_MODE_TABLE,
};
