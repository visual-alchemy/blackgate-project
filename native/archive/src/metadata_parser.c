#include "metadata_parser.h"
#include "pipeline_state.h"

#include <cjson/cJSON.h>
#include <glib.h>
#include <gst/gst.h>
#include <stdio.h>
#include <string.h>

// ─── MPEG-TS constants ─────────────────────────────────────────────────────

#define TS_SYNC_BYTE 0x47
#define PAT_PID      0x0000
#define STREAM_TYPE_H264  0x1B
#define STREAM_TYPE_HEVC  0x24
#define STREAM_TYPE_MPEG2 0x02
#define TS_PACKET_SIZE 188
#define TS_HEADER_SIZE 4
#define MAX_PES_PAYLOAD (192 * 1024)

// ─── PAT parser ────────────────────────────────────────────────────────────

static int skip_adaptation_field(const unsigned char *data, int offset,
                                 int adaptation_field_control)
{
    if (adaptation_field_control == 2 || adaptation_field_control == 3) {
        if (offset < TS_PACKET_SIZE) {
            int af_length = data[offset];
            offset += 1 + af_length;
        }
    }
    return offset;
}

int parse_pat(const unsigned char *data, int length, unsigned int *pmt_pid)
{
    (void)length;

    int offset = TS_HEADER_SIZE;
    int pid = ((data[1] & 0x1F) << 8) | data[2];
    if (pid != PAT_PID) return -1;

    int adaptation_field_control = (data[3] >> 4) & 0x3;
    int has_payload = (adaptation_field_control == 1 || adaptation_field_control == 3);
    if (!has_payload) return -1;

    offset = skip_adaptation_field(data, offset, adaptation_field_control);

    // pointer_field
    if (offset >= TS_PACKET_SIZE) return -1;
    int pointer_field = data[offset++];
    offset += pointer_field;
    if (offset + 4 > TS_PACKET_SIZE) return -1;

    // table_id must be 0x00 for PAT
    if (data[offset] != 0x00) return -1;

    // section_length
    offset += 1;
    if (offset + 4 > TS_PACKET_SIZE) return -1;
    int section_length = ((data[offset] & 0x0F) << 8) | data[offset + 1];
    offset += 2;

    // skip transport_stream_id (2 bytes)
    offset += 2;

    int section_end = offset + section_length - 5 - 4;
    if (section_end > TS_PACKET_SIZE) section_end = TS_PACKET_SIZE;

    while (offset + 4 <= section_end) {
        unsigned int program_number = (data[offset] << 8) | data[offset + 1];
        offset += 2;
        if (program_number != 0 && pmt_pid) {
            *pmt_pid = ((data[offset] & 0x1F) << 8) | data[offset + 1];
            return 0;
        }
        offset += 2;
    }
    return -1;
}

// ─── PMT parser ────────────────────────────────────────────────────────────

int parse_pmt(const unsigned char *data, int length,
              unsigned int *elementary_pid, unsigned int *stream_type)
{
    (void)length;

    int offset = TS_HEADER_SIZE;
    int adaptation_field_control = (data[3] >> 4) & 0x3;
    int has_payload = (adaptation_field_control == 1 || adaptation_field_control == 3);
    if (!has_payload) return -1;

    offset = skip_adaptation_field(data, offset, adaptation_field_control);

    if (offset >= TS_PACKET_SIZE) return -1;
    int pointer_field = data[offset++];
    offset += pointer_field;
    if (offset + 4 > TS_PACKET_SIZE) return -1;

    // table_id: 0x02 for PMT
    if (data[offset] != 0x02) return -1;

    offset += 1;
    if (offset + 4 > TS_PACKET_SIZE) return -1;
    int section_length = ((data[offset] & 0x0F) << 8) | data[offset + 1];
    offset += 2;

    // skip program_number (2 bytes) + version/current (1 byte) + section/ last (1 byte)
    offset += 4;
    // PCR_PID
    offset += 2;
    // program_info_length
    if (offset + 2 > TS_PACKET_SIZE) return -1;
    int program_info_length = ((data[offset] & 0x0F) << 8) | data[offset + 1];
    offset += 2 + program_info_length;

    int section_end = offset + section_length - 5 - 4;
    if (section_end > TS_PACKET_SIZE) section_end = TS_PACKET_SIZE;

    while (offset + 5 <= section_end) {
        unsigned int st = data[offset];
        unsigned int e_pid = ((data[offset + 1] & 0x1F) << 8) | data[offset + 2];
        int es_info_length = ((data[offset + 3] & 0x0F) << 8) | data[offset + 4];

        if (st == STREAM_TYPE_H264 || st == STREAM_TYPE_HEVC || st == STREAM_TYPE_MPEG2) {
            if (elementary_pid) *elementary_pid = e_pid;
            if (stream_type) *stream_type = st;
            return 0;
        }

        offset += 5 + es_info_length;
    }
    return -1;
}

// ─── BitReader ─────────────────────────────────────────────────────────────

unsigned int read_bits(BitReader *br, int n)
{
    unsigned int result = 0;
    for (int i = 0; i < n; i++) {
        if (br->byte_position >= br->data_size) return 0;
        int bit = (br->data[br->byte_position] >> (7 - br->bit_position)) & 1;
        result = (result << 1) | bit;
        br->bit_position++;
        if (br->bit_position == 8) {
            br->bit_position = 0;
            br->byte_position++;
        }
    }
    return result;
}

unsigned int read_ue(BitReader *br)
{
    int leading_zeros = 0;
    while (read_bits(br, 1) == 0) leading_zeros++;
    unsigned int value = read_bits(br, leading_zeros);
    return (1u << leading_zeros) - 1 + value;
}

// ─── H.264 SPS parser ──────────────────────────────────────────────────────

static int bitreader_skip_scaling_list(BitReader *br, int size_of_scaling_list)
{
    int last_scale = 8;
    int next_scale = 8;
    for (int j = 0; j < size_of_scaling_list; j++) {
        if (next_scale != 0) {
            int delta_scale = (int)read_ue(br);
            next_scale = (last_scale + delta_scale + 256) % 256;
        }
        last_scale = (next_scale == 0) ? last_scale : next_scale;
    }
    return 0;
}

int parse_h264_sps(const unsigned char *nal_data, int nal_length)
{
    if (nal_length < 3) return -1;

    // NAL header: nal_ref_idc occupies the top 2 bits of the second byte;
    // nal_unit_type is bottom 5 bits of the first byte.
    int nal_unit_type = nal_data[0] & 0x1F;
    if (nal_unit_type != 7) return -1;

    // RBSP: skip NAL header bytes
    const unsigned char *rbsp = nal_data + 1;
    int rbsp_len = nal_length - 1;

    BitReader br = {rbsp, 0, 0, rbsp_len};

    unsigned int profile_idc = read_bits(&br, 8);
    (void)profile_idc;

    // constraint_set_flags (4 bits) + reserved (4 bits) = 8 bits
    read_bits(&br, 8);

    unsigned int level_idc = read_bits(&br, 8);
    (void)level_idc;

    unsigned int seq_parameter_set_id = read_ue(&br);
    (void)seq_parameter_set_id;

    unsigned int chroma_format_idc = 1;
    if (profile_idc == 100 || profile_idc == 110 || profile_idc == 122 ||
        profile_idc == 244 || profile_idc == 44  || profile_idc == 83  ||
        profile_idc == 86  || profile_idc == 118 || profile_idc == 128 ||
        profile_idc == 138 || profile_idc == 139 || profile_idc == 134 || profile_idc == 135) {
        chroma_format_idc = read_ue(&br);
        if (chroma_format_idc == 3) {
            read_bits(&br, 1);
        }
        read_ue(&br); // bit_depth_luma_minus8
        read_ue(&br); // bit_depth_chroma_minus8
        read_bits(&br, 1); // qpprime_y_zero_transform_bypass_flag
        int seq_scaling_matrix_present_flag = read_bits(&br, 1);
        if (seq_scaling_matrix_present_flag) {
            int num_scaling_lists = (chroma_format_idc != 3) ? 8 : 12;
            for (int i = 0; i < num_scaling_lists; i++) {
                int seq_scaling_list_present_flag = read_bits(&br, 1);
                if (seq_scaling_list_present_flag) {
                    if (i < 6) {
                        bitreader_skip_scaling_list(&br, 16);
                    } else {
                        bitreader_skip_scaling_list(&br, 64);
                    }
                }
            }
        }
    }

    read_ue(&br); // log2_max_frame_num_minus4

    unsigned int pic_order_cnt_type = read_ue(&br);
    if (pic_order_cnt_type == 0) {
        read_ue(&br); // log2_max_pic_order_cnt_lsb_minus4
    } else if (pic_order_cnt_type == 1) {
        read_bits(&br, 1); // delta_pic_order_always_zero_flag
        read_ue(&br);      // offset_for_non_ref_pic
        read_ue(&br);      // offset_for_top_to_bottom_field
        unsigned int num_ref_frames_in_pic_order_cnt_cycle = read_ue(&br);
        for (unsigned int i = 0; i < num_ref_frames_in_pic_order_cnt_cycle; i++) {
            read_ue(&br);
        }
    }

    read_ue(&br); // max_num_ref_frames
    read_bits(&br, 1); // gaps_in_frame_num_value_allowed_flag

    unsigned int pic_width_in_mbs = read_ue(&br) + 1;
    unsigned int pic_height_in_map_units = read_ue(&br) + 1;

    unsigned int frame_mbs_only_flag = read_bits(&br, 1);
    int interlaced = (frame_mbs_only_flag == 0);

    unsigned int width = pic_width_in_mbs * 16;
    unsigned int height;
    if (!frame_mbs_only_flag) {
        read_bits(&br, 1); // mb_adaptive_frame_field_flag
        height = pic_height_in_map_units * 32;
    } else {
        height = pic_height_in_map_units * 16;
    }

    read_bits(&br, 1); // direct_8x8_inference_flag

    int frame_cropping_flag = read_bits(&br, 1);
    int crop_left = 0, crop_right = 0, crop_top = 0, crop_bottom = 0;
    if (frame_cropping_flag) {
        crop_left   = (int)read_ue(&br);
        crop_right  = (int)read_ue(&br);
        crop_top    = (int)read_ue(&br);
        crop_bottom = (int)read_ue(&br);
    }

    int sub_width_c  = 1;
    int sub_height_c = 1;
    if (chroma_format_idc == 1) {
        sub_width_c = 2; sub_height_c = 2;
    } else if (chroma_format_idc == 2) {
        sub_width_c = 2; sub_height_c = 1;
    }

    width  -= (crop_left + crop_right)   * sub_width_c;
    height -= (crop_top  + crop_bottom)  * (2 - frame_mbs_only_flag) * sub_height_c;

    // Framerate from VUI (simplified: only read if present)
    int fps_num = 0, fps_den = 1;
    int vui_parameters_present_flag = read_bits(&br, 1);
    if (vui_parameters_present_flag) {
        int aspect_ratio_info_present_flag = read_bits(&br, 1);
        if (aspect_ratio_info_present_flag) {
            int aspect_ratio_idc = read_bits(&br, 8);
            if (aspect_ratio_idc == 255) {
                read_bits(&br, 16); // sar_width
                read_bits(&br, 16); // sar_height
            }
        }
        int overscan_info_present_flag = read_bits(&br, 1);
        if (overscan_info_present_flag) read_bits(&br, 1);
        int video_signal_type_present_flag = read_bits(&br, 1);
        if (video_signal_type_present_flag) {
            read_bits(&br, 3); read_bits(&br, 1);
            int colour_description_present_flag = read_bits(&br, 1);
            if (colour_description_present_flag) {
                read_bits(&br, 8); read_bits(&br, 8); read_bits(&br, 8);
            }
        }
        int chroma_loc_info_present_flag = read_bits(&br, 1);
        if (chroma_loc_info_present_flag) { read_ue(&br); read_ue(&br); }

        int timing_info_present_flag = read_bits(&br, 1);
        if (timing_info_present_flag) {
            unsigned int num_units_in_tick = read_bits(&br, 32);
            unsigned int time_scale         = read_bits(&br, 32);
            read_bits(&br, 1); // fixed_frame_rate_flag
            if (num_units_in_tick > 0 && time_scale > 0) {
                fps_num = (int)time_scale;
                fps_den = (int)num_units_in_tick * 2;
            }
        }
    }

    // Store in global video_info
    pthread_mutex_lock(&video_info.mutex);
    video_info.width = (int)width;
    video_info.height = (int)height;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.interlaced = interlaced;
    video_info.video_stream_type = STREAM_TYPE_H264;
    pthread_mutex_unlock(&video_info.mutex);

    g_print("meta_width:%d\n", (int)width);
    g_print("meta_height:%d\n", (int)height);
    g_print("meta_frame_rate:%d/%d\n", fps_num, fps_den);
    g_print("meta_interlaced:%d\n", interlaced);
    g_print("VIDEO_STREAM_TYPE:h264\n");

    return 0;
}

// ─── MPEG-2 sequence header parser ─────────────────────────────────────────

int parse_mpeg2_sequence(const unsigned char *data, int length)
{
    (void)length;

    if (data[0] != 0x00 || data[1] != 0x00 || data[2] != 0x01 || data[3] != 0xB3)
        return -1;

    int offset = 4;
    int width  = ((data[offset] & 0xFF) << 4) | ((data[offset + 1] >> 4) & 0xF);
    int height = ((data[offset + 1] & 0x0F) << 8) | (data[offset + 2] & 0xFF);
    offset += 3;

    int aspect_ratio = (data[offset] >> 4) & 0xF;
    offset += 1;

    int frame_rate_code = (data[offset] >> 4) & 0xF;

    static const int fps_num_table[] = {0, 24000, 24, 25, 30000, 30, 50, 60000, 60};
    static const int fps_den_table[] = {1, 1001,  1,  1,  1001,  1,  1,  1001,  1};

    int fps_num = 0, fps_den = 1;
    if (frame_rate_code >= 1 && frame_rate_code <= 8) {
        fps_num = fps_num_table[frame_rate_code];
        fps_den = fps_den_table[frame_rate_code];
    }

    int interlaced = 0;
    if (offset + 3 < length) {
        int progressive_sequence = (data[offset + 3] >> 3) & 1;
        interlaced = !progressive_sequence;
    }

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = width;
    video_info.height = height;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.interlaced = interlaced;
    video_info.video_stream_type = STREAM_TYPE_MPEG2;
    pthread_mutex_unlock(&video_info.mutex);

    g_print("meta_width:%d\n", width);
    g_print("meta_height:%d\n", height);
    g_print("meta_frame_rate:%d/%d\n", fps_num, fps_den);
    g_print("meta_interlaced:%d\n", interlaced);
    g_print("VIDEO_STREAM_TYPE:mpeg2\n");

    return 0;
}

// ─── HEVC SPS parser ───────────────────────────────────────────────────────

int parse_hevc_sps(const unsigned char *nal_data, int nal_length)
{
    if (nal_length < 4) return -1;

    // HEVC NAL: nal_unit_type in top 6 bits; skip 2-byte NAL header
    int nal_unit_type = (nal_data[0] >> 1) & 0x3F;
    if (nal_unit_type != 33 && nal_unit_type != 34) {
        return -1;
    }
    if (nal_unit_type == 33) {
        return -1;
    }

    const unsigned char *rbsp = nal_data + 2;
    int rbsp_len = nal_length - 2;
    BitReader br = {rbsp, 0, 0, rbsp_len};

    unsigned int sps_video_parameter_set_id = read_bits(&br, 4);
    (void)sps_video_parameter_set_id;

    unsigned int sps_max_sub_layers_minus1 = read_bits(&br, 3);
    read_bits(&br, 1); // sps_temporal_id_nesting_flag

    // skip profile_tier_level
    {
        read_bits(&br, 2); // general_profile_space
        read_bits(&br, 1); // general_tier_flag
        read_bits(&br, 5); // general_profile_idc
        for (int j = 0; j < 32; j++) read_bits(&br, 1);
        read_bits(&br, 1); // general_progressive_source_flag
        read_bits(&br, 1); // general_interlaced_source_flag
        read_bits(&br, 1);
        read_bits(&br, 1);
        read_bits(&br, 2);
        read_bits(&br, 8); // general_level_idc
        unsigned int sub_layer_profile_present = 0;
        unsigned int sub_layer_level_present = 0;
        for (unsigned int i = 0; i < sps_max_sub_layers_minus1; i++) {
            sub_layer_profile_present = read_bits(&br, 1);
            sub_layer_level_present  = read_bits(&br, 1);
        }
        if (sps_max_sub_layers_minus1 > 0) {
            for (unsigned int i = sps_max_sub_layers_minus1; i < 8; i++)
                read_bits(&br, 2);
        }
        for (unsigned int i = 0; i < sps_max_sub_layers_minus1; i++) {
            if (sub_layer_profile_present) {
                read_bits(&br, 2); read_bits(&br, 1); read_bits(&br, 5);
                for (int j = 0; j < 32; j++) read_bits(&br, 1);
                read_bits(&br, 1); read_bits(&br, 1); read_bits(&br, 1);
                read_bits(&br, 1); read_bits(&br, 2);
            }
            if (sub_layer_level_present)
                read_bits(&br, 8);
        }
    }

    unsigned int sps_seq_parameter_set_id = read_ue(&br);
    (void)sps_seq_parameter_set_id;

    unsigned int chroma_format_idc = read_ue(&br);
    if (chroma_format_idc == 3) read_bits(&br, 1);

    unsigned int pic_width_in_luma_samples  = read_ue(&br);
    unsigned int pic_height_in_luma_samples = read_ue(&br);

    read_bits(&br, 1); // conformance_window_flag

    // Framerate from VUI (simplified)
    int fps_num = 0, fps_den = 1;
    int vui_present = read_bits(&br, 1);
    if (vui_present) {
        read_bits(&br, 1); // aspect_ratio_info_present_flag
        read_bits(&br, 1); // overscan_info_present_flag
        int video_signal_type_present_flag = read_bits(&br, 1);
        if (video_signal_type_present_flag) { read_bits(&br, 4); }
        read_bits(&br, 1); // chroma_loc_info_present_flag
        int timing_info_present = read_bits(&br, 1);
        if (timing_info_present) {
            unsigned int num_units_in_tick = read_bits(&br, 32);
            unsigned int time_scale         = read_bits(&br, 32);
            read_bits(&br, 1);
            if (num_units_in_tick > 0 && time_scale > 0) {
                fps_num = (int)time_scale;
                fps_den = (int)num_units_in_tick;
            }
        }
    }

    int interlaced = 0;

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = (int)pic_width_in_luma_samples;
    video_info.height = (int)pic_height_in_luma_samples;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.interlaced = interlaced;
    video_info.video_stream_type = STREAM_TYPE_HEVC;
    pthread_mutex_unlock(&video_info.mutex);

    g_print("meta_width:%d\n", (int)pic_width_in_luma_samples);
    g_print("meta_height:%d\n", (int)pic_height_in_luma_samples);
    g_print("meta_frame_rate:%d/%d\n", fps_num, fps_den);
    g_print("meta_interlaced:%d\n", interlaced);
    g_print("VIDEO_STREAM_TYPE:hevc\n");

    return 0;
}

// ─── TS probe callback ─────────────────────────────────────────────────────

GstPadProbeReturn ts_probe_callback(GstPad *pad, GstPadProbeInfo *info,
                                     gpointer user_data)
{
    (void)pad; (void)user_data;

    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;

    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;

    // Buffer must be at least one TS packet
    if (map.size < (gsize)TS_PACKET_SIZE) {
        gst_buffer_unmap(buf, &map);
        return GST_PAD_PROBE_OK;
    }

    static int pat_parsed = 0;
    static int pmt_parsed = 0;
    static unsigned int pmt_pid = 0;
    static unsigned int elementary_pid = 0;
    static unsigned int video_stream_type = 0;
    static unsigned char pes_buffer[MAX_PES_PAYLOAD];
    static int pes_buf_len = 0;
    static int metadata_reported = 0;
    static int metadata_attempts = 0;

    if (metadata_reported) {
        gst_buffer_unmap(buf, &map);
        return GST_PAD_PROBE_OK;
    }

    if (metadata_attempts > 500) {
        gst_buffer_unmap(buf, &map);
        g_print("VIDEO_STREAM_TYPE:unknown\n");
        metadata_reported = 1;
        return GST_PAD_PROBE_OK;
    }

    int num_packets = map.size / TS_PACKET_SIZE;
    for (int p = 0; p < num_packets; p++) {
        const unsigned char *ts = map.data + p * TS_PACKET_SIZE;

        if (ts[0] != TS_SYNC_BYTE) continue;

        unsigned int pid = ((ts[1] & 0x1F) << 8) | ts[2];

        // PAT
        if (!pat_parsed && pid == PAT_PID) {
            if (parse_pat(ts, TS_PACKET_SIZE, &pmt_pid) == 0) {
                pat_parsed = 1;
            }
        }

        // PMT
        if (pat_parsed && !pmt_parsed && pid == pmt_pid) {
            if (parse_pmt(ts, TS_PACKET_SIZE, &elementary_pid, &video_stream_type) == 0) {
                pmt_parsed = 1;
            }
        }

        // Video PES
        if (pmt_parsed && pid == elementary_pid && !metadata_reported) {
            int adaptation_field_control = (ts[3] >> 4) & 0x3;
            int has_payload = (adaptation_field_control == 1 || adaptation_field_control == 3);
            if (!has_payload) continue;

            int offset = skip_adaptation_field(ts, TS_HEADER_SIZE, adaptation_field_control);
            int payload_size = TS_PACKET_SIZE - offset;

            if (payload_size <= 0) continue;

            int is_pes_start = ((ts[1] & 0x40) != 0);
            if (is_pes_start) {
                // Start new PES buffer
                // PES header: packet_start_code_prefix(3) + stream_id(1) + PES_packet_length(2)
                if (payload_size < 6) continue;
                pes_buf_len = 0;
            }

            if (pes_buf_len + payload_size <= MAX_PES_PAYLOAD) {
                memcpy(pes_buffer + pes_buf_len, ts + offset, payload_size);
                pes_buf_len += payload_size;
            }

            metadata_attempts++;

            // Try parsing SPS/sequence header
            if (video_stream_type == STREAM_TYPE_H264) {
                // H.264: find NAL start code 0x00000001
                for (int i = 0; i <= pes_buf_len - 5; i++) {
                    if (pes_buffer[i] == 0x00 && pes_buffer[i+1] == 0x00 &&
                        pes_buffer[i+2] == 0x00 && pes_buffer[i+3] == 0x01) {
                        int nal_type = pes_buffer[i+4] & 0x1F;
                        if (nal_type == 7) {
                            if (parse_h264_sps(pes_buffer + i + 4, pes_buf_len - i - 4) == 0) {
                                metadata_reported = 1;
                                break;
                            }
                        }
                    }
                }
            } else if (video_stream_type == STREAM_TYPE_HEVC) {
                // HEVC: find NAL start code 0x00000001
                for (int i = 0; i <= pes_buf_len - 6; i++) {
                    if (pes_buffer[i] == 0x00 && pes_buffer[i+1] == 0x00 &&
                        pes_buffer[i+2] == 0x00 && pes_buffer[i+3] == 0x01) {
                        int nal_type = (pes_buffer[i+4] >> 1) & 0x3F;
                        if (nal_type == 33 || nal_type == 34) {
                            if (parse_hevc_sps(pes_buffer + i + 4, pes_buf_len - i - 4) == 0) {
                                metadata_reported = 1;
                                break;
                            }
                        }
                    }
                }
            } else if (video_stream_type == STREAM_TYPE_MPEG2) {
                for (int i = 0; i <= pes_buf_len - 4; i++) {
                    if (pes_buffer[i] == 0x00 && pes_buffer[i+1] == 0x00 &&
                        pes_buffer[i+2] == 0x01 && pes_buffer[i+3] == 0xB3) {
                        if (parse_mpeg2_sequence(pes_buffer + i, pes_buf_len - i) == 0) {
                            metadata_reported = 1;
                            break;
                        }
                    }
                }
            }
        }
    }

    gst_buffer_unmap(buf, &map);
    return GST_PAD_PROBE_OK;
}
