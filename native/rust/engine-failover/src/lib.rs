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

    pub fn from_wire_name(s: &str) -> Option<Self> {
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
    /// Route-level auto_join; drives lite's switch-time join/leave lifecycle.
    auto_join: bool,
}

impl SelectorState {
    /// `secondary_joined` must reflect the real pipeline state: builder.rs holds the
    /// secondary at NULL when `auto_join` is false, so the engine must be told.
    /// Hardcoding `true` here made `join-secondary` a silent no-op on
    /// auto_join=false routes — the switch reported success while the secondary
    /// stayed NULL.
    pub fn new(
        selector: gstreamer::Element,
        secondary: gstreamer::Element,
        auto_join: bool,
    ) -> Self {
        Self {
            selector,
            secondary,
            active: SourceTarget::Primary,
            secondary_joined: auto_join,
            auto_join,
        }
    }

    /// switch-source: point input-selector active-pad at sink_0/sink_1.
    /// Prints "SOURCE_SWITCHED:<target>" (stdout, Elixir-parsed).
    ///
    /// C lite 2404-2431 keeps the auto_join=false lifecycle atomic in native code:
    /// the secondary must be running before the selector moves to it, and must be
    /// stopped only after the selector has moved back to primary.
    pub fn switch_to(&mut self, target: SourceTarget) {
        let pad_name = match target {
            SourceTarget::Primary => "sink_0",
            SourceTarget::Secondary => "sink_1",
        };
        let Some(pad) = self.selector.static_pad(pad_name) else {
            eprintln!(
                "[failover] ERROR: pad {} not found on input-selector",
                pad_name
            );
            return;
        };

        if target == SourceTarget::Secondary && !self.auto_join {
            self.join_secondary();
        }

        self.selector.set_property("active-pad", &pad);
        self.active = target;
        println!("SOURCE_SWITCHED:{}", target.as_str());

        // Move the selector to primary BEFORE stopping the secondary.
        if target == SourceTarget::Primary && !self.auto_join {
            self.leave_secondary();
        }
    }

    /// join-secondary: raise the secondary source to PLAYING. "SECONDARY_JOINED".
    /// C lite 2434-2443: clear the locked-state flag then sync with parent, so the
    /// source joins the running pipeline's state machine (a bare set_state(Playing)
    /// on a locked element does nothing).
    pub fn join_secondary(&mut self) {
        if !self.secondary_joined {
            self.secondary.set_locked_state(false);
            if self.secondary.sync_state_with_parent().is_err() {
                eprintln!("[failover] join-secondary: failed to sync secondary with parent");
                return;
            }
            self.secondary_joined = true;
            println!("SECONDARY_JOINED");
        }
    }

    /// leave-secondary: lock and drop the secondary source to NULL. "SECONDARY_LEFT".
    /// C lite 2445-2454.
    pub fn leave_secondary(&mut self) {
        if self.secondary_joined {
            self.secondary.set_locked_state(true);
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
        assert_eq!(
            SourceTarget::from_wire_name("primary"),
            Some(SourceTarget::Primary)
        );
        assert_eq!(
            SourceTarget::from_wire_name("secondary"),
            Some(SourceTarget::Secondary)
        );
        assert_eq!(SourceTarget::from_wire_name("bogus"), None);
    }

    /// Regression: auto_join=false must leave the selector believing the secondary
    /// is NOT joined, or `join-secondary` silently no-ops and the operator's
    /// switch-to-secondary lands on a NULL source with no error anywhere.
    /// Also covers lite's switch-time join/leave lifecycle (gst_pipeline.c 2404).
    #[test]
    fn auto_join_false_makes_join_secondary_effective() {
        gstreamer::init().unwrap();

        // Real pipeline: sync_state_with_parent() needs a parent in a state.
        let pipeline = gstreamer::Pipeline::new();
        let primary = gstreamer::ElementFactory::make("identity")
            .name("p")
            .build()
            .unwrap();
        let secondary = gstreamer::ElementFactory::make("identity")
            .name("s")
            .build()
            .unwrap();
        let selector = gstreamer::ElementFactory::make("input-selector")
            .name("sel")
            .build()
            .unwrap();
        let sink = gstreamer::ElementFactory::make("fakesink").build().unwrap();
        pipeline
            .add_many([&primary, &secondary, &selector, &sink])
            .unwrap();

        let p_pad = selector.request_pad_simple("sink_%u").unwrap();
        let s_pad = selector.request_pad_simple("sink_%u").unwrap();
        p_pad.set_property("always-ok", true);
        s_pad.set_property("always-ok", true);
        primary.static_pad("src").unwrap().link(&p_pad).unwrap();
        secondary.static_pad("src").unwrap().link(&s_pad).unwrap();
        gstreamer::Element::link(&selector, &sink).unwrap();
        selector.set_property("active-pad", &p_pad);

        pipeline.set_state(gstreamer::State::Playing).unwrap();
        let _ = pipeline.state(gstreamer::ClockTime::from_seconds(5));

        // builder() with auto_join=false: lock + NULL the secondary.
        secondary.set_locked_state(true);
        secondary.set_state(gstreamer::State::Null).unwrap();

        let mut off = SelectorState::new(selector.clone(), secondary.clone(), false);
        assert!(
            !off.secondary_joined(),
            "auto_join=false must report secondary NOT joined"
        );
        off.join_secondary();
        assert!(
            off.secondary_joined(),
            "join_secondary must be effective on auto_join=false routes"
        );

        // lite switch_source lifecycle: switching to secondary joins first, and
        // switching back to primary leaves only AFTER the selector has moved.
        off.switch_to(SourceTarget::Secondary);
        assert!(
            off.secondary_joined(),
            "switch to secondary must leave it joined"
        );
        assert_eq!(off.active(), SourceTarget::Secondary);
        off.switch_to(SourceTarget::Primary);
        assert!(
            !off.secondary_joined(),
            "switch to primary must stop the secondary on auto_join=false"
        );

        // auto_join=true: the secondary is live from construction, and switching
        // away must NOT tear it down.
        let mut on = SelectorState::new(selector, secondary, true);
        assert!(
            on.secondary_joined(),
            "auto_join=true starts with the secondary already live"
        );
        on.switch_to(SourceTarget::Primary);
        assert!(
            on.secondary_joined(),
            "auto_join=true must not stop the secondary on switch back"
        );

        let _ = pipeline.set_state(gstreamer::State::Null);
    }
}
