#include "../include/ts_normalizer.h"

#include <string.h>

#define TS_SYNC_BYTE 0x47
#define TS_TIMESTAMP_MASK ((1ULL << 33) - 1)
#define DEFAULT_STEP_90K 3600
#define MAX_TRACKED_STEP_90K 90000

static guint64 add_33(guint64 value, guint64 offset)
{
    return (value + offset) & TS_TIMESTAMP_MASK;
}

static guint64 forward_delta_33(guint64 newer, guint64 older)
{
    return (newer - older) & TS_TIMESTAMP_MASK;
}

static gboolean packet_payload(const guint8 *packet, const guint8 **payload,
                               gsize *payload_size)
{
    guint8 adaptation_control = (packet[3] >> 4) & 0x03;
    if (!(adaptation_control & 0x01)) return FALSE;

    gsize offset = 4;
    if (adaptation_control & 0x02) {
        offset += 1 + packet[4];
    }
    if (offset >= BG_TS_PACKET_SIZE) return FALSE;

    *payload = packet + offset;
    *payload_size = BG_TS_PACKET_SIZE - offset;
    return TRUE;
}

static guint64 read_timestamp_33(const guint8 *bytes)
{
    return (((guint64)(bytes[0] >> 1) & 0x07) << 30) |
           ((guint64)bytes[1] << 22) |
           (((guint64)bytes[2] >> 1) << 15) |
           ((guint64)bytes[3] << 7) |
           ((guint64)bytes[4] >> 1);
}

static void write_timestamp_33(guint8 *bytes, guint64 value)
{
    value &= TS_TIMESTAMP_MASK;
    bytes[0] = (bytes[0] & 0xF0) | (((value >> 30) & 0x07) << 1) | 0x01;
    bytes[1] = (value >> 22) & 0xFF;
    bytes[2] = (((value >> 15) & 0x7F) << 1) | 0x01;
    bytes[3] = (value >> 7) & 0xFF;
    bytes[4] = ((value & 0x7F) << 1) | 0x01;
}

static gboolean packet_pes_timestamps(guint8 *packet, guint8 **pts, guint8 **dts)
{
    const guint8 *payload_const = NULL;
    gsize payload_size = 0;
    if (!(packet[1] & 0x40) ||
        !packet_payload(packet, &payload_const, &payload_size) || payload_size < 14) {
        return FALSE;
    }

    guint8 *payload = (guint8 *)payload_const;
    if (payload[0] != 0x00 || payload[1] != 0x00 || payload[2] != 0x01) return FALSE;

    guint8 flags = (payload[7] >> 6) & 0x03;
    guint8 header_length = payload[8];
    if ((flags != 0x02 && flags != 0x03) || header_length < 5 || payload_size < 14) {
        return FALSE;
    }

    *pts = payload + 9;
    *dts = NULL;
    if (flags == 0x03 && header_length >= 10 && payload_size >= 19) {
        *dts = payload + 14;
    }
    return TRUE;
}

gboolean bg_ts_packet_get_pcr_90k(const guint8 *packet, guint64 *value)
{
    if (!packet || packet[0] != TS_SYNC_BYTE) return FALSE;

    guint8 adaptation_control = (packet[3] >> 4) & 0x03;
    if (!(adaptation_control & 0x02) || packet[4] < 7 || !(packet[5] & 0x10)) {
        return FALSE;
    }

    guint64 base = ((guint64)packet[6] << 25) |
                   ((guint64)packet[7] << 17) |
                   ((guint64)packet[8] << 9) |
                   ((guint64)packet[9] << 1) |
                   ((guint64)packet[10] >> 7);
    if (value) *value = base & TS_TIMESTAMP_MASK;
    return TRUE;
}

gboolean bg_ts_packet_get_pts_90k(const guint8 *packet, guint64 *value)
{
    if (!packet || packet[0] != TS_SYNC_BYTE) return FALSE;

    guint8 *pts = NULL;
    guint8 *dts = NULL;
    if (!packet_pes_timestamps((guint8 *)packet, &pts, &dts)) return FALSE;
    (void)dts;
    if (value) *value = read_timestamp_33(pts);
    return TRUE;
}

static void packet_set_pcr_offset(guint8 *packet, guint64 offset)
{
    guint64 base = 0;
    if (!bg_ts_packet_get_pcr_90k(packet, &base)) return;

    base = add_33(base, offset);
    packet[6] = (base >> 25) & 0xFF;
    packet[7] = (base >> 17) & 0xFF;
    packet[8] = (base >> 9) & 0xFF;
    packet[9] = (base >> 1) & 0xFF;
    packet[10] = (packet[10] & 0x7F) | ((base & 0x01) << 7);
}

static gboolean packet_set_pes_timestamp_offset(guint8 *packet, guint64 offset)
{
    guint8 *pts = NULL;
    guint8 *dts = NULL;
    if (!packet_pes_timestamps(packet, &pts, &dts)) return FALSE;

    write_timestamp_33(pts, add_33(read_timestamp_33(pts), offset));
    if (dts) write_timestamp_33(dts, add_33(read_timestamp_33(dts), offset));
    return TRUE;
}

static gboolean find_first_timestamp(const guint8 *data, gsize size,
                                     guint64 *value, gboolean *is_pcr)
{
    guint64 first_pts = 0;
    gboolean have_pts = FALSE;
    gsize first_packet = 0;
    while (first_packet < size && first_packet < BG_TS_PACKET_SIZE &&
           data[first_packet] != TS_SYNC_BYTE) {
        first_packet++;
    }

    for (gsize offset = first_packet; offset + BG_TS_PACKET_SIZE <= size;
         offset += BG_TS_PACKET_SIZE) {
        const guint8 *packet = data + offset;
        guint64 timestamp = 0;
        if (bg_ts_packet_get_pcr_90k(packet, &timestamp)) {
            *value = timestamp;
            *is_pcr = TRUE;
            return TRUE;
        }
        if (!have_pts && bg_ts_packet_get_pts_90k(packet, &timestamp)) {
            first_pts = timestamp;
            have_pts = TRUE;
        }
    }

    if (have_pts) {
        *value = first_pts;
        *is_pcr = FALSE;
        return TRUE;
    }
    return FALSE;
}

void bg_ts_normalizer_reset(BgTsNormalizer *normalizer)
{
    if (!normalizer) return;
    memset(normalizer, 0, sizeof(*normalizer));
    normalizer->active_source = -1;
    normalizer->pcr_step_90k = DEFAULT_STEP_90K;
    normalizer->pts_step_90k = DEFAULT_STEP_90K;
    normalizer->initialized = TRUE;
}

static guint64 choose_source_offset(BgTsNormalizer *normalizer,
                                    const guint8 *data, gsize size)
{
    guint64 incoming = 0;
    gboolean is_pcr = FALSE;
    if (!find_first_timestamp(data, size, &incoming, &is_pcr)) return 0;

    guint64 desired = incoming;
    if (is_pcr && normalizer->last_pcr_valid) {
        desired = add_33(normalizer->last_pcr_90k, normalizer->pcr_step_90k);
    } else if (!is_pcr && normalizer->last_pts_valid) {
        desired = add_33(normalizer->last_pts_90k, normalizer->pts_step_90k);
    } else if (normalizer->last_pcr_valid) {
        desired = add_33(normalizer->last_pcr_90k, normalizer->pcr_step_90k);
    } else if (normalizer->last_pts_valid) {
        desired = add_33(normalizer->last_pts_90k, normalizer->pts_step_90k);
    }

    return forward_delta_33(desired, incoming);
}

static void rewrite_continuity(BgTsNormalizer *normalizer, guint8 *packet,
                               BgTsNormalizeResult *result)
{
    guint16 pid = ((packet[1] & 0x1F) << 8) | packet[2];
    guint8 adaptation_control = (packet[3] >> 4) & 0x03;
    gboolean has_payload = adaptation_control & 0x01;

    if (!normalizer->continuity_valid[pid]) {
        normalizer->continuity_counter[pid] = packet[3] & 0x0F;
        normalizer->continuity_valid[pid] = TRUE;
        return;
    }

    guint8 next = normalizer->continuity_counter[pid];
    if (has_payload) next = (next + 1) & 0x0F;
    if ((packet[3] & 0x0F) != next) result->continuity_rewritten++;
    packet[3] = (packet[3] & 0xF0) | next;
    normalizer->continuity_counter[pid] = next;
}

static void track_output_timestamps(BgTsNormalizer *normalizer,
                                    const guint8 *packet)
{
    guint64 value = 0;
    if (bg_ts_packet_get_pcr_90k(packet, &value)) {
        if (normalizer->last_pcr_valid) {
            guint64 step = forward_delta_33(value, normalizer->last_pcr_90k);
            if (step > 0 && step <= MAX_TRACKED_STEP_90K) {
                normalizer->pcr_step_90k = step;
            }
        }
        normalizer->last_pcr_90k = value;
        normalizer->last_pcr_valid = TRUE;
    }

    if (bg_ts_packet_get_pts_90k(packet, &value)) {
        if (normalizer->last_pts_valid) {
            guint64 step = forward_delta_33(value, normalizer->last_pts_90k);
            if (step > 0 && step <= MAX_TRACKED_STEP_90K) {
                normalizer->pts_step_90k = step;
            }
        }
        normalizer->last_pts_90k = value;
        normalizer->last_pts_valid = TRUE;
    }
}

gboolean bg_ts_normalize(BgTsNormalizer *normalizer, guint8 *data, gsize size,
                         gint source_index, BgTsNormalizeResult *result)
{
    if (!normalizer || !data || source_index < 0 || source_index > 1 ||
        size < BG_TS_PACKET_SIZE) {
        return FALSE;
    }
    if (!normalizer->initialized) bg_ts_normalizer_reset(normalizer);

    BgTsNormalizeResult local_result = {0};
    if (!result) result = &local_result;
    memset(result, 0, sizeof(*result));

    gboolean source_changed = normalizer->active_source != source_index;
    if (source_changed) {
        gboolean had_active_source = normalizer->active_source >= 0;
        guint64 offset = had_active_source
                             ? choose_source_offset(normalizer, data, size)
                             : 0;
        normalizer->source_offset_90k[source_index] = offset;
        normalizer->source_offset_valid[source_index] = TRUE;
        normalizer->active_source = source_index;
        result->source_changed = had_active_source;
        result->offset_90k = offset;
    }

    guint64 timestamp_offset = normalizer->source_offset_valid[source_index]
                                   ? normalizer->source_offset_90k[source_index]
                                   : 0;
    gsize first_packet = 0;
    while (first_packet < size && first_packet < BG_TS_PACKET_SIZE &&
           data[first_packet] != TS_SYNC_BYTE) {
        first_packet++;
    }

    for (gsize offset = first_packet; offset + BG_TS_PACKET_SIZE <= size;
         offset += BG_TS_PACKET_SIZE) {
        guint8 *packet = data + offset;
        if (packet[0] != TS_SYNC_BYTE) continue;

        guint64 pcr = 0;
        gboolean has_pcr = bg_ts_packet_get_pcr_90k(packet, &pcr);
        gboolean has_pts = bg_ts_packet_get_pts_90k(packet, NULL);
        if (has_pcr) packet_set_pcr_offset(packet, timestamp_offset);
        if (has_pts) packet_set_pes_timestamp_offset(packet, timestamp_offset);
        if ((has_pcr || has_pts) && timestamp_offset != 0) {
            result->timestamps_rewritten = TRUE;
        }

        rewrite_continuity(normalizer, packet, result);
        track_output_timestamps(normalizer, packet);
    }

    return TRUE;
}
