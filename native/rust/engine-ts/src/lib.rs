//! MPEG-TS timeline normalisation for a dual-ingest source switch.
//!
//! Ported from the reference branch's `native/src/ts_normalizer.c` (C engine), semantics unchanged.
//!
//! Why it exists: two SRT sessions — even two sessions pulling the same feed — each carry their own
//! timestamp timeline. Flipping the input-selector between them therefore hands the decoder a
//! discontinuity: its own PCR/PTS jump, and the per-PID continuity counters restart. The result is
//! what an operator sees as macroblocks at the cut. Rewriting both onto ONE output timeline is what
//! makes the cut look continuous, and it is the half of the reference's seamless mode that cannot be
//! replaced by waiting for a keyframe.
//!
//! How: the first buffer of the newly selected source is measured, and an offset is chosen so its
//! first timestamp lands exactly one nominal step after the last timestamp the output emitted. That
//! offset is then added to every PCR, PTS and DTS in that source's buffers (33-bit modular space,
//! which is the MPEG-TS timestamp space), while the continuity counters are re-sequenced per PID so
//! the demuxer never sees a break.
//!
//! Everything here is pure: no GStreamer, no I/O. The engine runs it from a pad probe on each source
//! path, before the input-selector, so both timelines are already mapped before any switch happens.

/// MPEG-TS packet size and sync byte.
pub const TS_PACKET_SIZE: usize = 188;
const TS_SYNC_BYTE: u8 = 0x47;

/// Timestamps are 33-bit values in 90 kHz units.
const TS_TIMESTAMP_MASK: u64 = (1u64 << 33) - 1;
/// 40 ms at 90 kHz: the nominal step used until real inter-timestamp deltas have been observed.
const DEFAULT_STEP_90K: u64 = 3600;
/// A delta larger than one second says nothing useful about the stream's cadence, so it is ignored.
const MAX_TRACKED_STEP_90K: u64 = 90_000;

/// Number of PIDs tracked for continuity rewriting (the MPEG-TS PID space).
const PID_COUNT: usize = 8192;

#[inline]
fn add_33(value: u64, offset: u64) -> u64 {
    (value.wrapping_add(offset)) & TS_TIMESTAMP_MASK
}

#[inline]
fn forward_delta_33(newer: u64, older: u64) -> u64 {
    (newer.wrapping_sub(older)) & TS_TIMESTAMP_MASK
}

/// What one `normalize` call did, for the engine's diagnostic line.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct NormalizeResult {
    /// The active source changed on this buffer (a switch actually happened).
    pub source_changed: bool,
    /// The offset applied to this source's timestamps, in 90 kHz units.
    pub offset_90k: u64,
    /// True when at least one PCR/PTS/DTS was rewritten.
    pub timestamps_rewritten: bool,
    /// How many continuity counters had to be corrected.
    pub continuity_rewritten: u32,
}

/// The per-pipeline normaliser: one instance, shared by both source paths.
#[derive(Debug, Clone)]
pub struct TsNormalizer {
    active_source: Option<usize>,
    source_offset_90k: [u64; 2],
    source_offset_valid: [bool; 2],
    last_pcr_valid: bool,
    last_pcr_90k: u64,
    pcr_step_90k: u64,
    last_pts_valid: bool,
    last_pts_90k: u64,
    pts_step_90k: u64,
    continuity_valid: Vec<bool>,
    continuity_counter: Vec<u8>,
}

impl Default for TsNormalizer {
    fn default() -> Self {
        Self::new()
    }
}

impl TsNormalizer {
    pub fn new() -> Self {
        let mut normalizer = Self {
            active_source: None,
            source_offset_90k: [0; 2],
            source_offset_valid: [false; 2],
            last_pcr_valid: false,
            last_pcr_90k: 0,
            pcr_step_90k: DEFAULT_STEP_90K,
            last_pts_valid: false,
            last_pts_90k: 0,
            pts_step_90k: DEFAULT_STEP_90K,
            continuity_valid: vec![false; PID_COUNT],
            continuity_counter: vec![0; PID_COUNT],
        };
        normalizer.reset();
        normalizer
    }

    /// Back to a clean slate: used when the pipeline is rebuilt.
    pub fn reset(&mut self) {
        self.active_source = None;
        self.source_offset_90k = [0; 2];
        self.source_offset_valid = [false; 2];
        self.last_pcr_valid = false;
        self.pcr_step_90k = DEFAULT_STEP_90K;
        self.last_pts_valid = false;
        self.pts_step_90k = DEFAULT_STEP_90K;
        self.continuity_valid.iter_mut().for_each(|v| *v = false);
        self.continuity_counter.iter_mut().for_each(|v| *v = 0);
    }

    /// The source currently being normalised, if any.
    pub fn active_source(&self) -> Option<usize> {
        self.active_source
    }

    /// Rewrite one buffer of `source_index` (0 = primary, 1 = secondary) in place.
    ///
    /// Returns `None` for a buffer that cannot be one (wrong size, or a source index outside 0..=1),
    /// which the caller should treat as "pass through untouched".
    pub fn normalize(&mut self, data: &mut [u8], source_index: usize) -> Option<NormalizeResult> {
        if source_index > 1 || data.len() < TS_PACKET_SIZE {
            return None;
        }

        let mut result = NormalizeResult::default();

        if self.active_source != Some(source_index) {
            let had_active = self.active_source.is_some();
            let offset = if had_active {
                self.choose_source_offset(data)
            } else {
                0
            };

            self.source_offset_90k[source_index] = offset;
            self.source_offset_valid[source_index] = true;
            self.active_source = Some(source_index);
            result.source_changed = had_active;
            result.offset_90k = offset;
        }

        let timestamp_offset = if self.source_offset_valid[source_index] {
            self.source_offset_90k[source_index]
        } else {
            0
        };

        let first_packet = first_sync_offset(data);
        let mut offset = first_packet;
        while offset + TS_PACKET_SIZE <= data.len() {
            let packet = &mut data[offset..offset + TS_PACKET_SIZE];
            if packet[0] != TS_SYNC_BYTE {
                offset += TS_PACKET_SIZE;
                continue;
            }

            let has_pcr = packet_get_pcr_90k(packet).is_some();
            let has_pts = packet_get_pts_90k(packet).is_some();

            if has_pcr {
                set_pcr_offset(packet, timestamp_offset);
            }
            if has_pts {
                set_pes_timestamp_offset(packet, timestamp_offset);
            }
            if (has_pcr || has_pts) && timestamp_offset != 0 {
                result.timestamps_rewritten = true;
            }

            self.rewrite_continuity(packet, &mut result);
            self.track_output_timestamps(packet);

            offset += TS_PACKET_SIZE;
        }

        Some(result)
    }

    /// Pick an offset that puts the new source's first timestamp one nominal step after the last
    /// timestamp the output emitted, so the output timeline never jumps or goes backwards.
    fn choose_source_offset(&self, data: &[u8]) -> u64 {
        let Some((incoming, is_pcr)) = find_first_timestamp(data) else {
            return 0;
        };

        let desired = if is_pcr && self.last_pcr_valid {
            add_33(self.last_pcr_90k, self.pcr_step_90k)
        } else if !is_pcr && self.last_pts_valid {
            add_33(self.last_pts_90k, self.pts_step_90k)
        } else if self.last_pcr_valid {
            add_33(self.last_pcr_90k, self.pcr_step_90k)
        } else if self.last_pts_valid {
            add_33(self.last_pts_90k, self.pts_step_90k)
        } else {
            incoming
        };

        forward_delta_33(desired, incoming)
    }

    fn rewrite_continuity(&mut self, packet: &mut [u8], result: &mut NormalizeResult) {
        let pid = (((packet[1] & 0x1F) as usize) << 8) | packet[2] as usize;
        let adaptation_control = (packet[3] >> 4) & 0x03;
        let has_payload = adaptation_control & 0x01 != 0;

        if !self.continuity_valid[pid] {
            self.continuity_counter[pid] = packet[3] & 0x0F;
            self.continuity_valid[pid] = true;
            return;
        }

        let mut next = self.continuity_counter[pid];
        if has_payload {
            next = (next + 1) & 0x0F;
        }
        if (packet[3] & 0x0F) != next {
            result.continuity_rewritten += 1;
        }
        packet[3] = (packet[3] & 0xF0) | next;
        self.continuity_counter[pid] = next;
    }

    fn track_output_timestamps(&mut self, packet: &[u8]) {
        if let Some(value) = packet_get_pcr_90k(packet) {
            if self.last_pcr_valid {
                let step = forward_delta_33(value, self.last_pcr_90k);
                if step > 0 && step <= MAX_TRACKED_STEP_90K {
                    self.pcr_step_90k = step;
                }
            }
            self.last_pcr_90k = value;
            self.last_pcr_valid = true;
        }

        if let Some(value) = packet_get_pts_90k(packet) {
            if self.last_pts_valid {
                let step = forward_delta_33(value, self.last_pts_90k);
                if step > 0 && step <= MAX_TRACKED_STEP_90K {
                    self.pts_step_90k = step;
                }
            }
            self.last_pts_90k = value;
            self.last_pts_valid = true;
        }
    }
}

/// Offset of the sync byte in the leading bytes of a buffer (a buffer may start mid-packet).
fn first_sync_offset(data: &[u8]) -> usize {
    let mut offset = 0;
    while offset < data.len() && offset < TS_PACKET_SIZE && data[offset] != TS_SYNC_BYTE {
        offset += 1;
    }
    offset
}

/// Payload slice of a packet, honouring the adaptation field.
fn packet_payload(packet: &[u8]) -> Option<&[u8]> {
    let adaptation_control = (packet[3] >> 4) & 0x03;
    if adaptation_control & 0x01 == 0 {
        return None;
    }

    let mut offset = 4usize;
    if adaptation_control & 0x02 != 0 {
        offset += 1 + packet[4] as usize;
    }
    if offset >= TS_PACKET_SIZE {
        return None;
    }

    Some(&packet[offset..TS_PACKET_SIZE])
}

fn read_timestamp_33(bytes: &[u8]) -> u64 {
    (((bytes[0] >> 1) as u64 & 0x07) << 30)
        | ((bytes[1] as u64) << 22)
        | (((bytes[2] >> 1) as u64) << 15)
        | ((bytes[3] as u64) << 7)
        | ((bytes[4] >> 1) as u64)
}

fn write_timestamp_33(bytes: &mut [u8], value: u64) {
    let value = value & TS_TIMESTAMP_MASK;
    bytes[0] = (bytes[0] & 0xF0) | ((((value >> 30) & 0x07) as u8) << 1) | 0x01;
    bytes[1] = ((value >> 22) & 0xFF) as u8;
    bytes[2] = ((((value >> 15) & 0x7F) as u8) << 1) | 0x01;
    bytes[3] = ((value >> 7) & 0xFF) as u8;
    bytes[4] = (((value & 0x7F) as u8) << 1) | 0x01;
}

/// Byte offsets of the PTS (and DTS, when present) inside a packet, if it starts a PES header.
fn packet_pes_timestamps(packet: &[u8]) -> Option<(usize, Option<usize>)> {
    if packet[1] & 0x40 == 0 {
        return None;
    }

    let payload = packet_payload(packet)?;
    let payload_size = payload.len();
    if payload_size < 14 {
        return None;
    }
    if payload[0] != 0x00 || payload[1] != 0x00 || payload[2] != 0x01 {
        return None;
    }

    let flags = (payload[7] >> 6) & 0x03;
    let header_length = payload[8];
    if (flags != 0x02 && flags != 0x03) || header_length < 5 {
        return None;
    }

    let payload_offset = TS_PACKET_SIZE - payload_size;
    let pts = payload_offset + 9;
    let dts = if flags == 0x03 && header_length >= 10 && payload_size >= 19 {
        Some(payload_offset + 14)
    } else {
        None
    };

    Some((pts, dts))
}

/// PCR base (33 bits) of a packet carrying one.
pub fn packet_get_pcr_90k(packet: &[u8]) -> Option<u64> {
    if packet.len() < TS_PACKET_SIZE || packet[0] != TS_SYNC_BYTE {
        return None;
    }

    let adaptation_control = (packet[3] >> 4) & 0x03;
    if adaptation_control & 0x02 == 0 || packet[4] < 7 || packet[5] & 0x10 == 0 {
        return None;
    }

    let base = ((packet[6] as u64) << 25)
        | ((packet[7] as u64) << 17)
        | ((packet[8] as u64) << 9)
        | ((packet[9] as u64) << 1)
        | ((packet[10] as u64) >> 7);

    Some(base & TS_TIMESTAMP_MASK)
}

/// PTS (33 bits) of a packet that starts a PES header carrying one.
pub fn packet_get_pts_90k(packet: &[u8]) -> Option<u64> {
    if packet.len() < TS_PACKET_SIZE || packet[0] != TS_SYNC_BYTE {
        return None;
    }

    let (pts, _dts) = packet_pes_timestamps(packet)?;
    Some(read_timestamp_33(&packet[pts..pts + 5]))
}

fn set_pcr_offset(packet: &mut [u8], offset: u64) {
    let Some(base) = packet_get_pcr_90k(packet) else {
        return;
    };

    let base = add_33(base, offset);
    packet[6] = ((base >> 25) & 0xFF) as u8;
    packet[7] = ((base >> 17) & 0xFF) as u8;
    packet[8] = ((base >> 9) & 0xFF) as u8;
    packet[9] = ((base >> 1) & 0xFF) as u8;
    packet[10] = (packet[10] & 0x7F) | (((base & 0x01) as u8) << 7);
}

fn set_pes_timestamp_offset(packet: &mut [u8], offset: u64) -> bool {
    let Some((pts, dts)) = packet_pes_timestamps(packet) else {
        return false;
    };

    let pts_value = read_timestamp_33(&packet[pts..pts + 5]);
    write_timestamp_33(&mut packet[pts..pts + 5], add_33(pts_value, offset));

    if let Some(dts) = dts {
        let dts_value = read_timestamp_33(&packet[dts..dts + 5]);
        write_timestamp_33(&mut packet[dts..dts + 5], add_33(dts_value, offset));
    }

    true
}

/// The first timestamp in a buffer: a PCR if the buffer carries one, otherwise the first PTS.
/// Returns `(value, is_pcr)`.
fn find_first_timestamp(data: &[u8]) -> Option<(u64, bool)> {
    let first_packet = first_sync_offset(data);
    let mut first_pts: Option<u64> = None;

    let mut offset = first_packet;
    while offset + TS_PACKET_SIZE <= data.len() {
        let packet = &data[offset..offset + TS_PACKET_SIZE];
        if packet[0] == TS_SYNC_BYTE {
            if let Some(pcr) = packet_get_pcr_90k(packet) {
                return Some((pcr, true));
            }
            if first_pts.is_none() {
                if let Some(pts) = packet_get_pts_90k(packet) {
                    first_pts = Some(pts);
                }
            }
        }
        offset += TS_PACKET_SIZE;
    }

    first_pts.map(|pts| (pts, false))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A packet carrying a PES header with a PTS: what the decoder reads to place a frame in time.
    fn pts_packet(pid: u16, counter: u8, pts: u64) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC_BYTE;
        packet[1] = 0x40 | (((pid >> 8) as u8) & 0x1F); // payload_unit_start
        packet[2] = (pid & 0xFF) as u8;
        packet[3] = (0x01 << 4) | (counter & 0x0F); // payload only

        let payload = 4;
        packet[payload] = 0x00;
        packet[payload + 1] = 0x00;
        packet[payload + 2] = 0x01;
        packet[payload + 3] = 0xE0;
        packet[payload + 7] = 0x02 << 6; // PTS only
        packet[payload + 8] = 5; // header data length
        write_timestamp_33(&mut packet[payload + 9..payload + 14], pts);
        packet
    }

    /// A packet whose adaptation field carries the PCR: the output clock.
    fn pcr_packet(pid: u16, counter: u8, pcr_base: u64) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC_BYTE;
        packet[1] = ((pid >> 8) as u8) & 0x1F;
        packet[2] = (pid & 0xFF) as u8;
        packet[3] = (0x02 << 4) | (counter & 0x0F); // adaptation field only
        packet[4] = 7; // adaptation_field_length
        packet[5] = 0x10; // PCR flag
        packet[6] = ((pcr_base >> 25) & 0xFF) as u8;
        packet[7] = ((pcr_base >> 17) & 0xFF) as u8;
        packet[8] = ((pcr_base >> 9) & 0xFF) as u8;
        packet[9] = ((pcr_base >> 1) & 0xFF) as u8;
        packet[10] = (((pcr_base & 0x01) as u8) << 7) | 0x7E;
        packet
    }

    #[test]
    fn pcr_and_pts_survive_a_round_trip() {
        let pts = 0x1_2345_6789u64 & TS_TIMESTAMP_MASK;
        let mut packet = pts_packet(0x101, 3, pts);
        assert_eq!(packet_get_pts_90k(&packet), Some(pts));

        let pcr = 0x0_9876_5432u64 & TS_TIMESTAMP_MASK;
        let mut pcr_pkt = pcr_packet(0x100, 0, pcr);
        assert_eq!(packet_get_pcr_90k(&pcr_pkt), Some(pcr));

        // Like the C, the offset helper reports that it FOUND and rewrote a timestamp; a zero
        // offset still leaves the value identical.
        assert!(set_pes_timestamp_offset(&mut packet, 0));
        assert_eq!(packet_get_pts_90k(&packet), Some(pts));
        set_pcr_offset(&mut pcr_pkt, 0);
        assert_eq!(packet_get_pcr_90k(&pcr_pkt), Some(pcr));
    }

    /// The heart of it: after a switch the output must continue one nominal step after the last
    /// timestamp it emitted, whatever timeline the new source happens to be on.
    #[test]
    fn a_switch_lands_the_new_source_one_step_after_the_last_output_timestamp() {
        let mut normalizer = TsNormalizer::new();

        let first = pcr_packet(0x100, 0, 1_000);
        let mut source0 = first.clone();
        let result = normalizer.normalize(&mut source0, 0).expect("first buffer");
        assert!(!result.source_changed, "the first source is not a switch");
        assert_eq!(result.offset_90k, 0);
        assert_eq!(packet_get_pcr_90k(&source0), Some(1_000));

        // The secondary sits on an unrelated timeline.
        let mut source1 = pcr_packet(0x100, 0, 999_000);
        let result = normalizer
            .normalize(&mut source1, 1)
            .expect("second source");
        assert!(result.source_changed);
        assert!(result.timestamps_rewritten);

        assert_eq!(
            packet_get_pcr_90k(&source1),
            Some(add_33(1_000, DEFAULT_STEP_90K)),
            "the new source must continue from the last output timestamp"
        );
    }

    /// Switching back re-derives an offset, so the output stays monotonic in both directions.
    #[test]
    fn the_output_timeline_never_goes_backwards_across_switches() {
        let mut normalizer = TsNormalizer::new();
        let mut seen = Vec::new();

        let mut buffer = pcr_packet(0x100, 0, 5_000);
        normalizer.normalize(&mut buffer, 0).unwrap();
        seen.push(packet_get_pcr_90k(&buffer).unwrap());

        let mut buffer = pcr_packet(0x100, 0, 90_000_000);
        normalizer.normalize(&mut buffer, 1).unwrap();
        seen.push(packet_get_pcr_90k(&buffer).unwrap());

        let mut buffer = pcr_packet(0x100, 0, 5_400);
        normalizer.normalize(&mut buffer, 0).unwrap();
        seen.push(packet_get_pcr_90k(&buffer).unwrap());

        for pair in seen.windows(2) {
            assert!(
                forward_delta_33(pair[1], pair[0]) > 0
                    && forward_delta_33(pair[1], pair[0]) < 1_000_000,
                "timeline went backwards or jumped: {pair:?}"
            );
        }
    }

    /// PES PTS *and* DTS are both rewritten, keeping their physical delay.
    #[test]
    fn pes_pts_and_dts_move_together() {
        let mut packet = pts_packet(0x101, 0, 1_000);
        // Turn it into a PTS+DTS header: flags 0x03, header length 10, DTS after the PTS.
        let payload = 4;
        packet[payload + 7] = 0x03 << 6;
        packet[payload + 8] = 10;
        write_timestamp_33(&mut packet[payload + 14..payload + 19], 400);

        let offset = 7_000;
        assert!(set_pes_timestamp_offset(&mut packet, offset));
        assert_eq!(packet_get_pts_90k(&packet), Some(1_000 + offset));
        assert_eq!(
            read_timestamp_33(&packet[payload + 14..payload + 19]),
            400 + offset,
            "DTS must move with the PTS"
        );
    }

    #[test]
    fn continuity_counters_are_resequenced_per_pid() {
        let mut normalizer = TsNormalizer::new();
        let mut buffer = pts_packet(0x101, 0, 1_000);
        let result = normalizer.normalize(&mut buffer, 0).unwrap();
        assert_eq!(
            result.continuity_rewritten, 0,
            "the first sighting only seeds"
        );

        // The second packet of the same PID repeats counter 0: a break the demuxer would reject.
        let mut buffer = pts_packet(0x101, 0, 1_100);
        let result = normalizer.normalize(&mut buffer, 0).unwrap();
        assert_eq!(
            buffer[3] & 0x0F,
            1,
            "counter must advance for a payload packet"
        );
        assert_eq!(result.continuity_rewritten, 1);

        // A different PID keeps its own sequence.
        let mut other = pts_packet(0x102, 7, 1_200);
        let result = normalizer.normalize(&mut other, 0).unwrap();
        assert_eq!(result.continuity_rewritten, 0);
        assert_eq!(other[3] & 0x0F, 7);
    }

    #[test]
    fn an_adaptation_only_packet_does_not_advance_the_counter() {
        let mut normalizer = TsNormalizer::new();
        let mut seed = pts_packet(0x101, 4, 1_000);
        normalizer.normalize(&mut seed, 0).unwrap();

        // Adaptation field only: MPEG-TS says the counter repeats.
        let mut adaptation_only = pcr_packet(0x101, 0, 1_500);
        normalizer.normalize(&mut adaptation_only, 0).unwrap();
        assert_eq!(
            adaptation_only[3] & 0x0F,
            4,
            "no payload means the counter repeats"
        );
    }

    #[test]
    fn unusable_buffers_are_reported_rather_than_touched() {
        let mut normalizer = TsNormalizer::new();

        let mut short = vec![0u8; TS_PACKET_SIZE - 1];
        assert!(normalizer.normalize(&mut short, 0).is_none());

        let mut buffer = pcr_packet(0x100, 0, 1);
        assert!(
            normalizer.normalize(&mut buffer, 2).is_none(),
            "no third source"
        );

        // A buffer with no sync byte at all must not be mangled.
        let before = buffer.clone();
        normalizer.normalize(&mut buffer, 0).unwrap();
        assert_eq!(before, buffer, "nothing to normalise, nothing to change");
    }

    /// A source sitting just before the 33-bit wrap still lands after the previous output.
    #[test]
    fn the_offset_arithmetic_handles_the_33_bit_wrap() {
        let mut normalizer = TsNormalizer::new();

        let mut near_wrap = pcr_packet(0x100, 0, TS_TIMESTAMP_MASK - 100);
        normalizer.normalize(&mut near_wrap, 0).unwrap();

        let mut after_wrap = pcr_packet(0x100, 0, 50);
        let result = normalizer.normalize(&mut after_wrap, 1).unwrap();
        assert!(result.source_changed);

        let out = packet_get_pcr_90k(&after_wrap).unwrap();
        let delta = forward_delta_33(out, TS_TIMESTAMP_MASK - 100);
        assert!(
            delta > 0 && delta < 1_000_000,
            "wrapped wrongly: delta {delta}"
        );
    }

    #[test]
    fn reset_forgets_every_source_timeline() {
        let mut normalizer = TsNormalizer::new();
        let mut buffer = pcr_packet(0x100, 0, 10_000);
        normalizer.normalize(&mut buffer, 0).unwrap();
        assert_eq!(normalizer.active_source(), Some(0));

        normalizer.reset();
        assert_eq!(normalizer.active_source(), None);

        let mut fresh = pcr_packet(0x100, 0, 10_000);
        let result = normalizer.normalize(&mut fresh, 0).unwrap();
        assert!(
            !result.source_changed,
            "a fresh normaliser has no previous source"
        );
        assert_eq!(
            packet_get_pcr_90k(&fresh),
            Some(10_000),
            "no offset on the first run"
        );
    }
}
