#include "thumbnail_worker.h"

#include <cjson/cJSON.h>
#include <gio/gio.h>
#include <glib.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "pipeline_state.h"

#define UNUSED(x) (void)(x)

pthread_t thumbnail_thread;
volatile gboolean thumbnail_running = FALSE;
gboolean thumbnail_thread_started = FALSE;

typedef struct {
    GstElement *appsink;
    char route_id[128];
    volatile gint running;
} ThumbnailCtx;

void on_thumbnail_pad_added(GstElement *decodebin, GstPad *pad, gpointer data)
{
    UNUSED(decodebin);
    GstElement *pipeline = GST_ELEMENT(data);

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);

    if (caps) {
        GstStructure *structure = gst_caps_get_structure(caps, 0);
        const gchar *name = gst_structure_get_name(structure);
        if (strstr(name, "video/") == name) {
            GstElement *convert = gst_bin_get_by_name(GST_BIN(pipeline), "thumb-convert");
            if (convert) {
                GstPad *sink_pad = gst_element_get_static_pad(convert, "sink");
                if (sink_pad && !gst_pad_is_linked(sink_pad)) {
                    gst_pad_link(pad, sink_pad);
                }
                if (sink_pad) gst_object_unref(sink_pad);
                gst_object_unref(convert);
            }
        }
        gst_caps_unref(caps);
    }
}

void *thumbnail_worker(void *arg)
{
    ThumbnailCtx *ctx = (ThumbnailCtx *)arg;

    while (g_atomic_int_get(&ctx->running)) {
        GstSample *sample = gst_app_sink_pull_sample(GST_APP_SINK(ctx->appsink));
        if (sample) {
            GstBuffer *buffer = gst_sample_get_buffer(sample);
            if (buffer) {
                GstMapInfo map;
                if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
                    char tmp_path[256];
                    snprintf(tmp_path, sizeof(tmp_path), "/tmp/blackgate_preview_%s.tmp", ctx->route_id);
                    FILE *fp = fopen(tmp_path, "wb");
                    if (fp) {
                        fwrite(map.data, 1, map.size, fp);
                        fclose(fp);
                        char final_path[256];
                        snprintf(final_path, sizeof(final_path), "/tmp/blackgate_preview_%s.jpg", ctx->route_id);
                        rename(tmp_path, final_path);
                    }
                    gst_buffer_unmap(buffer, &map);
                }
            }
            gst_sample_unref(sample);
        } else {
            g_usleep(500000);
        }
    }

    char final_path[256];
    snprintf(final_path, sizeof(final_path), "/tmp/blackgate_preview_%s.jpg", ctx->route_id);
    remove(final_path);
    return NULL;
}

void add_thumbnail_branch(GstElement *pipeline, GstElement *tee, const char *route_id)
{
    GstElement *tqueue = gst_element_factory_make("queue", "thumb-queue");
    GstElement *decodebin = gst_element_factory_make("decodebin", "thumb-decodebin");
    GstElement *videoconvert = gst_element_factory_make("videoconvert", "thumb-convert");
    GstElement *videoscale = gst_element_factory_make("videoscale", "thumb-scale");
    GstElement *capsfilter = gst_element_factory_make("capsfilter", "thumb-caps");
    GstElement *jpegenc = gst_element_factory_make("jpegenc", "thumb-jpegenc");
    GstElement *appsink = gst_element_factory_make("appsink", "thumb-appsink");

    if (!tqueue || !decodebin || !videoconvert || !videoscale || !capsfilter ||
        !jpegenc || !appsink) {
        g_printerr("Thumbnail: Failed to create elements for route %s\n", route_id);
        return;
    }

    g_object_set(tqueue, "leaky", 2, "max-size-buffers", 2, NULL);

    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "width", G_TYPE_INT, 320, "height", G_TYPE_INT, 180, NULL);
    g_object_set(capsfilter, "caps", caps, NULL);
    gst_caps_unref(caps);

    g_object_set(jpegenc, "quality", 85, NULL);
    g_object_set(appsink, "emit-signals", TRUE, "max-buffers", 1, "drop", TRUE, NULL);

    gst_bin_add_many(GST_BIN(pipeline), tqueue, decodebin, videoconvert, videoscale,
                     capsfilter, jpegenc, appsink, NULL);

    if (!gst_element_link(tqueue, decodebin)) {
        g_printerr("Thumbnail: Failed to link queue -> decodebin\n");
        return;
    }

    if (!gst_element_link_many(videoconvert, videoscale, capsfilter, jpegenc, appsink, NULL)) {
        g_printerr("Thumbnail: Failed to link downstream\n");
        return;
    }

    g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_thumbnail_pad_added), pipeline);

    GstPad *tee_pad = gst_element_request_pad_simple(tee, "src_%u");
    GstPad *queue_pad = gst_element_get_static_pad(tqueue, "sink");
    if (tee_pad && queue_pad) {
        gst_pad_link(tee_pad, queue_pad);
        gst_object_unref(queue_pad);
        gst_object_unref(tee_pad);
    } else {
        g_printerr("Thumbnail: Failed to get pads\n");
        return;
    }

    thumbnail_appsink = appsink;

    ThumbnailCtx *ctx = g_new0(ThumbnailCtx, 1);
    ctx->appsink = appsink;
    g_strlcpy(ctx->route_id, route_id, sizeof(ctx->route_id));
    g_atomic_int_set(&ctx->running, 1);

    thumbnail_running = TRUE;
    thumbnail_thread_started = TRUE;
    if (pthread_create(&thumbnail_thread, NULL, thumbnail_worker, ctx) == 0) {
        pthread_detach(thumbnail_thread);
        g_print("Thumbnail: Branch ready for route %s\n", route_id);
    }
}
