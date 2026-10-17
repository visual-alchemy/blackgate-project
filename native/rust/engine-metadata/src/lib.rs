// MPEG-TS metadata parser — ported from native/src/metadata_parser.c
//
// Extracts video stream metadata (codec, resolution, framerate, interlace)
// from MPEG Transport Stream packets via GStreamer pad probe.

use gstreamer as gst;

// ─── TS Constants ──────────────────────────────────────────────────────────

const TS_SYNC_BYTE: u8 = 0x47;
const PAT_PID: u16 = 0x0000;
const STREAM_TYPE_H264: u8 = 0x1B;
const STREAM_TYPE_HEVC: u8 = 0x24;
const STREAM_TYPE_MPEG2: u8 = 0x02;
// Audio stream types — C mpegts_stream_is_audio; collected for "audio-pids".
const STREAM_TYPE_MPEG1_AUDIO: u8 = 0x03;
const STREAM_TYPE_MPEG2_AUDIO: u8 = 0x04;
const STREAM_TYPE_AAC_ADTS: u8 = 0x0F;
const STREAM_TYPE_AAC_LATM: u8 = 0x11;
const STREAM_TYPE_AC3: u8 = 0x81;
const STREAM_TYPE_EAC3: u8 = 0x87;
const TS_PACKET_SIZE: usize = 188;
const TS_HEADER_SIZE: usize = 4;
const MAX_PES_PAYLOAD: usize = 192 * 1024;

// ─── Video Info ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct VideoInfo {
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub interlaced: bool,
    pub codec: VideoCodec,
    /// Codec profile idc (H.264 profile_idc / HEVC general_profile_idc).
    pub profile_idc: u8,
    /// Codec level idc (H.264 level_idc / HEVC general_level_idc).
    pub level_idc: u8,
    /// Chroma format idc: 0=4:0:0, 1=4:2:0, 2=4:2:2, 3=4:4:4.
    pub chroma_format_idc: u8,
    /// Bit depth (luma), 8/10/12.
    pub bit_depth: u8,
    /// Sample aspect ratio numerator/denominator (video-sar-*).
    pub sar_num: u16,
    pub sar_den: u16,
    /// True when the framerate was inferred rather than read from the stream.
    /// H.264 SPS often carries no VUI timing_info (C: fps_inferred, emitted as
    /// "video-framerate-inferred" and rendered by the UI with a "~" prefix).
    pub fps_inferred: bool,
    /// Video elementary stream PID from the PMT (0 when unknown) — "video-pid".
    pub video_pid: u16,
    /// Audio elementary stream PIDs from the PMT — "audio-pids".
    pub audio_pids: Vec<u16>,
}

/// C h264_profile_name() — idc → display name.
pub fn h264_profile_name(idc: u8) -> &'static str {
    match idc {
        66 => "Baseline",
        77 => "Main",
        88 => "Extended",
        100 => "High",
        110 => "High 10",
        122 => "High 4:2:2",
        244 => "High 4:4:4 Predictive",
        _ => "Unknown",
    }
}

/// C chroma_format_name().
pub fn chroma_format_name(idc: u8) -> &'static str {
    match idc {
        0 => "4:0:0",
        1 => "4:2:0",
        2 => "4:2:2",
        3 => "4:4:4",
        _ => "Unknown",
    }
}

/// C hevc_profile_name() — chroma/depth win over the profile idc when set.
pub fn hevc_profile_name(idc: u8, chroma: u8, depth: u8) -> &'static str {
    if chroma == 2 && depth == 10 {
        return "Main 4:2:2 10";
    }
    if chroma == 2 {
        return "Main 4:2:2";
    }
    if chroma == 1 && depth == 10 {
        return "Main 10";
    }
    if chroma == 1 && depth == 8 {
        return "Main";
    }
    match idc {
        1 => "Main",
        2 => "Main 10",
        3 => "Main Still Picture",
        4 => "Range Extensions",
        _ => "Unknown",
    }
}

/// C video-codec field: "AVC/H.264" | "HEVC/H.265" (empty when unknown).
pub fn codec_display_name(codec: VideoCodec) -> &'static str {
    match codec {
        VideoCodec::H264 => "AVC/H.264",
        VideoCodec::HEVC => "HEVC/H.265",
        _ => "",
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub enum VideoCodec {
    #[default]
    Unknown,
    H264,
    HEVC,
    Mpeg2,
}

impl VideoCodec {
    pub fn as_str(&self) -> &'static str {
        match self {
            VideoCodec::H264 => "h264",
            VideoCodec::HEVC => "hevc",
            VideoCodec::Mpeg2 => "mpeg2",
            VideoCodec::Unknown => "unknown",
        }
    }
}

/// MPEG-TS stream_type → VideoCodec (PMT mapping, C STREAM_TYPE_*).
pub fn codec_from_stream_type(stream_type: u8) -> VideoCodec {
    match stream_type {
        STREAM_TYPE_H264 => VideoCodec::H264,
        STREAM_TYPE_HEVC => VideoCodec::HEVC,
        STREAM_TYPE_MPEG2 => VideoCodec::Mpeg2,
        _ => VideoCodec::Unknown,
    }
}

// ─── BitReader ─────────────────────────────────────────────────────────────

struct BitReader<'a> {
    data: &'a [u8],
    byte_pos: usize,
    bit_pos: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_pos: 0,
        }
    }

    fn read_bits(&mut self, n: u8) -> u32 {
        let mut result: u32 = 0;
        for _ in 0..n {
            if self.byte_pos >= self.data.len() {
                return result;
            }
            let bit = (self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1;
            result = (result << 1) | bit as u32;
            self.bit_pos += 1;
            if self.bit_pos == 8 {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
        result
    }

    fn read_ue(&mut self) -> u32 {
        let mut leading_zeros = 0u32;
        while self.read_bits(1) == 0 {
            leading_zeros += 1;
        }
        let value = self.read_bits(leading_zeros as u8);
        (1u32 << leading_zeros) - 1 + value
    }

    fn skip_scaling_list(&mut self, size: usize) {
        let mut last_scale = 8i32;
        let mut next_scale = 8i32;
        for _ in 0..size {
            if next_scale != 0 {
                let delta_scale = self.read_ue() as i32;
                next_scale = (last_scale + delta_scale + 256) % 256;
            }
            last_scale = if next_scale == 0 {
                last_scale
            } else {
                next_scale
            };
        }
    }
}

// ─── Adaptation Field ──────────────────────────────────────────────────────

fn skip_adaptation_field(data: &[u8], offset: usize, af_control: u8) -> usize {
    if (af_control == 2 || af_control == 3) && offset < TS_PACKET_SIZE {
        let af_len = data[offset] as usize;
        return offset + 1 + af_len;
    }
    offset
}

// ─── PAT Parser ────────────────────────────────────────────────────────────

fn parse_pat(data: &[u8], pmt_pid: &mut u32) -> bool {
    let pid = ((data[1] as u16 & 0x1F) << 8) | data[2] as u16;
    if pid != PAT_PID {
        return false;
    }

    let af_control = (data[3] >> 4) & 0x3;
    let has_payload = af_control == 1 || af_control == 3;
    if !has_payload {
        return false;
    }

    let mut offset = skip_adaptation_field(data, TS_HEADER_SIZE, af_control);
    if offset >= TS_PACKET_SIZE {
        return false;
    }

    let pointer_field = data[offset] as usize;
    offset += 1;
    offset += pointer_field;
    if offset + 4 > TS_PACKET_SIZE {
        return false;
    }

    if data[offset] != 0x00 {
        return false;
    }
    offset += 1;
    if offset + 4 > TS_PACKET_SIZE {
        return false;
    }
    let section_length = ((data[offset] as usize & 0x0F) << 8) | data[offset + 1] as usize;
    offset += 2;
    offset += 5; // skip transport_stream_id (2B) + version/current (1B) + section_number (1B) + last_section_number (1B)

    let mut section_end = offset + section_length - 5 - 4;
    if section_end > TS_PACKET_SIZE {
        section_end = TS_PACKET_SIZE;
    }

    while offset + 4 <= section_end {
        let program_number = ((data[offset] as u16) << 8) | data[offset + 1] as u16;
        offset += 2;
        if program_number != 0 {
            *pmt_pid = ((data[offset] as u32 & 0x1F) << 8) | data[offset + 1] as u32;
            return true;
        }
        offset += 2;
    }
    false
}

// ─── PMT Parser ────────────────────────────────────────────────────────────

fn parse_pmt(
    data: &[u8],
    elementary_pid: &mut u32,
    stream_type: &mut u8,
    audio_pids: &mut Vec<u16>,
) -> bool {
    let af_control = (data[3] >> 4) & 0x3;
    let has_payload = af_control == 1 || af_control == 3;
    if !has_payload {
        return false;
    }

    let mut offset = skip_adaptation_field(data, TS_HEADER_SIZE, af_control);
    if offset >= TS_PACKET_SIZE {
        return false;
    }

    let pointer_field = data[offset] as usize;
    offset += 1;
    offset += pointer_field;
    if offset + 4 > TS_PACKET_SIZE {
        return false;
    }

    if data[offset] != 0x02 {
        return false;
    }
    offset += 1;
    if offset + 4 > TS_PACKET_SIZE {
        return false;
    }
    let section_length = ((data[offset] as usize & 0x0F) << 8) | data[offset + 1] as usize;
    offset += 2;
    // Five bytes, not four: program_number(2) + version/current(1) +
    // section_number(1) + last_section_number(1). Skipping only four left the
    // offset on last_section_number, so program_info_length was read one byte
    // early (240 instead of 0 for a real stream) and the stream loop ran off the
    // packet — the PMT never parsed and the probe silently found nothing.
    offset += 5;
    offset += 2; // skip PCR_PID

    if offset + 2 > TS_PACKET_SIZE {
        return false;
    }
    let program_info_length = ((data[offset] as usize & 0x0F) << 8) | data[offset + 1] as usize;
    offset += 2 + program_info_length;

    // section_length covers everything after the length field: the five bytes
    // above, PCR_PID(2), program_info_length(2), program_info, the stream entries
    // and the 4-byte CRC. We are now at the first stream entry, so what remains
    // before the CRC is section_length - 13 - program_info_length.
    let mut section_end = offset + section_length.saturating_sub(13 + program_info_length);
    if section_end > TS_PACKET_SIZE {
        section_end = TS_PACKET_SIZE;
    }

    let mut found_video = false;
    while offset + 5 <= section_end {
        let st = data[offset];
        let e_pid = ((data[offset + 1] as u32 & 0x1F) << 8) | data[offset + 2] as u32;
        let es_info_length = ((data[offset + 3] as usize & 0x0F) << 8) | data[offset + 4] as usize;

        if !found_video
            && (st == STREAM_TYPE_H264 || st == STREAM_TYPE_HEVC || st == STREAM_TYPE_MPEG2)
        {
            *elementary_pid = e_pid;
            *stream_type = st;
            found_video = true;
        } else if is_audio_stream_type(st) {
            // Keep scanning rather than returning at the first video stream: the C
            // engine collects every stream entry, and the audio PIDs are emitted as
            // "audio-pids" (they normally follow the video entry).
            audio_pids.push(e_pid as u16);
        }
        offset += 5 + es_info_length;
    }
    found_video
}

/// C mpegts_stream_is_audio — stream types collected into "audio-pids".
fn is_audio_stream_type(stream_type: u8) -> bool {
    matches!(
        stream_type,
        STREAM_TYPE_MPEG1_AUDIO
            | STREAM_TYPE_MPEG2_AUDIO
            | STREAM_TYPE_AAC_ADTS
            | STREAM_TYPE_AAC_LATM
            | STREAM_TYPE_AC3
            | STREAM_TYPE_EAC3
    )
}

// ─── Aspect Ratio Idc (H.264 Table E-1) ────────────────────────────────────

/// H.264 aspect_ratio_idc → (sar_num, sar_den) when the SPS carries an extended
/// sample aspect ratio. Only E-1 (SAR) entries map here; the 0..16 range in the
/// spec includes pixel-aspect entries, which byte-parity with the C engine
/// resolves via the same VUI fields.
fn sar_from_aspect_ratio_idc(idc: u32) -> (u16, u16) {
    match idc {
        1 => (1, 1),
        2 => (12, 11),
        3 => (10, 11),
        4 => (16, 11),
        5 => (40, 33),
        6 => (24, 11),
        7 => (20, 11),
        8 => (32, 11),
        9 => (80, 33),
        10 => (18, 11),
        11 => (15, 11),
        12 => (64, 33),
        13 => (160, 99),
        14 => (4, 3),
        15 => (3, 2),
        16 => (2, 1),
        _ => (1, 1),
    }
}

// ─── H.264 SPS Parser ──────────────────────────────────────────────────────

/// C remove_emulation_prevention — H.264/HEVC encoders insert a 0x03 byte after
/// every 00 00 pair so an RBSP can never contain a start code. Parsing the raw NAL
/// without dropping those bytes shifts every field after the first 00 00 03: a live
/// SPS carrying two EPBs reported a framerate of 2^24 (16777216) instead of 25 fps.
fn remove_emulation_prevention(nal: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal.len());
    let mut zeros = 0usize;
    for &b in nal {
        if zeros >= 2 && b == 0x03 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

fn parse_h264_sps(nal_data: &[u8]) -> Option<VideoInfo> {
    if nal_data.len() < 3 {
        return None;
    }

    let nal_unit_type = nal_data[0] & 0x1F;
    if nal_unit_type != 7 {
        return None;
    }

    let rbsp = remove_emulation_prevention(&nal_data[1..]);
    let mut br = BitReader::new(&rbsp);

    let profile_idc = br.read_bits(8);
    br.read_bits(8); // constraint + reserved
    let level_idc = br.read_bits(8);
    br.read_ue(); // seq_parameter_set_id

    let mut chroma_format_idc = 1u32;
    let mut bit_depth = 8u32;
    let high_profile = matches!(
        profile_idc,
        100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135
    );
    if high_profile {
        chroma_format_idc = br.read_ue();
        if chroma_format_idc == 3 {
            br.read_bits(1);
        }
        bit_depth = 8 + br.read_ue(); // bit_depth_luma_minus8
        br.read_ue(); // bit_depth_chroma_minus8
        br.read_bits(1); // qpprime_y_zero_transform_bypass_flag
        let scaling_present = br.read_bits(1);
        if scaling_present != 0 {
            let num_lists = if chroma_format_idc != 3 { 8 } else { 12 };
            for i in 0..num_lists {
                let list_present = br.read_bits(1);
                if list_present != 0 {
                    let list_size = if i < 6 { 16 } else { 64 };
                    br.skip_scaling_list(list_size);
                }
            }
        }
    }

    br.read_ue(); // log2_max_frame_num_minus4

    let pic_order_cnt_type = br.read_ue();
    if pic_order_cnt_type == 0 {
        br.read_ue(); // log2_max_pic_order_cnt_lsb_minus4
    } else if pic_order_cnt_type == 1 {
        br.read_bits(1); // delta_pic_order_always_zero_flag
        br.read_ue(); // offset_for_non_ref_pic
        br.read_ue(); // offset_for_top_to_bottom_field
        let num_ref = br.read_ue();
        for _ in 0..num_ref {
            br.read_ue();
        }
    }

    br.read_ue(); // max_num_ref_frames
    br.read_bits(1); // gaps_in_frame_num_value_allowed_flag

    let pic_width_in_mbs = br.read_ue() + 1;
    let pic_height_in_map_units = br.read_ue() + 1;
    let frame_mbs_only_flag = br.read_bits(1);
    let interlaced = frame_mbs_only_flag == 0;

    let width = pic_width_in_mbs * 16;
    let height = if frame_mbs_only_flag == 0 {
        br.read_bits(1); // mb_adaptive_frame_field_flag
        pic_height_in_map_units * 32
    } else {
        pic_height_in_map_units * 16
    };

    br.read_bits(1); // direct_8x8_inference_flag

    let (crop_left, crop_right, crop_top, crop_bottom) = if br.read_bits(1) != 0 {
        (br.read_ue(), br.read_ue(), br.read_ue(), br.read_ue())
    } else {
        (0, 0, 0, 0)
    };

    let (sub_w, sub_h) = match chroma_format_idc {
        1 => (2, 2),
        2 => (2, 1),
        _ => (1, 1),
    };

    let width = width.saturating_sub((crop_left + crop_right) * sub_w);
    let height =
        height.saturating_sub((crop_top + crop_bottom) * (2 - frame_mbs_only_flag) * sub_h);

    // VUI — framerate + sample aspect ratio.
    // C defaults to 25/1 with fps_inferred = TRUE: a live SPS often carries no
    // VUI timing_info at all (verified against a real source:
    // timing_info_present_flag = 0), and the UI renders an inferred rate with a
    // "~" prefix.
    let (mut fps_num, mut fps_den) = (25u32, 1u32);
    let mut fps_inferred = true;
    let (mut sar_num, mut sar_den) = (1u16, 1u16);
    if br.read_bits(1) != 0 {
        // aspect_ratio
        let ar_present = br.read_bits(1);
        if ar_present != 0 {
            let ar_idc = br.read_bits(8);
            if ar_idc == 255 {
                sar_num = br.read_bits(16) as u16;
                sar_den = br.read_bits(16) as u16;
            } else {
                let (n, d) = sar_from_aspect_ratio_idc(ar_idc);
                sar_num = n;
                sar_den = d;
            }
        }
        // overscan
        if br.read_bits(1) != 0 {
            br.read_bits(1);
        }
        // video_signal_type
        if br.read_bits(1) != 0 {
            br.read_bits(4);
            if br.read_bits(1) != 0 {
                br.read_bits(8);
                br.read_bits(8);
                br.read_bits(8);
            }
        }
        // chroma_loc
        if br.read_bits(1) != 0 {
            br.read_ue();
            br.read_ue();
        }
        // timing
        if br.read_bits(1) != 0 {
            let num_units = br.read_bits(32);
            let time_scale = br.read_bits(32);
            br.read_bits(1); // fixed_frame_rate_flag
            if num_units > 0 && time_scale > 0 {
                fps_num = time_scale;
                fps_den = num_units * 2;
                fps_inferred = false; // read from the source VUI
            }
        }
    }

    Some(VideoInfo {
        width,
        height,
        fps_num,
        fps_den,
        interlaced,
        codec: VideoCodec::H264,
        profile_idc: profile_idc as u8,
        level_idc: level_idc as u8,
        chroma_format_idc: chroma_format_idc as u8,
        bit_depth: bit_depth as u8,
        sar_num,
        sar_den,
        fps_inferred,
        // Filled in by TsProbeState from the PMT.
        video_pid: 0,
        audio_pids: Vec::new(),
    })
}

// ─── MPEG-2 Sequence Header Parser ─────────────────────────────────────────

fn parse_mpeg2_sequence(data: &[u8]) -> Option<VideoInfo> {
    if data.len() < 8 {
        return None;
    }
    if data[0] != 0x00 || data[1] != 0x00 || data[2] != 0x01 || data[3] != 0xB3 {
        return None;
    }

    let mut offset = 4;
    let width = (((data[offset] as u16) & 0xFF) << 4) | ((data[offset + 1] >> 4) & 0xF) as u16;
    let height = (((data[offset + 1] as u16) & 0x0F) << 8) | data[offset + 2] as u16;
    offset += 3;
    offset += 1; // aspect_ratio byte

    let frame_rate_code = (data[offset] >> 4) & 0xF;
    let fps_num_table: [u32; 9] = [0, 24000, 24, 25, 30000, 30, 50, 60000, 60];
    let fps_den_table: [u32; 9] = [1, 1001, 1, 1, 1001, 1, 1, 1001, 1];

    // frame_rate_code 0 is "forbidden"/unspecified: the rate is not in the stream.
    let fps_inferred = !(1..=8).contains(&frame_rate_code);
    let (fps_num, fps_den) = if (1..=8).contains(&frame_rate_code) {
        (
            fps_num_table[frame_rate_code as usize],
            fps_den_table[frame_rate_code as usize],
        )
    } else {
        (0, 1)
    };

    let interlaced = if offset + 4 < data.len() {
        let progressive = (data[offset + 3] >> 3) & 1;
        progressive == 0
    } else {
        false
    };

    Some(VideoInfo {
        width: width as u32,
        height: height as u32,
        fps_num,
        fps_den,
        interlaced,
        codec: VideoCodec::Mpeg2,
        // MPEG-2 sequence header carries no profile/level/chroma/SAR idc; C resets
        // sar to 1:1 and leaves the codec-detail fields empty.
        profile_idc: 0,
        level_idc: 0,
        chroma_format_idc: 1,
        bit_depth: 8,
        sar_num: 1,
        sar_den: 1,
        fps_inferred,
        video_pid: 0,
        audio_pids: Vec::new(),
    })
}

// ─── HEVC SPS Parser ───────────────────────────────────────────────────────

fn parse_hevc_sps(nal_data: &[u8]) -> Option<VideoInfo> {
    if nal_data.len() < 4 {
        return None;
    }

    let nal_unit_type = (nal_data[0] >> 1) & 0x3F;
    if nal_unit_type != 33 && nal_unit_type != 34 {
        return None;
    }
    if nal_unit_type == 33 {
        return None;
    } // VPS — skip

    let rbsp = remove_emulation_prevention(&nal_data[2..]);
    let mut br = BitReader::new(&rbsp);

    br.read_bits(4); // sps_video_parameter_set_id
    let max_sub_layers = br.read_bits(3);
    br.read_bits(1); // sps_temporal_id_nesting_flag

    // profile_tier_level
    br.read_bits(2); // general_profile_space
    br.read_bits(1); // general_tier_flag
    let general_profile_idc = br.read_bits(5);
    for _ in 0..32 {
        br.read_bits(1);
    }
    br.read_bits(1); // general_progressive_source_flag
    br.read_bits(1); // general_interlaced_source_flag
    br.read_bits(3); // non_packed + frame_only
    let general_level_idc = br.read_bits(8);
    let mut sub_layer_profile_present = 0u32;
    let mut sub_layer_level_present = 0u32;
    for _ in 0..max_sub_layers {
        sub_layer_profile_present = br.read_bits(1);
        sub_layer_level_present = br.read_bits(1);
    }
    if max_sub_layers > 0 {
        for _ in max_sub_layers..8 {
            br.read_bits(2);
        }
    }
    for _ in 0..max_sub_layers {
        if sub_layer_profile_present != 0 {
            br.read_bits(8); // profile_space, tier, profile_idc, 32 flags
            for _ in 0..32 {
                br.read_bits(1);
            }
            br.read_bits(4); // progressive, interlaced, non_packed, frame_only
        }
        if sub_layer_level_present != 0 {
            br.read_bits(8);
        }
    }

    br.read_ue(); // sps_seq_parameter_set_id
    let chroma_format_idc = br.read_ue();
    if chroma_format_idc == 3 {
        br.read_bits(1);
    }

    let pic_width = br.read_ue();
    let pic_height = br.read_ue();
    let conformance_window = br.read_bits(1);

    // Conformance window crop (sub_width/sub_height per chroma_format_idc).
    // The C engine (lite 1540-1552) applies this crop; it must be consumed here
    // so the bit depths that follow are read from the correct offset.
    let (mut width, mut height) = (pic_width, pic_height);
    if conformance_window != 0 {
        let left = br.read_ue();
        let right = br.read_ue();
        let top = br.read_ue();
        let bottom = br.read_ue();
        let (sub_w, sub_h) = match chroma_format_idc {
            1 => (2u32, 2u32),
            2 => (2, 1),
            _ => (1, 1),
        };
        let crop_w = (left + right) * sub_w;
        let crop_h = (top + bottom) * sub_h;
        if crop_w < width && crop_h < height {
            width -= crop_w;
            height -= crop_h;
        }
    }

    let bit_depth = br.read_ue() + 8; // bit_depth_luma_minus8
    br.read_ue(); // bit_depth_chroma_minus8

    // VUI — framerate
    let (mut fps_num, mut fps_den) = (0u32, 1u32);
    let mut fps_inferred = true;
    if br.read_bits(1) != 0 {
        br.read_bits(1); // aspect_ratio_info_present_flag
        br.read_bits(1); // overscan_info_present_flag
        if br.read_bits(1) != 0 {
            br.read_bits(4);
        }
        br.read_bits(1); // chroma_loc_info_present_flag
        if br.read_bits(1) != 0 {
            let num_units = br.read_bits(32);
            let time_scale = br.read_bits(32);
            br.read_bits(1);
            if num_units > 0 && time_scale > 0 {
                fps_num = time_scale;
                fps_den = num_units;
                fps_inferred = false;
            }
        }
    }

    Some(VideoInfo {
        width,
        height,
        fps_num,
        fps_den,
        interlaced: false,
        codec: VideoCodec::HEVC,
        profile_idc: general_profile_idc as u8,
        level_idc: general_level_idc as u8,
        chroma_format_idc: chroma_format_idc as u8,
        bit_depth: bit_depth as u8,
        // C resets HEVC SAR to 1:1 (lite 1553).
        sar_num: 1,
        sar_den: 1,
        fps_inferred,
        video_pid: 0,
        audio_pids: Vec::new(),
    })
}

// ─── TS Probe Callback ─────────────────────────────────────────────────────

/// GStreamer pad probe that inspects MPEG-TS packets for video stream metadata.
/// Returns `Some(VideoInfo)` once metadata is successfully detected, `None` while still scanning.
/// Caller should remove the probe after receiving `Some`.
pub struct TsProbeState {
    pat_parsed: bool,
    pmt_parsed: bool,
    pmt_pid: u32,
    elementary_pid: u32,
    video_stream_type: u8,
    /// Audio elementary PIDs from the PMT — surfaced as "audio-pids".
    audio_pids: Vec<u16>,
    pes_buffer: Vec<u8>,
}

impl Default for TsProbeState {
    fn default() -> Self {
        Self {
            pat_parsed: false,
            pmt_parsed: false,
            pmt_pid: 0,
            elementary_pid: 0,
            video_stream_type: 0,
            audio_pids: Vec::new(),
            pes_buffer: Vec::with_capacity(MAX_PES_PAYLOAD),
        }
    }
}

/// Offset of the first MPEG-TS packet boundary in a buffer.
///
/// SRT payload boundaries do not have to line up with the 188-byte TS packets, so
/// a buffer can start mid-packet. Stepping from a wrong offset then reads every
/// packet at the wrong position: the probe parsed a bogus PAT/PMT (a live stream
/// reported video PID 65 / audio PID 66 instead of 256/257, and a PMT packet with
/// PID 32 and a 140-byte adaptation field) and the real metadata only turned up by
/// luck. The C source_ts_probe_callback resyncs the same way; the extra check that
/// the following packet also starts with a sync byte keeps payload bytes that
/// happen to equal 0x47 from being mistaken for a boundary.
fn resync_offset(data: &[u8]) -> Option<usize> {
    let limit = data.len().min(TS_PACKET_SIZE);
    (0..limit).find(|&i| {
        data[i] == TS_SYNC_BYTE
            && (i + TS_PACKET_SIZE >= data.len() || data[i + TS_PACKET_SIZE] == TS_SYNC_BYTE)
    })
}

impl TsProbeState {
    /// C/lite keep probing until the stream yields a video header: the engine
    /// connects mid-GOP, so the first SPS/IDR can be seconds away. An attempt cap
    /// (per TS packet) gave up in ~50 ms at 15 Mbps and the probe never reported
    /// any video metadata.
    pub fn probe(&mut self, buf: &gst::Buffer) -> Option<VideoInfo> {
        let map = buf.map_readable().ok()?;
        if map.len() < TS_PACKET_SIZE {
            return None;
        }

        let data: &[u8] = &map;
        let base = resync_offset(data)?;
        let num_packets = (data.len() - base) / TS_PACKET_SIZE;
        for p in 0..num_packets {
            let ts = &data[base + p * TS_PACKET_SIZE..base + (p + 1) * TS_PACKET_SIZE];
            if ts[0] != TS_SYNC_BYTE {
                continue;
            }

            let pid = ((ts[1] as u16 & 0x1F) << 8) | ts[2] as u16;

            // PAT
            if !self.pat_parsed && pid == PAT_PID {
                let mut pmt_pid = 0u32;
                if parse_pat(ts, &mut pmt_pid) {
                    self.pat_parsed = true;
                    self.pmt_pid = pmt_pid;
                }
            }

            // PMT
            if self.pat_parsed && !self.pmt_parsed && pid as u32 == self.pmt_pid {
                let mut epid = 0u32;
                let mut st = 0u8;
                let mut audios = Vec::new();
                if parse_pmt(ts, &mut epid, &mut st, &mut audios) {
                    self.pmt_parsed = true;
                    self.elementary_pid = epid;
                    self.video_stream_type = st;
                    self.audio_pids = audios;
                }
            }

            // Video PES accumulation + SPS scanning
            if self.pmt_parsed && pid as u32 == self.elementary_pid {
                let af_control = (ts[3] >> 4) & 0x3;
                let has_payload = af_control == 1 || af_control == 3;
                if !has_payload {
                    continue;
                }

                let offset = skip_adaptation_field(ts, TS_HEADER_SIZE, af_control);
                let payload_size = TS_PACKET_SIZE.saturating_sub(offset);
                if payload_size == 0 {
                    continue;
                }

                let is_pes_start = (ts[1] & 0x40) != 0;
                if is_pes_start {
                    self.pes_buffer.clear();
                }

                if self.pes_buffer.len() + payload_size <= MAX_PES_PAYLOAD {
                    self.pes_buffer
                        .extend_from_slice(&ts[offset..offset + payload_size]);
                }

                let result = match self.video_stream_type {
                    STREAM_TYPE_H264 => self.scan_h264_start_codes(),
                    STREAM_TYPE_HEVC => self.scan_hevc_start_codes(),
                    STREAM_TYPE_MPEG2 => self.scan_mpeg2_start_codes(),
                    _ => None,
                };

                if let Some(mut info) = result {
                    // PMT-derived stream PIDs travel with the video info (C
                    // add_mpegts_source_stats emits video-pid + audio-pids).
                    info.video_pid = self.elementary_pid as u16;
                    info.audio_pids = self.audio_pids.clone();
                    return Some(info);
                }
            }
        }

        None
    }

    fn scan_h264_start_codes(&self) -> Option<VideoInfo> {
        let buf = &self.pes_buffer;
        if buf.len() < 5 {
            return None;
        }
        for i in 0..=buf.len().saturating_sub(5) {
            if buf[i] == 0x00 && buf[i + 1] == 0x00 && buf[i + 2] == 0x00 && buf[i + 3] == 0x01 {
                let nal_type = buf[i + 4] & 0x1F;
                if nal_type == 7 {
                    return parse_h264_sps(&buf[i + 4..]);
                }
            }
        }
        None
    }

    fn scan_hevc_start_codes(&self) -> Option<VideoInfo> {
        let buf = &self.pes_buffer;
        if buf.len() < 6 {
            return None;
        }
        for i in 0..=buf.len().saturating_sub(6) {
            if buf[i] == 0x00 && buf[i + 1] == 0x00 && buf[i + 2] == 0x00 && buf[i + 3] == 0x01 {
                let nal_type = (buf[i + 4] >> 1) & 0x3F;
                if nal_type == 33 || nal_type == 34 {
                    return parse_hevc_sps(&buf[i + 4..]);
                }
            }
        }
        None
    }

    fn scan_mpeg2_start_codes(&self) -> Option<VideoInfo> {
        let buf = &self.pes_buffer;
        if buf.len() < 4 {
            return None;
        }
        for i in 0..=buf.len().saturating_sub(4) {
            if buf[i] == 0x00 && buf[i + 1] == 0x00 && buf[i + 2] == 0x01 && buf[i + 3] == 0xB3 {
                return parse_mpeg2_sequence(&buf[i..]);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bitreader_read_bits() {
        let data = [0b10101010, 0b11110000];
        let mut br = BitReader::new(&data);
        assert_eq!(br.read_bits(4), 0b1010);
        assert_eq!(br.read_bits(4), 0b1010);
        assert_eq!(br.read_bits(4), 0b1111);
        assert_eq!(br.read_bits(4), 0b0000);
    }

    #[test]
    fn test_bitreader_read_ue() {
        // 1 in Exp-Golomb = 001 → leading_zeros=2, value=1 → (1<<2)-1+1 = 4
        // Representing "4" in ue: value=4. (4+1)=5 → 101 binary, leading_zeros=2 → 00101
        // So: 00101 = read_bits(1)=0, read_bits(1)=0, read_bits(1)=1, read_bits(2)=01
        let data = [0b0010_1000]; // 0,0,1,0,1,...
        let mut br = BitReader::new(&data);
        assert_eq!(br.read_ue(), 4);
    }

    #[test]
    fn test_parse_mpeg2_sequence_header() {
        // 0x00 0x00 0x01 0xB3 + width=1920 height=1080 bytes
        let bytes: [u8; 11] = [
            0x00, 0x00, 0x01, 0xB3, // start code
            0x78, 0x04, 0x38, // 1920x1080 (0x780=1920, 0x438=1080)
            0x10, // aspect_ratio=1, frame_rate_code=0
            0x00, 0x00, 0x00, // extra
        ];
        // But need to set frame_rate_code: data[7] >> 4
        // For 29.97: frame_rate_code=4 → 0x4_ placeholder + other nibble
        let mut data = bytes;
        data[8] = 0x40; // frame_rate_code=4 (30000/1001)
        let info = parse_mpeg2_sequence(&data).unwrap();
        assert_eq!(info.width, 1920);
        assert_eq!(info.height, 1080);
        assert_eq!(info.fps_num, 30000);
        assert_eq!(info.fps_den, 1001);
    }

    /// H.264 encoders insert emulation-prevention bytes (00 00 03) so an RBSP can
    /// never contain a start code. This is a real High-profile SPS from a live
    /// source and it carries two EPBs: parsing it without removing them shifted
    /// every field after the first escape, so the engine reported a framerate of
    /// 2^24 instead of 25 fps (C remove_emulation_prevention).
    #[test]
    fn parse_h264_sps_with_emulation_prevention_bytes() {
        let sps: [u8; 40] = [
            0x27, 0x64, 0x00, 0x28, 0xAD, 0x00, 0xEC, 0x07, 0x80, 0x44, 0x7D, 0xE0, 0x28, 0x40,
            0x40, 0x40, 0x50, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0x2E, 0x04,
            0x00, 0x00, 0xE4, 0xE1, 0xC0, 0x00, 0x1C, 0x9C, 0x3E, 0x17, 0xB8, 0x30,
        ];
        // Both escapes (after the NAL header) are dropped before bit parsing.
        assert_eq!(
            remove_emulation_prevention(&sps[1..]).len(),
            sps.len() - 1 - 2
        );

        let info = parse_h264_sps(&sps).expect("SPS parses");
        assert_eq!((info.width, info.height), (1920, 1080));
        assert_eq!(info.profile_idc, 100); // High
        assert_eq!(info.level_idc, 40);
        assert_eq!(info.chroma_format_idc, 1);
        assert_eq!(info.bit_depth, 8);
        assert_eq!((info.sar_num, info.sar_den), (1, 1)); // aspect_ratio_idc = 1
                                                          // VUI timing_info: num_units_in_tick = 1, time_scale = 50 → 25 fps.
        assert_eq!(info.fps_num, 50);
        assert_eq!(info.fps_den, 2);
        assert!(!info.fps_inferred, "timing_info was present in the SPS");
    }

    #[test]
    fn test_parse_pat() {
        // Simulate minimal PAT TS packet: PID=0, payload_unit_start, table_id=0x00
        let mut ts = [0u8; 188];
        ts[0] = 0x47; // sync byte
        ts[1] = 0x40; // payload_unit_start=1, PID=0
        ts[2] = 0x00; // PID continued
        ts[3] = 0x10; // adaptation_field_control=1 (payload only)
        ts[4] = 0x00; // pointer_field=0
        ts[5] = 0x00; // table_id=0x00 (PAT)
        ts[6] = 0xB0; // section_syntax_indicator=1, private=0, section_length_high=0
        ts[7] = 0x0D; // section_length=13
        ts[8] = 0x00;
        ts[9] = 0x01; // transport_stream_id=1
        ts[10] = 0x00; // version + current
        ts[11] = 0x00; // section_number
        ts[12] = 0x00; // last_section_number
                       // Program 0x0001 → PMT PID 0x0064 (100)
        ts[13] = 0x00;
        ts[14] = 0x01; // program_number=1
        ts[15] = 0xE0;
        ts[16] = 0x64; // PMT_PID=100
                       // CRC placeholder
        ts[17] = 0x00;
        ts[18] = 0x00;
        ts[19] = 0x00;
        ts[20] = 0x00;

        let mut pmt_pid = 0u32;
        assert!(parse_pat(&ts, &mut pmt_pid));
        assert_eq!(pmt_pid, 100);
    }

    /// Real PMT captured from a live SRT source (H.264 1920x1080 + AAC-LC):
    /// section_length 29, PCR_PID 256, stream entries H.264/256 and AAC-ADTS/257
    /// carrying an ISO-639 "eng" descriptor, then the CRC. Regression for the
    /// off-by-one that made every PMT parse fail (offset skipped four bytes
    /// instead of five, so program_info_length read 240 and the loop ran off the
    /// packet) — the probe then never saw any video metadata at all.
    #[test]
    fn parse_pmt_real_packet_reads_video_and_audio_pids() {
        let mut pkt = vec![0xFFu8; TS_PACKET_SIZE];
        let head: [u8; 37] = [
            0x47, 0x50, 0x00, 0x10, 0x00, 0x02, 0xB0, 0x1D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1,
            0x00, 0xF0, 0x00, 0x1B, 0xE1, 0x00, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, 0x06, 0x0A,
            0x04, 0x65, 0x6E, 0x67, 0x00, 0x8D, 0x82, 0x9A, 0x07,
        ];
        pkt[..head.len()].copy_from_slice(&head);

        let (mut pid, mut st) = (0u32, 0u8);
        let mut audio = Vec::new();
        assert!(parse_pmt(&pkt, &mut pid, &mut st, &mut audio));
        assert_eq!(pid, 256, "video elementary PID");
        assert_eq!(st, STREAM_TYPE_H264);
        assert_eq!(audio, vec![257], "audio PIDs collected from the same PMT");
    }

    /// Audio stream types are collected without truncating the scan at the first
    /// video entry (the audio PID normally follows the video one).
    #[test]
    fn parse_pmt_collects_audio_pid_listed_after_video() {
        let mut pkt = vec![0xFFu8; TS_PACKET_SIZE];
        // Header (PID 0x1000, payload only) + pointer 0 + PMT table_id.
        // section_length 28 = 5 (program/version/sections) + 2 (PCR_PID) + 2
        // (program_info_length) + 15 (three 5-byte stream entries) + 4 (CRC).
        let head: [u8; 32] = [
            0x47, 0x50, 0x00, 0x10, 0x00, 0x02, 0xB0, 0x1C, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1,
            0x00, 0xF0, 0x00, 0x1B, 0xE1, 0x00, 0xF0, 0x00, // H.264 / PID 256
            0x04, 0xE1, 0x01, 0xF0, 0x00, // MPEG-2 audio / PID 257
            0x03, 0xE1, 0x02, 0xF0, 0x00, // MPEG-1 audio / PID 258
        ];
        pkt[..head.len()].copy_from_slice(&head);

        let (mut pid, mut st) = (0u32, 0u8);
        let mut audio = Vec::new();
        assert!(parse_pmt(&pkt, &mut pid, &mut st, &mut audio));
        assert_eq!(pid, 256);
        assert_eq!(st, STREAM_TYPE_H264);
        assert_eq!(audio, vec![257, 258]);
    }

    /// A buffer can start mid-packet (SRT payload boundaries are not TS-aligned):
    /// the boundary is the first sync byte whose next 188-byte step is also a sync.
    #[test]
    fn resync_offset_skips_partial_leading_packet() {
        let mut buf = vec![0xAAu8; 100];
        for _ in 0..3 {
            buf.push(TS_SYNC_BYTE);
            buf.extend(std::iter::repeat_n(0x11, TS_PACKET_SIZE - 1));
        }
        assert_eq!(resync_offset(&buf), Some(100));
    }

    /// A 0x47 byte inside the leading partial packet must not be mistaken for a
    /// packet boundary — the byte 188 further on has to look like a packet too.
    #[test]
    fn resync_offset_ignores_stray_sync_byte_in_payload() {
        let mut buf = vec![0x00u8; 100];
        buf[10] = TS_SYNC_BYTE; // stray byte in the payload of the partial packet
        for _ in 0..3 {
            buf.push(TS_SYNC_BYTE);
            buf.extend(std::iter::repeat_n(0x11, TS_PACKET_SIZE - 1));
        }
        assert_eq!(resync_offset(&buf), Some(100));
    }

    /// Diagnostic: run the TS probe over a real MPEG-TS capture and report which
    /// stage got stuck. Feed it as the pipeline does (1316-byte SRT payloads,
    /// i.e. 7 TS packets).
    ///
    ///   TS_PROBE_FIXTURE=/path/capture.ts cargo test -p engine-metadata \
    ///     -- --nocapture ts_probe_real_capture
    #[test]
    fn ts_probe_real_capture() {
        let Ok(path) = std::env::var("TS_PROBE_FIXTURE") else {
            eprintln!("TS_PROBE_FIXTURE not set; skipping real-capture probe check");
            return;
        };
        let data = std::fs::read(&path).expect("read fixture");
        gst::init().expect("gst init");
        let mut state = TsProbeState::default();
        let mut detected = None;
        let mut chunks = 0usize;

        for chunk in data.chunks(1316) {
            chunks += 1;
            let buf = gst::Buffer::from_slice(chunk.to_vec());
            if let Some(info) = state.probe(&buf) {
                detected = Some(info);
                break;
            }
        }

        // Second pass over the same stream starting mid-packet, as a live SRT
        // buffer often does: the probe has to resync and still find the metadata.
        let mut mis_state = TsProbeState::default();
        let mut mis_detected = None;
        for chunk in data.get(100..).unwrap_or_default().chunks(1316) {
            let buf = gst::Buffer::from_slice(chunk.to_vec());
            if let Some(info) = mis_state.probe(&buf) {
                mis_detected = Some(info);
                break;
            }
        }
        match &mis_detected {
            Some(i) => eprintln!(
                "MISALIGNED DETECTED {}x{} video_pid={} audio_pids={:?}",
                i.width, i.height, i.video_pid, i.audio_pids
            ),
            None => eprintln!("MISALIGNED NOT DETECTED"),
        }

        eprintln!(
            "chunks={} pat_parsed={} pmt_parsed={} pmt_pid={} elementary_pid={} stream_type=0x{:02X}",
            chunks,
            state.pat_parsed,
            state.pmt_parsed,
            state.pmt_pid,
            state.elementary_pid,
            state.video_stream_type,
        );

        match detected {
            Some(i) => {
                eprintln!(
                    "DETECTED {}x{} {}/{} inferred={} interlaced={} codec={:?} profile={} level={} chroma={} depth={} sar={}/{} video_pid={} audio_pids={:?}",
                    i.width,
                    i.height,
                    i.fps_num,
                    i.fps_den,
                    i.fps_inferred,
                    i.interlaced,
                    i.codec,
                    i.profile_idc,
                    i.level_idc,
                    i.chroma_format_idc,
                    i.bit_depth,
                    i.sar_num,
                    i.sar_den,
                    i.video_pid,
                    i.audio_pids
                );
            }
            None => eprintln!("NOT DETECTED"),
        }
    }
}
