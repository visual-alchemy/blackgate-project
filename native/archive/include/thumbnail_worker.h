#ifndef THUMBNAIL_WORKER_H
#define THUMBNAIL_WORKER_H

#include <gst/gst.h>
#include <glib.h>
#include <pthread.h>

// Thread state — shared with gst_pipeline.c for cleanup.
extern pthread_t thumbnail_thread;
extern volatile gboolean thumbnail_running;
extern gboolean thumbnail_thread_started;

// Build the thumbnail preview branch off the main tee.
// Creates: queue → decodebin → videoconvert → videoscale → capsfilter(320x180) → jpegenc → appsink
// Spawns thumbnail_worker thread to extract frames every 5s.
void add_thumbnail_branch(GstElement *pipeline, GstElement *tee, const char *route_id);

// Thread function: polls appsink, writes /tmp/blackgate_preview_<id>.jpg every 5s.
void *thumbnail_worker(void *data);

// decodebin pad-added callback for the thumbnail branch.
void on_thumbnail_pad_added(GstElement *decodebin, GstPad *pad, gpointer data);

#endif
