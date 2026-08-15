#include <stdio.h>
#include <stdlib.h>

#include <gio/gio.h>
#include <unistd.h>

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

// GIOChannel stdin reader: g_io_channel_read_line() dynamically allocates the
// buffer, replacing the legacy `char buffer[1024]; fgets(...)` which truncated
// JSON configs longer than 1023 bytes (e.g. dual-URI switch configs).

static char *read_stdin_line(GIOChannel *channel)
{
    gchar *line = NULL;
    gsize length = 0;
    gsize terminator_pos = 0;
    GError *error = NULL;

    GIOStatus status = g_io_channel_read_line(channel, &line, &length,
                                              &terminator_pos, &error);
    if (status != G_IO_STATUS_NORMAL) {
        if (error) {
            g_printerr("stdin read failed (status=%d): %s\n", status, error->message);
            g_error_free(error);
        }
        if (line) g_free(line);
        return NULL;
    }

    if (terminator_pos < length) {
        line[terminator_pos] = '\0';
    }

    return line;
}

static gboolean stdin_watch_cb(GIOChannel *channel, GIOCondition cond, gpointer user_data)
{
    GMainLoop *loop = (GMainLoop *)user_data;

    if (cond & (G_IO_HUP | G_IO_ERR)) {
        g_print("stdin closed (cond=0x%x), shutting down pipeline\n", (unsigned)cond);
        if (loop) g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }

    char *line = read_stdin_line(channel);
    if (line == NULL) {
        if (loop) g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }

    handle_command_line(line);
    g_free(line);

    return G_SOURCE_CONTINUE;
}

int main(int argc, char* argv[])
{
    setvbuf(stdout, NULL, _IONBF, 0);

    init_unix_socket("/tmp/hydra_unix_sock");
    atexit(cleanup_socket);

    printf("Argument %d: %s\n", argc, argv[1]);
    send_message_to_unix_socket("route_id:");
    send_message_to_unix_socket(argv[1]);

    printf("Waiting for JSON input...\n");

    GIOChannel *stdin_channel = g_io_channel_unix_new(STDIN_FILENO);
    // encoding=NULL => binary-safe, no UTF-8 validation of arbitrary JSON bytes.
    g_io_channel_set_encoding(stdin_channel, NULL, NULL);
    g_io_channel_set_close_on_unref(stdin_channel, TRUE);

    // Protocol contract: the first stdin line is the init JSON config, read
    // blocking BEFORE the pipeline enters PLAYING. Runtime commands arrive later.
    char *init_line = read_stdin_line(stdin_channel);
    if (init_line == NULL) {
        g_printerr("Failed to read init JSON from stdin\n");
        g_io_channel_unref(stdin_channel);
        return 1;
    }
    printf("Received JSON: %s\n", init_line);

    cJSON *json = cJSON_Parse(init_line);
    g_free(init_line);
    if (!json) {
        printf("Error parsing JSON\n");
        g_io_channel_unref(stdin_channel);
        return 1;
    }

    gst_init(NULL, NULL);

    GstElement *pipeline = create_pipeline(json, argv[1]);
    if (!pipeline) {
        cJSON_Delete(json);
        g_io_channel_unref(stdin_channel);
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

        // Note: Don't poll bus here to avoid race condition with existing bus watch
        // The bus_callback in gst_pipeline.c will handle error messages

        cleanup_pipeline(pipeline);
        cJSON_Delete(json);
        g_io_channel_unref(stdin_channel);
        return 1;
    }

    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    set_main_loop(loop);

    g_io_add_watch(stdin_channel, G_IO_IN | G_IO_HUP | G_IO_ERR, stdin_watch_cb, loop);

    g_main_loop_run(loop);

    g_io_channel_unref(stdin_channel);
    g_main_loop_unref(loop);
    cleanup_pipeline(pipeline);
    cJSON_Delete(json);

    return 0;
}
