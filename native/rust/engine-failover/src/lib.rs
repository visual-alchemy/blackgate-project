use gstreamer::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    /// Holds an in-process switch until the target source proves it is cuttable, and keeps the
    /// output timeline continuous across the change. See [`SeamlessSwitch`].
    seamless: SeamlessSwitch,
}

impl SelectorState {
    /// `secondary_joined` must reflect the real pipeline state: builder.rs holds the
    /// secondary at NULL when `auto_join` is false, so the engine must be told.
    /// Hardcoding `true` here made `join-secondary` a silent no-op on
    /// auto_join=false routes — the switch reported success while the secondary
    /// stayed NULL.
    /// `active` is the selection the route was started with (`active_source` from Elixir), so the
    /// seamless state and the selector agree from the first buffer instead of assuming primary.
    pub fn new(
        selector: gstreamer::Element,
        secondary: gstreamer::Element,
        auto_join: bool,
        active: SourceTarget,
    ) -> Self {
        Self {
            selector,
            secondary,
            active,
            // builder.rs holds the secondary at NULL when auto_join is false, so the selector cannot
            // already be on it in that case.
            secondary_joined: auto_join || active == SourceTarget::Secondary,
            auto_join,
            seamless: SeamlessSwitch::new(active),
        }
    }

    /// `switch-source`: ask for a source change. It does NOT move the selector now - the change
    /// completes in [`Self::feed_source`] once the target source carries a keyframe, which is what
    /// keeps the cut invisible. Manual failover still gets the keyframe wait, because a cut to a
    /// source that has not produced a keyframe is the macroblock case.
    pub fn request_switch(&mut self, target: SourceTarget) -> bool {
        self.seamless.request(target)
    }

    /// The switch that is waiting for its keyframe, if any.
    pub fn pending_switch(&self) -> Option<SourceTarget> {
        self.seamless.pending()
    }

    /// Feed one buffer from one source (index 0 = primary, 1 = secondary). Returns the signal when
    /// this buffer completed or refused a requested change; the caller may report it, and the
    /// selector has already been moved when it did.
    pub fn feed_source(&mut self, index: usize, segment: &[u8]) -> Option<SwitchSignal> {
        let signal = self.seamless.on_source_segment(index, segment);

        match signal {
            Some(SwitchSignal::Switched(target)) => self.switch_to(target),
            Some(SwitchSignal::Rejected(target, reason)) => {
                println!("SOURCE_SWITCH_REJECTED:{}:{}", target.as_str(), reason);
            }
            None => {}
        }

        signal
    }

    /// Rewrite one buffer of the SELECTED source so the output timeline stays continuous.
    pub fn normalize(&mut self, data: &mut [u8]) -> Option<engine_ts::NormalizeResult> {
        self.seamless.normalize(data)
    }

    /// Probe both sources and the tee. Call after the pipeline is built; GStreamer accepts probes on
    /// a running pad, so this does not need to happen before it goes PLAYING.
    pub fn install_probes(
        state: &std::sync::Arc<std::sync::Mutex<Option<SelectorState>>>,
        primary: &gstreamer::Element,
        secondary: &gstreamer::Element,
        tee: &gstreamer::Element,
    ) {
        // A single-source pipeline has neither a selector to move nor a second timeline to
        // normalise, so nothing is installed there.
        match state.lock() {
            Ok(guard) if guard.is_some() => {}
            _ => return,
        }

        // Per source, on the source's own src pad: what the selector picks between, so programme
        // identity and keyframes are learned BEFORE any switch decision is taken.
        for (index, element) in [(0usize, primary), (1usize, secondary)] {
            let Some(pad) = element.static_pad("src") else {
                continue;
            };
            let state = state.clone();
            pad.add_probe(gstreamer::PadProbeType::BUFFER, move |_pad, info| {
                let Some(buffer) = info.buffer() else {
                    return gstreamer::PadProbeReturn::Ok;
                };
                let Ok(map) = buffer.map_readable() else {
                    return gstreamer::PadProbeReturn::Ok;
                };
                let Ok(mut guard) = state.lock() else {
                    return gstreamer::PadProbeReturn::Ok;
                };
                let Some(state) = guard.as_mut() else {
                    return gstreamer::PadProbeReturn::Ok;
                };
                let _ = state.feed_source(index, map.as_slice());
                gstreamer::PadProbeReturn::Ok
            });
        }

        // The tee's sink pad is downstream of the selector, so a buffer here carries whichever source
        // is active: exactly where the output timeline has to be made continuous.
        let Some(pad) = tee.static_pad("sink") else {
            return;
        };
        let state = state.clone();
        // A buffer that some other element still holds cannot be rewritten in place. Say so once
        // rather than skipping the normalisation silently, because a silent skip looks exactly like
        // a working switch with macroblocks in it.
        let shared = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        pad.add_probe(gstreamer::PadProbeType::BUFFER, move |_pad, info| {
            let Some(buffer) = info.buffer_mut() else {
                return gstreamer::PadProbeReturn::Ok;
            };
            let Some(buffer) = buffer.get_mut() else {
                if !shared.swap(true, std::sync::atomic::Ordering::Relaxed) {
                    eprintln!(
                        "[seamless] tee buffer is shared, so the timeline cannot be rewritten in \
                         place; switches will not be seamless"
                    );
                }
                return gstreamer::PadProbeReturn::Ok;
            };
            let Ok(mut map) = buffer.map_writable() else {
                return gstreamer::PadProbeReturn::Ok;
            };
            let Ok(mut guard) = state.lock() else {
                return gstreamer::PadProbeReturn::Ok;
            };
            let Some(state) = guard.as_mut() else {
                return gstreamer::PadProbeReturn::Ok;
            };

            if let Some(result) = state.normalize(map.as_mut_slice()) {
                if result.source_changed {
                    println!(
                        "TS_TIMELINE_NORMALIZED:{} offset-90k={} continuity-rewritten={}",
                        state.active().as_str(),
                        result.offset_90k,
                        result.continuity_rewritten
                    );
                }
            }
            gstreamer::PadProbeReturn::Ok
        });
    }

    /// switch-source: point input-selector active-pad at sink_0/sink_1.
    /// Prints "SOURCE_SWITCHED:<target>" (stdout, Elixir-parsed).
    ///
    /// C lite 2404-2431 keeps the auto_join=false lifecycle atomic in native code:
    /// the secondary must be running before the selector moves to it, and must be
    /// stopped only after the selector has moved back to primary.
    /// Move the selector for real, with the auto_join=false join/leave lifecycle. Reached only when
    /// a switch has been decided (see [`Self::feed_source`]).
    fn switch_to(&mut self, target: SourceTarget) {
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

use engine_ts::{
    packet_payload, packet_pid, EsScanner, PendingSwitch, ProgramTracker, SwitchOutcome,
    TsNormalizer, TS_PACKET_SIZE,
};

impl SourceTarget {
    pub fn index(self) -> usize {
        match self {
            SourceTarget::Primary => 0,
            SourceTarget::Secondary => 1,
        }
    }

    pub fn from_index(index: usize) -> Option<Self> {
        match index {
            0 => Some(SourceTarget::Primary),
            1 => Some(SourceTarget::Secondary),
            _ => None,
        }
    }
}

/// What the pipeline must do after a buffer was fed to the seamless state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchSignal {
    /// Move the selector to this source now; the caller also reports `SOURCE_SWITCHED`.
    Switched(SourceTarget),
    /// The requested source cannot be cut to; the caller reports the rejection and falls back.
    Rejected(SourceTarget, &'static str),
}

/// The guarded seamless switch.
///
/// It keeps both sources' program identity (PAT/PMT) and elementary-stream scanners, holds a requested
/// source change until the TARGET source carries a keyframe, and normalises the output timeline so the
/// decoder never sees the change. Everything is returned as a [`SwitchSignal`] instead of touching
/// GStreamer here, so the whole flow can be exercised by feeding transport packets - which is exactly
/// how it is tested.
pub struct SeamlessSwitch {
    trackers: [ProgramTracker; 2],
    scanners: [EsScanner; 2],
    pending: PendingSwitch,
    normalizer: TsNormalizer,
    active: usize,
}

impl SeamlessSwitch {
    pub fn new(active: SourceTarget) -> Self {
        Self {
            trackers: [ProgramTracker::new(), ProgramTracker::new()],
            scanners: [EsScanner::new(), EsScanner::new()],
            pending: PendingSwitch::new(),
            normalizer: TsNormalizer::new(),
            active: active.index(),
        }
    }

    pub fn active(&self) -> SourceTarget {
        SourceTarget::from_index(self.active).unwrap_or(SourceTarget::Primary)
    }

    pub fn pending(&self) -> Option<SourceTarget> {
        self.pending.pending().and_then(SourceTarget::from_index)
    }

    /// Ask for a source change. Nothing moves yet: the selector follows only once the target source is
    /// proven cuttable. Returns false when this is not actually a change.
    pub fn request(&mut self, target: SourceTarget) -> bool {
        matches!(
            self.pending.request(target.index(), self.active),
            SwitchOutcome::Waiting
        ) && self.pending.pending() == Some(target.index())
    }

    /// Forget a request (a pipeline rebuild, or a stop).
    pub fn clear_pending(&mut self) {
        self.pending.clear();
    }

    /// Feed one buffer of one source. Returns a signal when this buffer completed (or refused) a
    /// requested change.
    pub fn on_source_segment(&mut self, source: usize, segment: &[u8]) -> Option<SwitchSignal> {
        if source > 1 {
            return None;
        }

        let mut keyframe = false;
        let mut offset = 0usize;

        while offset + TS_PACKET_SIZE <= segment.len() {
            let packet = &segment[offset..offset + TS_PACKET_SIZE];
            offset += TS_PACKET_SIZE;

            self.trackers[source].feed_packet(packet);

            // Only the video elementary stream can carry a picture boundary.
            let Some(pid) = packet_pid(packet) else {
                continue;
            };
            if Some(pid) != self.trackers[source].video_pid() {
                continue;
            }

            let Some(payload) = packet_payload(packet) else {
                continue;
            };

            self.scanners[source].set_kind(self.trackers[source].stream_kind());
            let scan = self.scanners[source].scan(payload);
            if let Some(hash) = scan.config_hash {
                self.trackers[source].set_config_hash(hash);
            }
            if scan.keyframe {
                keyframe = true;
            }
        }

        let _ = self.trackers[source].take_changed();

        if !keyframe {
            return None;
        }

        let target = self.pending.pending()?;
        let compatible = self.trackers[0]
            .map()
            .compatible_with(&self.trackers[1].map());
        let target_ready = self.trackers[target].map().is_ready();

        match self.pending.on_keyframe(source, compatible, target_ready) {
            SwitchOutcome::Switch(index) => {
                self.active = index;
                Some(SwitchSignal::Switched(SourceTarget::from_index(index)?))
            }
            SwitchOutcome::Rejected(reason) => Some(SwitchSignal::Rejected(
                SourceTarget::from_index(source)?,
                reason,
            )),
            SwitchOutcome::Waiting => None,
        }
    }

    /// Rewrite one buffer of the currently selected source so the output timeline stays continuous.
    pub fn normalize(&mut self, data: &mut [u8]) -> Option<engine_ts::NormalizeResult> {
        self.normalizer.normalize(data, self.active)
    }

    /// Back to a clean slate; used when a pipeline is rebuilt.
    pub fn reset(&mut self) {
        self.normalizer.reset();
        self.pending.clear();
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

        let mut off = SelectorState::new(
            selector.clone(),
            secondary.clone(),
            false,
            SourceTarget::Primary,
        );
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
        let mut on = SelectorState::new(selector, secondary, true, SourceTarget::Primary);
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

#[cfg(test)]
mod seamless_tests {
    use super::*;

    const TS_SYNC: u8 = 0x47;

    /// A PSI packet: sync + PID + payload_unit_start + pointer_field + section.
    fn psi_packet(pid: u16, section: &[u8]) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC;
        packet[1] = 0x40 | (((pid >> 8) as u8) & 0x1F);
        packet[2] = (pid & 0xFF) as u8;
        packet[3] = 0x01 << 4;
        packet[4] = 0x00;
        packet[5..5 + section.len()].copy_from_slice(section);
        packet
    }

    fn pat_section(pmt_pid: u16) -> Vec<u8> {
        let mut section = vec![0x00u8, 0x00, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00];
        section.push(0x00);
        section.push(0x01); // program 1
        section.push(0xE0 | ((pmt_pid >> 8) as u8 & 0x1F));
        section.push((pmt_pid & 0xFF) as u8);
        let len = section.len() - 3 + 4;
        section[1] = 0xB0 | (((len >> 8) & 0x0F) as u8);
        section[2] = (len & 0xFF) as u8;
        section.extend_from_slice(&[0, 0, 0, 0]);
        section
    }

    fn pmt_section(video_pid: u16, stream_type: u8) -> Vec<u8> {
        let mut section = vec![
            0x02u8, 0x00, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0, 0x01, 0xF0, 0x00,
        ];
        section.push(stream_type);
        section.push(0xE0 | ((video_pid >> 8) as u8 & 0x1F));
        section.push((video_pid & 0xFF) as u8);
        section.push(0xF0);
        section.push(0x00);
        let len = section.len() - 3 + 4;
        section[1] = 0xB0 | (((len >> 8) & 0x0F) as u8);
        section[2] = (len & 0xFF) as u8;
        section.extend_from_slice(&[0, 0, 0, 0]);
        section
    }

    /// A video packet carrying an elementary stream starting at a PES header.
    fn pes_packet(video_pid: u16, counter: u8, es: &[u8]) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC;
        packet[1] = 0x40 | (((video_pid >> 8) as u8) & 0x1F);
        packet[2] = (video_pid & 0xFF) as u8;
        packet[3] = (0x01 << 4) | (counter & 0x0F);

        let payload = 4;
        packet[payload] = 0x00;
        packet[payload + 1] = 0x00;
        packet[payload + 2] = 0x01;
        packet[payload + 3] = 0xE0; // video stream id
        packet[payload + 4] = 0x00; // PES length
        packet[payload + 5] = 0x00;
        packet[payload + 6] = 0x80;
        packet[payload + 7] = 0x00;
        packet[payload + 8] = 0x00;
        packet[payload + 9..payload + 9 + es.len()].copy_from_slice(es);
        packet
    }

    fn sps_es(marker: u8) -> Vec<u8> {
        let mut es = vec![0x00, 0x00, 0x01, 0x67];
        es.extend(std::iter::repeat_n(marker, 24));
        es
    }

    fn idr_es() -> Vec<u8> {
        let mut es = vec![0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00];
        es.extend(std::iter::repeat_n(0x33, 16));
        es
    }

    fn slice_es() -> Vec<u8> {
        let mut es = vec![0x00, 0x00, 0x01, 0x41, 0x9A, 0x00];
        es.extend(std::iter::repeat_n(0x44, 16));
        es
    }

    /// What one source's buffers look like: programme tables, then elementary-stream packets.
    fn segment(video_pid: u16, sps_marker: u8, payloads: &[Vec<u8>]) -> Vec<u8> {
        let pmt_pid = 0x0100;
        let mut segment = psi_packet(0x0000, &pat_section(pmt_pid));
        segment.extend(psi_packet(pmt_pid, &pmt_section(video_pid, 0x1B)));

        let mut counter = 0u8;
        for payload in payloads {
            segment.extend(pes_packet(video_pid, counter, payload));
            counter = (counter + 1) & 0x0F;
        }
        let _ = sps_marker;
        segment
    }

    #[test]
    fn a_switch_waits_for_the_target_keyframe_then_completes() {
        let mut seamless = SeamlessSwitch::new(SourceTarget::Primary);

        // Both sources report their programme and configuration, but only the primary has a keyframe.
        seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));
        seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));

        assert!(seamless.request(SourceTarget::Secondary));
        assert_eq!(seamless.pending(), Some(SourceTarget::Secondary));

        // A keyframe on the source we are LEAVING changes nothing.
        assert_eq!(
            seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[idr_es()])),
            None
        );
        assert_eq!(seamless.active(), SourceTarget::Primary);

        // The target's keyframe completes the switch.
        assert_eq!(
            seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[idr_es()])),
            Some(SwitchSignal::Switched(SourceTarget::Secondary))
        );
        assert_eq!(seamless.active(), SourceTarget::Secondary);
        assert_eq!(seamless.pending(), None);
    }

    #[test]
    fn a_target_that_never_shows_a_keyframe_never_completes() {
        let mut seamless = SeamlessSwitch::new(SourceTarget::Primary);
        seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));
        seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));

        seamless.request(SourceTarget::Secondary);
        assert_eq!(
            seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[slice_es()])),
            None
        );
        assert_eq!(
            seamless.active(),
            SourceTarget::Primary,
            "the active source keeps flowing"
        );
    }

    #[test]
    fn an_incompatible_program_is_rejected() {
        let mut seamless = SeamlessSwitch::new(SourceTarget::Primary);
        seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));
        // Same codec, different elementary stream: not a program that can be cut together.
        seamless.on_source_segment(1, &segment(0x0201, 0xAA, &[sps_es(0xAA)]));

        seamless.request(SourceTarget::Secondary);
        assert_eq!(
            seamless.on_source_segment(1, &segment(0x0201, 0xAA, &[idr_es()])),
            Some(SwitchSignal::Rejected(
                SourceTarget::Secondary,
                "incompatible-mpegts-map"
            ))
        );
        assert_eq!(seamless.active(), SourceTarget::Primary);
    }

    #[test]
    fn a_different_codec_configuration_is_also_incompatible() {
        let mut seamless = SeamlessSwitch::new(SourceTarget::Primary);
        seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));
        seamless.on_source_segment(1, &segment(0x0101, 0xBB, &[sps_es(0xBB)]));

        seamless.request(SourceTarget::Secondary);
        assert!(matches!(
            seamless.on_source_segment(1, &segment(0x0101, 0xBB, &[idr_es()])),
            Some(SwitchSignal::Rejected(_, "incompatible-mpegts-map"))
        ));
    }

    #[test]
    fn normalize_continues_the_output_timeline_across_a_switch() {
        let mut seamless = SeamlessSwitch::new(SourceTarget::Primary);
        seamless.on_source_segment(0, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));
        seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[sps_es(0xAA)]));

        // While the primary is still the active source, its clock sets the output timeline.
        let mut from_primary = pcr_segment(0x0101, 1_000);
        let first = seamless.normalize(&mut from_primary).expect("normalised");
        assert!(!first.source_changed, "the first buffer is not a switch");
        let first_pcr =
            engine_ts::packet_get_pcr_90k(&from_primary[0..TS_PACKET_SIZE]).expect("pcr");
        assert_eq!(
            first_pcr, 1_000,
            "no offset while the timeline is untouched"
        );

        seamless.request(SourceTarget::Secondary);
        assert_eq!(
            seamless.on_source_segment(1, &segment(0x0101, 0xAA, &[idr_es()])),
            Some(SwitchSignal::Switched(SourceTarget::Secondary))
        );

        // The secondary sits on an unrelated timeline; the output must not jump to it.
        let mut from_secondary = pcr_segment(0x0101, 900_000);
        let second = seamless.normalize(&mut from_secondary).expect("normalised");
        assert!(second.source_changed);
        assert!(second.timestamps_rewritten);

        let out = engine_ts::packet_get_pcr_90k(&from_secondary[0..TS_PACKET_SIZE]).expect("pcr");
        assert!(
            out > first_pcr && out - first_pcr < 100_000,
            "the output must continue just past {first_pcr}, not jump to 900000 (got {out})"
        );
    }

    fn pcr_segment(pid: u16, pcr_base: u64) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC;
        packet[1] = ((pid >> 8) as u8) & 0x1F;
        packet[2] = (pid & 0xFF) as u8;
        packet[3] = 0x02 << 4;
        packet[4] = 7;
        packet[5] = 0x10;
        packet[6] = ((pcr_base >> 25) & 0xFF) as u8;
        packet[7] = ((pcr_base >> 17) & 0xFF) as u8;
        packet[8] = ((pcr_base >> 9) & 0xFF) as u8;
        packet[9] = ((pcr_base >> 1) & 0xFF) as u8;
        packet[10] = (((pcr_base & 0x01) as u8) << 7) | 0x7E;
        packet
    }
}
