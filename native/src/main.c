#include <stdio.h>
#include <stdlib.h>

#include "gst_pipeline.h"
#include "unix_socket.h"

//  stdin expects a JSON object:
// {
//     "source": {
//         "type": "srtsrc",
//         "localaddress": "127.0.0.1",
//         "localport": 8000,
//         "auto-reconnect": true,
//         "keep-listening": false,
//         "mode": "listener"
//     },
//     "sinks": [
//         {
//             "type": "srtsink",
//             "localaddress": "127.0.0.1",
//             "localport": 8002,
//             "mode": "listener"
//         },
//         {
//             "type": "udpsink",
//             "address": "127.0.0.1",
//             "port": 8003
//         }
//     ]
// }
//

// Example JSON:
// {\"sinks\":[{\"localaddress\":\"127.0.0.1\",\"localport\":8002,\"mode\":\"listener\",\"type\":\"srtsink\"},{\"address\":\"127.0.0.1\",\"port\":8003,\"type\":\"udpsink\"}],\"source\":{\"auto-reconnect\":true,\"keep-listening\":false,\"localaddress\":\"127.0.0.1\",\"localport\":8000,\"type\":\"srtsrc\"}}

int main(int argc, char* argv[])
{
    setvbuf(stdout, NULL, _IONBF, 0);
    char buffer[1024];

    init_unix_socket("/tmp/hydra_unix_sock");
    atexit(cleanup_socket);

    printf("Argument %d: %s\n", argc, argv[1]);
    send_message_to_unix_socket("route_id:");
    send_message_to_unix_socket(argv[1]);

    printf("Waiting for JSON input...\n");
    fgets(buffer, sizeof(buffer), stdin);
    printf("Received JSON: %s\n", buffer);

    cJSON* json = cJSON_Parse(buffer);
    if (!json) {
        printf("Error parsing JSON\n");
        return 1;
    }

    gst_init(NULL, NULL);

    GstElement* pipeline = create_pipeline(json, argv[1]);
    if (!pipeline) {
        cJSON_Delete(json);
        return 1;
    }

    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        g_printerr("Unable to set the pipeline to the playing state.\n");

        // Diagnose which element failed the state change
        GstIterator *it = gst_bin_iterate_elements(GST_BIN(pipeline));
        GValue item = G_VALUE_INIT;
        while (gst_iterator_next(it, &item) == GST_ITERATOR_OK) {
            GstElement *elem = GST_ELEMENT(g_value_get_object(&item));
            GstState state, pending;
            GstStateChangeReturn elem_ret = gst_element_get_state(elem, &state, &pending, GST_CLOCK_TIME_NONE);
            if (state != GST_STATE_PLAYING) {
                g_printerr("Element '%s' state=%s pending=%s ret=%d\n",
                    GST_ELEMENT_NAME(elem),
                    gst_element_state_get_name(state),
                    gst_element_state_get_name(pending),
                    elem_ret);
            }
            g_value_reset(&item);
        }
        gst_iterator_free(it);

        // Also dump the last bus error if any
        GstBus *bus = gst_element_get_bus(pipeline);
        GstMessage *msg = gst_bus_poll(bus, GST_MESSAGE_ERROR, 0);
        if (msg) {
            GError *err = NULL;
            gchar *debug = NULL;
            gst_message_parse_error(msg, &err, &debug);
            g_printerr("Bus error from %s: %s | debug: %s\n",
                       GST_OBJECT_NAME(msg->src), err->message, debug ? debug : "none");
            g_error_free(err);
            g_free(debug);
            gst_message_unref(msg);
        }
        gst_object_unref(bus);

        cleanup_pipeline(pipeline);
        cJSON_Delete(json);
        return 1;
    }

    GMainLoop* loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);

    g_main_loop_unref(loop);
    cleanup_pipeline(pipeline);
    cJSON_Delete(json);

    return 0;
}
