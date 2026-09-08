#ifndef GST_PIPELINE_H
#define GST_PIPELINE_H

#include <cJSON.h>
#include <gst/gst.h>
#include <pthread.h>
#include <unistd.h>

GstElement *create_pipeline(cJSON *json, const char *route_id);
void cleanup_pipeline(GstElement *pipeline);
void print_srt_stats(GstElement *source);
void blackgate_apply_decoder_policy(void);

void handle_command_line(const char *line);
void switch_source(const char *target);
void join_secondary(void);
void leave_secondary(void);
void set_main_loop(GMainLoop *loop);

#endif
