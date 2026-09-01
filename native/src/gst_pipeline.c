#include "gst_pipeline.h"

#include <gio/gio.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <pthread.h>
#include <srt/srt.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#include "unix_socket.h"

#define MAX_SINKS 32

static gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config, int sink_index);
static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property);
static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc);
static void collect_sink_stats(void);

// Forward declarations for SDI decodebin callbacks
static void on_sdi_tsdemux_pad_added(GstElement *src, GstPad *new_pad, gpointer user_data);
static void on_sdi_decodebin_video_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data);
static void on_sdi_decodebin_audio_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data);

// SDI Audio Health Monitor — tracks last audio buffer time per device
// Only prints a warning when audio stops flowing (not every buffer)
#define SDI_AUDIO_HEALTH_INTERVAL_SEC 10
static volatile gint64 sdi_audio_last_buffer_time[8] = {0};
static volatile gint64 sdi_audio_buffer_count[8] = {0};
static volatile gboolean sdi_audio_silence_reported[8] = {FALSE};

// SDI Video Health Monitor — tracks last video frame time and count per device
static volatile gint64 sdi_video_last_buffer_time[8] = {0};
static volatile gint64 sdi_video_buffer_count[8] = {0};

static GstElement *sdi_vrate_elements[8] = {NULL};

// SDI Auto-Detect: detected mode string per device (populated by auto-detect callback)
static const char *sdi_detected_mode[8] = {NULL};

// Global active route ID
static char global_route_id[128] = {0};

// =============================================================================
// DeckLink Mode Lookup Table
// Maps detected {width, height, fps_num, fps_den, interlaced} → DeckLink mode
// =============================================================================
typedef struct {
    int width;
    int height;
    int fps_num;
    int fps_den;
    gboolean interlaced;
    const char *mode_str;            // GStreamer enum nick for decklinkvideosink mode
    const char *caps_interlace_mode; // "interleaved" for interlaced modes, NULL for progressive
} DeckLinkModeEntry;

static const DeckLinkModeEntry decklink_mode_table[] = {
    // HD Progressive
    {1920, 1080, 24000, 1001, FALSE, "1080p2398", NULL},
    {1920, 1080, 24,    1,    FALSE, "1080p24",   NULL},
    {1920, 1080, 25,    1,    FALSE, "1080p25",   NULL},
    {1920, 1080, 30000, 1001, FALSE, "1080p2997", NULL},
    {1920, 1080, 30,    1,    FALSE, "1080p30",   NULL},
    {1920, 1080, 50,    1,    FALSE, "1080p50",   NULL},
    {1920, 1080, 60000, 1001, FALSE, "1080p5994", NULL},
    {1920, 1080, 60,    1,    FALSE, "1080p60",   NULL},
    // HD Interlaced
    {1920, 1080, 25,    1,    TRUE,  "1080i50",   "interleaved"},
    {1920, 1080, 30000, 1001, TRUE,  "1080i5994", "interleaved"},
    {1920, 1080, 30,    1,    TRUE,  "1080i60",   "interleaved"},
    // 720p Progressive
    {1280,  720, 50,    1,    FALSE, "720p50",    NULL},
    {1280,  720, 60000, 1001, FALSE, "720p5994",  NULL},
    {1280,  720, 60,    1,    FALSE, "720p60",    NULL},
    // SD Interlaced
    { 720,  576, 25,    1,    TRUE,  "pal",       "interleaved"},
    { 720,  480, 30000, 1001, TRUE,  "ntsc",      "interleaved"},
    { 720,  480, 30,    1,    TRUE,  "ntsc",      "interleaved"},
    // 4K UHD Progressive
    {3840, 2160, 24000, 1001, FALSE, "2160p2398", NULL},
    {3840, 2160, 24,    1,    FALSE, "2160p24",   NULL},
    {3840, 2160, 25,    1,    FALSE, "2160p25",   NULL},
    {3840, 2160, 30000, 1001, FALSE, "2160p2997", NULL},
    {3840, 2160, 30,    1,    FALSE, "2160p30",   NULL},
    {3840, 2160, 50,    1,    FALSE, "2160p50",   NULL},
    {3840, 2160, 60000, 1001, FALSE, "2160p5994", NULL},
    {3840, 2160, 60,    1,    FALSE, "2160p60",   NULL},
    // Sentinel (end of table)
    {0, 0, 0, 0, FALSE, NULL, NULL},
};

// Lookup a DeckLink mode entry matching the given video properties.
// Returns a pointer to the matching entry, or NULL if no match found.
static const DeckLinkModeEntry *lookup_decklink_mode(int width, int height,
                                                      int fps_num, int fps_den,
                                                      gboolean interlaced)
{
    for (int i = 0; decklink_mode_table[i].mode_str != NULL; i++) {
        const DeckLinkModeEntry *e = &decklink_mode_table[i];
        if (e->width == width && e->height == height &&
            e->fps_num == fps_num && e->fps_den == fps_den &&
            e->interlaced == interlaced) {
            return e;
        }
    }
    return NULL;
}

// Context struct for SDI auto-detect deferred video chain linking.
// Passed as user_data to the decodebin pad-added callback when video_mode is "auto".
typedef struct {
    GstElement *pipeline;
    GstElement *vqueue;
    GstElement *vconvert;
    GstElement *vrate;
    GstElement *vscale;
    GstElement *vcaps;
    GstElement *vid_identity;
    GstElement *videosink;
    int device_number;
    int sink_index;
    // Fallback values (used when auto-detect can't match a broadcast standard)
    char fallback_mode[32];
    int fallback_width;
    int fallback_height;
    char fallback_framerate[16];
} SdiAutoDetectCtx;

// INVARIANT: switch_source() clears s_sdi_applied_caps[slot]; the vqueue-sink
// probe (below) re-applies mode+caps when flowing caps differ from it.
static SdiAutoDetectCtx *s_sdi_auto_ctx[8]     = {0};
static GstPad          *s_sdi_vq_sink_pad[8]   = {0};
static GstElement      *s_sdi_vinterlace[8]    = {0};
static char             s_sdi_applied_caps[8][256] = {{0}};

// SDI branch registry per sink slot. switch_source() rebuilds branches through
// add_sink_to_pipeline(); tsdemux/decodebin pad churn across different-muxer
// feeds is not reliably migratable pad-by-pad, so teardown+rebuild is the
// strategy. Element[0] is always the branch's input queue (tee peer).
#define SDI_BRANCH_MAX_ELEMS 24
static GstElement *s_sdi_branch_elems[8][SDI_BRANCH_MAX_ELEMS];
static int         s_sdi_branch_n[8] = {0};
static int         s_sdi_branch_device[8] = {-1,-1,-1,-1,-1,-1,-1,-1};
static char       *s_sdi_sink_json[8] = {NULL};
static GstElement *g_pipeline = NULL;
static GstElement *tee_element; // tentative; defined with initializer below
// Pacing elements per slot: teardown clears their sync flag first so the
// 5s branch queues drain instantly instead of wall-clock paced.
static GstElement *s_sdi_branch_identity[8] = {NULL};
static GstElement *s_sdi_branch_vsink[8]    = {NULL};
static GstElement *s_sdi_branch_asink[8]    = {NULL};
static GstElement *s_sdi_branch_q2[8]       = {NULL};
static GstElement *s_sdi_branch_vq[8]       = {NULL};
static GstElement *s_sdi_branch_aq[8]       = {NULL};

static void sdi_branch_track(int slot, int device_num, GstElement *first, ...);
static void sdi_branch_untrack(int slot, GstElement *elem);

// Re-run mode matching + capsfilter/interlace-element application for a slot
// from the caps currently flowing into vqueue. Also updates decklinkvideosink
// mode and sdi_detected_mode[].
static void sdi_reapply_mode(int slot, GstCaps *caps)
{
    SdiAutoDetectCtx *ctx = s_sdi_auto_ctx[slot];
    if (!ctx || !caps || gst_caps_is_empty(caps)) return;

    GstCaps *nc = gst_caps_make_writable(gst_caps_copy(caps));
    GstStructure *s = gst_caps_get_structure(nc, 0);
    gst_structure_fixate(s);

    gint width = 0, height = 0, fps_num = 0, fps_den = 1;
    gboolean interlaced = FALSE;
    gst_structure_get_int(s, "width", &width);
    gst_structure_get_int(s, "height", &height);
    gst_structure_get_fraction(s, "framerate", &fps_num, &fps_den);
    const gchar *ims = gst_structure_get_string(s, "interlace-mode");
    if (ims && g_strcmp0(ims, "interleaved") == 0) interlaced = TRUE;
    gst_caps_unref(nc);

    if (width <= 0 || height <= 0 || fps_num <= 0) return;

    int lookup_num = fps_num, lookup_den = fps_den;
    if (fps_den == 1001 && (fps_num == 24000 || fps_num == 30000 || fps_num == 60000)) {
        lookup_num = fps_num / 1000; lookup_den = 1;
    } else if (fps_den == 1001 && fps_num == 50000) {
        lookup_num = 50; lookup_den = 1;
    } else if (fps_den != 1 && fps_den != 0) {
        lookup_num = (fps_num + fps_den / 2) / fps_den; lookup_den = 1;
    }

    const DeckLinkModeEntry *entry = lookup_decklink_mode(width, height, fps_num, fps_den, interlaced);
    if (!entry && (lookup_num != fps_num || lookup_den != fps_den))
        entry = lookup_decklink_mode(width, height, lookup_num, lookup_den, interlaced);

    const char *mode_str;
    int out_w, out_h;
    const char *out_fr;
    gboolean need_interlace = FALSE;
    const char *out_im = NULL;
    char fr_buf[16];

    if (entry) {
        mode_str = entry->mode_str;
        out_w = entry->width;
        out_h = entry->height;
        out_im = entry->caps_interlace_mode;
        need_interlace = (!interlaced && entry->caps_interlace_mode != NULL);
        snprintf(fr_buf, sizeof(fr_buf), "%d/%d", entry->fps_num, entry->fps_den);
        out_fr = fr_buf;
    } else {
        mode_str = ctx->fallback_mode;
        out_w = ctx->fallback_width;
        out_h = ctx->fallback_height;
        out_fr = ctx->fallback_framerate;
        if (strstr(mode_str, "i") != NULL || strcmp(mode_str, "pal") == 0 || strcmp(mode_str, "ntsc") == 0) {
            need_interlace = !interlaced;
            out_im = "interleaved";
        }
    }

    if (ctx->device_number >= 0 && ctx->device_number < 8)
        sdi_detected_mode[ctx->device_number] = mode_str;

    gst_util_set_object_arg(G_OBJECT(ctx->videosink), "mode", mode_str);

    char caps_str[256];
    if (out_im)
        snprintf(caps_str, sizeof(caps_str),
                 "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s, interlace-mode=%s",
                 out_w, out_h, out_fr, out_im);
    else
        snprintf(caps_str, sizeof(caps_str),
                 "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s",
                 out_w, out_h, out_fr);

    gboolean has_interlace = (s_sdi_vinterlace[slot] != NULL);
    g_print("SDI AUTO-DETECT: re-apply for switch → mode=%s need_interlace=%s (chain has=%s)\n",
            mode_str, need_interlace ? "yes" : "no", has_interlace ? "yes" : "no");

    if (need_interlace == has_interlace) {
        GstCaps *out_caps = gst_caps_from_string(caps_str);
        g_object_set(ctx->vcaps, "caps", out_caps, NULL);
        gst_caps_unref(out_caps);
    } else if (need_interlace && !has_interlace) {
        // vscale → vcaps becomes vscale → vinterlace → vcaps
        GstElement *vinterlace = gst_element_factory_make("interlace", NULL);
        if (vinterlace) {
            gst_util_set_object_arg(G_OBJECT(vinterlace), "field-pattern", "2:2");
            g_object_set(vinterlace, "top-field-first", TRUE, NULL);
            gst_bin_add(GST_BIN(ctx->pipeline), vinterlace);
            gst_element_unlink(ctx->vscale, ctx->vcaps);
            if (gst_element_link_many(ctx->vscale, vinterlace, ctx->vcaps, NULL)) {
                gst_element_sync_state_with_parent(vinterlace);
                s_sdi_vinterlace[slot] = vinterlace;
                sdi_branch_track(slot, ctx->device_number, vinterlace, NULL);
                g_print("SDI AUTO-DETECT: interlace element inserted for switched source\n");
            } else {
                g_printerr("SDI AUTO-DETECT: interlace insert link failed — reverting\n");
                gst_element_unlink(ctx->vscale, vinterlace);
                gst_bin_remove(GST_BIN(ctx->pipeline), vinterlace);
                GstCaps *out_caps = gst_caps_from_string(caps_str);
                g_object_set(ctx->vcaps, "caps", out_caps, NULL);
                gst_caps_unref(out_caps);
            }
        }
    } else if (!need_interlace && has_interlace) {
        // vscale → vinterlace → vcaps becomes vscale → vcaps
        GstElement *vinterlace = s_sdi_vinterlace[slot];
        gst_element_unlink(ctx->vscale, vinterlace);
        gst_element_unlink(vinterlace, ctx->vcaps);
        gst_element_set_state(vinterlace, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(ctx->pipeline), vinterlace);
        gst_object_unref(vinterlace);
        sdi_branch_untrack(slot, vinterlace);
        s_sdi_vinterlace[slot] = NULL;
        GstCaps *out_caps = gst_caps_from_string(caps_str);
        g_object_set(ctx->vcaps, "caps", out_caps, NULL);
        gst_caps_unref(out_caps);
        g_print("SDI AUTO-DETECT: interlace element removed for switched source\n");
    }

    snprintf(s_sdi_applied_caps[slot], sizeof(s_sdi_applied_caps[slot]),
             "%dx%d@%d/%d%s", width, height, lookup_num, lookup_den,
             interlaced ? "i" : "p");
    g_print("SDI AUTO-DETECT: re-applied → %dx%d@%d/%d %s mode=%s\n",
            out_w, out_h, lookup_num, lookup_den, interlaced ? "interlaced" : "progressive",
            mode_str);
}

// vqueue-sink probe: s_sdi_applied_caps[slot] is cleared by switch_source();
// when flowing caps differ from the stored set, re-apply mode + capsfilter.
static GstPadProbeReturn sdi_caps_reapply_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)info;
    int slot = GPOINTER_TO_INT(user_data);
    SdiAutoDetectCtx *ctx = s_sdi_auto_ctx[slot];
    if (!ctx) return GST_PAD_PROBE_OK;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return GST_PAD_PROBE_OK;

    GstCaps *nc = gst_caps_make_writable(gst_caps_copy(caps));
    GstStructure *s = gst_caps_get_structure(nc, 0);
    gst_structure_fixate(s);

    gint width = 0, height = 0, fps_num = 0, fps_den = 1;
    gboolean interlaced = FALSE;
    gst_structure_get_int(s, "width", &width);
    gst_structure_get_int(s, "height", &height);
    gst_structure_get_fraction(s, "framerate", &fps_num, &fps_den);
    const gchar *ims = gst_structure_get_string(s, "interlace-mode");
    if (ims && g_strcmp0(ims, "interleaved") == 0) interlaced = TRUE;
    gst_caps_unref(nc);

    if (width <= 0 || height <= 0 || fps_num <= 0) {
        gst_caps_unref(caps);
        return GST_PAD_PROBE_OK;
    }

    int lookup_num = fps_num, lookup_den = fps_den;
    if (fps_den == 1001 && (fps_num == 24000 || fps_num == 30000 || fps_num == 60000)) {
        lookup_num = fps_num / 1000; lookup_den = 1;
    } else if (fps_den == 1001 && fps_num == 50000) {
        lookup_num = 50; lookup_den = 1;
    } else if (fps_den != 1 && fps_den != 0) {
        lookup_num = (fps_num + fps_den / 2) / fps_den; lookup_den = 1;
    }

    char key[64];
    snprintf(key, sizeof(key), "%dx%d@%d/%d%s",
             width, height, lookup_num, lookup_den, interlaced ? "i" : "p");

    if (g_strcmp0(key, s_sdi_applied_caps[slot]) != 0) {
        sdi_reapply_mode(slot, caps);
    }

    gst_caps_unref(caps);
    return GST_PAD_PROBE_OK;
}

static GstPadProbeReturn sdi_audio_health_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)info;
    int device_number = GPOINTER_TO_INT(user_data);
    if (device_number < 0 || device_number > 7) return GST_PAD_PROBE_OK;

    gint64 now = g_get_monotonic_time(); // microseconds
    sdi_audio_last_buffer_time[device_number] = now;
    sdi_audio_buffer_count[device_number]++;

    // If we previously reported silence, log that audio is back
    if (sdi_audio_silence_reported[device_number]) {
        sdi_audio_silence_reported[device_number] = FALSE;
        g_print("SDI_AUDIO_RECOVERED: device=%d audio_buffers_flowing_again\n", device_number);
    }

    return GST_PAD_PROBE_OK;
}

static GstPadProbeReturn sdi_video_health_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)info;
    int device_number = GPOINTER_TO_INT(user_data);
    if (device_number < 0 || device_number > 7) return GST_PAD_PROBE_OK;

    gint64 now = g_get_monotonic_time(); // microseconds
    sdi_video_last_buffer_time[device_number] = now;
    sdi_video_buffer_count[device_number]++;

    return GST_PAD_PROBE_OK;
}

// SDI decodebin callbacks: tsdemux → decodebin (codec-agnostic)
typedef struct {
    GstElement *vdecodebin;
    GstElement *adecodebin;
} TsdemuxPadData;

// Called when tsdemux exposes a new pad — routes video to vdecodebin, audio to adecodebin
static void on_sdi_tsdemux_pad_added(GstElement *src, GstPad *new_pad, gpointer user_data)
{
    (void)src;
    TsdemuxPadData *d = (TsdemuxPadData *)user_data;

    GstCaps *caps = gst_pad_get_current_caps(new_pad);
    if (!caps) caps = gst_pad_query_caps(new_pad, NULL);
    if (!caps) return;

    GstStructure *s = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(s);

    GstElement *target = NULL;
    if (g_str_has_prefix(name, "video/")) {
        target = d->vdecodebin;
    } else if (g_str_has_prefix(name, "audio/")) {
        target = d->adecodebin;
    }

    if (target) {
        GstPad *sink_pad = gst_element_get_static_pad(target, "sink");
        if (sink_pad && !gst_pad_is_linked(sink_pad)) {
            GstPadLinkReturn ret = gst_pad_link(new_pad, sink_pad);
            if (ret != GST_PAD_LINK_OK) {
                g_printerr("SDI tsdemux: pad link failed for '%s': %d\n", name, ret);
            } else {
                g_print("SDI tsdemux: linked %s → decodebin\n", name);
            }
        }
        if (sink_pad) gst_object_unref(sink_pad);
    }
    gst_caps_unref(caps);
}

// Called when video decodebin exposes a decoded raw video pad
static void on_sdi_decodebin_video_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data)
{
    (void)decodebin;
    GstElement *vqueue = (GstElement *)user_data;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    if (!caps) return;

    GstStructure *s = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(s);
    gst_caps_unref(caps);

    if (!g_str_has_prefix(name, "video/x-raw")) return;

    GstPad *sink_pad = gst_element_get_static_pad(vqueue, "sink");
    if (sink_pad && !gst_pad_is_linked(sink_pad)) {
        GstPadLinkReturn ret = gst_pad_link(pad, sink_pad);
        if (ret == GST_PAD_LINK_OK) {
            g_print("SDI: decodebin video → output chain linked\n");
        } else {
            g_printerr("SDI: decodebin video pad link failed: %d\n", ret);
        }
    }
    if (sink_pad) gst_object_unref(sink_pad);
}

// =============================================================================
// SDI Auto-Detect: decodebin video pad-added callback
// Called when decodebin exposes a decoded raw video pad in AUTO mode.
// Extracts the video caps, looks up the matching DeckLink mode, configures
// the decklinkvideosink and capsfilter, optionally adds the interlace element,
// links the full video chain, then links decodebin → vqueue to start flow.
// =============================================================================
static void on_sdi_decodebin_video_pad_added_autodetect(GstElement *decodebin, GstPad *pad, gpointer user_data)
{
    (void)decodebin;
    SdiAutoDetectCtx *ctx = (SdiAutoDetectCtx *)user_data;

    // Second pad-added = new program/muxer after a source switch. The old
    // linked pad starves; migrate the link. Mode/caps follow via caps probe.
    int slot = ctx->sink_index;
    if (slot >= 0 && slot < 8 && s_sdi_vq_sink_pad[slot]) {
        GstPad *vq_sink = s_sdi_vq_sink_pad[slot];
        GstPad *old_peer = gst_pad_is_linked(vq_sink) ? gst_pad_get_peer(vq_sink) : NULL;
        if (old_peer && old_peer != pad) {
            gst_pad_unlink(old_peer, vq_sink);
            g_print("SDI AUTO-DETECT: video pad migrated on program change (%s → %s)\n",
                    GST_PAD_NAME(old_peer), GST_PAD_NAME(pad));
            gst_object_unref(old_peer);
        }
        if (!gst_pad_is_linked(vq_sink) &&
            gst_pad_link(pad, vq_sink) == GST_PAD_LINK_OK) {
            g_print("SDI AUTO-DETECT: decodebin video → vqueue re-linked after switch\n");
        }
        s_sdi_applied_caps[slot][0] = '\0';
        return;
    }

    // --- Step 1: Only handle raw video pads ---
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    if (!caps) return;

    GstStructure *s = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(s);

    if (!g_str_has_prefix(name, "video/x-raw")) {
        gst_caps_unref(caps);
        return;
    }

    // --- Step 2: Extract video properties from decoded caps ---
    gint width = 0, height = 0;
    gint fps_num = 0, fps_den = 1;
    gboolean interlaced = FALSE;

    gst_structure_get_int(s, "width", &width);
    gst_structure_get_int(s, "height", &height);
    gst_structure_get_fraction(s, "framerate", &fps_num, &fps_den);

    const gchar *interlace_mode_str = gst_structure_get_string(s, "interlace-mode");
    if (interlace_mode_str && g_strcmp0(interlace_mode_str, "interleaved") == 0) {
        interlaced = TRUE;
    }

    gst_caps_unref(caps);

    g_print("SDI AUTO-DETECT: decoded video caps → %dx%d @ %d/%d fps, %s\n",
            width, height, fps_num, fps_den,
            interlaced ? "interlaced" : "progressive");

    // Normalize framerate: fps_den should be 1 for standard broadcast rates
    // Handle cases like 30000/1001 → treat as 30/1 for mode lookup
    int lookup_fps_num = fps_num;
    int lookup_fps_den = fps_den;
    if (fps_den == 1001 && (fps_num == 24000 || fps_num == 30000 || fps_num == 60000)) {
        // NTSC fractional rates: 24000/1001≈23.976, 30000/1001≈29.97, 60000/1001≈59.94
        lookup_fps_num = fps_num / 1000;
        lookup_fps_den = 1;
        g_print("SDI AUTO-DETECT: normalized NTSC fractional rate %d/%d → %d/%d\n",
                fps_num, fps_den, lookup_fps_num, lookup_fps_den);
    } else if (fps_den == 1001 && fps_num == 50000) {
        lookup_fps_num = 50;
        lookup_fps_den = 1;
    } else if (fps_den != 1 && fps_den != 0) {
        // For other non-standard denominators, round to nearest integer fps
        lookup_fps_num = (fps_num + fps_den / 2) / fps_den;
        lookup_fps_den = 1;
        g_print("SDI AUTO-DETECT: rounded non-standard rate %d/%d → %d/%d\n",
                fps_num, fps_den, lookup_fps_num, lookup_fps_den);
    }

    // --- Step 3: Lookup DeckLink mode ---
    // First try exact match with raw fps_num / fps_den
    const DeckLinkModeEntry *entry = lookup_decklink_mode(width, height,
                                                          fps_num, fps_den,
                                                          interlaced);
    if (!entry && (lookup_fps_num != fps_num || lookup_fps_den != fps_den)) {
        // Fallback to normalized framerate lookup
        entry = lookup_decklink_mode(width, height,
                                     lookup_fps_num, lookup_fps_den,
                                     interlaced);
    }

    const char *mode_str;
    int out_width, out_height;
    const char *out_framerate;
    gboolean need_interlace_element = FALSE;
    const char *out_interlace_mode = NULL;

    if (entry) {
        // Matched a broadcast standard — use it directly
        mode_str = entry->mode_str;
        out_width = entry->width;
        out_height = entry->height;
        out_interlace_mode = entry->caps_interlace_mode;
        // Only insert interlace element if input is progressive and output is interlaced
        need_interlace_element = (!interlaced && entry->caps_interlace_mode != NULL);

        // Build framerate string from the table entry
        char fr_buf[16];
        snprintf(fr_buf, sizeof(fr_buf), "%d/%d", entry->fps_num, entry->fps_den);
        out_framerate = g_strdup(fr_buf);

        g_print("SDI AUTO-DETECT: MATCHED → mode=%s (interlace_elem=%s)\n",
                mode_str, need_interlace_element ? "yes" : "no");
    } else {
        // No match — fall back to user-configured defaults
        mode_str = ctx->fallback_mode;
        out_width = ctx->fallback_width;
        out_height = ctx->fallback_height;
        out_framerate = ctx->fallback_framerate;

        // Check if the fallback mode is interlaced
        if (strstr(mode_str, "i") != NULL ||
            strcmp(mode_str, "pal") == 0 ||
            strcmp(mode_str, "ntsc") == 0) {
            need_interlace_element = !interlaced;
            out_interlace_mode = "interleaved";
        }

        g_printerr("SDI AUTO-DETECT: NO MATCH for %dx%d@%d/%d %s — fallback to %s\n",
                   width, height, lookup_fps_num, lookup_fps_den,
                   interlaced ? "interlaced" : "progressive",
                   mode_str);
    }

    // Store detected mode for stats reporting
    if (ctx->device_number >= 0 && ctx->device_number < 8) {
        sdi_detected_mode[ctx->device_number] = mode_str;
    }

    // --- Step 4: Configure decklinkvideosink mode ---
    gst_util_set_object_arg(G_OBJECT(ctx->videosink), "mode", mode_str);
    g_print("SDI AUTO-DETECT: set decklinkvideosink mode=%s\n", mode_str);

    // --- Step 5: Build and set capsfilter caps ---
    char caps_str[256];
    if (out_interlace_mode) {
        snprintf(caps_str, sizeof(caps_str),
                 "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s, interlace-mode=%s",
                 out_width, out_height, out_framerate, out_interlace_mode);
    } else {
        snprintf(caps_str, sizeof(caps_str),
                 "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s",
                 out_width, out_height, out_framerate);
    }

    g_print("SDI AUTO-DETECT: capsfilter → %s\n", caps_str);
    GstCaps *out_caps = gst_caps_from_string(caps_str);
    g_object_set(ctx->vcaps, "caps", out_caps, NULL);
    gst_caps_unref(out_caps);

    // --- Step 6: Optionally create and add interlace element ---
    GstElement *vinterlace = NULL;
    if (need_interlace_element) {
        vinterlace = gst_element_factory_make("interlace", NULL);
        if (vinterlace) {
            gst_util_set_object_arg(G_OBJECT(vinterlace), "field-pattern", "2:2");
            g_object_set(vinterlace, "top-field-first", TRUE, NULL);
            gst_bin_add(GST_BIN(ctx->pipeline), vinterlace);
            sdi_branch_track(ctx->sink_index, ctx->device_number, vinterlace, NULL);
            g_print("SDI AUTO-DETECT: added interlace element (field-pattern=2:2, tff=TRUE)\n");
            if (ctx->sink_index >= 0 && ctx->sink_index < 8)
                s_sdi_vinterlace[ctx->sink_index] = vinterlace;
        } else {
            g_printerr("SDI AUTO-DETECT: WARNING — failed to create interlace element, proceeding without\n");
            need_interlace_element = FALSE;
        }
    }

    // --- Step 7: Link the full video chain ---
    gboolean video_link_ok;
    if (need_interlace_element && vinterlace) {
        video_link_ok = gst_element_link_many(
            ctx->vqueue, ctx->vconvert, ctx->vrate, ctx->vscale,
            vinterlace, ctx->vcaps, ctx->vid_identity, ctx->videosink, NULL);
    } else {
        video_link_ok = gst_element_link_many(
            ctx->vqueue, ctx->vconvert, ctx->vrate, ctx->vscale,
            ctx->vcaps, ctx->vid_identity, ctx->videosink, NULL);
    }

    if (!video_link_ok) {
        g_printerr("SDI AUTO-DETECT: FAILED to link video output chain for mode=%s\n", mode_str);
        // Try falling back without interlace element
        if (need_interlace_element && vinterlace) {
            g_printerr("SDI AUTO-DETECT: retrying without interlace element...\n");
            gst_element_set_state(vinterlace, GST_STATE_NULL);
            gst_bin_remove(GST_BIN(ctx->pipeline), vinterlace);

            // Rebuild caps without interlace-mode
            snprintf(caps_str, sizeof(caps_str),
                     "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s",
                     out_width, out_height, out_framerate);
            out_caps = gst_caps_from_string(caps_str);
            g_object_set(ctx->vcaps, "caps", out_caps, NULL);
            gst_caps_unref(out_caps);

            video_link_ok = gst_element_link_many(
                ctx->vqueue, ctx->vconvert, ctx->vrate, ctx->vscale,
                ctx->vcaps, ctx->vid_identity, ctx->videosink, NULL);

            if (!video_link_ok) {
                g_printerr("SDI AUTO-DETECT: FATAL — video chain link failed even without interlace\n");
                return;
            }
        } else {
            return;
        }
    }

    g_print("SDI AUTO-DETECT: video chain linked successfully\n");

    // --- Step 8: Sync new elements to pipeline state (PLAYING) ---
    if (vinterlace) {
        gst_element_sync_state_with_parent(vinterlace);
    }

    // --- Step 9: Link decodebin pad → vqueue to start video flow ---
    GstPad *sink_pad = gst_element_get_static_pad(ctx->vqueue, "sink");
    if (sink_pad && !gst_pad_is_linked(sink_pad)) {
        GstPadLinkReturn ret = gst_pad_link(pad, sink_pad);
        if (ret == GST_PAD_LINK_OK) {
            g_print("SDI AUTO-DETECT: decodebin video → vqueue linked, flow started\n");
            if (ctx->sink_index >= 0 && ctx->sink_index < 8 && !s_sdi_vq_sink_pad[ctx->sink_index]) {
                s_sdi_vq_sink_pad[ctx->sink_index] = gst_object_ref(sink_pad);
                gst_pad_add_probe(sink_pad, GST_PAD_PROBE_TYPE_BUFFER,
                                  sdi_caps_reapply_probe, GINT_TO_POINTER(ctx->sink_index), NULL);
                g_print("SDI AUTO-DETECT: caps re-apply probe installed (slot %d)\n", ctx->sink_index);
            }
        } else {
            g_printerr("SDI AUTO-DETECT: decodebin video → vqueue link FAILED: %d\n", ret);
        }
    }
    if (sink_pad) gst_object_unref(sink_pad);

    // Free the entry's framerate string if we allocated it (only when matched)
    if (entry) {
        g_free((gchar *)out_framerate);
    }
}

static void sdi_branch_track(int slot, int device_num, GstElement *first, ...)
{
    if (slot < 0 || slot > 7 || !first) return;
    if (s_sdi_branch_n[slot] == 0) s_sdi_branch_device[slot] = device_num;

    va_list ap;
    va_start(ap, first);
    for (GstElement *e = first; e; e = va_arg(ap, GstElement *)) {
        if (s_sdi_branch_n[slot] < SDI_BRANCH_MAX_ELEMS)
            s_sdi_branch_elems[slot][s_sdi_branch_n[slot]++] = e;
    }
    va_end(ap);
}

static void sdi_branch_untrack(int slot, GstElement *elem)
{
    if (slot < 0 || slot > 7 || !elem) return;
    for (int i = 0; i < s_sdi_branch_n[slot]; i++) {
        if (s_sdi_branch_elems[slot][i] == elem) {
            memmove(&s_sdi_branch_elems[slot][i], &s_sdi_branch_elems[slot][i + 1],
                    (s_sdi_branch_n[slot] - i - 1) * sizeof(GstElement *));
            s_sdi_branch_n[slot]--;
            return;
        }
    }
}

// Detaches one SDI branch from the tee and frees its elements; the stored
// sink JSON is intentionally kept for the subsequent rebuild.

// IDLE-probe detach state: owns its own pad refs so the waiter never shares
// lifetime with the probe; outcome is observed via pad link state instead.
typedef struct {
    GstPad *tee_src;
    GstPad *branch_sink;
} TeeDetach;

static void tee_detach_free(gpointer p)
{
    TeeDetach *d = p;
    gst_object_unref(d->tee_src);
    gst_object_unref(d->branch_sink);
    g_free(d);
}

static GstPadProbeReturn tee_idle_detach_cb(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    (void)pad; (void)info;
    TeeDetach *d = user;
    gst_pad_unlink(d->tee_src, d->branch_sink);
    return GST_PAD_PROBE_REMOVE;
}

static void teardown_sdi_branch(int slot)
{
    if (slot < 0 || slot > 7 || s_sdi_branch_n[slot] == 0 || !g_pipeline) return;

    // decklink audio is paced by the card clock even with sync=FALSE, so the
    // 5s branch queues never drain on demand. leaky=downstream dissolves the
    // backpressure; unsync the pacing elements so sinks stop clock-waiting.
    if (s_sdi_branch_q2[slot])       g_object_set(s_sdi_branch_q2[slot],       "leaky", 2, NULL);
    if (s_sdi_branch_vq[slot])       g_object_set(s_sdi_branch_vq[slot],       "leaky", 2, NULL);
    if (s_sdi_branch_aq[slot])       g_object_set(s_sdi_branch_aq[slot],       "leaky", 2, NULL);
    if (s_sdi_branch_identity[slot]) g_object_set(s_sdi_branch_identity[slot], "sync", FALSE, NULL);
    if (s_sdi_branch_vsink[slot])    g_object_set(s_sdi_branch_vsink[slot],    "sync", FALSE, NULL);
    if (s_sdi_branch_asink[slot])    g_object_set(s_sdi_branch_asink[slot],    "sync", FALSE, NULL);
    g_usleep(100000);

    // Unlink only while the tee pad is idle; releasing a request pad that is
    // mid-push is what crashed the pipeline before. Outcome is checked via
    // pad link state, never through shared probe memory.
    GstElement *queue = s_sdi_branch_elems[slot][0];
    if (queue && tee_element) {
        GstPad *qsink = gst_element_get_static_pad(queue, "sink");
        GstPad *tee_src = qsink ? gst_pad_get_peer(qsink) : NULL;
        if (tee_src) {
            TeeDetach *d = g_new(TeeDetach, 1);
            d->tee_src = gst_object_ref(tee_src);
            d->branch_sink = gst_object_ref(qsink);
            gst_pad_add_probe(tee_src, GST_PAD_PROBE_TYPE_IDLE,
                              tee_idle_detach_cb, d, tee_detach_free);
            gboolean detached = FALSE;
            for (int i = 0; i < 50 && !detached; i++) {
                if (!gst_pad_is_linked(qsink)) detached = TRUE;
                else g_usleep(20000);
            }
            if (!detached) gst_pad_unlink(tee_src, qsink);
            gst_element_release_request_pad(tee_element, tee_src);
            gst_object_unref(tee_src);
        }
        if (qsink) gst_object_unref(qsink);
    }

    // Two-phase stop: set_state(NULL) returns ASYNC for sinks with live
    // scheduling threads (decklink) — freeing before completion segfaults.
    for (int i = 0; i < s_sdi_branch_n[slot]; i++)
        gst_element_set_state(s_sdi_branch_elems[slot][i], GST_STATE_NULL);
    for (int i = 0; i < s_sdi_branch_n[slot]; i++)
        gst_element_get_state(s_sdi_branch_elems[slot][i], NULL, NULL, GST_SECOND);
    for (int i = 0; i < s_sdi_branch_n[slot]; i++) {
        GstElement *e = s_sdi_branch_elems[slot][i];
        gst_bin_remove(GST_BIN(g_pipeline), e);
        gst_object_unref(e);
    }
    s_sdi_branch_n[slot] = 0;

    int dev = s_sdi_branch_device[slot];
    if (dev >= 0 && dev < 8) {
        sdi_vrate_elements[dev] = NULL;
        sdi_detected_mode[dev] = NULL;
        sdi_video_buffer_count[dev] = 0;
        sdi_audio_buffer_count[dev] = 0;
    }
    if (s_sdi_vq_sink_pad[slot]) {
        gst_object_unref(s_sdi_vq_sink_pad[slot]);
        s_sdi_vq_sink_pad[slot] = NULL;
    }
    s_sdi_auto_ctx[slot] = NULL;
    s_sdi_vinterlace[slot] = NULL;
    s_sdi_applied_caps[slot][0] = '\0';
    s_sdi_branch_identity[slot] = NULL;
    s_sdi_branch_vsink[slot] = NULL;
    s_sdi_branch_asink[slot] = NULL;
    s_sdi_branch_q2[slot] = NULL;
    s_sdi_branch_vq[slot] = NULL;
    s_sdi_branch_aq[slot] = NULL;
    g_print("SDI: branch slot %d torn down for source switch\n", slot);
}

static void rebuild_sdi_branch(int slot)
{
    if (slot < 0 || slot > 7 || !s_sdi_sink_json[slot] || !g_pipeline) return;

    cJSON *cfg = cJSON_Parse(s_sdi_sink_json[slot]);
    if (!cfg) {
        g_printerr("SDI: branch slot %d rebuild failed to parse stored config\n", slot);
        return;
    }
    gboolean ok = add_sink_to_pipeline(g_pipeline, tee_element, cfg, slot);
    if (ok && GST_STATE(g_pipeline) == GST_STATE_PLAYING) {
        for (int i = 0; i < s_sdi_branch_n[slot]; i++)
            gst_element_sync_state_with_parent(s_sdi_branch_elems[slot][i]);
    }
    cJSON_Delete(cfg);
    g_print("SDI: branch slot %d rebuilt for active source (ok=%d)\n", slot, ok);
}

// Called when audio decodebin exposes a decoded raw audio pad
static void on_sdi_decodebin_audio_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data)
{
    (void)decodebin;
    GstElement *aqueue = (GstElement *)user_data;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    if (!caps) return;

    GstStructure *s = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(s);
    gst_caps_unref(caps);

    if (!g_str_has_prefix(name, "audio/x-raw")) return;

    GstPad *sink_pad = gst_element_get_static_pad(aqueue, "sink");
    if (sink_pad) {
        GstPad *old_peer = gst_pad_is_linked(sink_pad) ? gst_pad_get_peer(sink_pad) : NULL;
        if (old_peer && old_peer != pad) {
            gst_pad_unlink(old_peer, sink_pad);
            g_print("SDI: audio pad migrated on program change (%s → %s)\n",
                    GST_PAD_NAME(old_peer), GST_PAD_NAME(pad));
            gst_object_unref(old_peer);
        }
        if (!gst_pad_is_linked(sink_pad)) {
            GstPadLinkReturn ret = gst_pad_link(pad, sink_pad);
            if (ret == GST_PAD_LINK_OK) {
                g_print("SDI: decodebin audio → output chain linked\n");
            } else {
                g_printerr("SDI: decodebin audio pad link failed: %d\n", ret);
            }
        }
    }
    if (sink_pad) gst_object_unref(sink_pad);
}

static pthread_t stats_thread;
static GstElement *source_element = NULL;
static gboolean running = TRUE;
static GMainLoop *loop = NULL;
// Run loop owned by main.c, injected via set_main_loop(); bus_callback quits it on ERROR.
static GMainLoop *run_loop = NULL;

// Store SRT sink elements for stats collection
static GstElement *sink_elements[MAX_SINKS];
static int sink_count = 0;

// Store tee element for video caps query
static GstElement *tee_element = NULL;

// Dual-ingest (input-selector) state — populated when secondary_source JSON present.
// T3 reads selector_element/primary_sink_pad/secondary_sink_pad to switch active pad.
static GstElement *selector_element = NULL;
static GstElement *primary_source_element = NULL;
static GstElement *secondary_source_element = NULL;
static GstPad *primary_sink_pad = NULL;
static GstPad *secondary_sink_pad = NULL;
static gboolean dual_ingest_active = FALSE;
static gboolean auto_join_enabled = TRUE;
static gboolean seamless_sdi_enabled = FALSE;
static gint selected_source_index = 0;
static gint pending_source_index = -1;
static GMutex seamless_switch_mutex;

// Thumbnail capture state
static GstElement *thumbnail_appsink = NULL;
static pthread_t thumbnail_thread;
static volatile gboolean thumbnail_running = FALSE;
static gboolean thumbnail_thread_started = FALSE;

// MPEG-TS parsing structures for video metadata extraction
#define TS_PACKET_SIZE 188
#define TS_SYNC_BYTE 0x47
#define PAT_PID 0x0000

// Video stream types in MPEG-TS PMT
#define STREAM_TYPE_MPEG2_VIDEO 0x02
#define STREAM_TYPE_H264 0x1B
#define STREAM_TYPE_HEVC 0x24
#define MAX_PROGRAM_STREAMS 16

typedef struct {
    gboolean pat_valid;
    gboolean pmt_valid;
    guint16 transport_stream_id;
    guint16 program_number;
    guint16 pmt_pid;
    guint16 pcr_pid;
    guint16 video_pid;
    guint8 video_stream_type;
    guint32 program_map_hash;
    gboolean codec_config_valid;
    guint32 codec_config_hash;
    guint stream_count;
    guint16 stream_pids[MAX_PROGRAM_STREAMS];
    guint8 stream_types[MAX_PROGRAM_STREAMS];
    guint8 es_tail[4];
    guint es_tail_len;
} SourceTsInfo;

static SourceTsInfo source_ts_info[2];

// Parsed video information
typedef struct {
    gint width;
    gint height;
    gint fps_num;
    gint fps_den;
    gboolean interlaced;
    gboolean fps_inferred; // TRUE if framerate was inferred, not detected
    gboolean info_valid;
    guint16 pmt_pid;
    guint16 video_pid;
    guint8 video_stream_type;
    pthread_mutex_t mutex;
} VideoInfo;

static VideoInfo video_info = {0, 0, 0, 1, FALSE, FALSE, FALSE, 0, 0, 0, PTHREAD_MUTEX_INITIALIZER};

// Forward declarations for MPEG-TS parsing
static void parse_pat(const guint8 *data, gsize size);
static void parse_pmt(const guint8 *data, gsize size);

// Forward declarations for thumbnail
static void add_thumbnail_branch(GstElement *pipeline, GstElement *tee, const char *route_id);
static void *thumbnail_worker(void *arg);
static void on_thumbnail_pad_added(GstElement *decodebin, GstPad *pad, gpointer data);
static void parse_h264_sps(const guint8 *data, gsize size);
static void parse_mpeg2_sequence(const guint8 *data, gsize size);
static GstPadProbeReturn ts_probe_callback(GstPad *pad, GstPadProbeInfo *info, gpointer user_data);
static GstPadProbeReturn source_ts_probe_callback(GstPad *pad, GstPadProbeInfo *info,
                                                  gpointer user_data);

static void send_json_to_socket(cJSON *root)
{
    if (!root) return;
    char *json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        send_message_to_unix_socket(json_str);
        free(json_str);
    }
}

static cJSON *build_source_stats_json(GstElement *src, const char *tag)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "source", tag);

    if (!src) {
        cJSON_AddNumberToObject(root, "total-bytes-received", 0);
        cJSON_AddNumberToObject(root, "connected-callers", 0);
        cJSON_AddArrayToObject(root, "callers");
        return root;
    }

    GstStructure *stats = NULL;
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(src), "stats")) {
        g_object_get(src, "stats", &stats, NULL);
    }

    if (stats) {
        guint64 bytes_total = 0;
        gst_structure_get_uint64(stats, "bytes-received-total", &bytes_total);
        cJSON_AddNumberToObject(root, "total-bytes-received", (double)bytes_total);

        // Extract top-level stats (available in caller mode and as aggregate in listener mode)
        gint64 packets_received = 0, packets_lost = 0, packets_dropped = 0;
        gint64 packets_retransmitted = 0, bytes_received = 0;
        gdouble rtt_ms = 0.0, receive_rate_mbps = 0.0, bandwidth_mbps = 0.0;
        gint negotiated_latency_ms = 0;

        gst_structure_get_int64(stats, "packets-received", &packets_received);
        gst_structure_get_int64(stats, "packets-received-lost", &packets_lost);
        gst_structure_get_int64(stats, "packets-received-dropped", &packets_dropped);
        gst_structure_get_int64(stats, "packets-received-retransmitted", &packets_retransmitted);
        gst_structure_get_int64(stats, "bytes-received", &bytes_received);
        gst_structure_get_double(stats, "rtt-ms", &rtt_ms);
        gst_structure_get_double(stats, "receive-rate-mbps", &receive_rate_mbps);
        gst_structure_get_double(stats, "bandwidth-mbps", &bandwidth_mbps);
        gst_structure_get_int(stats, "negotiated-latency-ms", &negotiated_latency_ms);

        // Add top-level stats to JSON
        cJSON_AddNumberToObject(root, "packets-received", (double)packets_received);
        cJSON_AddNumberToObject(root, "packets-received-lost", (double)packets_lost);
        cJSON_AddNumberToObject(root, "packets-received-dropped", (double)packets_dropped);
        cJSON_AddNumberToObject(root, "packets-received-retransmitted", (double)packets_retransmitted);
        cJSON_AddNumberToObject(root, "bytes-received", (double)bytes_received);
        cJSON_AddNumberToObject(root, "rtt-ms", rtt_ms);
        cJSON_AddNumberToObject(root, "receive-rate-mbps", receive_rate_mbps);
        cJSON_AddNumberToObject(root, "bandwidth-mbps", bandwidth_mbps);
        cJSON_AddNumberToObject(root, "negotiated-latency-ms", negotiated_latency_ms);

        const GValue *callers_val = gst_structure_get_value(stats, "callers");
        if (!callers_val) {
            cJSON_AddNumberToObject(root, "connected-callers", 0);
            cJSON_AddArrayToObject(root, "callers");
        } else if (G_VALUE_HOLDS(callers_val, G_TYPE_VALUE_ARRAY)) {
            GValueArray *callers_array = g_value_get_boxed(callers_val);
            gint num_callers = callers_array ? callers_array->n_values : 0;

            cJSON_AddNumberToObject(root, "connected-callers", num_callers);
            cJSON *callers = cJSON_AddArrayToObject(root, "callers");

            gdouble max_rtt = 0.0;
            gdouble total_receive_rate = 0.0;
            gdouble total_bandwidth = 0.0;

            for (gint i = 0; i < num_callers; i++) {
                GValue *caller_val = &callers_array->values[i];
                if (!G_VALUE_HOLDS(caller_val, GST_TYPE_STRUCTURE)) {
                    continue;
                }

                const GstStructure *caller_stats = g_value_get_boxed(caller_val);
                if (!caller_stats) {
                    continue;
                }

                cJSON *caller = cJSON_CreateObject();

                gint n_fields = gst_structure_n_fields(caller_stats);
                for (gint j = 0; j < n_fields; j++) {
                    const gchar *field_name = gst_structure_nth_field_name(caller_stats, j);
                    const GValue *value = gst_structure_get_value(caller_stats, field_name);

                    if (G_VALUE_HOLDS(value, G_TYPE_INT64)) {
                        cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_int64(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_INT)) {
                        cJSON_AddNumberToObject(caller, field_name, g_value_get_int(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_UINT64)) {
                        cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_uint64(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_DOUBLE)) {
                        gdouble val = g_value_get_double(value);
                        cJSON_AddNumberToObject(caller, field_name, val);

                        if (g_strcmp0(field_name, "rtt-ms") == 0 && val > max_rtt) {
                            max_rtt = val;
                        } else if (g_strcmp0(field_name, "receive-rate-mbps") == 0) {
                            total_receive_rate += val;
                        } else if (g_strcmp0(field_name, "bandwidth-mbps") == 0) {
                            total_bandwidth += val;
                        }
                    } else if (G_VALUE_HOLDS(value, G_TYPE_OBJECT) && g_strcmp0(field_name, "caller-address") == 0) {
                        GObject *addr_obj = g_value_get_object(value);
                        if (G_IS_INET_SOCKET_ADDRESS(addr_obj)) {
                            GInetSocketAddress *addr = G_INET_SOCKET_ADDRESS(addr_obj);
                            GInetAddress *inet_addr = g_inet_socket_address_get_address(addr);
                            guint16 port = g_inet_socket_address_get_port(addr);
                            gchar *ip = g_inet_address_to_string(inet_addr);
                            gchar *addr_str = g_strdup_printf("%s:%d", ip, port);
                            cJSON_AddStringToObject(caller, field_name, addr_str);
                            g_free(ip);
                            g_free(addr_str);
                        }
                    }
                }

                cJSON_AddItemToArray(callers, caller);
            }

            // Fallback top-level listener stats from active callers array if top-level structure returned 0
            if (rtt_ms <= 0.0 && max_rtt > 0.0) {
                cJSON_ReplaceItemInObject(root, "rtt-ms", cJSON_CreateNumber(max_rtt));
            }
            if (receive_rate_mbps <= 0.0 && total_receive_rate > 0.0) {
                cJSON_ReplaceItemInObject(root, "receive-rate-mbps", cJSON_CreateNumber(total_receive_rate));
            }
            if (bandwidth_mbps <= 0.0 && total_bandwidth > 0.0) {
                cJSON_ReplaceItemInObject(root, "bandwidth-mbps", cJSON_CreateNumber(total_bandwidth));
            }
        }
    } else {
        // Provide default source stats fields when SRT stats are unavailable
        cJSON_AddNumberToObject(root, "total-bytes-received", 0);
        cJSON_AddNumberToObject(root, "connected-callers", 0);
        cJSON_AddArrayToObject(root, "callers");
    }

    if (stats) {
        gst_structure_free(stats);
    }

    return root;
}

static void *print_stats(void *src)
{
    GstElement *source = (GstElement *)src;

    while (running) {
        sleep(1);

        // --- SDI Audio Health Check (every cycle) ---
        gint64 now_us = g_get_monotonic_time();
        for (int i = 0; i < 8; i++) {
            gint64 last = sdi_audio_last_buffer_time[i];
            if (last == 0) continue; // never received audio on this device

            gint64 silence_us = now_us - last;
            if (silence_us > (SDI_AUDIO_HEALTH_INTERVAL_SEC * G_USEC_PER_SEC)) {
                if (!sdi_audio_silence_reported[i]) {
                    sdi_audio_silence_reported[i] = TRUE;
                    g_print("SDI_AUDIO_SILENT: device=%d no_audio_for=%.1fs total_buffers=%lld\n",
                            i, (double)silence_us / G_USEC_PER_SEC,
                            (long long)sdi_audio_buffer_count[i]);
                }
            }
        }

        // Always emit primary (keeps legacy single-source contract: one stats object with "source":"primary").
        cJSON *primary = build_source_stats_json(source, "primary");

        // Metadata attaches to primary only — the MPEG-TS probe is on the shared tee sink pad.
        pthread_mutex_lock(&video_info.mutex);
        if (video_info.info_valid) {
            cJSON_AddNumberToObject(primary, "video-width", video_info.width);
            cJSON_AddNumberToObject(primary, "video-height", video_info.height);
            cJSON_AddNumberToObject(primary, "video-framerate-num", video_info.fps_num);
            cJSON_AddNumberToObject(primary, "video-framerate-den", video_info.fps_den);
            cJSON_AddBoolToObject(primary, "video-framerate-inferred", video_info.fps_inferred);
            cJSON_AddStringToObject(primary, "video-interlace-mode",
                                    video_info.interlaced ? "interleaved" : "progressive");
        }
        pthread_mutex_unlock(&video_info.mutex);

        // Query and append SDI videorate statistics (primary only)
        cJSON *sdi_array = cJSON_CreateArray();
        for (int i = 0; i < 8; i++) {
            GstElement *vrate = sdi_vrate_elements[i];
            if (vrate) {
                guint64 dropped = 0;
                guint64 duplicated = 0;
                g_object_get(vrate, "drop", &dropped, "duplicate", &duplicated, NULL);

                cJSON *sdi_item = cJSON_CreateObject();
                cJSON_AddNumberToObject(sdi_item, "device_number", i);
                cJSON_AddNumberToObject(sdi_item, "dropped_frames", (double)dropped);
                cJSON_AddNumberToObject(sdi_item, "duplicated_frames", (double)duplicated);
                cJSON_AddNumberToObject(sdi_item, "video_frames", (double)sdi_video_buffer_count[i]);
                cJSON_AddNumberToObject(sdi_item, "audio_buffers", (double)sdi_audio_buffer_count[i]);
                // Include auto-detected mode if available (set by auto-detect callback)
                if (sdi_detected_mode[i] != NULL) {
                    cJSON_AddStringToObject(sdi_item, "detected_mode", sdi_detected_mode[i]);
                }
                cJSON_AddItemToArray(sdi_array, sdi_item);
            }
        }
        cJSON_AddItemToObject(primary, "sdi_video_stats", sdi_array);

        send_json_to_socket(primary);
        cJSON_Delete(primary);

        if (dual_ingest_active && secondary_source_element) {
            cJSON *secondary = build_source_stats_json(secondary_source_element, "secondary");
            pthread_mutex_lock(&video_info.mutex);
            if (video_info.info_valid) {
                cJSON_AddNumberToObject(secondary, "video-width", video_info.width);
                cJSON_AddNumberToObject(secondary, "video-height", video_info.height);
                cJSON_AddNumberToObject(secondary, "video-framerate-num", video_info.fps_num);
                cJSON_AddNumberToObject(secondary, "video-framerate-den", video_info.fps_den);
                cJSON_AddBoolToObject(secondary, "video-framerate-inferred", video_info.fps_inferred);
                cJSON_AddStringToObject(secondary, "video-interlace-mode",
                                        video_info.interlaced ? "interleaved" : "progressive");
            }
            pthread_mutex_unlock(&video_info.mutex);
            send_json_to_socket(secondary);
            cJSON_Delete(secondary);
        }

        // Also collect and send sink stats
        collect_sink_stats();
    }

    return NULL;
}

// Collect stats from all SRT sink elements (destinations)
static void collect_sink_stats(void)
{
    for (int i = 0; i < sink_count; i++) {
        GstElement *sink = sink_elements[i];
        if (!sink) continue;

        GstStructure *stats = NULL;
        g_object_get(sink, "stats", &stats, NULL);

        if (!stats) {
            continue;
        }

        cJSON *root = cJSON_CreateObject();
        cJSON_AddNumberToObject(root, "sink-index", i);

        // Extract sink stats (bytes sent, send rate, etc.)
        guint64 bytes_sent_total = 0;
        gint64 packets_sent = 0, packets_lost = 0, packets_dropped = 0;
        gint64 packets_retransmitted = 0;
        gdouble rtt_ms = 0.0, send_rate_mbps = 0.0, bandwidth_mbps = 0.0;
        gint negotiated_latency_ms = 0;

        gst_structure_get_uint64(stats, "bytes-sent-total", &bytes_sent_total);
        gst_structure_get_int64(stats, "packets-sent", &packets_sent);
        gst_structure_get_int64(stats, "packets-sent-lost", &packets_lost);
        gst_structure_get_int64(stats, "packets-sent-dropped", &packets_dropped);
        gst_structure_get_int64(stats, "packets-sent-retransmitted", &packets_retransmitted);
        gst_structure_get_double(stats, "rtt-ms", &rtt_ms);
        gst_structure_get_double(stats, "send-rate-mbps", &send_rate_mbps);
        gst_structure_get_double(stats, "bandwidth-mbps", &bandwidth_mbps);
        gst_structure_get_int(stats, "negotiated-latency-ms", &negotiated_latency_ms);

        cJSON_AddNumberToObject(root, "bytes-sent-total", (double)bytes_sent_total);
        cJSON_AddNumberToObject(root, "packets-sent", (double)packets_sent);
        cJSON_AddNumberToObject(root, "packets-sent-lost", (double)packets_lost);
        cJSON_AddNumberToObject(root, "packets-sent-dropped", (double)packets_dropped);
        cJSON_AddNumberToObject(root, "packets-sent-retransmitted", (double)packets_retransmitted);
        cJSON_AddNumberToObject(root, "rtt-ms", rtt_ms);
        cJSON_AddNumberToObject(root, "send-rate-mbps", send_rate_mbps);
        cJSON_AddNumberToObject(root, "bandwidth-mbps", bandwidth_mbps);
        cJSON_AddNumberToObject(root, "negotiated-latency-ms", negotiated_latency_ms);

        // Check for connected callers (clients pulling from this sink in listener mode)
        const GValue *callers_val = gst_structure_get_value(stats, "callers");
        if (!callers_val) {
            cJSON_AddNumberToObject(root, "connected-callers", 0);
            cJSON_AddArrayToObject(root, "callers");
        } else if (G_VALUE_HOLDS(callers_val, G_TYPE_VALUE_ARRAY)) {
            GValueArray *callers_array = g_value_get_boxed(callers_val);
            gint num_callers = callers_array ? callers_array->n_values : 0;

            cJSON_AddNumberToObject(root, "connected-callers", num_callers);
            cJSON *callers = cJSON_AddArrayToObject(root, "callers");

            for (gint j = 0; j < num_callers; j++) {
                GValue *caller_val = &callers_array->values[j];
                if (!G_VALUE_HOLDS(caller_val, GST_TYPE_STRUCTURE)) {
                    continue;
                }

                const GstStructure *caller_stats = g_value_get_boxed(caller_val);
                if (!caller_stats) {
                    continue;
                }

                cJSON *caller = cJSON_CreateObject();

                gint n_fields = gst_structure_n_fields(caller_stats);
                for (gint k = 0; k < n_fields; k++) {
                    const gchar *field_name = gst_structure_nth_field_name(caller_stats, k);
                    const GValue *value = gst_structure_get_value(caller_stats, field_name);

                    if (G_VALUE_HOLDS(value, G_TYPE_INT64)) {
                        cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_int64(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_INT)) {
                        cJSON_AddNumberToObject(caller, field_name, g_value_get_int(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_UINT64)) {
                        cJSON_AddNumberToObject(caller, field_name, (double)g_value_get_uint64(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_DOUBLE)) {
                        cJSON_AddNumberToObject(caller, field_name, g_value_get_double(value));
                    } else if (G_VALUE_HOLDS(value, G_TYPE_OBJECT) && g_strcmp0(field_name, "caller-address") == 0) {
                        GObject *addr_obj = g_value_get_object(value);
                        if (G_IS_INET_SOCKET_ADDRESS(addr_obj)) {
                            GInetSocketAddress *addr = G_INET_SOCKET_ADDRESS(addr_obj);
                            GInetAddress *inet_addr = g_inet_socket_address_get_address(addr);
                            guint16 port = g_inet_socket_address_get_port(addr);
                            gchar *ip = g_inet_address_to_string(inet_addr);
                            gchar *addr_str = g_strdup_printf("%s:%d", ip, port);
                            cJSON_AddStringToObject(caller, field_name, addr_str);
                            g_free(ip);
                            g_free(addr_str);
                        }
                    }
                }

                cJSON_AddItemToArray(callers, caller);
            }
        }

        char *json_str = cJSON_PrintUnformatted(root);
        if (json_str) {
            // Send with sink prefix so Elixir can distinguish from source stats
            send_prefixed_message_to_unix_socket("stats_sink:", json_str);
            free(json_str);
        }

        cJSON_Delete(root);
        gst_structure_free(stats);
    }
}

static gboolean bus_callback(GstBus *bus, GstMessage *msg, gpointer data)
{
    GstElement *pipeline = GST_ELEMENT(data);

    switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_WARNING: {
            GError *err;
            gchar *debug;
            gst_message_parse_warning(msg, &err, &debug);
            g_print("Pipeline Warning from %s: %s\n", GST_OBJECT_NAME(msg->src), err->message);

            // Send warning stats via Unix socket if from decoder/demuxer
            const gchar *src_name = GST_OBJECT_NAME(msg->src);
            if (src_name && (g_str_has_prefix(src_name, "avdec") ||
                             g_str_has_prefix(src_name, "va") ||
                             g_str_has_prefix(src_name, "decodebin") ||
                             g_str_has_prefix(src_name, "tsdemux"))) {
                cJSON *root = cJSON_CreateObject();
                cJSON_AddStringToObject(root, "type", "warning");
                cJSON_AddStringToObject(root, "route_id", global_route_id);
                cJSON_AddStringToObject(root, "element", src_name);
                cJSON_AddStringToObject(root, "message", err->message);

                char *json_str = cJSON_PrintUnformatted(root);
                if (json_str) {
                    send_message_to_unix_socket(json_str);
                    free(json_str);
                }
                cJSON_Delete(root);
            }

            // srtsrc WARNING = degraded source; emit SOURCE_INVALID for Elixir health flag.
            if (src_name) {
                if (g_strcmp0(src_name, "secondary_source") == 0)
                    g_print("SOURCE_INVALID:secondary %s\n", err ? err->message : "");
                else if (g_strcmp0(src_name, "source") == 0)
                    g_print("SOURCE_INVALID:primary %s\n", err ? err->message : "");
            }

            g_error_free(err);
            g_free(debug);
            break;
        }
        case GST_MESSAGE_ERROR: {
            GError *err;
            gchar *debug;
            gst_message_parse_error(msg, &err, &debug);
            g_print("Error: %s (src: %s, debug: %s)\n",
                    err ? err->message : "unknown",
                    GST_MESSAGE_SRC_NAME(msg),
                    debug ? debug : "none");
            g_error_free(err);
            g_free(debug);
            if (run_loop) g_main_loop_quit(run_loop);
            break;
        }
        case GST_MESSAGE_STATE_CHANGED: {
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(pipeline)) {
                GstState old_state, new_state, pending_state;
                gst_message_parse_state_changed(msg, &old_state, &new_state, &pending_state);
                g_print("Pipeline state changed from %s to %s\n", gst_element_state_get_name(old_state),
                        gst_element_state_get_name(new_state));
            }
            break;
        }
        case GST_MESSAGE_ELEMENT: {
            const GstStructure *s = gst_message_get_structure(msg);
            if (s && gst_structure_has_name(s, "GstSRTObject")) {
                g_print("SRT event received\n");
            } else if (s && gst_structure_has_name(s, "connection-removed")) {
                GstObject *src_obj = GST_MESSAGE_SRC(msg);
                const gchar *oname = src_obj ? GST_OBJECT_NAME(src_obj) : "";
                g_print("SOURCE_INVALID:%s\n",
                        g_strcmp0(oname, "secondary_source") == 0 ? "secondary" : "primary");
            }
            break;
        }
        default:
            break;
    }
    return TRUE;
}

static gboolean on_caller_connecting(GstElement *element, GSocketAddress *addr,
                                     const gchar *stream_id, gpointer user_data)
{
    (void)element;
    const char *name = (const char *)user_data;

    gchar *addr_str = NULL;
    if (addr && G_IS_INET_SOCKET_ADDRESS(addr)) {
        GInetSocketAddress *inet_addr = G_INET_SOCKET_ADDRESS(addr);
        GInetAddress *address = g_inet_socket_address_get_address(inet_addr);
        guint16 port = g_inet_socket_address_get_port(inet_addr);
        gchar *ip = g_inet_address_to_string(address);
        addr_str = g_strdup_printf("%s:%d", ip, port);
        g_free(ip);
    }

    g_print("New SRT caller connection to %s from %s (stream ID: %s)\n",
            name ? name : "source",
            addr_str ? addr_str : "unknown",
            stream_id ? "present" : "none");
    g_free(addr_str);

    // Attribute the connection to primary or secondary source for health tracking.
    if (name && g_strcmp0(name, "secondary_source") == 0)
        g_print("SOURCE_VALID:secondary\n");
    else
        g_print("SOURCE_VALID:primary\n");

    if (stream_id) {
        send_prefixed_message_to_unix_socket("stats_source_stream_id:", stream_id);
    }

    return TRUE;
}

static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc)
{
    // GStreamer SRT mode values: 0=none, 1=caller, 2=listener, 3=rendezvous
    gint mode_value = 0;

    if (strcmp(mode_str, "listener") == 0) {
        mode_value = 2;
        g_print("Set mode=listener (2) for %s\n", element_desc);
    } else if (strcmp(mode_str, "caller") == 0) {
        mode_value = 1;
        g_print("Set mode=caller (1) for %s\n", element_desc);
    } else if (strcmp(mode_str, "rendezvous") == 0) {
        mode_value = 3;
        g_print("Set mode=rendezvous (3) for %s\n", element_desc);
    } else {
        g_printerr("Unknown SRT mode: %s\n", mode_str);
        return;
    }

    // Actually set the mode property on the element!
    // Note: mode is set via the URI query param, not as a direct property
    // The URI already contains mode=X, so this is just for logging
}

static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property)
{
    cJSON *property;
    cJSON_ArrayForEach(property, config)
    {
        if (strcmp(property->string, skip_property) == 0) {
            continue;
        }

        if ((strcmp(element_type, "srtsrc") == 0 || strcmp(element_type, "srtsink") == 0) &&
            strcmp(property->string, "mode") == 0 && cJSON_IsString(property)) {
            set_srt_mode_property(element, property->valuestring, element_type);
            continue;
        }

        if (strcmp(element_type, "udpsink") == 0 && strcmp(property->string, "address") == 0 &&
            cJSON_IsString(property)) {
            g_object_set(element, "host", property->valuestring, NULL);
            g_print("Set host=%s for %s element\n", property->valuestring, element_type);
            continue;
        }

        if (cJSON_IsBool(property)) {
            g_object_set(element, property->string, property->valueint, NULL);
            g_print("Set %s=%s for %s element\n", property->string, property->valueint ? "true" : "false",
                    element_type);
        } else if (cJSON_IsNumber(property)) {
            g_object_set(element, property->string, property->valueint, NULL);
            g_print("Set %s=%d for %s element\n", property->string, property->valueint, element_type);
        } else if (cJSON_IsString(property)) {
            g_object_set(element, property->string, property->valuestring, NULL);
            if (strcmp(property->string, "uri") == 0 ||
                strcmp(property->string, "passphrase") == 0 ||
                strcmp(property->string, "streamid") == 0) {
                g_print("Set %s=<redacted> for %s element\n", property->string, element_type);
            } else {
                g_print("Set %s=%s for %s element\n", property->string, property->valuestring,
                        element_type);
            }
        }
    }
}

// =============================================================================
// MPEG-TS Parsing Functions
// =============================================================================

// Parse PAT (Program Association Table) to find PMT PID
static void parse_pat(const guint8 *data, gsize size)
{
    if (size < 8) return;

    // Skip TS header (4 bytes) and PAT header
    // table_id(1) + syntax(2) + reserved(1) + section_length(2) + ts_stream_id(2)
    // + reserved(1) + version(1) + section_number(1) + last_section_number(1) = 8 bytes

    gsize offset = 0;

    // Find start of PAT data after adaptation field
    if (data[3] & 0x20) {     // Adaptation field present
        offset = 5 + data[4]; // Skip adaptation field length
    } else {
        offset = 4;
    }

    if (data[3] & 0x10) { // Payload present
        // Pointer field
        offset += 1 + data[offset];
    }

    if (offset + 8 > size) return;

    // Skip table_id (1 byte), section_syntax_indicator + reserved + section_length (2 bytes)
    // transport_stream_id (2 bytes), reserved + version + current_next (1 byte)
    // section_number (1 byte), last_section_number (1 byte)
    gsize pat_offset = offset + 8;

    // Section length is in bytes 1-2 (offset+1, offset+2)
    guint16 section_length = ((data[offset + 1] & 0x0F) << 8) | data[offset + 2];
    gsize section_end = offset + 3 + section_length - 4; // -4 for CRC

    // Parse program entries (each is 4 bytes: program_number(2) + reserved(3 bits) + PMT_PID(13 bits))
    while (pat_offset + 4 <= section_end && pat_offset + 4 <= size) {
        guint16 program_number = (data[pat_offset] << 8) | data[pat_offset + 1];
        guint16 pmt_pid = ((data[pat_offset + 2] & 0x1F) << 8) | data[pat_offset + 3];

        if (program_number != 0) { // 0 is Network PID, skip it
            pthread_mutex_lock(&video_info.mutex);
            if (video_info.pmt_pid == 0) {
                video_info.pmt_pid = pmt_pid;
                g_print("MPEG-TS: Found PMT PID: %d (program %d)\n", pmt_pid, program_number);
            }
            pthread_mutex_unlock(&video_info.mutex);
            break;
        }
        pat_offset += 4;
    }
}

// Parse PMT (Program Map Table) to find video stream PID and type
static void parse_pmt(const guint8 *data, gsize size)
{
    if (size < 12) return;

    gsize offset = 0;

    // Skip adaptation field if present
    if (data[3] & 0x20) {
        offset = 5 + data[4];
    } else {
        offset = 4;
    }

    if (data[3] & 0x10) {           // Payload present
        offset += 1 + data[offset]; // Pointer field
    }

    if (offset + 12 > size) return;

    guint16 section_length = ((data[offset + 1] & 0x0F) << 8) | data[offset + 2];

    // Skip: table_id(1) + section_length(2) + program_number(2) + reserved(1)
    // + section_number(1) + last_section_number(1) + reserved(1) + PCR_PID(2) + reserved(1) + program_info_length(2)
    guint16 program_info_length = ((data[offset + 10] & 0x0F) << 8) | data[offset + 11];

    gsize stream_offset = offset + 12 + program_info_length;
    gsize section_end = offset + 3 + section_length - 4; // -4 for CRC

    // Parse elementary stream entries
    while (stream_offset + 5 <= section_end && stream_offset + 5 <= size) {
        guint8 stream_type = data[stream_offset];
        guint16 es_pid = ((data[stream_offset + 1] & 0x1F) << 8) | data[stream_offset + 2];
        guint16 es_info_length = ((data[stream_offset + 3] & 0x0F) << 8) | data[stream_offset + 4];

        // Check if this is a video stream
        if (stream_type == STREAM_TYPE_MPEG2_VIDEO || stream_type == STREAM_TYPE_H264 ||
            stream_type == STREAM_TYPE_HEVC) {
            pthread_mutex_lock(&video_info.mutex);
            if (video_info.video_pid == 0) {
                video_info.video_pid = es_pid;
                video_info.video_stream_type = stream_type;
                const char *type_name = stream_type == STREAM_TYPE_H264   ? "H.264"
                                        : stream_type == STREAM_TYPE_HEVC ? "HEVC"
                                                                          : "MPEG-2";
                g_print("MPEG-TS: Found video stream PID: %d (type: %s)\n", es_pid, type_name);
            }
            pthread_mutex_unlock(&video_info.mutex);
            break;
        }

        stream_offset += 5 + es_info_length;
    }
}

static gboolean get_ts_payload(const guint8 *packet, const guint8 **payload,
                               gsize *payload_size)
{
    if (!packet || packet[0] != TS_SYNC_BYTE || !(packet[3] & 0x10)) return FALSE;

    gsize offset = 4;
    if (packet[3] & 0x20) {
        offset += 1 + packet[4];
    }
    if (offset >= TS_PACKET_SIZE) return FALSE;

    *payload = packet + offset;
    *payload_size = TS_PACKET_SIZE - offset;
    return TRUE;
}

static guint32 fnv1a_hash(const guint8 *data, gsize size)
{
    guint32 hash = 2166136261u;
    for (gsize i = 0; i < size; i++) {
        hash ^= data[i];
        hash *= 16777619u;
    }
    return hash;
}

static void parse_source_pat(SourceTsInfo *info, const guint8 *packet)
{
    const guint8 *payload = NULL;
    gsize payload_size = 0;
    if (!(packet[1] & 0x40) || !get_ts_payload(packet, &payload, &payload_size) ||
        payload_size < 9) {
        return;
    }

    guint pointer = payload[0];
    if ((gsize)pointer + 9 > payload_size) return;
    const guint8 *section = payload + 1 + pointer;
    gsize available = payload_size - 1 - pointer;
    if (section[0] != 0x00 || available < 8) return;

    guint16 section_length = ((section[1] & 0x0F) << 8) | section[2];
    gsize section_size = 3 + section_length;
    if (section_size > available || section_size < 12) return;

    guint16 transport_stream_id = (section[3] << 8) | section[4];
    gsize entry_end = section_size - 4;
    for (gsize offset = 8; offset + 4 <= entry_end; offset += 4) {
        guint16 program_number = (section[offset] << 8) | section[offset + 1];
        if (program_number == 0) continue;

        info->transport_stream_id = transport_stream_id;
        info->program_number = program_number;
        info->pmt_pid = ((section[offset + 2] & 0x1F) << 8) | section[offset + 3];
        info->pat_valid = TRUE;
        return;
    }
}

static void parse_source_pmt(SourceTsInfo *info, const guint8 *packet)
{
    const guint8 *payload = NULL;
    gsize payload_size = 0;
    if (!(packet[1] & 0x40) || !get_ts_payload(packet, &payload, &payload_size) ||
        payload_size < 13) {
        return;
    }

    guint pointer = payload[0];
    if ((gsize)pointer + 13 > payload_size) return;
    const guint8 *section = payload + 1 + pointer;
    gsize available = payload_size - 1 - pointer;
    if (section[0] != 0x02 || available < 12) return;

    guint16 section_length = ((section[1] & 0x0F) << 8) | section[2];
    gsize section_size = 3 + section_length;
    if (section_size > available || section_size < 16) return;

    guint16 program_number = (section[3] << 8) | section[4];
    guint16 pcr_pid = ((section[8] & 0x1F) << 8) | section[9];
    guint16 program_info_length = ((section[10] & 0x0F) << 8) | section[11];
    gsize offset = 12 + program_info_length;
    gsize entry_end = section_size - 4;

    guint count = 0;
    guint16 video_pid = 0;
    guint8 video_type = 0;
    guint16 pids[MAX_PROGRAM_STREAMS] = {0};
    guint8 types[MAX_PROGRAM_STREAMS] = {0};

    while (offset + 5 <= entry_end && count < MAX_PROGRAM_STREAMS) {
        guint8 stream_type = section[offset];
        guint16 stream_pid = ((section[offset + 1] & 0x1F) << 8) | section[offset + 2];
        guint16 es_info_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4];
        if (offset + 5 + es_info_length > entry_end) break;

        types[count] = stream_type;
        pids[count] = stream_pid;
        count++;

        if (video_pid == 0 &&
            (stream_type == STREAM_TYPE_MPEG2_VIDEO || stream_type == STREAM_TYPE_H264 ||
             stream_type == STREAM_TYPE_HEVC)) {
            video_pid = stream_pid;
            video_type = stream_type;
        }

        offset += 5 + es_info_length;
    }

    if (count == 0 || video_pid == 0) return;

    info->program_number = program_number;
    info->pcr_pid = pcr_pid;
    info->video_pid = video_pid;
    info->video_stream_type = video_type;
    info->program_map_hash = fnv1a_hash(section + 8, section_size - 12);
    info->stream_count = count;
    memcpy(info->stream_pids, pids, sizeof(pids));
    memcpy(info->stream_types, types, sizeof(types));
    info->pmt_valid = TRUE;
}

static gboolean source_maps_compatible_unlocked(void)
{
    const SourceTsInfo *primary = &source_ts_info[0];
    const SourceTsInfo *secondary = &source_ts_info[1];

    if (!primary->pat_valid || !primary->pmt_valid ||
        !secondary->pat_valid || !secondary->pmt_valid) {
        return FALSE;
    }

    if (primary->transport_stream_id != secondary->transport_stream_id ||
        primary->program_number != secondary->program_number ||
        primary->pmt_pid != secondary->pmt_pid || primary->pcr_pid != secondary->pcr_pid ||
        primary->video_pid != secondary->video_pid ||
        primary->video_stream_type != secondary->video_stream_type ||
        primary->program_map_hash != secondary->program_map_hash ||
        !primary->codec_config_valid || !secondary->codec_config_valid ||
        primary->codec_config_hash != secondary->codec_config_hash ||
        primary->stream_count != secondary->stream_count) {
        return FALSE;
    }

    for (guint i = 0; i < primary->stream_count; i++) {
        if (primary->stream_pids[i] != secondary->stream_pids[i] ||
            primary->stream_types[i] != secondary->stream_types[i]) {
            return FALSE;
        }
    }

    return TRUE;
}

static gboolean source_maps_ready_unlocked(void)
{
    return source_ts_info[0].pat_valid && source_ts_info[0].pmt_valid &&
           source_ts_info[1].pat_valid && source_ts_info[1].pmt_valid;
}

static gboolean source_descriptions_ready_unlocked(void)
{
    return source_maps_ready_unlocked() && source_ts_info[0].codec_config_valid &&
           source_ts_info[1].codec_config_valid;
}

static gboolean payload_contains_keyframe(SourceTsInfo *info, const guint8 *payload,
                                          gsize payload_size)
{
    guint8 scan[TS_PACKET_SIZE + 4];
    guint prefix = MIN(info->es_tail_len, (guint)sizeof(info->es_tail));
    memcpy(scan, info->es_tail, prefix);
    memcpy(scan + prefix, payload, payload_size);
    gsize scan_size = prefix + payload_size;
    gboolean keyframe = FALSE;

    for (gsize i = 0; i + 5 < scan_size; i++) {
        if (scan[i] != 0 || scan[i + 1] != 0 || scan[i + 2] != 1) continue;

        guint8 code = scan[i + 3];
        gsize config_available = scan_size - (i + 3);
        if (info->video_stream_type == STREAM_TYPE_H264) {
            guint8 nal_type = code & 0x1F;
            if (nal_type == 7 && config_available >= 12) {
                info->codec_config_hash = fnv1a_hash(scan + i + 3, 12);
                info->codec_config_valid = TRUE;
            } else if (nal_type == 5) {
                keyframe = TRUE;
            }
        }
        if (info->video_stream_type == STREAM_TYPE_HEVC) {
            guint8 nal_type = (code >> 1) & 0x3F;
            if (nal_type == 33 && config_available >= 16) {
                info->codec_config_hash = fnv1a_hash(scan + i + 3, 16);
                info->codec_config_valid = TRUE;
            } else if (nal_type >= 16 && nal_type <= 21) {
                keyframe = TRUE;
            }
        }
        if (info->video_stream_type == STREAM_TYPE_MPEG2_VIDEO) {
            if (code == 0xB3 && config_available >= 8) {
                info->codec_config_hash = fnv1a_hash(scan + i + 3, 8);
                info->codec_config_valid = TRUE;
            } else if (code == 0x00) {
                guint8 picture_coding_type = (scan[i + 5] >> 3) & 0x07;
                if (picture_coding_type == 1) keyframe = TRUE;
            }
        }
    }

    info->es_tail_len = MIN((guint)scan_size, (guint)sizeof(info->es_tail));
    if (info->es_tail_len > 0) {
        memcpy(info->es_tail, scan + scan_size - info->es_tail_len, info->es_tail_len);
    }
    return keyframe;
}

static void reject_pending_switch_if_incompatible(void)
{
    gint rejected = -1;

    g_mutex_lock(&seamless_switch_mutex);
    if (pending_source_index >= 0 && source_descriptions_ready_unlocked() &&
        !source_maps_compatible_unlocked()) {
        rejected = pending_source_index;
        pending_source_index = -1;
    }
    g_mutex_unlock(&seamless_switch_mutex);

    if (rejected >= 0) {
        g_print("SOURCE_SWITCH_REJECTED:%s:incompatible-mpegts-map\n",
                rejected == 1 ? "secondary" : "primary");
    }
}

static void complete_pending_switch_on_keyframe(gint source_index)
{
    gboolean switched = FALSE;
    gboolean rejected = FALSE;
    GstPad *target_pad = source_index == 1 ? secondary_sink_pad : primary_sink_pad;

    if (!target_pad || !selector_element) {
        g_mutex_lock(&seamless_switch_mutex);
        if (pending_source_index == source_index) pending_source_index = -1;
        g_mutex_unlock(&seamless_switch_mutex);
        g_print("SOURCE_SWITCH_REJECTED:%s:target-pad-unavailable\n",
                source_index == 1 ? "secondary" : "primary");
        return;
    }

    g_mutex_lock(&seamless_switch_mutex);
    if (pending_source_index == source_index) {
        if (source_descriptions_ready_unlocked() && source_maps_compatible_unlocked()) {
            selected_source_index = source_index;
            pending_source_index = -1;
            switched = TRUE;
        } else if (source_descriptions_ready_unlocked()) {
            pending_source_index = -1;
            rejected = TRUE;
        }
    }
    g_mutex_unlock(&seamless_switch_mutex);

    if (rejected) {
        g_print("SOURCE_SWITCH_REJECTED:%s:incompatible-mpegts-map\n",
                source_index == 1 ? "secondary" : "primary");
        return;
    }
    if (!switched) return;

    g_object_set(selector_element, "active-pad", target_pad, NULL);
    g_print("SOURCE_SWITCHED:%s\n", source_index == 1 ? "secondary" : "primary");
}

static GstPadProbeReturn source_ts_probe_callback(GstPad *pad, GstPadProbeInfo *probe_info,
                                                  gpointer user_data)
{
    (void)pad;
    gint source_index = GPOINTER_TO_INT(user_data);
    if (source_index < 0 || source_index > 1) return GST_PAD_PROBE_OK;

    GstBuffer *buffer = GST_PAD_PROBE_INFO_BUFFER(probe_info);
    if (!buffer) return GST_PAD_PROBE_OK;

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;

    gboolean keyframe = FALSE;
    gsize first_packet = 0;
    while (first_packet < map.size && first_packet < TS_PACKET_SIZE &&
           map.data[first_packet] != TS_SYNC_BYTE) {
        first_packet++;
    }

    g_mutex_lock(&seamless_switch_mutex);
    SourceTsInfo *stream_info = &source_ts_info[source_index];
    for (gsize offset = first_packet; offset + TS_PACKET_SIZE <= map.size;
         offset += TS_PACKET_SIZE) {
        const guint8 *packet = map.data + offset;
        if (packet[0] != TS_SYNC_BYTE) continue;

        guint16 pid = ((packet[1] & 0x1F) << 8) | packet[2];
        if (pid == PAT_PID) {
            parse_source_pat(stream_info, packet);
        } else if (stream_info->pat_valid && pid == stream_info->pmt_pid) {
            parse_source_pmt(stream_info, packet);
        } else if (stream_info->pmt_valid && pid == stream_info->video_pid) {
            const guint8 *payload = NULL;
            gsize payload_size = 0;
            if (get_ts_payload(packet, &payload, &payload_size) &&
                payload_contains_keyframe(stream_info, payload, payload_size)) {
                keyframe = TRUE;
            }
        }
    }
    g_mutex_unlock(&seamless_switch_mutex);

    gst_buffer_unmap(buffer, &map);
    reject_pending_switch_if_incompatible();
    if (keyframe) complete_pending_switch_on_keyframe(source_index);
    return GST_PAD_PROBE_OK;
}

// Bit reader helper for H.264 SPS parsing
typedef struct {
    const guint8 *data;
    gsize size;
    gsize byte_offset;
    gint bit_offset;
} BitReader;

static guint32 read_bits(BitReader *br, gint n)
{
    guint32 result = 0;
    for (gint i = 0; i < n; i++) {
        if (br->byte_offset >= br->size) return result;
        result <<= 1;
        result |= (br->data[br->byte_offset] >> (7 - br->bit_offset)) & 1;
        br->bit_offset++;
        if (br->bit_offset >= 8) {
            br->bit_offset = 0;
            br->byte_offset++;
        }
    }
    return result;
}

// Read 32-bit unsigned integer (byte-aligned read for efficiency)
static guint32 read_u32(BitReader *br)
{
    guint32 result = 0;
    result |= read_bits(br, 8) << 24;
    result |= read_bits(br, 8) << 16;
    result |= read_bits(br, 8) << 8;
    result |= read_bits(br, 8);
    return result;
}

static guint32 read_ue(BitReader *br) // Exp-Golomb unsigned
{
    gint leading_zeros = 0;
    while (read_bits(br, 1) == 0 && leading_zeros < 32) leading_zeros++;
    return (1 << leading_zeros) - 1 + read_bits(br, leading_zeros);
}

// Parse H.264 SPS NAL unit to get resolution and framerate
static void parse_h264_sps(const guint8 *data, gsize size)
{
    if (size < 5) return;

    // Skip NAL header (1 byte)
    BitReader br = {data + 1, size - 1, 0, 0};

    guint8 profile_idc = read_bits(&br, 8);
    read_bits(&br, 8); // constraint_set flags + reserved
    read_bits(&br, 8); // level_idc
    read_ue(&br);      // seq_parameter_set_id

    // Handle high profiles
    if (profile_idc == 100 || profile_idc == 110 || profile_idc == 122 || profile_idc == 244 || profile_idc == 44 ||
        profile_idc == 83 || profile_idc == 86 || profile_idc == 118 || profile_idc == 128 || profile_idc == 138 ||
        profile_idc == 139 || profile_idc == 134) {
        guint32 chroma_format_idc = read_ue(&br);
        if (chroma_format_idc == 3) read_bits(&br, 1); // separate_colour_plane_flag
        read_ue(&br);                                  // bit_depth_luma_minus8
        read_ue(&br);                                  // bit_depth_chroma_minus8
        read_bits(&br, 1);                             // qpprime_y_zero_transform_bypass_flag
        if (read_bits(&br, 1)) {                       // seq_scaling_matrix_present_flag
            for (int i = 0; i < ((chroma_format_idc != 3) ? 8 : 12); i++) {
                if (read_bits(&br, 1)) { // seq_scaling_list_present_flag
                    gint size_list = (i < 6) ? 16 : 64;
                    gint last_scale = 8, next_scale = 8;
                    for (int j = 0; j < size_list; j++) {
                        if (next_scale != 0) {
                            gint delta = read_ue(&br);
                            next_scale = (last_scale + delta) % 256;
                        }
                        last_scale = (next_scale == 0) ? last_scale : next_scale;
                    }
                }
            }
        }
    }

    read_ue(&br); // log2_max_frame_num_minus4
    guint32 pic_order_cnt_type = read_ue(&br);
    if (pic_order_cnt_type == 0) {
        read_ue(&br); // log2_max_pic_order_cnt_lsb_minus4
    } else if (pic_order_cnt_type == 1) {
        read_bits(&br, 1); // delta_pic_order_always_zero_flag
        read_ue(&br);      // offset_for_non_ref_pic
        read_ue(&br);      // offset_for_top_to_bottom_field
        guint32 num_ref_frames_in_pic_order_cnt_cycle = read_ue(&br);
        for (guint32 i = 0; i < num_ref_frames_in_pic_order_cnt_cycle; i++) read_ue(&br);
    }

    read_ue(&br);      // max_num_ref_frames
    read_bits(&br, 1); // gaps_in_frame_num_value_allowed_flag

    guint32 pic_width_in_mbs_minus1 = read_ue(&br);
    guint32 pic_height_in_map_units_minus1 = read_ue(&br);
    guint32 frame_mbs_only_flag = read_bits(&br, 1);

    gint width = (pic_width_in_mbs_minus1 + 1) * 16;
    gint height = (pic_height_in_map_units_minus1 + 1) * 16 * (frame_mbs_only_flag ? 1 : 2);
    gboolean interlaced = !frame_mbs_only_flag;

    // Crop dimensions if needed
    if (!frame_mbs_only_flag) read_bits(&br, 1); // mb_adaptive_frame_field_flag
    read_bits(&br, 1);                           // direct_8x8_inference_flag

    if (read_bits(&br, 1)) { // frame_cropping_flag
        guint32 crop_left = read_ue(&br);
        guint32 crop_right = read_ue(&br);
        guint32 crop_top = read_ue(&br);
        guint32 crop_bottom = read_ue(&br);
        width -= (crop_left + crop_right) * 2;
        height -= (crop_top + crop_bottom) * 2 * (frame_mbs_only_flag ? 1 : 2);
    }

    // Infer framerate from resolution and interlace mode (common broadcast standards)
    // Note: VUI timing_info parsing is unreliable due to H.264 emulation prevention bytes
    // Default to 25fps (PAL standard, common for Indonesian/European content)
    gint fps_num = 25, fps_den = 1;
    gboolean fps_inferred = TRUE; // All H.264 framerates are inferred (VUI unreliable)

    if (interlaced) {
        // Interlaced content: typically 25i (PAL) or 30i (NTSC)
        fps_num = 25;
        fps_den = 1;
    } else {
        // Progressive content: 25fps is a reasonable default for broadcast
        fps_num = 25;
        fps_den = 1;
    }

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = width;
    video_info.height = height;
    video_info.interlaced = interlaced;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.fps_inferred = fps_inferred;
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/H.264: Resolution: %dx%d, Interlaced: %s, FPS: ~%d (inferred)\n", width, height,
            interlaced ? "yes" : "no", fps_num);
    pthread_mutex_unlock(&video_info.mutex);
}

// Parse MPEG-2 sequence header for resolution/framerate
static void parse_mpeg2_sequence(const guint8 *data, gsize size)
{
    if (size < 8) return;

    // Sequence header: horizontal_size(12) + vertical_size(12) + aspect_ratio(4) + frame_rate_code(4)
    gint width = (data[0] << 4) | (data[1] >> 4);
    gint height = ((data[1] & 0x0F) << 8) | data[2];
    guint8 frame_rate_code = data[3] & 0x0F;

    // Frame rate lookup table (frame_rate_code)
    static const gint fps_num_table[] = {0, 24000, 24, 25, 30000, 30, 50, 60000, 60};
    static const gint fps_den_table[] = {1, 1001, 1, 1, 1001, 1, 1, 1001, 1};

    gint fps_num = (frame_rate_code < 9) ? fps_num_table[frame_rate_code] : 0;
    gint fps_den = (frame_rate_code < 9) ? fps_den_table[frame_rate_code] : 1;

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = width;
    video_info.height = height;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.fps_inferred = FALSE; // MPEG-2 framerate is detected from stream header
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/MPEG-2: Resolution: %dx%d, FPS: %d/%d\n", width, height, fps_num, fps_den);
    pthread_mutex_unlock(&video_info.mutex);
}

// Parse HEVC (H.265) SPS for resolution/framerate
static void parse_hevc_sps(const guint8 *data, gsize size)
{
    // HEVC NAL unit header is 2 bytes, SPS starts after that
    if (size < 20) return;

    // Skip NAL unit header (2 bytes) for HEVC
    BitReader br = {data + 2, size - 2, 0, 0};

    read_bits(&br, 4);                             // sps_video_parameter_set_id
    guint8 max_sub_layers = read_bits(&br, 3) + 1; // sps_max_sub_layers_minus1 + 1
    read_bits(&br, 1);                             // sps_temporal_id_nesting_flag

    // Skip profile_tier_level - simplified approach
    // This is complex in full spec, but we can skip fixed bits for common profiles
    read_bits(&br, 2);  // general_profile_space
    read_bits(&br, 1);  // general_tier_flag
    read_bits(&br, 5);  // general_profile_idc
    read_bits(&br, 32); // general_profile_compatibility_flags (32 bits)
    read_bits(&br, 1);  // general_progressive_source_flag
    read_bits(&br, 1);  // general_interlaced_source_flag
    read_bits(&br, 1);  // general_non_packed_constraint_flag
    read_bits(&br, 1);  // general_frame_only_constraint_flag
    // Skip remaining constraint flags (44 bits)
    read_bits(&br, 32);
    read_bits(&br, 12);
    read_bits(&br, 8); // general_level_idc

    // Skip sub_layer_profile/level for each sub-layer
    if (max_sub_layers > 1) {
        for (int i = 0; i < max_sub_layers - 1; i++) {
            read_bits(&br, 2); // sub_layer_profile/level_present_flag
        }
        // Padding if max_sub_layers < 8
        for (int i = max_sub_layers - 1; i < 8; i++) {
            read_bits(&br, 2); // reserved
        }
    }

    read_ue(&br); // sps_seq_parameter_set_id
    guint32 chroma_format_idc = read_ue(&br);
    if (chroma_format_idc == 3) {
        read_bits(&br, 1); // separate_colour_plane_flag
    }

    // The key info we need!
    guint32 pic_width = read_ue(&br);  // pic_width_in_luma_samples
    guint32 pic_height = read_ue(&br); // pic_height_in_luma_samples

    // Check for conformance_window_flag
    if (read_bits(&br, 1)) { // conformance_window_flag
        guint32 left = read_ue(&br);
        guint32 right = read_ue(&br);
        guint32 top = read_ue(&br);
        guint32 bottom = read_ue(&br);
        // Adjust for cropping (simplified)
        pic_width -= (left + right) * 2;
        pic_height -= (top + bottom) * 2;
    }

    // Infer framerate based on resolution (50fps standard for HD/UHD broadcast)
    gint fps_num = (pic_height >= 720) ? 50 : 25, fps_den = 1;
    gboolean fps_inferred = TRUE;

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = pic_width;
    video_info.height = pic_height;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.fps_inferred = fps_inferred;
    video_info.interlaced = FALSE; // HEVC is progressive by design for UHD
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/HEVC: Resolution: %dx%d, FPS: ~%d (inferred)\n", pic_width, pic_height, fps_num);
    pthread_mutex_unlock(&video_info.mutex);
}

// Buffer probe callback to parse MPEG-TS packets
static GstPadProbeReturn ts_probe_callback(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)user_data;

    GstBuffer *buffer = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buffer) return GST_PAD_PROBE_OK;

    // Only parse until we have valid video info
    pthread_mutex_lock(&video_info.mutex);
    gboolean have_info = video_info.info_valid;
    pthread_mutex_unlock(&video_info.mutex);
    if (have_info) return GST_PAD_PROBE_OK;

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;

    // Process each TS packet in the buffer
    for (gsize i = 0; i + TS_PACKET_SIZE <= map.size; i += TS_PACKET_SIZE) {
        const guint8 *pkt = map.data + i;

        if (pkt[0] != TS_SYNC_BYTE) continue;

        guint16 pid = ((pkt[1] & 0x1F) << 8) | pkt[2];

        if (pid == PAT_PID) {
            parse_pat(pkt, TS_PACKET_SIZE);
        } else {
            pthread_mutex_lock(&video_info.mutex);
            guint16 pmt_pid = video_info.pmt_pid;
            guint16 video_pid = video_info.video_pid;
            guint8 video_type = video_info.video_stream_type;
            pthread_mutex_unlock(&video_info.mutex);

            if (pid == pmt_pid && pmt_pid != 0) {
                parse_pmt(pkt, TS_PACKET_SIZE);
            } else if (pid == video_pid && video_pid != 0) {
                // Look for video start codes in PES payload
                gsize payload_start = 4;
                if (pkt[3] & 0x20) payload_start += 1 + pkt[4]; // Skip adaptation field

                if (payload_start + 20 < TS_PACKET_SIZE && (pkt[3] & 0x10)) {
                    const guint8 *payload = pkt + payload_start;
                    gsize payload_size = TS_PACKET_SIZE - payload_start;

                    // Search for start codes
                    for (gsize j = 0; j + 4 < payload_size; j++) {
                        if (payload[j] == 0 && payload[j + 1] == 0 && payload[j + 2] == 1) {
                            if (video_type == STREAM_TYPE_H264) {
                                // H.264 NAL unit type in lower 5 bits
                                guint8 nal_type = payload[j + 3] & 0x1F;
                                if (nal_type == 7) { // SPS
                                    parse_h264_sps(payload + j + 3, payload_size - j - 3);
                                    break;
                                }
                            } else if (video_type == STREAM_TYPE_HEVC) {
                                // HEVC NAL unit type is in bits 1-6 of first byte after start code
                                // NAL header is 2 bytes: [F(1) Type(6) LayerId(6) TID(3)]
                                guint8 nal_type = (payload[j + 3] >> 1) & 0x3F;
                                if (nal_type == 33) { // SPS (NAL_UNIT_SPS = 33)
                                    parse_hevc_sps(payload + j + 3, payload_size - j - 3);
                                    break;
                                }
                            } else if (video_type == STREAM_TYPE_MPEG2_VIDEO) {
                                if (payload[j + 3] == 0xB3) { // Sequence header
                                    parse_mpeg2_sequence(payload + j + 4, payload_size - j - 4);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    gst_buffer_unmap(buffer, &map);
    return GST_PAD_PROBE_OK;
}

static GstPadProbeReturn drop_buffer_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)info;
    (void)user_data;
    return GST_PAD_PROBE_DROP;
}

// =============================================================================
// Thumbnail Capture Branch
// =============================================================================

static GstPadProbeReturn drop_thumbnail_pad_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)info;
    (void)user_data;
    return GST_PAD_PROBE_DROP;
}

static void on_thumbnail_pad_added(GstElement *decodebin, GstPad *pad, gpointer data)
{
    (void)decodebin;
    GstElement *videoconvert = (GstElement *)data;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    if (!caps) return;

    GstStructure *str = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(str);

    if (g_str_has_prefix(name, "video/")) {
        gint width = 0, height = 0;
        gint fps_num = 0, fps_den = 1;
        gst_structure_get_int(str, "width", &width);
        gst_structure_get_int(str, "height", &height);
        gst_structure_get_fraction(str, "framerate", &fps_num, &fps_den);

        const gchar *interlace_mode_str = gst_structure_get_string(str, "interlace-mode");
        gboolean interlaced = FALSE;
        if (interlace_mode_str && g_strcmp0(interlace_mode_str, "interleaved") == 0) {
            interlaced = TRUE;
        }

        pthread_mutex_lock(&video_info.mutex);
        if (width > 0 && height > 0) {
            video_info.width = width;
            video_info.height = height;
        }
        if (fps_num > 0 && fps_den > 0) {
            video_info.fps_num = fps_num;
            video_info.fps_den = fps_den;
            video_info.fps_inferred = FALSE; // We have decoded/negotiated caps!
        }
        video_info.interlaced = interlaced;
        video_info.info_valid = TRUE;
        pthread_mutex_unlock(&video_info.mutex);
    }

    gst_caps_unref(caps);

    if (!g_str_has_prefix(name, "video/")) {
        // Drop any non-video pads (audio, etc) to prevent GST_FLOW_NOT_LINKED
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        return;
    }

    GstPad *sink_pad = gst_element_get_static_pad(videoconvert, "sink");
    if (!gst_pad_is_linked(sink_pad)) {
        GstPadLinkReturn ret = gst_pad_link(pad, sink_pad);
        if (ret == GST_PAD_LINK_OK) {
            g_print("Thumbnail: Linked video pad to videoconvert\n");
        } else {
            g_printerr("Thumbnail: Failed to link video pad: %d\n", ret);
        }
    }
    if (sink_pad) gst_object_unref(sink_pad);
}

static void *thumbnail_worker(void *arg)
{
    char *route_id = (char *)arg;
    char path[512];
    char tmp_path[512];
    snprintf(path, sizeof(path), "/tmp/blackgate_preview_%s.jpg", route_id);
    snprintf(tmp_path, sizeof(tmp_path), "/tmp/blackgate_preview_%s.tmp.jpg", route_id);

    g_print("Thumbnail: Worker started, saving to %s\n", path);

    // Give the pipeline a moment to reach PLAYING state
    sleep(3);

    while (thumbnail_running) {
        if (!thumbnail_appsink) {
            sleep(1);
            continue;
        }

        GstSample *sample = gst_app_sink_try_pull_sample(
            GST_APP_SINK(thumbnail_appsink),
            GST_SECOND // 1 second timeout
        );

        if (sample) {
            GstBuffer *buffer = gst_sample_get_buffer(sample);
            GstMapInfo map;

            if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
                FILE *f = fopen(tmp_path, "wb");
                if (f) {
                    fwrite(map.data, 1, map.size, f);
                    fclose(f);
                    rename(tmp_path, path); // Atomic replace
                    g_print("Thumbnail: Saved %zu bytes\n", map.size);
                }
                gst_buffer_unmap(buffer, &map);
            }
            gst_sample_unref(sample);
        }

        // Sleep 5 seconds in 100ms chunks for responsive shutdown
        for (int i = 0; i < 50 && thumbnail_running; i++) {
            usleep(100000);
        }
    }

    // Cleanup preview files on stop
    remove(path);
    remove(tmp_path);
    free(route_id);
    g_print("Thumbnail: Worker stopped\n");
    return NULL;
}

static void add_thumbnail_branch(GstElement *pipeline, GstElement *tee, const char *route_id)
{
    GstElement *queue       = gst_element_factory_make("queue",         "thumbnail_queue");
    GstElement *decodebin   = gst_element_factory_make("decodebin",     "thumbnail_decodebin");
    GstElement *convert     = gst_element_factory_make("videoconvert",  "thumbnail_convert");
    GstElement *scale       = gst_element_factory_make("videoscale",    "thumbnail_scale");
    GstElement *capsfilter  = gst_element_factory_make("capsfilter",    "thumbnail_capsfilter");
    GstElement *jpegenc     = gst_element_factory_make("jpegenc",       "thumbnail_jpegenc");
    GstElement *appsink     = gst_element_factory_make("appsink",       "thumbnail_appsink");

    if (!queue || !decodebin || !convert || !scale || !capsfilter || !jpegenc || !appsink) {
        g_printerr("Thumbnail: One or more elements unavailable — skipping thumbnail branch\n");
        if (queue)      gst_object_unref(queue);
        if (decodebin)  gst_object_unref(decodebin);
        if (convert)    gst_object_unref(convert);
        if (scale)      gst_object_unref(scale);
        if (capsfilter) gst_object_unref(capsfilter);
        if (jpegenc)    gst_object_unref(jpegenc);
        if (appsink)    gst_object_unref(appsink);
        return;
    }

    // Leaky upstream queue: drops old buffers so thumbnail never blocks main stream
    g_object_set(queue,
        "max-size-buffers", 10,
        "max-size-bytes",   0,
        "max-size-time",    (guint64)0,
        "leaky",            2,  // GST_QUEUE_LEAK_UPSTREAM
        NULL);

    // Scale target: 320x180
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "width",  G_TYPE_INT, 320,
        "height", G_TYPE_INT, 180,
        NULL);
    g_object_set(capsfilter, "caps", caps, NULL);
    gst_caps_unref(caps);

    g_object_set(jpegenc, "quality", 75, NULL);

    g_object_set(appsink,
        "emit-signals", FALSE,
        "max-buffers",  2,
        "drop",         TRUE,
        "sync",         FALSE,
        NULL);

    gst_bin_add_many(GST_BIN(pipeline), queue, decodebin, convert, scale, capsfilter, jpegenc, appsink, NULL);

    g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_thumbnail_pad_added), convert);

    if (!gst_element_link(tee, queue) || !gst_element_link(queue, decodebin)) {
        g_printerr("Thumbnail: Failed to link tee → queue → decodebin\n");
        return;
    }

    if (!gst_element_link_many(convert, scale, capsfilter, jpegenc, appsink, NULL)) {
        g_printerr("Thumbnail: Failed to link video chain\n");
        return;
    }

    thumbnail_appsink = appsink;

    char *route_id_copy = strdup(route_id);
    thumbnail_running = TRUE;
    if (pthread_create(&thumbnail_thread, NULL, thumbnail_worker, route_id_copy) != 0) {
        g_printerr("Thumbnail: Failed to start worker thread\n");
        thumbnail_running = FALSE;
        free(route_id_copy);
    } else {
        thumbnail_thread_started = TRUE;
        g_print("Thumbnail: Branch ready for route %s\n", route_id);
    }
}

// Build a single source element from its JSON config. Mirrors the source setup
// historically inlined in create_pipeline (type lookup → factory make →
// set_element_properties → timestamp policy → srtsrc caller-connecting signal).
// `name` becomes both the GstElement name and the user_data passed to
// on_caller_connecting so T3 can attribute health to primary vs secondary.
static GstElement *make_source(cJSON *source_obj, const char *name)
{
    cJSON *source_type = cJSON_GetObjectItem(source_obj, "type");
    if (!cJSON_IsString(source_type)) {
        g_printerr("Invalid source config: missing or invalid 'type' in %s\n", name);
        return NULL;
    }

    GstElement *src = gst_element_factory_make(source_type->valuestring, name);
    if (!src) {
        g_printerr("Failed to create %s source element (type: %s)\n", name, source_type->valuestring);
        return NULL;
    }

    g_print("Created source element: %s (type: %s)\n", GST_ELEMENT_NAME(src), G_OBJECT_TYPE_NAME(src));

    set_element_properties(src, source_obj, source_type->valuestring, "type");

    // Preserve encoder PCR/PTS for every MPEG-TS network source. Applying the
    // local arrival clock here turns SRT/UDP jitter into timestamp jitter and
    // has caused decklinkvideosink ScheduleVideoFrame failures (E_FAIL).
    // input-selector keyframe gating chooses the switch boundary; it does not
    // require rewriting source buffer timestamps.
    g_object_set(src, "do-timestamp", FALSE, NULL);
    g_print("Set do-timestamp=FALSE for %s source element (preserve source timing)\n", name);

    if (g_strcmp0(source_type->valuestring, "srtsrc") == 0) {
        g_signal_connect(src, "caller-connecting", G_CALLBACK(on_caller_connecting), (gpointer)name);
    }

    return src;
}

// =============================================================================
// Pipeline Creation
// =============================================================================

GstElement *create_pipeline(cJSON *json, const char *route_id)
{
    GstElement *pipeline, *source, *tee;

    if (route_id) {
        strncpy(global_route_id, route_id, sizeof(global_route_id) - 1);
        global_route_id[sizeof(global_route_id) - 1] = '\0';
    } else {
        global_route_id[0] = '\0';
    }

    // Normalize source JSON: prefer "primary_source", fall back to legacy "source".
    cJSON *source_obj = cJSON_GetObjectItem(json, "primary_source");
    if (!cJSON_IsObject(source_obj)) {
        source_obj = cJSON_GetObjectItem(json, "source");
    }
    cJSON *secondary_obj = cJSON_GetObjectItem(json, "secondary_source");
    cJSON *sinks_array = cJSON_GetObjectItem(json, "sinks");

    if (!cJSON_IsObject(source_obj) || !cJSON_IsArray(sinks_array)) {
        g_printerr("Invalid JSON format: missing source object or 'sinks' array\n");
        return NULL;
    }

    // Dual-ingest activates iff a secondary_source object is present.
    dual_ingest_active = cJSON_IsObject(secondary_obj);

    // auto_join defaults TRUE; set FALSE to hold secondary at NULL after build.
    cJSON *auto_join_json = cJSON_GetObjectItem(json, "auto_join");
    auto_join_enabled = auto_join_json ? cJSON_IsTrue(auto_join_json) : TRUE;

    cJSON *seamless_sdi_json = cJSON_GetObjectItem(json, "seamless_sdi_failover");
    seamless_sdi_enabled = seamless_sdi_json && cJSON_IsTrue(seamless_sdi_json);
    if (seamless_sdi_enabled && !auto_join_enabled) {
        g_printerr("Seamless SDI failover requires auto_join; forcing secondary warm\n");
        auto_join_enabled = TRUE;
    }

    // Keep primary/secondary slots stable. Elixir passes persisted logical
    // selection so later switch-source commands keep their meaning.
    cJSON *active_source_json = cJSON_GetObjectItem(json, "active_source");
    gboolean start_on_secondary =
        cJSON_IsString(active_source_json) &&
        g_strcmp0(active_source_json->valuestring, "secondary") == 0;

    g_mutex_lock(&seamless_switch_mutex);
    memset(source_ts_info, 0, sizeof(source_ts_info));
    selected_source_index = start_on_secondary ? 1 : 0;
    pending_source_index = -1;
    g_mutex_unlock(&seamless_switch_mutex);

    pipeline = gst_pipeline_new("test-pipeline");
    tee = gst_element_factory_make("tee", "tee");

    if (!pipeline || !tee) {
        g_printerr("Failed to create pipeline or tee element\n");
        return NULL;
    }

    g_object_set(tee, "allow-not-linked", TRUE, NULL);
    g_print("Set allow-not-linked=TRUE for tee element\n");

    primary_source_element = make_source(source_obj, "source");
    if (!primary_source_element) {
        gst_object_unref(pipeline);
        gst_object_unref(tee);
        return NULL;
    }
    // Alias so the existing stats thread + print_stats(source) keep working.
    source = primary_source_element;
    source_element = primary_source_element;

    if (dual_ingest_active) {
        // =================================================================
        // DUAL-INGEST: primary + secondary → input-selector → tee
        // =================================================================
        selector_element = gst_element_factory_make("input-selector", "input-selector");
        secondary_source_element = make_source(secondary_obj, "secondary_source");

        if (!selector_element || !secondary_source_element) {
            g_printerr("Failed to create input-selector or secondary source for dual-ingest\n");
            if (selector_element) gst_object_unref(selector_element);
            if (secondary_source_element) gst_object_unref(secondary_source_element);
            gst_object_unref(pipeline);
            return NULL;
        }

        // Keep inactive-stream synchronization disabled even in seamless mode:
        // sync-streams can stall the active SRT input while its peer is absent.
        // Preserve encoder PCR/PTS and let the seamless gate below switch only
        // when the target reaches a compatible random-access frame.
        g_object_set(selector_element,
                     "sync-streams", FALSE,
                     "sync-mode", 0,
                     "cache-buffers", TRUE,
                     "drop-backwards", TRUE,
                     NULL);

        gst_bin_add_many(GST_BIN(pipeline),
                         primary_source_element, secondary_source_element,
                         selector_element, tee, NULL);

        // Request sink pads sink_0 (primary), sink_1 (secondary).
        primary_sink_pad = gst_element_request_pad_simple(selector_element, "sink_%u");
        secondary_sink_pad = gst_element_request_pad_simple(selector_element, "sink_%u");
        if (!primary_sink_pad || !secondary_sink_pad) {
            g_printerr("Failed to request sink pads on input-selector\n");
            gst_object_unref(pipeline);
            return NULL;
        }

        // MANDATORY: always-ok=TRUE keeps inactive srtsrc alive — without it the
        // inactive pad returns GST_FLOW_NOT_LINKED and the srtsrc task dies.
        g_object_set(G_OBJECT(primary_sink_pad), "always-ok", TRUE, NULL);
        g_object_set(G_OBJECT(secondary_sink_pad), "always-ok", TRUE, NULL);

        GstPad *primary_src_pad = gst_element_get_static_pad(primary_source_element, "src");
        GstPad *secondary_src_pad = gst_element_get_static_pad(secondary_source_element, "src");

        if (seamless_sdi_enabled) {
            gst_pad_add_probe(primary_src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                              source_ts_probe_callback, GINT_TO_POINTER(0), NULL);
            gst_pad_add_probe(secondary_src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                              source_ts_probe_callback, GINT_TO_POINTER(1), NULL);
        }

        if (gst_pad_link(primary_src_pad, primary_sink_pad) != GST_PAD_LINK_OK) {
            g_printerr("DUAL-INGEST: failed to link primary source → selector sink_0\n");
        }
        if (gst_pad_link(secondary_src_pad, secondary_sink_pad) != GST_PAD_LINK_OK) {
            g_printerr("DUAL-INGEST: failed to link secondary source → selector sink_1\n");
        }
        gst_object_unref(primary_src_pad);
        gst_object_unref(secondary_src_pad);

        if (!gst_element_link(selector_element, tee)) {
            g_printerr("DUAL-INGEST: failed to link input-selector → tee\n");
            gst_object_unref(pipeline);
            return NULL;
        }

        GstPad *initial_pad = start_on_secondary ? secondary_sink_pad : primary_sink_pad;
        g_object_set(selector_element, "active-pad", initial_pad, NULL);

        g_print("DUAL-INGEST Pipeline: primary+secondary → input-selector → tee "
                "(initial=%s, seamless-sdi=%s)\n",
                start_on_secondary ? "secondary" : "primary",
                seamless_sdi_enabled ? "enabled" : "disabled");
    } else {
        // =================================================================
        // SINGLE-SOURCE (legacy): source → tee
        // =================================================================
        gst_bin_add_many(GST_BIN(pipeline), primary_source_element, tee, NULL);
        if (!gst_element_link(primary_source_element, tee)) {
            g_printerr("Elements could not be linked.\n");
            gst_object_unref(pipeline);
            return NULL;
        }
        g_print("ULTRA-SIMPLE Pipeline: source -> tee (no intermediate processing)\n");
    }

    // Reset video info for new pipeline
    pthread_mutex_lock(&video_info.mutex);
    video_info.width = 0;
    video_info.height = 0;
    video_info.fps_num = 0;
    video_info.fps_den = 1;
    video_info.interlaced = FALSE;
    video_info.info_valid = FALSE;
    video_info.pmt_pid = 0;
    video_info.video_pid = 0;
    video_info.video_stream_type = 0;
    pthread_mutex_unlock(&video_info.mutex);

    // Add buffer probe on tee sink pad to parse MPEG-TS packets
    GstPad *tee_sink_pad = gst_element_get_static_pad(tee, "sink");
    if (tee_sink_pad) {
        gst_pad_add_probe(tee_sink_pad, GST_PAD_PROBE_TYPE_BUFFER, ts_probe_callback, NULL, NULL);
        g_print("MPEG-TS: Installed buffer probe on tee sink pad for video metadata extraction\n");
        gst_object_unref(tee_sink_pad);
    }

    // Reset sink counter
    sink_count = 0;
    thumbnail_thread_started = FALSE;
    thumbnail_appsink = NULL;

    cJSON *sink;
    int sink_idx = 0;
    cJSON_ArrayForEach(sink, sinks_array)
    {
        if (!add_sink_to_pipeline(pipeline, tee, sink, sink_idx)) {
            // Check if this is an SDI sink — SDI failures are non-fatal
            cJSON *sink_type = cJSON_GetObjectItem(sink, "type");
            if (sink_type && cJSON_IsString(sink_type) &&
                strcmp(sink_type->valuestring, "sdisink") == 0) {
                g_printerr("WARNING: SDI sink %d failed — continuing without SDI output\n", sink_idx);
                // Don't destroy pipeline, just skip this sink
            } else {
                // SRT/UDP sink failure is fatal
                gst_object_unref(pipeline);
                return NULL;
            }
        }
        sink_idx++;
    }

    // Add thumbnail capture branch (gracefully skipped if elements unavailable)
    if (route_id && route_id[0] != '\0') {
        add_thumbnail_branch(pipeline, tee, route_id);
    }

    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, bus_callback, pipeline);
    gst_object_unref(bus);

    source_element = source;
    tee_element = tee;
    g_pipeline = pipeline;

    running = TRUE;
    if (pthread_create(&stats_thread, NULL, print_stats, source) != 0) {
        g_printerr("Failed to create stats thread\n");
    }

    // auto_join=false: hold secondary at NULL so it does not connect until T3
    // explicitly raises it via join_secondary(). Primary still plays.
    if (dual_ingest_active && !auto_join_enabled && secondary_source_element &&
        !start_on_secondary) {
        gst_element_set_locked_state(secondary_source_element, TRUE);
        gst_element_set_state(secondary_source_element, GST_STATE_NULL);
        g_print("DUAL-INGEST: secondary held at NULL (auto_join=false)\n");
    }

    return pipeline;
}

gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config, int sink_index)
{
    cJSON *sink_type = cJSON_GetObjectItem(sink_config, "type");

    if (!cJSON_IsString(sink_type)) {
        g_printerr("Invalid sink format: missing or invalid 'type'\n");
        return FALSE;
    }

    // =========================================================================
    // SDI Output via DeckLink (decode MPEG-TS → raw video/audio → SDI port)
    // Uses decodebin for codec-agnostic decoding (H.264, HEVC, MPEG-2, etc.)
    // =========================================================================
    if (strcmp(sink_type->valuestring, "sdisink") == 0) {
        cJSON *device_number_json = cJSON_GetObjectItem(sink_config, "device-number");
        cJSON *video_mode_json    = cJSON_GetObjectItem(sink_config, "video-mode");
        cJSON *interlaced_json   = cJSON_GetObjectItem(sink_config, "interlaced");

        int device_number = (device_number_json && cJSON_IsNumber(device_number_json))
                            ? device_number_json->valueint : 0;
        const char *video_mode_str = (video_mode_json && cJSON_IsString(video_mode_json))
                                     ? video_mode_json->valuestring : "1080p25";
        gboolean interlaced = (interlaced_json && cJSON_IsBool(interlaced_json))
                              ? interlaced_json->valueint : FALSE;

        // --- Validate DeckLink device availability before creating pipeline ---
        GstElement *test_sink = gst_element_factory_make("decklinkvideosink", NULL);
        if (!test_sink) {
            g_printerr("SDI sink %d: DeckLink plugin not available - install BlackMagic drivers\n", sink_index);
            return FALSE;
        }
        g_object_set(test_sink, "device-number", device_number, NULL);
        gst_object_unref(test_sink);

        // --- Determine if auto-detect mode ---
        gboolean is_auto_detect = (strcmp(video_mode_str, "auto") == 0);

        // --- Create elements ---
        GstElement *queue       = gst_element_factory_make("queue2",            NULL);
        GstElement *tsdemux     = gst_element_factory_make("tsdemux",           NULL);
        // Video chain: decodebin handles any video codec (H.264, HEVC, MPEG-2)
        GstElement *vdecodebin  = gst_element_factory_make("decodebin",         NULL);
        GstElement *vqueue      = gst_element_factory_make("queue",             NULL);
        GstElement *vconvert    = gst_element_factory_make("videoconvert",      NULL);
        GstElement *vrate       = gst_element_factory_make("videorate",         NULL);
        GstElement *vscale      = gst_element_factory_make("videoscale",        NULL);
        // In auto-detect mode, vinterlace is created dynamically by the callback if needed.
        GstElement *vinterlace  = NULL;
        GstElement *vcaps       = gst_element_factory_make("capsfilter",        NULL);
        GstElement *videosink   = gst_element_factory_make("decklinkvideosink", NULL);
        // Audio chain: decodebin handles any audio codec (AAC, MP2, Opus)
        GstElement *adecodebin  = gst_element_factory_make("decodebin",         NULL);
        GstElement *aqueue      = gst_element_factory_make("queue",             NULL);
        GstElement *aconvert    = gst_element_factory_make("audioconvert",      NULL);
        GstElement *amix        = gst_element_factory_make("audiomixmatrix",    NULL);
        GstElement *aresample   = gst_element_factory_make("audioresample",     NULL);
        GstElement *arate       = gst_element_factory_make("audiorate",         NULL);
        GstElement *acaps       = gst_element_factory_make("capsfilter",        NULL);
        GstElement *audiosink   = gst_element_factory_make("decklinkaudiosink", NULL);

        if (!queue || !tsdemux || !vdecodebin || !vqueue || !vconvert || !vrate ||
            !vscale || !vcaps || !videosink ||
            !adecodebin || !aqueue || !aconvert || !amix || !aresample || !arate || !acaps || !audiosink) {
            g_printerr("SDI sink %d: Failed to create one or more elements\n", sink_index);
            if (queue)      gst_object_unref(queue);
            if (tsdemux)    gst_object_unref(tsdemux);
            if (vdecodebin) gst_object_unref(vdecodebin);
            if (vqueue)     gst_object_unref(vqueue);
            if (vconvert)   gst_object_unref(vconvert);
            if (vrate)      gst_object_unref(vrate);
            if (vscale)     gst_object_unref(vscale);
            if (vinterlace) gst_object_unref(vinterlace);
            if (vcaps)      gst_object_unref(vcaps);
            if (videosink)  gst_object_unref(videosink);
            if (adecodebin) gst_object_unref(adecodebin);
            if (aqueue)     gst_object_unref(aqueue);
            if (aconvert)   gst_object_unref(aconvert);
            if (amix)       gst_object_unref(amix);
            if (aresample)  gst_object_unref(aresample);
            if (arate)      gst_object_unref(arate);
            if (acaps)      gst_object_unref(acaps);
            if (audiosink)  gst_object_unref(audiosink);
            return FALSE;
        }

        // --- Read fallback width/height/framerate from JSON (used for both manual and auto fallback) ---
        cJSON *width_json      = cJSON_GetObjectItem(sink_config, "width");
        cJSON *height_json     = cJSON_GetObjectItem(sink_config, "height");
        cJSON *framerate_json  = cJSON_GetObjectItem(sink_config, "framerate");

        int width  = (width_json     && cJSON_IsNumber(width_json))     ? width_json->valueint     : 1920;
        int height = (height_json    && cJSON_IsNumber(height_json))    ? height_json->valueint    : 1080;
        const char *framerate = (framerate_json && cJSON_IsString(framerate_json))
                                ? framerate_json->valuestring : "25/1";

        // --- Configure DeckLink sinks (common to both auto and manual) ---
        g_object_set(videosink, "device-number", device_number, NULL);
        // DeckLink video runs with sync=FALSE (pacing is handled by the identity element).
        // DeckLink audio runs with sync=TRUE. This allows GStreamer's master clock-slaving
        // mechanism to pace and resample audio buffers properly, preventing stuttering and underruns.
        g_object_set(videosink, "sync", FALSE, NULL);
        g_object_set(audiosink, "device-number", device_number, "sync", TRUE, "max-lateness", (gint64)200000000, NULL);

        // Create identity element for video frame pacing via system clock
        GstElement *vid_identity = gst_element_factory_make("identity", NULL);
        g_object_set(vid_identity, "sync", TRUE, NULL);

        // Configure audiomixmatrix: upmix stereo to 8ch for SDI broadcast compatibility.
        // We configure it to manual mode and set a transformation matrix that duplicates
        // the stereo input (ch1/2) to all 4 stereo pairs (ch3/4, ch5/6, ch7/8).
        // This ensures that downstream switchers receive audio regardless of which pair they monitor.
        g_object_set(amix, "in-channels", 2, "out-channels", 8, "channel-mask", (guint64)0xc3f, NULL);
        gst_util_set_object_arg(G_OBJECT(amix), "mode", "manual");

        GValue matrix = G_VALUE_INIT;
        g_value_init(&matrix, GST_TYPE_ARRAY);
        for (int i = 0; i < 8; i++) {
            GValue row = G_VALUE_INIT;
            g_value_init(&row, GST_TYPE_ARRAY);
            for (int j = 0; j < 2; j++) {
                GValue val = G_VALUE_INIT;
                g_value_init(&val, G_TYPE_DOUBLE);
                // Odd rows map to In 1 (j=0), even rows map to In 2 (j=1)
                double coef = (i % 2 == j) ? 1.0 : 0.0;
                g_value_set_double(&val, coef);
                gst_value_array_append_value(&row, &val);
                g_value_unset(&val);
            }
            gst_value_array_append_value(&matrix, &row);
            g_value_unset(&row);
        }
        g_object_set_property(G_OBJECT(amix), "matrix", &matrix);
        g_value_unset(&matrix);

        // Configure audio caps filter: S16LE, 48kHz, 8 channels interleaved (standard SDI output requirement)
        GstCaps *audio_caps = gst_caps_from_string("audio/x-raw, format=S16LE, rate=48000, channels=8, channel-mask=(bitmask)0x0000000000000c3f, layout=interleaved");
        g_object_set(acaps, "caps", audio_caps, NULL);
        gst_caps_unref(audio_caps);

        // --- Configure input queue (match proven gst-launch: 5s buffer) ---
        g_object_set(queue,
                     "use-buffering",    FALSE,
                     "max-size-buffers", 0,
                     "max-size-bytes",   0,
                     "max-size-time",    (guint64)5000000000,
                     NULL);

        // --- Configure queues after decodebin (match gst-launch: large non-leaky) ---
        g_object_set(vqueue,
                     "max-size-buffers", 0,
                     "max-size-time",    (guint64)5000000000,
                     "max-size-bytes",   0,
                     "leaky",            0,
                     NULL);
        g_object_set(aqueue,
                     "max-size-buffers", 0,
                     "max-size-time",    (guint64)5000000000,
                     "max-size-bytes",   0,
                     "leaky",            0,
                     NULL);

        // Configure videorate: skip corrupted frames until first keyframe
        g_object_set(vrate, "skip-to-first", TRUE, NULL);

        if (device_number >= 0 && device_number < 8) {
            sdi_vrate_elements[device_number] = vrate;
        }

        s_sdi_branch_n[sink_index] = 0;
        {
            char *json_text = cJSON_PrintUnformatted(sink_config);
            g_free(s_sdi_sink_json[sink_index]);
            s_sdi_sink_json[sink_index] = g_strdup(json_text);
            cJSON_free(json_text);
        }
        s_sdi_branch_identity[sink_index] = vid_identity;
        s_sdi_branch_vsink[sink_index]    = videosink;
        s_sdi_branch_asink[sink_index]    = audiosink;
        s_sdi_branch_q2[sink_index]       = queue;
        s_sdi_branch_vq[sink_index]       = vqueue;
        s_sdi_branch_aq[sink_index]       = aqueue;
        sdi_branch_track(sink_index, device_number,
                         queue, tsdemux,
                         vdecodebin, vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink,
                         adecodebin, aqueue, aconvert, amix, aresample, arate, acaps, audiosink,
                         NULL);

        if (is_auto_detect) {
            // =================================================================
            // AUTO-DETECT PATH
            // Video chain is NOT linked now. The auto-detect callback will:
            //   1. Extract decoded video caps from decodebin
            //   2. Lookup matching DeckLink mode
            //   3. Configure decklinkvideosink mode + capsfilter
            //   4. Optionally create and add interlace element
            //   5. Link the full video chain
            //   6. Link decodebin → vqueue to start flow
            // =================================================================

            g_print("SDI sink %d: AUTO-DETECT mode — video chain deferred until first frame\n", sink_index);

            // In auto mode, set decklinkvideosink to a safe initial mode
            // (it will be reconfigured by the callback before any data arrives)
            gst_util_set_object_arg(G_OBJECT(videosink), "mode", "1080p25");

            // Add elements to pipeline (video chain elements are added but NOT linked)
            gst_bin_add_many(GST_BIN(pipeline),
                             queue, tsdemux,
                             vdecodebin, vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink,
                             adecodebin, aqueue, aconvert, amix, aresample, arate, acaps, audiosink,
                             NULL);

            // Audio chain is linked statically (audio caps are always forced)
            if (!gst_element_link_many(aqueue, aconvert, amix, aresample, arate, acaps, audiosink, NULL)) {
                g_printerr("SDI sink %d: Failed to link audio output chain\n", sink_index);
                return FALSE;
            }

            // Link tee → queue → tsdemux (static)
            if (!gst_element_link_many(tee, queue, tsdemux, NULL)) {
                g_printerr("SDI sink %d: Failed to link tee → queue → tsdemux\n", sink_index);
                return FALSE;
            }

            // Dynamic pad linking for tsdemux → decodebin
            TsdemuxPadData *ts_pad_data = g_new0(TsdemuxPadData, 1);
            ts_pad_data->vdecodebin = vdecodebin;
            ts_pad_data->adecodebin = adecodebin;

            g_signal_connect_data(
                tsdemux, "pad-added",
                G_CALLBACK(on_sdi_tsdemux_pad_added),
                ts_pad_data, (GClosureNotify)g_free, (GConnectFlags)0
            );

            // Allocate auto-detect context with all elements the callback needs
            SdiAutoDetectCtx *auto_ctx = g_new0(SdiAutoDetectCtx, 1);
            auto_ctx->pipeline     = pipeline;
            auto_ctx->vqueue       = vqueue;
            auto_ctx->vconvert     = vconvert;
            auto_ctx->vrate        = vrate;
            auto_ctx->vscale       = vscale;
            auto_ctx->vcaps        = vcaps;
            auto_ctx->vid_identity = vid_identity;
            auto_ctx->videosink    = videosink;
            auto_ctx->device_number = device_number;
            // Store fallback values (used if auto-detect can't match a broadcast standard)
            snprintf(auto_ctx->fallback_mode, sizeof(auto_ctx->fallback_mode), "1080p25");
            auto_ctx->fallback_width  = width;
            auto_ctx->fallback_height = height;
            snprintf(auto_ctx->fallback_framerate, sizeof(auto_ctx->fallback_framerate), "%s", framerate);
            auto_ctx->sink_index = sink_index;

            if (sink_index >= 0 && sink_index < 8) {
                if (s_sdi_vq_sink_pad[sink_index]) {
                    gst_object_unref(s_sdi_vq_sink_pad[sink_index]);
                    s_sdi_vq_sink_pad[sink_index] = NULL;
                }
                s_sdi_vinterlace[sink_index] = NULL;
                s_sdi_applied_caps[sink_index][0] = '\0';
                s_sdi_auto_ctx[sink_index] = auto_ctx;
            }

            // Connect auto-detect callback for video (deferred linking)
            g_signal_connect_data(
                vdecodebin, "pad-added",
                G_CALLBACK(on_sdi_decodebin_video_pad_added_autodetect),
                auto_ctx, (GClosureNotify)g_free, (GConnectFlags)0
            );
            // Audio decodebin uses the standard callback (no auto-detect needed for audio)
            g_signal_connect(adecodebin, "pad-added", G_CALLBACK(on_sdi_decodebin_audio_pad_added), aqueue);

            // Audio health monitor
            GstPad *audio_sink_pad = gst_element_get_static_pad(audiosink, "sink");
            if (audio_sink_pad) {
                gst_pad_add_probe(audio_sink_pad, GST_PAD_PROBE_TYPE_BUFFER,
                                  sdi_audio_health_probe, GINT_TO_POINTER(device_number), NULL);
                gst_object_unref(audio_sink_pad);
                sdi_audio_last_buffer_time[device_number] = g_get_monotonic_time();
                g_print("SDI sink %d: Audio health monitor installed\n", sink_index);
            }

            // Video health monitor
            GstPad *video_sink_pad = gst_element_get_static_pad(videosink, "sink");
            if (video_sink_pad) {
                gst_pad_add_probe(video_sink_pad, GST_PAD_PROBE_TYPE_BUFFER,
                                  sdi_video_health_probe, GINT_TO_POINTER(device_number), NULL);
                gst_object_unref(video_sink_pad);
                sdi_video_last_buffer_time[device_number] = g_get_monotonic_time();
                g_print("SDI sink %d: Video health monitor installed\n", sink_index);
            }

            g_print("SDI sink %d: pipeline created (AUTO-DETECT) → DeckLink device %d\n",
                    sink_index, device_number);
            return TRUE;

        } else {
            // =================================================================
            // MANUAL MODE PATH (existing behavior, unchanged)
            // Video chain is configured and linked statically at pipeline creation.
            // =================================================================

            // Configure video caps for DeckLink
            char caps_str[256];
            if (interlaced) {
                snprintf(caps_str, sizeof(caps_str),
                         "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s, interlace-mode=interleaved",
                         width, height, framerate);
            } else {
                snprintf(caps_str, sizeof(caps_str),
                         "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s",
                         width, height, framerate);
            }

            g_print("SDI sink %d: mode=%s -> caps: %s\n", sink_index, video_mode_str, caps_str);

            GstCaps *caps = gst_caps_from_string(caps_str);
            g_object_set(vcaps, "caps", caps, NULL);
            gst_caps_unref(caps);

            // Set DeckLink mode
            gst_util_set_object_arg(G_OBJECT(videosink), "mode", video_mode_str);

            // --- Add all elements to pipeline ---
            gst_bin_add_many(GST_BIN(pipeline),
                             queue, tsdemux,
                             vdecodebin, vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink,
                             adecodebin, aqueue, aconvert, amix, aresample, arate, acaps, audiosink,
                             NULL);

            // --- Link static chains downstream of decodebin ---
            // Video: vqueue → videoconvert → videorate → videoscale → capsfilter → identity(sync) → decklinkvideosink
            gboolean video_link_ok = gst_element_link_many(vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink, NULL);
            if (!video_link_ok) {
                g_printerr("SDI sink %d: Failed to link video output chain\n", sink_index);
                return FALSE;
            }
            // Audio: aqueue → audioconvert → audiomixmatrix → audioresample → audiorate → capsfilter → decklinkaudiosink
            if (!gst_element_link_many(aqueue, aconvert, amix, aresample, arate, acaps, audiosink, NULL)) {
                g_printerr("SDI sink %d: Failed to link audio output chain\n", sink_index);
                return FALSE;
            }

            // --- Link tee → queue → tsdemux (static) ---
            if (!gst_element_link_many(tee, queue, tsdemux, NULL)) {
                g_printerr("SDI sink %d: Failed to link tee → queue → tsdemux\n", sink_index);
                return FALSE;
            }

            // --- Dynamic pad linking for tsdemux → decodebin ---
            TsdemuxPadData *ts_pad_data = g_new0(TsdemuxPadData, 1);
            ts_pad_data->vdecodebin = vdecodebin;
            ts_pad_data->adecodebin = adecodebin;

            g_signal_connect_data(
                tsdemux, "pad-added",
                G_CALLBACK(on_sdi_tsdemux_pad_added),
                ts_pad_data, (GClosureNotify)g_free, (GConnectFlags)0
            );

            // --- Dynamic pad linking for decodebin → output queues ---
            g_signal_connect(vdecodebin, "pad-added", G_CALLBACK(on_sdi_decodebin_video_pad_added), vqueue);
            g_signal_connect(adecodebin, "pad-added", G_CALLBACK(on_sdi_decodebin_audio_pad_added), aqueue);

            // --- Audio health monitor: probe on audiosink to detect when audio stops ---
            GstPad *audio_sink_pad = gst_element_get_static_pad(audiosink, "sink");
            if (audio_sink_pad) {
                gst_pad_add_probe(audio_sink_pad, GST_PAD_PROBE_TYPE_BUFFER,
                                  sdi_audio_health_probe, GINT_TO_POINTER(device_number), NULL);
                gst_object_unref(audio_sink_pad);
                sdi_audio_last_buffer_time[device_number] = g_get_monotonic_time();
                g_print("SDI sink %d: Audio health monitor installed\n", sink_index);
            }

            // --- Video health monitor: probe on videosink ---
            GstPad *video_sink_pad = gst_element_get_static_pad(videosink, "sink");
            if (video_sink_pad) {
                gst_pad_add_probe(video_sink_pad, GST_PAD_PROBE_TYPE_BUFFER,
                                  sdi_video_health_probe, GINT_TO_POINTER(device_number), NULL);
                gst_object_unref(video_sink_pad);
                sdi_video_last_buffer_time[device_number] = g_get_monotonic_time();
                g_print("SDI sink %d: Video health monitor installed\n", sink_index);
            }

            g_print("SDI sink %d: pipeline created (decodebin) → DeckLink device %d (mode %s)\n",
                    sink_index, device_number, video_mode_str);
            return TRUE;
        }
    }


    // =========================================================================
    // Standard passthrough sinks (SRT, UDP)
    // =========================================================================

    GstElement *queue = gst_element_factory_make("queue2", NULL);
    GstElement *tsparse = NULL;
    GstElement *sink_element = gst_element_factory_make(sink_type->valuestring, NULL);

    if (!queue || !sink_element) {
        g_printerr("Could not create sink elements.\n");
        return FALSE;
    }

    g_object_set(queue, "use-buffering", FALSE, NULL);
    g_object_set(queue, "max-size-buffers", 0, NULL);
    g_object_set(queue, "max-size-bytes", 50 * 1024 * 1024, NULL);
    g_object_set(queue, "max-size-time", (guint64)3000000000, NULL);

    set_element_properties(sink_element, sink_config, sink_type->valuestring, "type");

    if (strcmp(sink_type->valuestring, "udpsink") == 0) {
        g_object_set(sink_element, "sync", FALSE, NULL);
        g_object_set(sink_element, "async", FALSE, NULL);
        g_print("Configured UDP sink with sync=FALSE, async=FALSE\n");
    }

    if (strcmp(sink_type->valuestring, "srtsink") == 0) {
        g_object_set(sink_element, "async", FALSE, NULL);
        g_object_set(sink_element, "sync", TRUE, NULL);
        g_object_set(sink_element, "wait-for-connection", FALSE, NULL);
        g_print("Configured SRT sink with async=FALSE, sync=TRUE, wait-for-connection=FALSE\n");

        if (sink_count < MAX_SINKS) {
            sink_elements[sink_count] = sink_element;
            sink_count++;
            g_print("Stored SRT sink element at index %d for stats collection\n", sink_index);
        }

        // Create tsparse for packet alignment (1316 bytes MTU) and PCR timing smoothing
        tsparse = gst_element_factory_make("tsparse", NULL);
        if (tsparse) {
            g_object_set(tsparse, "alignment", 7, "set-timestamps", TRUE, NULL);
            g_print("Configured tsparse before SRT sink for packet alignment and PCR smoothing\n");
        } else {
            g_printerr("Warning: tsparse plugin not found. Pacing and alignment disabled.\n");
        }
    }

    if (tsparse) {
        gst_bin_add_many(GST_BIN(pipeline), queue, tsparse, sink_element, NULL);
        if (!gst_element_link_many(tee, queue, tsparse, sink_element, NULL)) {
            g_printerr("Could not link sink elements with tsparse.\n");
            return FALSE;
        }
    } else {
        gst_bin_add_many(GST_BIN(pipeline), queue, sink_element, NULL);
        if (!gst_element_link_many(tee, queue, sink_element, NULL)) {
            g_printerr("Could not link sink elements.\n");
            return FALSE;
        }
    }

    return TRUE;
}

void cleanup_pipeline(GstElement *pipeline)
{
    running = FALSE;
    thumbnail_running = FALSE; // Signal thumbnail thread to stop

    for (int i = 0; i < 8; i++) {
        sdi_audio_last_buffer_time[i] = 0;
        sdi_audio_buffer_count[i] = 0;
        sdi_audio_silence_reported[i] = FALSE;
        sdi_video_last_buffer_time[i] = 0;
        sdi_video_buffer_count[i] = 0;
        sdi_vrate_elements[i] = NULL;
    }

    // Set pipeline to NULL first — this flushes appsink, unblocking try_pull_sample
    gst_element_set_state(pipeline, GST_STATE_NULL);

    pthread_join(stats_thread, NULL);

    if (thumbnail_thread_started) {
        pthread_join(thumbnail_thread, NULL);
        thumbnail_thread_started = FALSE;
    }

    thumbnail_appsink = NULL;

    gst_object_unref(pipeline);

    selector_element = NULL;
    primary_source_element = NULL;
    secondary_source_element = NULL;
    primary_sink_pad = NULL;
    secondary_sink_pad = NULL;
    dual_ingest_active = FALSE;
    seamless_sdi_enabled = FALSE;
    g_mutex_lock(&seamless_switch_mutex);
    pending_source_index = -1;
    memset(source_ts_info, 0, sizeof(source_ts_info));
    g_mutex_unlock(&seamless_switch_mutex);

    if (loop) {
        g_main_loop_unref(loop);
        loop = NULL;
    }
}

// Runtime command interface (T2 stubs; T3 fills handle_command_line).
void set_main_loop(GMainLoop *l)
{
    run_loop = l;
}

void handle_command_line(const char *line)
{
    if (!line) return;

    cJSON *cmd = cJSON_Parse(line);
    if (!cmd) {
        g_printerr("Bad command JSON\n");
        return;
    }

    cJSON *c = cJSON_GetObjectItem(cmd, "command");
    if (cJSON_IsString(c)) {
        if (strcmp(c->valuestring, "switch-source") == 0) {
            cJSON *t = cJSON_GetObjectItem(cmd, "target");
            switch_source(cJSON_IsString(t) ? t->valuestring : "primary");
        } else if (strcmp(c->valuestring, "join-secondary") == 0) {
            join_secondary();
        } else if (strcmp(c->valuestring, "leave-secondary") == 0) {
            leave_secondary();
        } else {
            g_printerr("Unknown command: %s\n", c->valuestring);
        }
    }

    cJSON_Delete(cmd);
}

// Off the stdin path: set_state(NULL) can block seconds on clock-waiting
// sinks. Serialized; rapid switches converge to the latest rebuild.
static GMutex s_sdi_rebuild_lock;
static gpointer sdi_rebuild_worker(gpointer data)
{
    (void)data;
    g_mutex_lock(&s_sdi_rebuild_lock);
    for (int slot = 0; slot < 8; slot++) {
        if (s_sdi_sink_json[slot]) teardown_sdi_branch(slot);
    }
    for (int slot = 0; slot < 8; slot++) {
        if (s_sdi_sink_json[slot]) rebuild_sdi_branch(slot);
    }
    g_mutex_unlock(&s_sdi_rebuild_lock);
    return NULL;
}

void switch_source(const char *target)
{
    if (!dual_ingest_active || !selector_element) {
        g_printerr("switch_source: not a dual-ingest pipeline\n");
        return;
    }

    gboolean to_secondary = (g_strcmp0(target, "secondary") == 0);
    gint target_index = to_secondary ? 1 : 0;

    if (seamless_sdi_enabled) {
        gboolean already_selected = FALSE;
        gboolean incompatible = FALSE;

        g_mutex_lock(&seamless_switch_mutex);
        already_selected = selected_source_index == target_index;
        if (!already_selected && source_descriptions_ready_unlocked() &&
            !source_maps_compatible_unlocked()) {
            incompatible = TRUE;
            pending_source_index = -1;
        } else if (!already_selected) {
            pending_source_index = target_index;
        }
        g_mutex_unlock(&seamless_switch_mutex);

        if (already_selected) {
            g_print("SOURCE_SWITCHED:%s\n", to_secondary ? "secondary" : "primary");
        } else if (incompatible) {
            g_print("SOURCE_SWITCH_REJECTED:%s:incompatible-mpegts-map\n",
                    to_secondary ? "secondary" : "primary");
        } else {
            g_print("SOURCE_SWITCH_PENDING:%s:waiting-for-keyframe\n",
                    to_secondary ? "secondary" : "primary");
        }
        return;
    }

    // Keep auto_join=false lifecycle atomic inside native code. Secondary must
    // be running before selector moves to it.
    if (to_secondary && !auto_join_enabled) {
        join_secondary();
    }

    GstPad *pad = (to_secondary && secondary_sink_pad) ? secondary_sink_pad
                                                        : primary_sink_pad;
    if (!pad) {
        g_printerr("switch_source: target pad unavailable\n");
        return;
    }

    g_object_set(selector_element, "active-pad", pad, NULL);
    g_print("SOURCE_SWITCHED:%s\n", to_secondary ? "secondary" : "primary");

    // Move selector to primary before stopping secondary.
    if (!to_secondary && !auto_join_enabled) {
        leave_secondary();
    }

    // sdi_rebuild_worker() (SDI branch teardown+rebuild) is implemented but
    // intentionally NOT wired: it stalls and has segfaulted under live streams
    // — needs a gdb session on the pipeline before enabling. Until then SDI
    // holds its last frame across a switch; route restart restores it.
}

void join_secondary(void)
{
    if (!dual_ingest_active || !secondary_source_element) {
        return;
    }
    gst_element_set_locked_state(secondary_source_element, FALSE);
    if (!gst_element_sync_state_with_parent(secondary_source_element)) {
        g_printerr("join_secondary: failed to synchronize secondary with parent\n");
        return;
    }
    g_print("SECONDARY_JOINED\n");
}

void leave_secondary(void)
{
    if (!dual_ingest_active || !secondary_source_element) {
        return;
    }
    gst_element_set_locked_state(secondary_source_element, TRUE);
    gst_element_set_state(secondary_source_element, GST_STATE_NULL);
    g_print("SECONDARY_LEFT\n");
}
