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

/// PID of a transport packet.
pub fn packet_pid(packet: &[u8]) -> Option<u16> {
    if packet.len() < TS_PACKET_SIZE || packet[0] != TS_SYNC_BYTE {
        return None;
    }
    Some((((packet[1] & 0x1F) as u16) << 8) | packet[2] as u16)
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
/// The payload slice of a packet, honouring the adaptation field (used by the per-source
/// probes as well, which is why it is public).
pub fn packet_payload(packet: &[u8]) -> Option<&[u8]> {
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

// ── Elementary-stream scan: is this payload a cut point, and what codec config is it? ────────────

/// Which elementary-stream codec the scan looks for, from the PMT's stream_type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamKind {
    H264,
    Hevc,
    Mpeg2,
    Unknown,
}

impl StreamKind {
    /// The MPEG-TS `stream_type` mapping (the C engine's STREAM_TYPE_* set).
    pub fn from_stream_type(stream_type: u8) -> Self {
        match stream_type {
            0x1B => StreamKind::H264,
            0x24 => StreamKind::Hevc,
            0x02 => StreamKind::Mpeg2,
            _ => StreamKind::Unknown,
        }
    }
}

/// Trailing payload bytes carried into the next scan: an elementary-stream start code can straddle
/// two buffers, and a scan that forgets them misses the keyframe at exactly the moment a switch is
/// waiting for it.
const ES_TAIL_LEN: usize = TS_PACKET_SIZE + 4;

/// FNV-1a over a codec configuration block. Only ever compared against another value produced here,
/// so the width is ours to choose: what matters is that two sources hash equal exactly when they
/// carry the same configuration.
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

/// What one payload scan found.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct EsScan {
    pub keyframe: bool,
    /// Set when this payload carried the codec configuration (SPS / sequence header).
    pub config_hash: Option<u64>,
}

/// Per-source elementary-stream scanner.
#[derive(Debug, Clone, Default)]
pub struct EsScanner {
    tail: Vec<u8>,
    kind: Option<StreamKind>,
    config_hash: Option<u64>,
}

impl EsScanner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_kind(&mut self, kind: StreamKind) {
        self.kind = Some(kind);
    }

    pub fn config_hash(&self) -> Option<u64> {
        self.config_hash
    }

    /// Scan one payload for a cut point (a random-access picture) and for the codec configuration.
    pub fn scan(&mut self, payload: &[u8]) -> EsScan {
        let mut scan = Vec::with_capacity(self.tail.len() + payload.len());
        scan.extend_from_slice(&self.tail);
        scan.extend_from_slice(payload);

        let mut found = EsScan::default();

        let mut i = 0usize;
        while i + 5 < scan.len() {
            if scan[i] != 0 || scan[i + 1] != 0 || scan[i + 2] != 1 {
                i += 1;
                continue;
            }

            let code = scan[i + 3];
            let available = scan.len() - (i + 3);

            match self.kind {
                Some(StreamKind::H264) => match code & 0x1F {
                    7 if available >= 12 => {
                        self.config_hash = Some(fnv1a(&scan[i + 3..i + 15]));
                        found.config_hash = self.config_hash;
                    }
                    5 => found.keyframe = true,
                    _ => {}
                },
                Some(StreamKind::Hevc) => match (code >> 1) & 0x3F {
                    33 if available >= 16 => {
                        self.config_hash = Some(fnv1a(&scan[i + 3..i + 19]));
                        found.config_hash = self.config_hash;
                    }
                    16..=21 => found.keyframe = true,
                    _ => {}
                },
                Some(StreamKind::Mpeg2) => {
                    if code == 0xB3 && available >= 8 {
                        self.config_hash = Some(fnv1a(&scan[i + 3..i + 11]));
                        found.config_hash = self.config_hash;
                    } else if code == 0x00 && ((scan[i + 5] >> 3) & 0x07) == 1 {
                        // Picture header: picture_coding_type 1 is an I picture.
                        found.keyframe = true;
                    }
                }
                // An unknown codec cannot be cut safely, so nothing is ever reported as a cut point.
                Some(StreamKind::Unknown) | None => {}
            }

            i += 1;
        }

        let keep = scan.len().min(ES_TAIL_LEN);
        self.tail = scan[scan.len() - keep..].to_vec();

        found
    }
}

// ── Program map: what has to match for two sources to be cut together ───────────────────────────

/// One source's MPEG-TS program identity, as far as a switch cares: the video elementary stream, its
/// codec, the audio set, and the codec configuration itself.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProgramMap {
    pub video_pid: u16,
    pub video_stream_type: u8,
    pub audio_pids: Vec<u16>,
    pub codec_config_hash: Option<u64>,
}

impl ProgramMap {
    /// Ready once the video stream and its codec configuration have both been seen. Until then there
    /// is nothing to compare, and a switch must wait rather than guess.
    pub fn is_ready(&self) -> bool {
        self.video_pid != 0 && self.codec_config_hash.is_some()
    }

    /// Two sources can be cut together only when the decoder would see the same program shape and the
    /// same codec configuration across the change: same video PID and stream type, same audio set,
    /// same SPS/sequence-header hash. Anything else is what the reference calls an incompatible
    /// MPEG-TS map, and it must fall back to rebuilding the pipeline.
    pub fn compatible_with(&self, other: &Self) -> bool {
        if !self.is_ready() || !other.is_ready() {
            return false;
        }

        let mut ours = self.audio_pids.clone();
        let mut theirs = other.audio_pids.clone();
        ours.sort_unstable();
        theirs.sort_unstable();

        self.video_pid == other.video_pid
            && self.video_stream_type == other.video_stream_type
            && ours == theirs
            && self.codec_config_hash == other.codec_config_hash
    }
}

// ── The guarded switch: hold the selector until the target source proves it is cuttable ─────────

/// What the caller should do after the pending state was fed an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchOutcome {
    /// Still waiting, or nothing was requested.
    Waiting,
    /// Move the selector to this source now and report `SOURCE_SWITCHED`.
    Switch(usize),
    /// The requested source cannot be cut to; report the rejection and fall back to a rebuild.
    Rejected(&'static str),
}

/// A requested source change that has not been acted on yet.
///
/// The switch is deliberately NOT performed when it is requested. It completes only once the TARGET
/// source has been observed to carry a keyframe, so the decoder starts on a clean picture, and only
/// when the two programs are compatible. Until then the active source keeps flowing - which is why
/// this costs neither a black gap nor macroblocks, the two failure modes measured on the operator's
/// box. The caller applies its own timeout: a request that never completes falls back to a rebuild.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PendingSwitch {
    pending: Option<usize>,
}

impl PendingSwitch {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending(&self) -> Option<usize> {
        self.pending
    }

    /// Ask to move to `target` (0 = primary, 1 = secondary). Requesting the active source is not a
    /// switch, and anything outside 0..=1 cannot be honoured.
    pub fn request(&mut self, target: usize, active: usize) -> SwitchOutcome {
        if target > 1 {
            return SwitchOutcome::Rejected("invalid target");
        }
        if target == active {
            self.pending = None;
            return SwitchOutcome::Waiting;
        }

        self.pending = Some(target);
        SwitchOutcome::Waiting
    }

    /// A keyframe was seen on `source`. Complete the switch when that source is the requested one and
    /// the programs are compatible; reject when it is the requested one but they are not; keep
    /// waiting while the target's program is not proven ready.
    pub fn on_keyframe(
        &mut self,
        source: usize,
        maps_compatible: bool,
        target_ready: bool,
    ) -> SwitchOutcome {
        if self.pending != Some(source) {
            return SwitchOutcome::Waiting;
        }

        if !target_ready {
            return SwitchOutcome::Waiting;
        }

        if !maps_compatible {
            self.pending = None;
            return SwitchOutcome::Rejected("incompatible-mpegts-map");
        }

        self.pending = None;
        SwitchOutcome::Switch(source)
    }

    /// Drop any request (a pipeline rebuild, or a stop).
    pub fn clear(&mut self) {
        self.pending = None;
    }
}

// ── Program identification: PAT → PMT → the elementary streams ───────────────────────────────────
//
// The per-source probes need to know which PID carries video before they can look for a cut point,
// and whether two sources carry the same program shape before a switch may complete. `engine-metadata`
// parses this too, but for its own (stats) purposes and privately; this is the small, testable slice
// the switch needs, kept here so the logic stays in one provable place.

/// Walks a transport stream's PSI far enough to identify the video and audio elementary streams.
#[derive(Debug, Default, Clone)]
pub struct ProgramTracker {
    pmt_pid: Option<u16>,
    map: ProgramMap,
    audio_pids: Vec<u16>,
    changed: bool,
}

impl ProgramTracker {
    pub const PAT_PID: u16 = 0x0000;

    pub fn new() -> Self {
        Self::default()
    }

    /// The program map as it is currently known.
    pub fn map(&self) -> ProgramMap {
        ProgramMap {
            audio_pids: self.audio_pids.clone(),
            ..self.map.clone()
        }
    }

    pub fn video_pid(&self) -> Option<u16> {
        if self.map.video_pid == 0 {
            None
        } else {
            Some(self.map.video_pid)
        }
    }

    /// Which codec the video stream carries.
    pub fn stream_kind(&self) -> StreamKind {
        StreamKind::from_stream_type(self.map.video_stream_type)
    }

    /// Stamp the codec configuration hash once the elementary-stream scan has seen it.
    pub fn set_config_hash(&mut self, hash: u64) {
        if self.map.codec_config_hash != Some(hash) {
            self.map.codec_config_hash = Some(hash);
            self.changed = true;
        }
    }

    /// Take the "something changed" flag, so the caller only republishes the map when it really did.
    pub fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    /// Feed one 188-byte transport packet. Safe on anything: a malformed or unrelated packet is
    /// simply not a PAT or PMT and changes nothing.
    pub fn feed_packet(&mut self, packet: &[u8]) {
        if packet.len() < TS_PACKET_SIZE || packet[0] != TS_SYNC_BYTE {
            return;
        }

        let pid = (((packet[1] & 0x1F) as u16) << 8) | packet[2] as u16;
        let payload_unit_start = packet[1] & 0x40 != 0;

        if pid == Self::PAT_PID {
            if payload_unit_start {
                self.parse_pat(packet);
            }
        } else if Some(pid) == self.pmt_pid && payload_unit_start {
            self.parse_pmt(packet);
        }
    }

    /// Locate the PSI section inside a packet payload (pointer_field, then the table).
    fn payload_section(packet: &[u8]) -> Option<&[u8]> {
        let payload = packet_payload(packet)?;
        if payload.is_empty() {
            return None;
        }
        let pointer = payload[0] as usize;
        let start = 1 + pointer;
        if start >= payload.len() {
            return None;
        }
        Some(&payload[start..])
    }

    fn parse_pat(&mut self, packet: &[u8]) {
        let Some(section) = Self::payload_section(packet) else {
            return;
        };
        if section.len() < 8 || section[0] != 0x00 {
            return;
        }

        let section_length = (((section[1] & 0x0F) as usize) << 8) | section[2] as usize;
        // 8 header bytes before the entries, minus the 3 already counted in section_length, and
        // without the trailing CRC.
        let entries_end = (3 + section_length).saturating_sub(4).min(section.len());
        let mut i = 8;
        while i + 4 <= entries_end {
            let program_number = ((section[i] as u16) << 8) | section[i + 1] as u16;
            let pid = (((section[i + 2] & 0x1F) as u16) << 8) | section[i + 3] as u16;
            // program_number 0 is the network PID, not a program.
            if program_number != 0 {
                if self.pmt_pid != Some(pid) {
                    self.pmt_pid = Some(pid);
                    self.changed = true;
                }
                return;
            }
            i += 4;
        }
    }

    fn parse_pmt(&mut self, packet: &[u8]) {
        let Some(section) = Self::payload_section(packet) else {
            return;
        };
        if section.len() < 12 || section[0] != 0x02 {
            return;
        }

        let section_length = (((section[1] & 0x0F) as usize) << 8) | section[2] as usize;
        let program_info_length = (((section[10] & 0x0F) as usize) << 8) | section[11] as usize;
        let mut i = 12 + program_info_length;
        let entries_end = (3 + section_length).saturating_sub(4).min(section.len());

        let mut video: Option<(u16, u8)> = None;
        let mut audio: Vec<u16> = Vec::new();

        while i + 5 <= entries_end {
            let stream_type = section[i];
            let elementary_pid = (((section[i + 1] & 0x1F) as u16) << 8) | section[i + 2] as u16;
            let es_info_length =
                (((section[i + 3] & 0x0F) as usize) << 8) | section[i + 4] as usize;

            match StreamKind::from_stream_type(stream_type) {
                StreamKind::H264 | StreamKind::Hevc | StreamKind::Mpeg2 => {
                    if video.is_none() {
                        video = Some((elementary_pid, stream_type));
                    }
                }
                StreamKind::Unknown => {
                    if matches!(stream_type, 0x03 | 0x04 | 0x0F | 0x11) {
                        audio.push(elementary_pid);
                    }
                }
            }

            i += 5 + es_info_length;
        }

        if let Some((pid, stream_type)) = video {
            if self.map.video_pid != pid || self.map.video_stream_type != stream_type {
                self.map.video_pid = pid;
                self.map.video_stream_type = stream_type;
                // A different video stream cannot keep the previous configuration's fingerprint.
                self.map.codec_config_hash = None;
                self.changed = true;
            }
        }

        audio.sort_unstable();
        if audio != self.audio_pids {
            self.audio_pids = audio;
            self.changed = true;
        }
    }
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

    // ── Elementary-stream scan ────────────────────────────────────────────────────────────────

    /// An H.264 payload with a NAL of the given type, padded enough to hash when it is an SPS.
    fn h264_nal(nal_type: u8, extra: usize) -> Vec<u8> {
        let mut payload = vec![0x00, 0x00, 0x01, nal_type & 0x1F];
        payload.extend(std::iter::repeat_n(0xAB, extra));
        payload
    }

    #[test]
    fn h264_idr_is_a_cut_point_and_an_sps_is_the_config_fingerprint() {
        let mut scanner = EsScanner::new();
        scanner.set_kind(StreamKind::H264);

        assert!(
            !scanner.scan(&h264_nal(1, 20)).keyframe,
            "a plain slice is not a cut point"
        );
        assert!(scanner.config_hash().is_none());

        let scan = scanner.scan(&h264_nal(7, 32));
        assert!(
            scan.config_hash.is_some(),
            "an SPS is the configuration fingerprint"
        );
        let sps_hash = scanner.config_hash();

        let scan = scanner.scan(&h264_nal(5, 8));
        assert!(scan.keyframe, "NAL type 5 (IDR) is the cut point");
        assert_eq!(
            scanner.config_hash(),
            sps_hash,
            "an IDR does not change the configuration"
        );

        let mut same = EsScanner::new();
        same.set_kind(StreamKind::H264);
        same.scan(&h264_nal(7, 32));
        assert_eq!(same.config_hash(), sps_hash, "the same SPS hashes the same");

        let mut different = EsScanner::new();
        different.set_kind(StreamKind::H264);
        let mut other_sps = vec![0x00, 0x00, 0x01, 0x67];
        other_sps.extend(std::iter::repeat_n(0x11, 32));
        different.scan(&other_sps);
        assert_ne!(
            different.config_hash(),
            sps_hash,
            "a different SPS does not"
        );
    }

    /// A start code split across two buffers must still be found: that is the buffer boundary a
    /// switch is most likely to land on.
    #[test]
    fn a_start_code_split_across_buffers_is_still_seen() {
        let mut scanner = EsScanner::new();
        scanner.set_kind(StreamKind::H264);

        assert!(!scanner.scan(&[0x00, 0x00]).keyframe);
        // The scan needs a little room past the start code (the loop stops at `i + 5 < len`), which
        // real payloads always have.
        assert!(
            scanner.scan(&[0x01, 0x05, 0xAA, 0xBB, 0xCC, 0xDD]).keyframe,
            "the IDR spans two buffers"
        );
    }

    #[test]
    fn hevc_irap_and_mpeg2_i_picture_are_cut_points() {
        let mut hevc = EsScanner::new();
        hevc.set_kind(StreamKind::Hevc);
        assert!(
            hevc.scan(&[0x00, 0x00, 0x01, 0x28, 0x01, 0x02, 0x03])
                .keyframe,
            "hevc IRAP"
        );

        // A fresh scanner: the tail from the previous payload is deliberately re-scanned (the C does
        // the same), so reusing this one would re-find the IRAP above.
        let mut plain = EsScanner::new();
        plain.set_kind(StreamKind::Hevc);
        assert!(
            !plain
                .scan(&[0x00, 0x00, 0x01, 0x52, 0x01, 0x02, 0x03])
                .keyframe,
            "hevc non-IRAP"
        );

        let mut mpeg2 = EsScanner::new();
        mpeg2.set_kind(StreamKind::Mpeg2);
        assert!(
            mpeg2
                .scan(&[0x00, 0x00, 0x01, 0x00, 0x00, 0x08, 0x00])
                .keyframe,
            "picture_coding_type 1 is an I picture"
        );

        // Fresh again for the same reason, and it is worth knowing why: the carried tail is
        // re-scanned, exactly as the C does, so a keyframe in the previous buffer is reported again
        // on the next one. Harmless in a live stream (a keyframe that recent means the decoder is
        // already at a clean point), but it is why these cases each need their own scanner.
        let mut mpeg2_plain = EsScanner::new();
        mpeg2_plain.set_kind(StreamKind::Mpeg2);
        assert!(
            !mpeg2_plain
                .scan(&[0x00, 0x00, 0x01, 0x00, 0x00, 0x18, 0x00])
                .keyframe,
            "picture_coding_type 3 is a B picture"
        );
    }

    #[test]
    fn an_unknown_codec_never_reports_a_cut_point() {
        let mut scanner = EsScanner::new();
        scanner.set_kind(StreamKind::Unknown);
        assert!(!scanner.scan(&h264_nal(5, 8)).keyframe);
    }

    // ── Program map compatibility ─────────────────────────────────────────────────────────────

    fn program_map(video_pid: u16, stream_type: u8, audio: &[u16], hash: u64) -> ProgramMap {
        ProgramMap {
            video_pid,
            video_stream_type: stream_type,
            audio_pids: audio.to_vec(),
            codec_config_hash: Some(hash),
        }
    }

    #[test]
    fn identical_programs_are_compatible_and_every_difference_is_not() {
        let base = program_map(0x101, 0x1B, &[0x201, 0x202], 42);

        assert!(
            base.compatible_with(&program_map(0x101, 0x1B, &[0x202, 0x201], 42)),
            "audio order is irrelevant"
        );
        assert!(
            !base.compatible_with(&program_map(0x102, 0x1B, &[0x201, 0x202], 42)),
            "video PID"
        );
        assert!(
            !base.compatible_with(&program_map(0x101, 0x24, &[0x201, 0x202], 42)),
            "codec"
        );
        assert!(
            !base.compatible_with(&program_map(0x101, 0x1B, &[0x201], 42)),
            "audio set"
        );
        assert!(
            !base.compatible_with(&program_map(0x101, 0x1B, &[0x201, 0x202], 43)),
            "configuration"
        );
    }

    #[test]
    fn an_unready_program_map_is_never_compatible() {
        let base = program_map(0x101, 0x1B, &[0x201], 42);
        let no_hash = ProgramMap {
            video_pid: 0x101,
            video_stream_type: 0x1B,
            audio_pids: vec![0x201],
            codec_config_hash: None,
        };
        let no_video = ProgramMap {
            video_pid: 0,
            ..no_hash.clone()
        };

        assert!(!base.compatible_with(&no_hash));
        assert!(!no_hash.compatible_with(&base));
        assert!(!base.compatible_with(&no_video));
        assert!(!ProgramMap::default().compatible_with(&ProgramMap::default()));
    }

    // ── The guarded switch ────────────────────────────────────────────────────────────────────

    #[test]
    fn a_switch_completes_only_on_the_targets_keyframe() {
        let mut pending = PendingSwitch::new();

        assert_eq!(pending.request(1, 0), SwitchOutcome::Waiting);
        assert_eq!(pending.pending(), Some(1));

        assert_eq!(
            pending.on_keyframe(0, true, true),
            SwitchOutcome::Waiting,
            "a keyframe on the source we are leaving changes nothing"
        );
        assert_eq!(pending.pending(), Some(1));

        assert_eq!(pending.on_keyframe(1, true, true), SwitchOutcome::Switch(1));
        assert_eq!(pending.pending(), None);
    }

    #[test]
    fn an_incompatible_target_is_rejected_and_an_unproven_one_waits() {
        let mut pending = PendingSwitch::new();
        pending.request(1, 0);
        assert_eq!(
            pending.on_keyframe(1, false, true),
            SwitchOutcome::Rejected("incompatible-mpegts-map")
        );
        assert_eq!(pending.pending(), None, "a rejection ends the request");

        let mut pending = PendingSwitch::new();
        pending.request(1, 0);
        assert_eq!(
            pending.on_keyframe(1, false, false),
            SwitchOutcome::Waiting,
            "nothing proven yet: the caller's timeout decides"
        );
        assert_eq!(pending.pending(), Some(1));
    }

    #[test]
    fn asking_for_the_active_source_is_not_a_switch() {
        let mut pending = PendingSwitch::new();
        assert_eq!(pending.request(0, 0), SwitchOutcome::Waiting);
        assert_eq!(pending.pending(), None);
        assert_eq!(
            pending.request(2, 0),
            SwitchOutcome::Rejected("invalid target")
        );
    }

    // ── Program identification ────────────────────────────────────────────────────────────────

    /// A PSI packet: sync, the given PID, payload_unit_start, then pointer_field + section.
    fn psi_packet(pid: u16, section: &[u8]) -> Vec<u8> {
        let mut packet = vec![0xFFu8; TS_PACKET_SIZE];
        packet[0] = TS_SYNC_BYTE;
        packet[1] = 0x40 | (((pid >> 8) as u8) & 0x1F);
        packet[2] = (pid & 0xFF) as u8;
        packet[3] = 0x01 << 4; // payload only
        packet[4] = 0x00; // pointer_field
        packet[5..5 + section.len()].copy_from_slice(section);
        packet
    }

    fn pat_section(programs: &[(u16, u16)]) -> Vec<u8> {
        let mut section = vec![0x00u8, 0x00, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00];
        for (number, pid) in programs {
            section.push((number >> 8) as u8);
            section.push((*number & 0xFF) as u8);
            section.push(0xE0 | ((pid >> 8) as u8 & 0x1F));
            section.push((*pid & 0xFF) as u8);
        }
        let len = section.len() - 3 + 4;
        section[1] = 0xB0 | (((len >> 8) & 0x0F) as u8);
        section[2] = (len & 0xFF) as u8;
        section.extend_from_slice(&[0, 0, 0, 0]); // CRC placeholder
        section
    }

    fn pmt_section(streams: &[(u8, u16)]) -> Vec<u8> {
        let mut section = vec![
            0x02u8, 0x00, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0, 0x01, 0xF0, 0x00,
        ];
        for (stream_type, pid) in streams {
            section.push(*stream_type);
            section.push(0xE0 | ((pid >> 8) as u8 & 0x1F));
            section.push((*pid & 0xFF) as u8);
            section.push(0xF0);
            section.push(0x00);
        }
        let len = section.len() - 3 + 4;
        section[1] = 0xB0 | (((len >> 8) & 0x0F) as u8);
        section[2] = (len & 0xFF) as u8;
        section.extend_from_slice(&[0, 0, 0, 0]);
        section
    }

    #[test]
    fn pat_then_pmt_identifies_the_video_and_audio_streams() {
        let mut tracker = ProgramTracker::new();
        assert_eq!(tracker.video_pid(), None);

        tracker.feed_packet(&psi_packet(
            ProgramTracker::PAT_PID,
            &pat_section(&[(0, 0x0011), (1, 0x0100)]),
        ));
        assert!(tracker.take_changed(), "learning the PMT PID is a change");

        tracker.feed_packet(&psi_packet(
            0x0100,
            &pmt_section(&[(0x03, 0x0201), (0x0F, 0x0202), (0x1B, 0x0101)]),
        ));

        let map = tracker.map();
        assert_eq!(map.video_pid, 0x0101, "the H.264 stream is the video PID");
        assert_eq!(map.video_stream_type, 0x1B);
        assert_eq!(map.audio_pids, vec![0x0201, 0x0202]);
        assert_eq!(tracker.stream_kind(), StreamKind::H264);
        assert!(
            !map.is_ready(),
            "no codec configuration seen yet, so not ready to cut to"
        );
    }

    #[test]
    fn a_network_pid_entry_is_not_a_program() {
        let mut tracker = ProgramTracker::new();
        tracker.feed_packet(&psi_packet(
            ProgramTracker::PAT_PID,
            &pat_section(&[(0, 0x0011)]),
        ));
        assert_eq!(tracker.video_pid(), None);
        assert!(
            !tracker.take_changed(),
            "a network PID alone teaches nothing"
        );
    }

    #[test]
    fn the_configuration_hash_completes_a_map() {
        let mut tracker = ProgramTracker::new();
        tracker.feed_packet(&psi_packet(
            ProgramTracker::PAT_PID,
            &pat_section(&[(1, 0x0100)]),
        ));
        tracker.feed_packet(&psi_packet(0x0100, &pmt_section(&[(0x1B, 0x0101)])));
        assert!(!tracker.map().is_ready());

        tracker.set_config_hash(7);
        assert!(tracker.map().is_ready());
        assert_eq!(tracker.map().codec_config_hash, Some(7));
    }

    #[test]
    fn a_new_video_stream_drops_the_stale_configuration_hash() {
        let mut tracker = ProgramTracker::new();
        tracker.feed_packet(&psi_packet(
            ProgramTracker::PAT_PID,
            &pat_section(&[(1, 0x0100)]),
        ));
        tracker.feed_packet(&psi_packet(0x0100, &pmt_section(&[(0x1B, 0x0101)])));
        tracker.set_config_hash(7);

        // The encoder restarted with a different video PID: the old fingerprint cannot apply.
        tracker.feed_packet(&psi_packet(0x0100, &pmt_section(&[(0x24, 0x0102)])));
        assert_eq!(tracker.map().video_pid, 0x0102);
        assert_eq!(tracker.stream_kind(), StreamKind::Hevc);
        assert_eq!(tracker.map().codec_config_hash, None);
        assert!(!tracker.map().is_ready());
    }

    #[test]
    fn garbage_packets_change_nothing() {
        let mut tracker = ProgramTracker::new();
        tracker.feed_packet(&[]);
        tracker.feed_packet(&[0x00; TS_PACKET_SIZE]);
        let mut random = vec![0x11u8; TS_PACKET_SIZE];
        random[0] = TS_SYNC_BYTE;
        random[1] = 0x40;
        random[2] = 0x50; // an unrelated PID
        tracker.feed_packet(&random);

        assert_eq!(tracker.video_pid(), None);
        assert!(!tracker.take_changed());
    }
}
