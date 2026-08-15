#include "stats_serialize.h"
#include "pipeline_state.h"
#include "unix_socket.h"

#include <cjson/cJSON.h>
#include <gio/gio.h>
#include <glib.h>
#include <gst/gst.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

void send_json_to_socket(cJSON *root)
{
    if (!root) return;
    char *json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        send_message_to_unix_socket(json_str);
        send_message_to_unix_socket("\n");
        free(json_str);
    }
}

cJSON *build_source_stats_json(GstElement *source, const char *tag)
{
    cJSON *root = cJSON_CreateObject();

    GstStructure *stats = NULL;
    g_object_get(source, "stats", &stats, NULL);

    if (stats) {
        // Top-level stats
        guint64 total_bytes_received = 0;
        gint64 packets_received = 0, packets_lost = 0, packets_dropped = 0;
        gint64 packets_retransmitted = 0;
        gdouble rtt_ms = 0.0, receive_rate_mbps = 0.0, bandwidth_mbps = 0.0;
        gint negotiated_latency_ms = 0;

        gst_structure_get_uint64(stats, "total-bytes-received", &total_bytes_received);
        gst_structure_get_int64(stats, "packets-received", &packets_received);
        gst_structure_get_int64(stats, "packets-received-lost", &packets_lost);
        gst_structure_get_int64(stats, "packets-received-dropped", &packets_dropped);
        gst_structure_get_int64(stats, "packets-received-retransmitted", &packets_retransmitted);
        gst_structure_get_double(stats, "rtt-ms", &rtt_ms);
        gst_structure_get_double(stats, "receive-rate-mbps", &receive_rate_mbps);
        gst_structure_get_double(stats, "bandwidth-mbps", &bandwidth_mbps);
        gst_structure_get_int(stats, "negotiated-latency-ms", &negotiated_latency_ms);

        // SRT source tag — primary / secondary
        cJSON_AddStringToObject(root, "source", tag);

        cJSON_AddNumberToObject(root, "total-bytes-received", (double)total_bytes_received);
        cJSON_AddNumberToObject(root, "packets-received", (double)packets_received);
        cJSON_AddNumberToObject(root, "packets-received-lost", (double)packets_lost);
        cJSON_AddNumberToObject(root, "packets-received-dropped", (double)packets_dropped);
        cJSON_AddNumberToObject(root, "packets-received-retransmitted", (double)packets_retransmitted);
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

void *print_stats(void *src)
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
void collect_sink_stats(void)
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
