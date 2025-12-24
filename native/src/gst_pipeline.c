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
