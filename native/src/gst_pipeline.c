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

// Global active route ID
static char global_route_id[128] = {0};

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
static gint selected_source_index = 0;
static gint pending_source_index = -1;
static GMutex switch_mutex;
static GQuark source_index_quark = 0;

// Thumbnail capture state
static GstElement *thumbnail_appsink = NULL;
static pthread_t thumbnail_thread;
static volatile gboolean thumbnail_running = FALSE;
static gboolean thumbnail_thread_started = FALSE;
static GMutex thumbnail_pad_mutex;

// MPEG-TS parsing structures for video metadata extraction
#define TS_PACKET_SIZE 188
#define TS_SYNC_BYTE 0x47
#define PAT_PID 0x0000

// Video stream types in MPEG-TS PMT
#define STREAM_TYPE_MPEG2_VIDEO 0x02
#define STREAM_TYPE_MPEG1_AUDIO 0x03
#define STREAM_TYPE_MPEG2_AUDIO 0x04
#define STREAM_TYPE_AAC_ADTS 0x0F
#define STREAM_TYPE_AAC_LATM 0x11
#define STREAM_TYPE_H264 0x1B
#define STREAM_TYPE_HEVC 0x24
#define STREAM_TYPE_AC3 0x81
#define STREAM_TYPE_EAC3 0x87
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

    // Source-pad counters are transport-neutral. SRT exposes equivalent
    // values through its `stats` property; udpsrc does not.
    guint64 bytes_received_total;
    guint64 packets_received_total;
    gint64 first_buffer_at_us;
    guint64 last_report_bytes;
    gint64 last_report_at_us;
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
    guint8 h264_profile_idc;
    guint8 h264_level_idc;
    guint8 h264_chroma_format_idc;
    guint8 h264_bit_depth;
    guint8 hevc_profile_idc;
    guint8 hevc_level_idc;
    guint8 hevc_chroma_format_idc;
    guint8 hevc_bit_depth;
    guint16 sar_num;
    guint16 sar_den;
    guint16 pmt_pid;
    guint16 video_pid;
    guint8 video_stream_type;
    pthread_mutex_t mutex;
} VideoInfo;

static VideoInfo video_info = {
    .fps_den = 1, .sar_num = 1, .sar_den = 1,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
};

static const char *h264_profile_name(guint8 idc)
{
    switch (idc) {
    case 66: return "Baseline"; case 77: return "Main"; case 88: return "Extended";
    case 100: return "High"; case 110: return "High 10"; case 122: return "High 4:2:2";
    case 244: return "High 4:4:4 Predictive"; default: return "Unknown";
    }
}

static const char *chroma_format_name(guint8 idc)
{
    switch (idc) {
    case 0: return "4:0:0"; case 1: return "4:2:0"; case 2: return "4:2:2";
    case 3: return "4:4:4"; default: return "Unknown";
    }
}

static const char *hevc_profile_name(guint8 idc, guint8 chroma, guint8 depth)
{
    if (chroma == 2 && depth == 10) return "Main 4:2:2 10";
    if (chroma == 2) return "Main 4:2:2";
    if (chroma == 1 && depth == 10) return "Main 10";
    if (chroma == 1 && depth == 8) return "Main";
    switch (idc) {
    case 1: return "Main"; case 2: return "Main 10";
    case 3: return "Main Still Picture"; case 4: return "Range Extensions";
    default: return "Unknown";
    }
}

// Forward declarations for MPEG-TS parsing
static void parse_pat(const guint8 *data, gsize size);
static void parse_pmt(const guint8 *data, gsize size);
static gboolean source_maps_compatible_unlocked(void);
static gboolean source_descriptions_ready_unlocked(void);

// Forward declarations for thumbnail
static void add_thumbnail_branch(GstElement *pipeline, GstElement *tee, const char *route_id);
static void *thumbnail_worker(void *arg);
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

static gboolean mpegts_stream_is_audio(guint8 stream_type)
{
    return stream_type == STREAM_TYPE_MPEG1_AUDIO ||
           stream_type == STREAM_TYPE_MPEG2_AUDIO ||
           stream_type == STREAM_TYPE_AAC_ADTS ||
           stream_type == STREAM_TYPE_AAC_LATM ||
           stream_type == STREAM_TYPE_AC3 ||
           stream_type == STREAM_TYPE_EAC3;
}

static void add_source_probe_stats(cJSON *root, const char *tag)
{
    if (!root) return;

    gint source_index = g_strcmp0(tag, "secondary") == 0 ? 1 : 0;
    gint64 now_us = g_get_monotonic_time();
    guint64 bytes_total = 0;
    guint64 packets_total = 0;
    guint64 bytes_since_last_report = 0;
    gdouble receive_rate_mbps = 0.0;

    g_mutex_lock(&switch_mutex);
    SourceTsInfo *stream_info = &source_ts_info[source_index];
    bytes_total = stream_info->bytes_received_total;
    packets_total = stream_info->packets_received_total;

    gint64 sample_started_at_us = stream_info->last_report_at_us;
    guint64 sample_started_bytes = stream_info->last_report_bytes;
    if (sample_started_at_us == 0) {
        sample_started_at_us = stream_info->first_buffer_at_us;
        sample_started_bytes = 0;
    }

    if (sample_started_at_us > 0 && now_us > sample_started_at_us &&
        bytes_total >= sample_started_bytes) {
        bytes_since_last_report = bytes_total - sample_started_bytes;
        receive_rate_mbps =
            ((gdouble)bytes_since_last_report * 8.0) / (now_us - sample_started_at_us);
    }

    stream_info->last_report_bytes = bytes_total;
    stream_info->last_report_at_us = now_us;
    g_mutex_unlock(&switch_mutex);

    cJSON_AddNumberToObject(root, "total-bytes-received", (double)bytes_total);
    cJSON_AddNumberToObject(root, "bytes-received", (double)bytes_since_last_report);
    cJSON_AddNumberToObject(root, "packets-received", (double)packets_total);
    cJSON_AddNumberToObject(root, "packets-received-lost", 0);
    cJSON_AddNumberToObject(root, "packets-received-dropped", 0);
    cJSON_AddNumberToObject(root, "packets-received-retransmitted", 0);
    cJSON_AddNumberToObject(root, "rtt-ms", 0.0);
    cJSON_AddNumberToObject(root, "receive-rate-mbps", receive_rate_mbps);
    cJSON_AddNumberToObject(root, "bandwidth-mbps", 0.0);
    cJSON_AddNumberToObject(root, "negotiated-latency-ms", 0);
    cJSON_AddNumberToObject(root, "connected-callers", 0);
    cJSON_AddArrayToObject(root, "callers");
}

static void add_mpegts_source_stats(cJSON *root, const char *tag)
{
    // Every MPEG-TS source populates slot 0 (and dual ingest also populates
    // slot 1).  PID diagnostics must therefore not depend on dual ingest.
    if (!root) return;

    gint source_index = g_strcmp0(tag, "secondary") == 0 ? 1 : 0;
    SourceTsInfo snapshot;

    g_mutex_lock(&switch_mutex);
    snapshot = source_ts_info[source_index];
    g_mutex_unlock(&switch_mutex);

    if (!snapshot.pat_valid || !snapshot.pmt_valid) return;

    if (snapshot.video_pid > 0) {
        cJSON_AddNumberToObject(root, "video-pid", snapshot.video_pid);
    }

    cJSON *audio_pids = cJSON_AddArrayToObject(root, "audio-pids");
    for (guint i = 0; i < snapshot.stream_count; i++) {
        if (!mpegts_stream_is_audio(snapshot.stream_types[i])) continue;
        cJSON_AddItemToArray(audio_pids, cJSON_CreateNumber(snapshot.stream_pids[i]));
    }
}

static void add_video_metadata_stats(cJSON *root)
{
    if (!root) return;
    pthread_mutex_lock(&video_info.mutex);
    if (video_info.info_valid) {
        cJSON_AddNumberToObject(root, "video-width", video_info.width);
        cJSON_AddNumberToObject(root, "video-height", video_info.height);
        cJSON_AddNumberToObject(root, "video-framerate-num", video_info.fps_num);
        cJSON_AddNumberToObject(root, "video-framerate-den", video_info.fps_den);
        cJSON_AddBoolToObject(root, "video-framerate-inferred", video_info.fps_inferred);
        cJSON_AddStringToObject(root, "video-interlace-mode", video_info.interlaced ? "interleaved" : "progressive");
        if (video_info.video_stream_type == STREAM_TYPE_H264) {
            cJSON_AddStringToObject(root, "video-codec", "AVC/H.264");
            cJSON_AddStringToObject(root, "video-profile", h264_profile_name(video_info.h264_profile_idc));
            cJSON_AddNumberToObject(root, "video-level-idc", video_info.h264_level_idc);
            cJSON_AddStringToObject(root, "video-chroma-format", chroma_format_name(video_info.h264_chroma_format_idc));
            cJSON_AddNumberToObject(root, "video-bit-depth", video_info.h264_bit_depth);
        } else if (video_info.video_stream_type == STREAM_TYPE_HEVC) {
            cJSON_AddStringToObject(root, "video-codec", "HEVC/H.265");
            cJSON_AddStringToObject(root, "video-profile", hevc_profile_name(video_info.hevc_profile_idc, video_info.hevc_chroma_format_idc, video_info.hevc_bit_depth));
            cJSON_AddNumberToObject(root, "video-level-idc", video_info.hevc_level_idc);
            cJSON_AddStringToObject(root, "video-chroma-format", chroma_format_name(video_info.hevc_chroma_format_idc));
            cJSON_AddNumberToObject(root, "video-bit-depth", video_info.hevc_bit_depth);
        }
        cJSON_AddNumberToObject(root, "video-sar-num", video_info.sar_num);
        cJSON_AddNumberToObject(root, "video-sar-den", video_info.sar_den);
    }
    pthread_mutex_unlock(&video_info.mutex);
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
        // udpsrc has no `stats` property. The probe sees every source buffer,
        // so its counters provide route health, watchdog, and UI telemetry
        // without inventing SRT caller or RTT data.
        add_source_probe_stats(root, tag);
    }

    if (stats) {
        gst_structure_free(stats);
    }

    add_mpegts_source_stats(root, tag);

    return root;
}

static void *print_stats(void *src)
{
    GstElement *source = (GstElement *)src;

    while (running) {
        sleep(1);

        // Always emit primary (keeps legacy single-source contract: one stats object with "source":"primary").
        cJSON *primary = build_source_stats_json(source, "primary");

        add_video_metadata_stats(primary);

        send_json_to_socket(primary);
        cJSON_Delete(primary);

        if (dual_ingest_active && secondary_source_element) {
            cJSON *secondary = build_source_stats_json(secondary_source_element, "secondary");
            add_video_metadata_stats(secondary);
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

    g_mutex_lock(&switch_mutex);
    if (pending_source_index >= 0 && source_descriptions_ready_unlocked() &&
        !source_maps_compatible_unlocked()) {
        rejected = pending_source_index;
        pending_source_index = -1;
    }
    g_mutex_unlock(&switch_mutex);

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
        g_mutex_lock(&switch_mutex);
        if (pending_source_index == source_index) pending_source_index = -1;
        g_mutex_unlock(&switch_mutex);
        g_print("SOURCE_SWITCH_REJECTED:%s:target-pad-unavailable\n",
                source_index == 1 ? "secondary" : "primary");
        return;
    }

    g_mutex_lock(&switch_mutex);
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
    g_mutex_unlock(&switch_mutex);

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

    if (G_UNLIKELY(source_index_quark == 0)) {
        source_index_quark = g_quark_from_static_string("blackgate-source-index");
    }
    gst_mini_object_set_qdata(GST_MINI_OBJECT_CAST(buffer), source_index_quark,
                              GINT_TO_POINTER(source_index + 1), NULL);

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return GST_PAD_PROBE_OK;

    gboolean keyframe = FALSE;
    gsize first_packet = 0;
    while (first_packet < map.size && first_packet < TS_PACKET_SIZE &&
           map.data[first_packet] != TS_SYNC_BYTE) {
        first_packet++;
    }

    g_mutex_lock(&switch_mutex);
    SourceTsInfo *stream_info = &source_ts_info[source_index];
    gint64 now_us = g_get_monotonic_time();
    stream_info->bytes_received_total += map.size;
    stream_info->packets_received_total++;
    if (stream_info->first_buffer_at_us == 0) {
        stream_info->first_buffer_at_us = now_us;
    }

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
    g_mutex_unlock(&switch_mutex);

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

// Remove emulation-prevention bytes from an H.264 RBSP. The encoder inserts a
// 0x03 byte after every 00 00 pair to prevent an accidental start code
// (00 00 01) inside the payload. Per H.264 spec 7.3.2.1, these must be
// stripped before parsing or bit-level fields deep in the SPS (VUI timing_info)
// read misaligned. Returns the cleaned size.
static gsize remove_emulation_prevention(const guint8 *in, gsize in_size, guint8 *out, gsize out_cap)
{
    gsize out_size = 0;
    gint zero_count = 0;
    for (gsize i = 0; i < in_size; i++) {
        if (zero_count >= 2 && in[i] == 0x03) {
            zero_count = 0; // skip the EPB (0x03 is not a zero byte)
            continue;
        }
        if (out_size < out_cap) out[out_size++] = in[i];
        if (in[i] == 0x00) zero_count++;
        else zero_count = 0;
    }
    return out_size;
}

// Parse H.264 SPS NAL unit to get resolution and framerate
static void parse_h264_sps(const guint8 *data, gsize size)
{
    if (size < 5) return;

    // Strip emulation-prevention bytes from the RBSP (data[0] is the NAL header)
    guint8 rbsp[256];
    gsize rbsp_size = remove_emulation_prevention(data + 1, size - 1, rbsp, sizeof(rbsp));

    BitReader br = {rbsp, rbsp_size, 0, 0};

    guint8 profile_idc = read_bits(&br, 8);
    read_bits(&br, 8); // constraint_set flags + reserved
    guint8 level_idc = read_bits(&br, 8);
    read_ue(&br);      // seq_parameter_set_id

    guint32 chroma_format_idc = 1;
    guint32 bit_depth_luma = 8;
    // Handle high profiles
    if (profile_idc == 100 || profile_idc == 110 || profile_idc == 122 || profile_idc == 244 || profile_idc == 44 ||
        profile_idc == 83 || profile_idc == 86 || profile_idc == 118 || profile_idc == 128 || profile_idc == 138 ||
        profile_idc == 139 || profile_idc == 134) {
        chroma_format_idc = read_ue(&br);
        if (chroma_format_idc == 3) read_bits(&br, 1); // separate_colour_plane_flag
        bit_depth_luma = 8 + read_ue(&br);             // bit_depth_luma_minus8
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

    // Parse framerate from VUI timing_info when present (read from source, not inferred).
    // Fallback to 25fps only when the SPS carries no VUI timing info.
    gint fps_num = 25, fps_den = 1;
    gboolean fps_inferred = TRUE;

    guint16 sar_num = 1, sar_den = 1;
    if (read_bits(&br, 1)) { // vui_parameters_present_flag
        if (read_bits(&br, 1)) { // aspect_ratio_info_present_flag
            guint32 aspect_ratio_idc = read_bits(&br, 8);
            if (aspect_ratio_idc == 255) { // extended SAR
                sar_num = read_bits(&br, 16);
                sar_den = read_bits(&br, 16);
            } else {
                static const guint16 sar_table[][2] = {{0,0},{1,1},{12,11},{10,11},{16,11},{40,33},{24,11},{20,11},{32,11},{80,33},{18,11},{15,11},{64,33},{160,99},{4,3},{3,2},{2,1}};
                if (aspect_ratio_idc < G_N_ELEMENTS(sar_table)) { sar_num = sar_table[aspect_ratio_idc][0]; sar_den = sar_table[aspect_ratio_idc][1]; }
            }
        }
        if (read_bits(&br, 1)) { // overscan_info_present_flag
            read_bits(&br, 1);   // overscan_appropriate_flag
        }
        if (read_bits(&br, 1)) { // video_signal_type_present_flag
            read_bits(&br, 3);   // video_format
            read_bits(&br, 1);   // video_full_range_flag
            if (read_bits(&br, 1)) { // colour_description_present_flag
                read_bits(&br, 8);   // colour_primaries
                read_bits(&br, 8);   // transfer_characteristics
                read_bits(&br, 8);   // matrix_coefficients
            }
        }
        if (read_bits(&br, 1)) { // chroma_loc_info_present_flag
            read_ue(&br);        // chroma_sample_loc_type_top_field
            read_ue(&br);        // chroma_sample_loc_type_bottom_field
        }
        if (read_bits(&br, 1)) { // timing_info_present_flag
            guint32 num_units_in_tick = read_u32(&br);
            guint32 time_scale = read_u32(&br);
            read_bits(&br, 1);   // fixed_frame_rate_flag

            if (num_units_in_tick > 0 && time_scale > 0) {
                // Frame rate = time_scale / (2 * num_units_in_tick), reduced to lowest terms.
                guint32 a = time_scale;
                guint32 b = 2 * num_units_in_tick;
                guint32 g = a, t = b;
                while (t) { guint32 r = g % t; g = t; t = r; }
                if (g > 0) {
                    fps_num = (gint)(a / g);
                    fps_den = (gint)(b / g);
                    fps_inferred = FALSE; // read from source VUI
                }
            }
        }
    }

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = width;
    video_info.height = height;
    video_info.interlaced = interlaced;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.fps_inferred = fps_inferred;
    video_info.h264_profile_idc = profile_idc;
    video_info.h264_level_idc = level_idc;
    video_info.h264_chroma_format_idc = chroma_format_idc;
    video_info.h264_bit_depth = bit_depth_luma;
    video_info.video_stream_type = STREAM_TYPE_H264;
    video_info.sar_num = sar_num ? sar_num : 1;
    video_info.sar_den = sar_den ? sar_den : 1;
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/H.264: Resolution: %dx%d, Interlaced: %s, FPS: %d/%d (%s)\n", width, height,
            interlaced ? "yes" : "no", fps_num, fps_den,
            fps_inferred ? "inferred" : "from VUI");
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
    if (size < 20) return;
    guint8 rbsp[256];
    gsize rbsp_size = remove_emulation_prevention(data + 2, size - 2, rbsp, sizeof(rbsp));
    BitReader br = {rbsp, rbsp_size, 0, 0};
    read_bits(&br, 4);                             // sps_video_parameter_set_id
    guint8 max_sub_layers = read_bits(&br, 3) + 1; // sps_max_sub_layers_minus1 + 1
    read_bits(&br, 1);                             // sps_temporal_id_nesting_flag
    read_bits(&br, 2);  // general_profile_space
    read_bits(&br, 1);  // general_tier_flag
    guint8 profile_idc = read_bits(&br, 5);
    read_bits(&br, 32); // general_profile_compatibility_flags (32 bits)
    read_bits(&br, 1);  // general_progressive_source_flag
    gboolean interlaced = read_bits(&br, 1);
    read_bits(&br, 1);  // general_non_packed_constraint_flag
    read_bits(&br, 1);  // general_frame_only_constraint_flag
    // Skip remaining constraint flags (44 bits)
    read_bits(&br, 32);
    read_bits(&br, 12);
    guint8 level_idc = read_bits(&br, 8);
    gboolean profile_present[7] = {FALSE}, level_present[7] = {FALSE};
    if (max_sub_layers > 1) {
        for (int i = 0; i < max_sub_layers - 1; i++) {
            profile_present[i] = read_bits(&br, 1);
            level_present[i] = read_bits(&br, 1);
        }
        for (int i = max_sub_layers - 1; i < 8; i++) {
            read_bits(&br, 2);
        }
        for (int i = 0; i < max_sub_layers - 1; i++) {
            if (profile_present[i]) { read_bits(&br, 8); read_bits(&br, 32); read_bits(&br, 32); read_bits(&br, 12); }
            if (level_present[i]) read_bits(&br, 8);
        }
    }

    read_ue(&br); // sps_seq_parameter_set_id
    guint32 chroma_format_idc = read_ue(&br);
    if (chroma_format_idc > 3) return;
    if (chroma_format_idc == 3) {
        read_bits(&br, 1); // separate_colour_plane_flag
    }

    // The key info we need!
    guint32 pic_width = read_ue(&br);  // pic_width_in_luma_samples
    guint32 pic_height = read_ue(&br); // pic_height_in_luma_samples
    if (!pic_width || !pic_height) return;

    // Check for conformance_window_flag
    if (read_bits(&br, 1)) { // conformance_window_flag
        guint32 left = read_ue(&br);
        guint32 right = read_ue(&br);
        guint32 top = read_ue(&br);
        guint32 bottom = read_ue(&br);
        static const guint8 sub_width[] = {1, 2, 2, 1}, sub_height[] = {1, 2, 1, 1};
        guint32 crop_w = (left + right) * sub_width[chroma_format_idc];
        guint32 crop_h = (top + bottom) * sub_height[chroma_format_idc];
        if (crop_w >= pic_width || crop_h >= pic_height) return;
        pic_width -= crop_w; pic_height -= crop_h;
    }
    guint8 bit_depth = read_ue(&br) + 8;
    read_ue(&br); // bit_depth_chroma_minus8

    // Infer framerate based on resolution (50fps standard for HD/UHD broadcast)
    gint fps_num = (pic_height >= 720) ? 50 : 25, fps_den = 1;
    gboolean fps_inferred = TRUE;

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = pic_width;
    video_info.height = pic_height;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.fps_inferred = fps_inferred;
    video_info.interlaced = interlaced;
    video_info.hevc_profile_idc = profile_idc;
    video_info.hevc_level_idc = level_idc;
    video_info.hevc_chroma_format_idc = chroma_format_idc;
    video_info.hevc_bit_depth = bit_depth;
    video_info.video_stream_type = STREAM_TYPE_HEVC;
    video_info.sar_num = video_info.sar_den = 1;
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

// Keyframe gate for thumbnail: parsers mark inter-frames as delta units. Only
// decode random-access frames to keep this optional branch cheap and clean.
static GstPadProbeReturn thumbnail_keyframe_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
{
    (void)pad;
    (void)user_data;
    GstBuffer *buffer = gst_pad_probe_info_get_buffer(info);
    if (buffer && GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT)) {
        return GST_PAD_PROBE_DROP;
    }
    return GST_PAD_PROBE_OK;
}

static void on_thumbnail_tsdemux_pad_added(GstElement *tsdemux, GstPad *pad, gpointer data)
{
    (void)tsdemux;
    GstElement *deinterlace = (GstElement *)data;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    if (!caps || gst_caps_is_empty(caps) || gst_caps_is_any(caps) ||
        gst_caps_get_size(caps) == 0) {
        if (caps) gst_caps_unref(caps);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        return;
    }

    GstStructure *str = gst_caps_get_structure(caps, 0);
    if (!str) {
        gst_caps_unref(caps);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        return;
    }
    const gchar *name = gst_structure_get_name(str);
    gboolean is_h264 = g_strcmp0(name, "video/x-h264") == 0;
    gboolean is_h265 = g_strcmp0(name, "video/x-h265") == 0;
    gst_caps_unref(caps);

    // Audio and unsupported video pads must be consumed: a demux pad left
    // unlinked can propagate GST_FLOW_NOT_LINKED back through the tee.
    if (!is_h264 && !is_h265) {
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        return;
    }

    const char *codec = is_h264 ? "H.264" : "HEVC";
    const char *parser_factory = is_h264 ? "h264parse" : "h265parse";
    const char *decoder_factory = is_h264 ? "avdec_h264" : "avdec_h265";
    const char *parser_name = is_h264 ? "thumbnail_h264parse" : "thumbnail_h265parse";
    const char *decoder_name = is_h264 ? "thumbnail_avdec_h264" : "thumbnail_avdec_h265";

    g_mutex_lock(&thumbnail_pad_mutex);

    GstPad *decode_sink = gst_element_get_static_pad(deinterlace, "sink");
    if (!decode_sink || gst_pad_is_linked(decode_sink)) {
        if (decode_sink) gst_object_unref(decode_sink);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        g_mutex_unlock(&thumbnail_pad_mutex);
        return;
    }

    GstObject *parent = gst_object_get_parent(GST_OBJECT(deinterlace));
    GstElement *pipeline = parent ? GST_ELEMENT(parent) : NULL;
    GstElement *parser = gst_element_factory_make(parser_factory, parser_name);
    GstElement *decoder = gst_element_factory_make(decoder_factory, decoder_name);
    if (!pipeline || !parser || !decoder) {
        g_printerr("Thumbnail: %s parser/decoder unavailable; preview disabled for this stream\n", codec);
        if (pipeline) gst_object_unref(pipeline);
        if (parser) gst_object_unref(parser);
        if (decoder) gst_object_unref(decoder);
        gst_object_unref(decode_sink);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        g_mutex_unlock(&thumbnail_pad_mutex);
        return;
    }

    // Repeat HEVC VPS/SPS/PPS at IDRs so decoder can initialize after joining
    // a live transport stream.
    if (is_h265 && g_object_class_find_property(G_OBJECT_GET_CLASS(parser), "config-interval")) {
        g_object_set(parser, "config-interval", -1, NULL);
    }

    // HEVC thumbnails must decode the complete access-unit sequence: P/B
    // pictures carry references needed to reconstruct later frames. Reject
    // decoder-marked corrupt output instead of writing visibly damaged JPEGs.
    if (is_h265) {
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(decoder), "output-corrupt")) {
            g_object_set(decoder, "output-corrupt", FALSE, NULL);
        }
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(decoder), "discard-corrupted-frames")) {
            g_object_set(decoder, "discard-corrupted-frames", TRUE, NULL);
        }
    }

    gboolean parser_added = gst_bin_add(GST_BIN(pipeline), parser);
    gboolean decoder_added = parser_added && gst_bin_add(GST_BIN(pipeline), decoder);
    if (!parser_added || !decoder_added ||
        !gst_element_link(parser, decoder) ||
        !gst_element_link(decoder, deinterlace)) {
        g_printerr("Thumbnail: Failed to construct %s decode chain\n", codec);
        if (decoder_added) gst_bin_remove(GST_BIN(pipeline), decoder);
        else gst_object_unref(decoder);
        if (parser_added) gst_bin_remove(GST_BIN(pipeline), parser);
        else gst_object_unref(parser);
        gst_object_unref(decode_sink);
        gst_object_unref(pipeline);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
        g_mutex_unlock(&thumbnail_pad_mutex);
        return;
    }

    // H.264 preview keeps its existing IDR-only decode behavior. Do not gate
    // HEVC here: dropping its inter pictures breaks reference continuity.
    GstPad *parse_src = is_h264 ? gst_element_get_static_pad(parser, "src") : NULL;
    if (parse_src) {
        gst_pad_add_probe(parse_src, GST_PAD_PROBE_TYPE_BUFFER,
                          thumbnail_keyframe_probe, NULL, NULL);
        gst_object_unref(parse_src);
    }

    gboolean states_synced = gst_element_sync_state_with_parent(parser) &&
                             gst_element_sync_state_with_parent(decoder);
    GstPad *parser_sink = gst_element_get_static_pad(parser, "sink");
    GstPadLinkReturn ret = (states_synced && parser_sink)
        ? gst_pad_link(pad, parser_sink)
        : GST_PAD_LINK_REFUSED;
    if (parser_sink) gst_object_unref(parser_sink);

    // Release the temporary sink-pad ref used for the linked-state check.
    gst_object_unref(decode_sink);

    if (ret == GST_PAD_LINK_OK) {
        g_print("Thumbnail: Linked %s pad through %s → %s\n", codec,
                parser_factory, decoder_factory);
    } else {
        g_printerr("Thumbnail: Failed to link %s video pad (link=%d, state-sync=%s)\n",
                   codec, ret, states_synced ? "ok" : "failed");
        gst_element_set_state(decoder, GST_STATE_NULL);
        gst_element_set_state(parser, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(pipeline), decoder);
        gst_bin_remove(GST_BIN(pipeline), parser);
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, drop_thumbnail_pad_probe, NULL, NULL);
    }

    gst_object_unref(pipeline);
    g_mutex_unlock(&thumbnail_pad_mutex);
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
    GstElement *tsdemux     = gst_element_factory_make("tsdemux",       "thumbnail_tsdemux");
    GstElement *deinterlace = gst_element_factory_make("deinterlace",   "thumbnail_deinterlace");
    GstElement *rate        = gst_element_factory_make("videorate",      "thumbnail_rate");
    GstElement *convert     = gst_element_factory_make("videoconvert",  "thumbnail_convert");
    GstElement *scale       = gst_element_factory_make("videoscale",    "thumbnail_scale");
    GstElement *capsfilter  = gst_element_factory_make("capsfilter",    "thumbnail_capsfilter");
    GstElement *jpegenc     = gst_element_factory_make("jpegenc",       "thumbnail_jpegenc");
    GstElement *appsink     = gst_element_factory_make("appsink",       "thumbnail_appsink");

    if (!queue || !tsdemux || !deinterlace || !rate || !convert || !scale || !capsfilter || !jpegenc || !appsink) {
        g_printerr("Thumbnail: One or more elements unavailable — skipping thumbnail branch\n");
        if (queue)       gst_object_unref(queue);
        if (tsdemux)     gst_object_unref(tsdemux);
        if (deinterlace) gst_object_unref(deinterlace);
        if (rate)        gst_object_unref(rate);
        if (convert)     gst_object_unref(convert);
        if (scale)       gst_object_unref(scale);
        if (capsfilter)  gst_object_unref(capsfilter);
        if (jpegenc)     gst_object_unref(jpegenc);
        if (appsink)     gst_object_unref(appsink);
        return;
    }

    // Do not shed buffers from compressed MPEG-TS before demux/decode. Packet
    // loss here corrupts both transport continuity and HEVC reference frames.
    // Allow short decode/scheduling bursts to queue; sustained decoder overload
    // can still back-pressure this tee branch once this bounded queue fills.
    g_object_set(queue,
        "max-size-buffers", 0,
        "max-size-bytes",   64 * 1024 * 1024,
        "max-size-time",    (guint64)(8 * GST_SECOND),
        "leaky",            0,  // GST_QUEUE_NO_LEAK
        NULL);

    // Decode continuously, then keep only one raw frame per second for preview
    // conversion/JPEG work. This rate limiter is downstream of both decoders.
    g_object_set(rate,
        "max-rate", 1,
        "drop-only", TRUE,
        NULL);

    // Scale target: 320x180
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "width",  G_TYPE_INT, 320,
        "height", G_TYPE_INT, 180,
        NULL);
    g_object_set(capsfilter, "caps", caps, NULL);
    gst_caps_unref(caps);

    g_object_set(jpegenc, "quality", 85, NULL);

    // Optional preview may receive no frames (unsupported codec or long GOP).
    // Do not let its preroll hold the whole pipeline in PAUSED.
    g_object_set(appsink,
        "emit-signals", FALSE,
        "max-buffers",  2,
        "drop",         TRUE,
        "sync",         FALSE,
        "async",        FALSE,
        NULL);

    gst_bin_add_many(GST_BIN(pipeline), queue, tsdemux, deinterlace, rate, convert, scale, capsfilter, jpegenc, appsink, NULL);

    // Codec-specific parser/decoder is added when tsdemux exposes its video
    // pad. Both codecs then share the same thumbnail processing and JPEG tail.
    g_signal_connect(tsdemux, "pad-added", G_CALLBACK(on_thumbnail_tsdemux_pad_added), deinterlace);

    if (!gst_element_link(tee, queue) || !gst_element_link(queue, tsdemux)) {
        g_printerr("Thumbnail: Failed to link tee → queue → tsdemux\n");
        return;
    }

    if (!gst_element_link_many(deinterlace, rate, convert, scale, capsfilter, jpegenc, appsink, NULL)) {
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
    // local arrival clock here turns SRT/UDP jitter into timestamp jitter.
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

    // Keep primary/secondary slots stable. Elixir passes persisted logical
    // selection so later switch-source commands keep their meaning.
    cJSON *active_source_json = cJSON_GetObjectItem(json, "active_source");
    gboolean start_on_secondary =
        cJSON_IsString(active_source_json) &&
        g_strcmp0(active_source_json->valuestring, "secondary") == 0;

    g_mutex_lock(&switch_mutex);
    memset(source_ts_info, 0, sizeof(source_ts_info));
    selected_source_index = start_on_secondary ? 1 : 0;
    pending_source_index = -1;
    g_mutex_unlock(&switch_mutex);
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

        // Keep inactive-stream synchronization disabled:
        // sync-streams can stall the active SRT input while its peer is absent.
        // Preserve encoder PCR/PTS while both sources remain warm.
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

        // Parse both transport streams for per-source diagnostics and
        // compatibility status and source metadata.
        gst_pad_add_probe(primary_src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                          source_ts_probe_callback, GINT_TO_POINTER(0), NULL);
        gst_pad_add_probe(secondary_src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                          source_ts_probe_callback, GINT_TO_POINTER(1), NULL);

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
                "(initial=%s)\n",
                start_on_secondary ? "secondary" : "primary");
    } else {
        // =================================================================
        // SINGLE-SOURCE (legacy): source → tee
        // =================================================================
        gst_bin_add_many(GST_BIN(pipeline), primary_source_element, tee, NULL);

        // Keep source-level MPEG-TS metadata available for normal routes.
        // Dual-ingest installs this probe on both sources above; historically
        // single-source routes had no equivalent probe, so their PID stats
        // remained N/A even when the stream carried a valid PAT/PMT.
        GstPad *primary_src_pad = gst_element_get_static_pad(primary_source_element, "src");
        if (!primary_src_pad) {
            g_printerr("SINGLE-SOURCE: failed to get primary source src pad for PID probe\n");
            gst_object_unref(pipeline);
            return NULL;
        }
        gst_pad_add_probe(primary_src_pad, GST_PAD_PROBE_TYPE_BUFFER,
                          source_ts_probe_callback, GINT_TO_POINTER(0), NULL);
        gst_object_unref(primary_src_pad);

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
            // Sink failure is fatal
            gst_object_unref(pipeline);
            return NULL;
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
    g_mutex_lock(&switch_mutex);
    pending_source_index = -1;
    memset(source_ts_info, 0, sizeof(source_ts_info));
    g_mutex_unlock(&switch_mutex);

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

void switch_source(const char *target)
{
    if (!dual_ingest_active || !selector_element) {
        g_printerr("switch_source: not a dual-ingest pipeline\n");
        return;
    }

    gboolean to_secondary = (g_strcmp0(target, "secondary") == 0);
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
