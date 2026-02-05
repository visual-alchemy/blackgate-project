#include "gst_pipeline.h"

#include <gio/gio.h>
#include <gst/gst.h>
#include <pthread.h>
#include <srt/srt.h>
#include <string.h>

#include "unix_socket.h"

#define MAX_SINKS 32

static gboolean add_sink_to_pipeline(GstElement *pipeline, GstElement *tee, cJSON *sink_config, int sink_index);
static void set_element_properties(GstElement *element, cJSON *config, const char *element_type,
                                   const char *skip_property);
static void set_srt_mode_property(GstElement *element, const char *mode_str, const char *element_desc);
static void collect_sink_stats(void);

static pthread_t stats_thread;
static GstElement *source_element = NULL;
static gboolean running = TRUE;
static GMainLoop *loop = NULL;

// Store SRT sink elements for stats collection
static GstElement *sink_elements[MAX_SINKS];
static int sink_count = 0;

// Store tee element for video caps query
static GstElement *tee_element = NULL;

// MPEG-TS parsing structures for video metadata extraction
#define TS_PACKET_SIZE 188
#define TS_SYNC_BYTE 0x47
#define PAT_PID 0x0000

// Video stream types in MPEG-TS PMT
#define STREAM_TYPE_MPEG2_VIDEO 0x02
#define STREAM_TYPE_H264 0x1B
#define STREAM_TYPE_HEVC 0x24

// Parsed video information
typedef struct {
    gint width;
    gint height;
    gint fps_num;
    gint fps_den;
    gboolean interlaced;
    gboolean info_valid;
    guint16 pmt_pid;
    guint16 video_pid;
    guint8 video_stream_type;
    pthread_mutex_t mutex;
} VideoInfo;

static VideoInfo video_info = {0, 0, 0, 1, FALSE, FALSE, 0, 0, 0, PTHREAD_MUTEX_INITIALIZER};

// Forward declarations for MPEG-TS parsing
static void parse_pat(const guint8 *data, gsize size);
static void parse_pmt(const guint8 *data, gsize size);
static void parse_h264_sps(const guint8 *data, gsize size);
static void parse_mpeg2_sequence(const guint8 *data, gsize size);
static GstPadProbeReturn ts_probe_callback(GstPad *pad, GstPadProbeInfo *info, gpointer user_data);

static void *print_stats(void *src)
{
    GstElement *source = (GstElement *)src;

    while (running) {
        sleep(1);

        GstStructure *stats = NULL;
        g_object_get(source, "stats", &stats, NULL);

        if (!stats) {
            g_print("Failed to retrieve SRT stats\n");
            continue;
        }

        cJSON *root = cJSON_CreateObject();

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

        // Add video metadata from MPEG-TS parsing (if available)
        pthread_mutex_lock(&video_info.mutex);
        if (video_info.info_valid) {
            cJSON_AddNumberToObject(root, "video-width", video_info.width);
            cJSON_AddNumberToObject(root, "video-height", video_info.height);
            cJSON_AddNumberToObject(root, "video-framerate-num", video_info.fps_num);
            cJSON_AddNumberToObject(root, "video-framerate-den", video_info.fps_den);
            cJSON_AddStringToObject(root, "video-interlace-mode",
                                    video_info.interlaced ? "interleaved" : "progressive");
        }
        pthread_mutex_unlock(&video_info.mutex);

        char *json_str = cJSON_PrintUnformatted(root);
        if (json_str) {
            send_message_to_unix_socket(json_str);
            send_message_to_unix_socket("\n"); // Newline separator
            free(json_str);
        }

        cJSON_Delete(root);
        gst_structure_free(stats);

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
            send_message_to_unix_socket("stats_sink:");
            send_message_to_unix_socket(json_str);
            send_message_to_unix_socket("\n"); // Newline separator
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
        case GST_MESSAGE_ERROR: {
            GError *err;
            gchar *debug;
            gst_message_parse_error(msg, &err, &debug);
            g_print("Error: %s\n", err->message);
            g_error_free(err);
            g_free(debug);
            if (loop) g_main_loop_quit(loop);
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
    g_print("\nIncoming SRT Connection1:\n");

    if (addr && G_IS_INET_SOCKET_ADDRESS(addr)) {
        GInetSocketAddress *inet_addr = G_INET_SOCKET_ADDRESS(addr);
        GInetAddress *address = g_inet_socket_address_get_address(inet_addr);
        guint16 port = g_inet_socket_address_get_port(inet_addr);
        gchar *ip = g_inet_address_to_string(address);
        g_print("  From: %s:%d\n", ip, port);
        g_free(ip);
    }

    if (stream_id) {
        g_print("  Stream ID: '%s'\n", stream_id);
    } else {
        g_print("  Stream ID: (none)\n");
    }

    if (authenticated) {
        *authenticated = TRUE;
    }

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
    gint fps_num = 25, fps_den = 1; // Default to 25fps (PAL)
    if (interlaced) {
        // Interlaced content: typically 25i (PAL) or 30i (NTSC)
        fps_num = 25;
        fps_den = 1;
    } else {
        // Progressive: common rates are 25p, 30p, 50p, 60p
        if (height >= 1080) {
            fps_num = 25;
            fps_den = 1; // 1080p usually 25fps for broadcast
        } else if (height >= 720) {
            fps_num = 50;
            fps_den = 1; // 720p usually 50fps
        } else {
            fps_num = 25;
            fps_den = 1;
        }
    }

    pthread_mutex_lock(&video_info.mutex);
    video_info.width = width;
    video_info.height = height;
    video_info.interlaced = interlaced;
    video_info.fps_num = fps_num;
    video_info.fps_den = fps_den;
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/H.264: Resolution: %dx%d, Interlaced: %s, FPS: %d (inferred)\n", width, height,
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
    video_info.info_valid = TRUE;
    g_print("MPEG-TS/MPEG-2: Resolution: %dx%d, FPS: %d/%d\n", width, height, fps_num, fps_den);
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

GstElement *create_pipeline(cJSON *json)
{
    GstElement *pipeline, *source, *tee;

    cJSON *source_obj = cJSON_GetObjectItem(json, "source");
    cJSON *sinks_array = cJSON_GetObjectItem(json, "sinks");

    if (!cJSON_IsObject(source_obj) || !cJSON_IsArray(sinks_array)) {
        g_printerr("Invalid JSON format: missing 'source' object or 'sinks' array\n");
        return NULL;
    }

    cJSON *source_type = cJSON_GetObjectItem(source_obj, "type");
    if (!cJSON_IsString(source_type)) {
        g_printerr("Invalid JSON format: missing or invalid 'type' in source\n");
        return NULL;
    }

    pipeline = gst_pipeline_new("test-pipeline");
    source = gst_element_factory_make(source_type->valuestring, "source");
    tee = gst_element_factory_make("tee", "tee");

    if (!pipeline || !source || !tee) {
        g_printerr("Failed to create elements\n");
        return NULL;
    }

    g_object_set(tee, "allow-not-linked", TRUE, NULL);
    g_print("Set allow-not-linked=TRUE for tee element\n");

    g_print("Created source element: %s (type: %s)\n", GST_ELEMENT_NAME(source), G_OBJECT_TYPE_NAME(source));

    set_element_properties(source, source_obj, source_type->valuestring, "type");

    // Use do-timestamp=FALSE for pure MPEG-TS passthrough
    // Regenerating timestamps corrupts PES packet structure causing artifacts
    g_object_set(source, "do-timestamp", FALSE, NULL);
    g_print("Set do-timestamp=FALSE for source element (pure passthrough)\n");

    if (g_strcmp0(source_type->valuestring, "srtsrc") == 0) {
        // Signal for logging incoming connections
        g_signal_connect(source, "caller-connecting", G_CALLBACK(on_caller_connecting), NULL);
    }

    // ULTRA-SIMPLE PIPELINE: source -> tee (no queues, no processing)
    gst_bin_add_many(GST_BIN(pipeline), source, tee, NULL);
    if (!gst_element_link(source, tee)) {
        g_printerr("Elements could not be linked.\n");
        gst_object_unref(pipeline);
        return NULL;
    }
    g_print("ULTRA-SIMPLE Pipeline: source -> tee (no intermediate processing)\n");

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

    cJSON *sink;
    int sink_idx = 0;
    cJSON_ArrayForEach(sink, sinks_array)
    {
        if (!add_sink_to_pipeline(pipeline, tee, sink, sink_idx)) {
            gst_object_unref(pipeline);
            return NULL;
        }
        sink_idx++;
    }

    loop = g_main_loop_new(NULL, FALSE);

    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, bus_callback, pipeline);
    gst_object_unref(bus);

    source_element = source;
    tee_element = tee;

    running = TRUE;
    if (pthread_create(&stats_thread, NULL, print_stats, source) != 0) {
        g_printerr("Failed to create stats thread\n");
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

    // Use queue2 for better streaming performance (supports ring buffer mode)
    GstElement *queue = gst_element_factory_make("queue2", NULL);
    GstElement *sink_element = gst_element_factory_make(sink_type->valuestring, NULL);

    if (!queue || !sink_element) {
        g_printerr("Could not create sink elements.\n");
        return FALSE;
    }

    // Configure queue2 for high-bitrate streaming (up to 50Mbps)
    // At 20Mbps: 50MB = ~20 seconds buffer, 3s time limit controls actual latency
    g_object_set(queue, "use-buffering", FALSE, NULL);               // Don't pause for buffering
    g_object_set(queue, "max-size-buffers", 0, NULL);                // Unlimited buffer count
    g_object_set(queue, "max-size-bytes", 50 * 1024 * 1024, NULL);   // 50MB max (handles 20Mbps+)
    g_object_set(queue, "max-size-time", (guint64)3000000000, NULL); // 3 seconds max

    set_element_properties(sink_element, sink_config, sink_type->valuestring, "type");

    if (strcmp(sink_type->valuestring, "udpsink") == 0) {
        g_object_set(sink_element, "sync", FALSE, NULL);
        g_object_set(sink_element, "async", FALSE, NULL);
        g_print("Configured UDP sink with sync=FALSE, async=FALSE\n");
    }

    if (strcmp(sink_type->valuestring, "srtsink") == 0) {
        g_object_set(sink_element, "async", FALSE, NULL);
        g_object_set(sink_element, "sync", FALSE, NULL);
        g_object_set(sink_element, "wait-for-connection", FALSE, NULL);
        g_print("Configured SRT sink with async=FALSE, sync=FALSE, wait-for-connection=FALSE\n");

        // Store this SRT sink element for stats collection
        if (sink_count < MAX_SINKS) {
            sink_elements[sink_count] = sink_element;
            sink_count++;
            g_print("Stored SRT sink element at index %d for stats collection\n", sink_index);
        }
    }

    gst_bin_add_many(GST_BIN(pipeline), queue, sink_element, NULL);
    if (!gst_element_link_many(tee, queue, sink_element, NULL)) {
        g_printerr("Could not link sink elements.\n");
        return FALSE;
    }

    return TRUE;
}

void cleanup_pipeline(GstElement *pipeline)
{
    running = FALSE;
    pthread_join(stats_thread, NULL);

    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);

    if (loop) {
        g_main_loop_unref(loop);
        loop = NULL;
    }
}
