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

fn parse_pmt(data: &[u8], elementary_pid: &mut u32, stream_type: &mut u8) -> bool {
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
    offset += 4; // skip program_number + version/current + section/last
    offset += 2; // skip PCR_PID

    if offset + 2 > TS_PACKET_SIZE {
        return false;
    }
    let program_info_length = ((data[offset] as usize & 0x0F) << 8) | data[offset + 1] as usize;
    offset += 2 + program_info_length;

    let mut section_end = offset + section_length - 5 - 4;
    if section_end > TS_PACKET_SIZE {
        section_end = TS_PACKET_SIZE;
    }

    while offset + 5 <= section_end {
        let st = data[offset];
        let e_pid = ((data[offset + 1] as u32 & 0x1F) << 8) | data[offset + 2] as u32;
        let es_info_length = ((data[offset + 3] as usize & 0x0F) << 8) | data[offset + 4] as usize;

        if st == STREAM_TYPE_H264 || st == STREAM_TYPE_HEVC || st == STREAM_TYPE_MPEG2 {
            *elementary_pid = e_pid;
            *stream_type = st;
            return true;
        }
        offset += 5 + es_info_length;
    }
    false
}

// ─── H.264 SPS Parser ──────────────────────────────────────────────────────

fn parse_h264_sps(nal_data: &[u8]) -> Option<VideoInfo> {
    if nal_data.len() < 3 {
        return None;
    }

    let nal_unit_type = nal_data[0] & 0x1F;
    if nal_unit_type != 7 {
        return None;
    }

    let rbsp = &nal_data[1..];
    let mut br = BitReader::new(rbsp);

    let profile_idc = br.read_bits(8);
    br.read_bits(8); // constraint + reserved
    br.read_bits(8); // level_idc
    br.read_ue(); // seq_parameter_set_id

    let mut chroma_format_idc = 1u32;
    let high_profile = matches!(
        profile_idc,
        100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135
    );
    if high_profile {
        chroma_format_idc = br.read_ue();
        if chroma_format_idc == 3 {
            br.read_bits(1);
        }
        br.read_ue(); // bit_depth_luma_minus8
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

    // VUI — framerate
    let (mut fps_num, mut fps_den) = (0u32, 1u32);
    if br.read_bits(1) != 0 {
        // aspect_ratio
        let ar_present = br.read_bits(1);
        if ar_present != 0 {
            let ar_idc = br.read_bits(8);
            if ar_idc == 255 {
                br.read_bits(16);
                br.read_bits(16);
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

    let rbsp = &nal_data[2..];
    let mut br = BitReader::new(rbsp);

    br.read_bits(4); // sps_video_parameter_set_id
    let max_sub_layers = br.read_bits(3);
    br.read_bits(1); // sps_temporal_id_nesting_flag

    // profile_tier_level (bulk skip)
    br.read_bits(2); // general_profile_space
    br.read_bits(1); // general_tier_flag
    br.read_bits(5); // general_profile_idc
    for _ in 0..32 {
        br.read_bits(1);
    }
    br.read_bits(1); // general_progressive_source_flag
    br.read_bits(1); // general_interlaced_source_flag
    br.read_bits(3); // non_packed + frame_only
    br.read_bits(8); // general_level_idc
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
    br.read_bits(1); // conformance_window_flag

    // VUI — framerate
    let (mut fps_num, mut fps_den) = (0u32, 1u32);
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
            }
        }
    }

    Some(VideoInfo {
        width: pic_width,
        height: pic_height,
        fps_num,
        fps_den,
        interlaced: false,
        codec: VideoCodec::HEVC,
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
    pes_buffer: Vec<u8>,
    metadata_attempts: u32,
}

impl Default for TsProbeState {
    fn default() -> Self {
        Self {
            pat_parsed: false,
            pmt_parsed: false,
            pmt_pid: 0,
            elementary_pid: 0,
            video_stream_type: 0,
            pes_buffer: Vec::with_capacity(MAX_PES_PAYLOAD),
            metadata_attempts: 0,
        }
    }
}

impl TsProbeState {
    /// True when the 500-attempt cap is exceeded (C: VIDEO_STREAM_TYPE:unknown).
    pub fn attempts_exceeded(&self) -> bool {
        self.metadata_attempts > 500
    }

    pub fn probe(&mut self, buf: &gst::Buffer) -> Option<VideoInfo> {
        let map = buf.map_readable().ok()?;
        if map.len() < TS_PACKET_SIZE {
            return None;
        }
        if self.metadata_attempts > 500 {
            return None;
        }

        let num_packets = map.len() / TS_PACKET_SIZE;
        for p in 0..num_packets {
            let ts = &map[p * TS_PACKET_SIZE..(p + 1) * TS_PACKET_SIZE];
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
                if parse_pmt(ts, &mut epid, &mut st) {
                    self.pmt_parsed = true;
                    self.elementary_pid = epid;
                    self.video_stream_type = st;
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

                self.metadata_attempts += 1;

                let result = match self.video_stream_type {
                    STREAM_TYPE_H264 => self.scan_h264_start_codes(),
                    STREAM_TYPE_HEVC => self.scan_hevc_start_codes(),
                    STREAM_TYPE_MPEG2 => self.scan_mpeg2_start_codes(),
                    _ => None,
                };

                if result.is_some() {
                    return result;
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
}
