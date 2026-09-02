#ifndef TS_NORMALIZER_H
#define TS_NORMALIZER_H

#include <glib.h>

#define BG_TS_PACKET_SIZE 188
#define BG_TS_PID_COUNT 8192

typedef struct {
    gboolean initialized;
    gint active_source;
    gboolean source_offset_valid[2];
    guint64 source_offset_90k[2];
    gboolean last_pcr_valid;
    guint64 last_pcr_90k;
    guint64 pcr_step_90k;
    gboolean last_pts_valid;
    guint64 last_pts_90k;
    guint64 pts_step_90k;
    gboolean continuity_valid[BG_TS_PID_COUNT];
    guint8 continuity_counter[BG_TS_PID_COUNT];
} BgTsNormalizer;

typedef struct {
    gboolean source_changed;
    gboolean timestamps_rewritten;
    guint continuity_rewritten;
    guint64 offset_90k;
} BgTsNormalizeResult;

void bg_ts_normalizer_reset(BgTsNormalizer *normalizer);

gboolean bg_ts_normalize(BgTsNormalizer *normalizer, guint8 *data, gsize size,
                         gint source_index, BgTsNormalizeResult *result);

gboolean bg_ts_packet_get_pcr_90k(const guint8 *packet, guint64 *value);
gboolean bg_ts_packet_get_pts_90k(const guint8 *packet, guint64 *value);

#endif
