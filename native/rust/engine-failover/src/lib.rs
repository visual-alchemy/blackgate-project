use gstreamer::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SourceTarget {
    Primary,
    Secondary,
}

impl SourceTarget {
    pub fn as_str(&self) -> &str {
        match self {
            SourceTarget::Primary => "primary",
            SourceTarget::Secondary => "secondary",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "primary" => Some(SourceTarget::Primary),
            "secondary" => Some(SourceTarget::Secondary),
            _ => None,
        }
    }
}

/// Dual-ingest failover state (C ipc_protocol.c selector control).
pub struct SelectorState {
    selector: gstreamer::Element,
    secondary: gstreamer::Element,
    active: SourceTarget,
    secondary_joined: bool,
}

impl SelectorState {
    pub fn new(selector: gstreamer::Element, secondary: gstreamer::Element) -> Self {
        Self {
            selector,
            secondary,
            active: SourceTarget::Primary,
            secondary_joined: true,
        }
    }

    /// switch-source: point input-selector active-pad at sink_0/sink_1.
    /// Prints "SOURCE_SWITCHED:<target>" (stdout, Elixir-parsed).
    pub fn switch_to(&mut self, target: SourceTarget) {
        let pad_name = match target {
            SourceTarget::Primary => "sink_0",
            SourceTarget::Secondary => "sink_1",
        };
        if let Some(pad) = self.selector.static_pad(pad_name) {
            self.selector.set_property("active-pad", &pad);
            self.active = target;
            println!("SOURCE_SWITCHED:{}", target.as_str());
        } else {
            eprintln!("[failover] ERROR: pad {} not found on input-selector", pad_name);
        }
    }

    /// join-secondary: raise the secondary source to PLAYING. "SECONDARY_JOINED".
    pub fn join_secondary(&mut self) {
        if !self.secondary_joined {
            let _ = self.secondary.set_state(gstreamer::State::Playing);
            self.secondary_joined = true;
            println!("SECONDARY_JOINED");
        }
    }

    /// leave-secondary: drop the secondary source to NULL. "SECONDARY_LEFT".
    pub fn leave_secondary(&mut self) {
        if self.secondary_joined {
            let _ = self.secondary.set_state(gstreamer::State::Null);
            self.secondary_joined = false;
            println!("SECONDARY_LEFT");
        }
    }

    pub fn active(&self) -> SourceTarget {
        self.active
    }

    pub fn secondary_joined(&self) -> bool {
        self.secondary_joined
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_strings_match_elixir_wire_names() {
        assert_eq!(SourceTarget::Primary.as_str(), "primary");
        assert_eq!(SourceTarget::Secondary.as_str(), "secondary");
        assert_eq!(SourceTarget::from_str("primary"), Some(SourceTarget::Primary));
        assert_eq!(SourceTarget::from_str("secondary"), Some(SourceTarget::Secondary));
        assert_eq!(SourceTarget::from_str("bogus"), None);
    }
}
