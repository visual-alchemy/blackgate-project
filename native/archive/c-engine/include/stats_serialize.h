#ifndef STATS_SERIALIZE_H
#define STATS_SERIALIZE_H

#include <cjson/cJSON.h>
#include <gst/gst.h>

// Send a cJSON object as a JSON string to the Elixir unix socket.
// Appends a newline after the payload.
void send_json_to_socket(cJSON *root);

// Build a source stats cJSON object from the given GStreamer source element.
// tag is "primary" or "secondary".
cJSON *build_source_stats_json(GstElement *source, const char *tag);

// The stats thread entry point. src is the GstElement *source to query stats from.
// Runs every 1s until the global `running` flag is cleared.
void *print_stats(void *src);

// Collect stats from all SRT sink elements (sink_elements[] globals)
// and send them to the unix socket with "stats_sink:" prefix.
void collect_sink_stats(void);

#endif
