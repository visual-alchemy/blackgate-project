#include "gst_pipeline.h"
#include "ipc_protocol.h"
#include "pipeline_state.h"
#include "metadata_parser.h"
#include "stats_serialize.h"
#include "thumbnail_worker.h"

#include <gio/gio.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <pthread.h>
#include <srt/srt.h>
#include <stdio.h>
#include <string.h>

#include "unix_socket.h"

#define MAX_SINKS 32

static gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config, int sink_index);
static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property);
static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc);

// Forward declarations for SDI decodebin callbacks
static void on_sdi_tsdemux_pad_added(GstElement *src, GstPad *new_pad, gpointer user_data);
static void on_sdi_decodebin_video_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data);
static void on_sdi_decodebin_audio_pad_added(GstElement *decodebin, GstPad *pad, gpointer user_data);

// SDI Audio Health Monitor — tracks last audio buffer time per device
// Only prints a warning when audio stops flowing (not every buffer)
volatile gint64 sdi_audio_last_buffer_time[8] = {0};
volatile gint64 sdi_audio_buffer_count[8] = {0};
volatile gboolean sdi_audio_silence_reported[8] = {FALSE};

// SDI Video Health Monitor — tracks last video frame time and count per device
volatile gint64 sdi_video_last_buffer_time[8] = {0};
volatile gint64 sdi_video_buffer_count[8] = {0};

GstElement *sdi_vrate_elements[8] = {NULL};

// SDI Auto-Detect: detected mode string per device (populated by auto-detect callback)
const char *sdi_detected_mode[8] = {NULL};

// Global active route ID
char global_route_id[128] = {0};

// =============================================================================
// DeckLink Mode Lookup Table
// Maps detected {width, height, fps_num, fps_den, interlaced} → DeckLink mode
// =============================================================================
static const DeckLinkModeEntry decklink_mode_table[] = {
    // HD Progressive
    {1920, 1080, 24, 1, FALSE, "1080p24", NULL},
    {1920, 1080, 25, 1, FALSE, "1080p25", NULL},
    {1920, 1080, 30, 1, FALSE, "1080p30", NULL},
    {1920, 1080, 50, 1, FALSE, "1080p50", NULL},
    {1920, 1080, 60, 1, FALSE, "1080p60", NULL},
    // HD Interlaced
    {1920, 1080, 25, 1, TRUE,  "1080i50", "interleaved"},
    {1920, 1080, 30, 1, TRUE,  "1080i60", "interleaved"},
    // 720p Progressive
    {1280,  720, 50, 1, FALSE, "720p50",  NULL},
    {1280,  720, 60, 1, FALSE, "720p60",  NULL},
    // SD Interlaced
    { 720,  576, 25, 1, TRUE,  "pal",     "interleaved"},
    { 720,  480, 30, 1, TRUE,  "ntsc",    "interleaved"},
    // 4K UHD Progressive
    {3840, 2160, 25, 1, FALSE, "2160p25", NULL},
    {3840, 2160, 30, 1, FALSE, "2160p30", NULL},
    {3840, 2160, 50, 1, FALSE, "2160p50", NULL},
    {3840, 2160, 60, 1, FALSE, "2160p60", NULL},
    // Sentinel (end of table)
    {0, 0, 0, 0, FALSE, NULL, NULL},
};

// Lookup a DeckLink mode entry matching the given video properties.
// Returns a pointer to the matching entry, or NULL if no match found.
const DeckLinkModeEntry *lookup_decklink_mode(int width, int height,
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
    const DeckLinkModeEntry *entry = lookup_decklink_mode(width, height,
                                                          lookup_fps_num, lookup_fps_den,
                                                          interlaced);

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
        need_interlace_element = (entry->caps_interlace_mode != NULL);

        // Build framerate string from the table entry
        char fr_buf[16];
        snprintf(fr_buf, sizeof(fr_buf), "%d/%d", entry->fps_num, entry->fps_den);
        out_framerate = g_strdup(fr_buf);

        g_print("SDI AUTO-DETECT: MATCHED → mode=%s (interlace=%s)\n",
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
            need_interlace_element = TRUE;
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
            g_print("SDI AUTO-DETECT: added interlace element (field-pattern=2:2, tff=TRUE)\n");
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
    if (sink_pad && !gst_pad_is_linked(sink_pad)) {
        GstPadLinkReturn ret = gst_pad_link(pad, sink_pad);
        if (ret == GST_PAD_LINK_OK) {
            g_print("SDI: decodebin audio → output chain linked\n");
        } else {
            g_printerr("SDI: decodebin audio pad link failed: %d\n", ret);
        }
    }
    if (sink_pad) gst_object_unref(sink_pad);
}

pthread_t stats_thread;
GstElement *source_element = NULL;
volatile gboolean running = TRUE;
GMainLoop *loop = NULL;
// Run loop owned by main.c, injected via set_main_loop(); bus_callback quits it on ERROR.
GMainLoop *run_loop = NULL;

// Store SRT sink elements for stats collection
GstElement *sink_elements[MAX_SINKS];
int sink_count = 0;

// Store tee element for video caps query
GstElement *tee_element = NULL;

// Dual-ingest (input-selector) state — populated when secondary_source JSON present.
GstElement *selector_element = NULL;
GstElement *primary_source_element = NULL;
GstElement *secondary_source_element = NULL;
GstPad *primary_sink_pad = NULL;
GstPad *secondary_sink_pad = NULL;
volatile gboolean dual_ingest_active = FALSE;
volatile gboolean auto_join_enabled = TRUE;

// Thumbnail capture state — moved to thumbnail_worker.c
GstElement *thumbnail_appsink = NULL;

VideoInfo video_info = {0, 0, 0, 1, FALSE, FALSE, FALSE, 0, 0, 0, PTHREAD_MUTEX_INITIALIZER};

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
                    send_message_to_unix_socket("\n");
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
            g_print("Error: %s\n", err->message);
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
                g_print("SRT Event: %s\n", gst_structure_to_string(s));
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

static void on_caller_connecting(GstElement *element, GSocketAddress *addr, const gchar *stream_id,
                                 gboolean *authenticated, gpointer user_data)
{
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

    g_print("New SRT caller connection to %s from %s (stream_id: %s)\n",
            name ? name : "source",
            addr_str ? addr_str : "unknown",
            stream_id ? stream_id : "none");
    g_free(addr_str);

    if (authenticated) {
        *authenticated = TRUE;
    }

    // Attribute the connection to primary or secondary source for health tracking.
    if (name && g_strcmp0(name, "secondary_source") == 0)
        g_print("SOURCE_VALID:secondary\n");
    else
        g_print("SOURCE_VALID:primary\n");

    if (stream_id) {
        send_message_to_unix_socket("stats_source_stream_id:");
        send_message_to_unix_socket(stream_id);
    }
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
            g_print("Set %s=%s for %s element\n", property->string, property->valuestring, element_type);
        }
    }
}


// Build a single source element from its JSON config. Mirrors the source setup
// historically inlined in create_pipeline (type lookup → factory make →
// set_element_properties → SDI do-timestamp → srtsrc caller-connecting signal).
// `name` becomes both the GstElement name and the user_data passed to
// on_caller_connecting so T3 can attribute health to primary vs secondary.
static GstElement *make_source(cJSON *source_obj, const char *name, cJSON *sinks_array)
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

    gboolean has_sdi_sink = FALSE;
    if (cJSON_IsArray(sinks_array)) {
        cJSON *sink_item;
        cJSON_ArrayForEach(sink_item, sinks_array) {
            cJSON *sink_type = cJSON_GetObjectItem(sink_item, "type");
            if (sink_type && cJSON_IsString(sink_type) &&
                strcmp(sink_type->valuestring, "sdisink") == 0) {
                has_sdi_sink = TRUE;
                break;
            }
        }
    }

    if (has_sdi_sink) {
        g_object_set(src, "do-timestamp", TRUE, NULL);
        g_print("Set do-timestamp=TRUE for %s source element (SDI playout detected)\n", name);
    } else {
        g_object_set(src, "do-timestamp", FALSE, NULL);
        g_print("Set do-timestamp=FALSE for %s source element (pure passthrough)\n", name);
    }

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

    pipeline = gst_pipeline_new("test-pipeline");
    tee = gst_element_factory_make("tee", "tee");

    if (!pipeline || !tee) {
        g_printerr("Failed to create pipeline or tee element\n");
        return NULL;
    }

    g_object_set(tee, "allow-not-linked", TRUE, NULL);
    g_print("Set allow-not-linked=TRUE for tee element\n");

    primary_source_element = make_source(source_obj, "source", sinks_array);
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
        secondary_source_element = make_source(secondary_obj, "secondary_source", sinks_array);

        if (!selector_element || !secondary_source_element) {
            g_printerr("Failed to create input-selector or secondary source for dual-ingest\n");
            if (selector_element) gst_object_unref(selector_element);
            if (secondary_source_element) gst_object_unref(secondary_source_element);
            gst_object_unref(pipeline);
            return NULL;
        }

        // sync-mode=1 (SYNC_ACTIVE), cache-buffers + drop-backwards for clean failover.
        g_object_set(selector_element,
                     "sync-mode", 1,
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

        // active-pad takes GstPad*, not string — fetch sink_0 explicitly.
        GstPad *active_pad = gst_element_get_static_pad(selector_element, "sink_0");
        if (active_pad) {
            g_object_set(selector_element, "active-pad", active_pad, NULL);
            gst_object_unref(active_pad);
        }

        g_print("DUAL-INGEST Pipeline: primary+secondary → input-selector → tee\n");
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

    running = TRUE;
    if (pthread_create(&stats_thread, NULL, print_stats, source) != 0) {
        g_printerr("Failed to create stats thread\n");
    }

    // auto_join=false: hold secondary at NULL so it does not connect until T3
    // explicitly raises it via join_secondary(). Primary still plays.
    if (dual_ingest_active && !auto_join_enabled && secondary_source_element) {
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
        // In auto-detect mode, vinterlace is created dynamically by the callback.
        // In manual mode, create it statically if the mode is interlaced.
        GstElement *vinterlace  = NULL;
        if (!is_auto_detect && interlaced) {
            vinterlace = gst_element_factory_make("interlace", NULL);
        }
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
            !adecodebin || !aqueue || !aconvert || !amix || !aresample || !arate || !acaps || !audiosink ||
            (!is_auto_detect && interlaced && !vinterlace)) {
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

            if (interlaced && vinterlace) {
                gst_util_set_object_arg(G_OBJECT(vinterlace), "field-pattern", "2:2");
                g_object_set(vinterlace, "top-field-first", TRUE, NULL);
            }

            // --- Add all elements to pipeline ---
            gst_bin_add_many(GST_BIN(pipeline),
                             queue, tsdemux,
                             vdecodebin, vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink,
                             adecodebin, aqueue, aconvert, amix, aresample, arate, acaps, audiosink,
                             NULL);
            if (interlaced) {
                gst_bin_add(GST_BIN(pipeline), vinterlace);
            }

            // --- Link static chains downstream of decodebin ---
            // Video: vqueue → videoconvert → videorate → videoscale → (vinterlace) → capsfilter → identity(sync) → decklinkvideosink
            gboolean video_link_ok;
            if (interlaced) {
                video_link_ok = gst_element_link_many(vqueue, vconvert, vrate, vscale, vinterlace, vcaps, vid_identity, videosink, NULL);
            } else {
                video_link_ok = gst_element_link_many(vqueue, vconvert, vrate, vscale, vcaps, vid_identity, videosink, NULL);
            }
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

