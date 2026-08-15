#include "ipc_protocol.h"
#include "pipeline_state.h"

#include <cjson/cJSON.h>
#include <glib.h>
#include <gst/gst.h>
#include <stdio.h>
#include <string.h>

void handle_command_line(const char *line)
{
    if (!line) return;

    cJSON *cmd = cJSON_Parse(line);
    if (!cmd) {
        g_printerr("Bad command JSON: %s\n", line);
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
    GstPad *pad = (to_secondary && secondary_sink_pad) ? secondary_sink_pad
                                                        : primary_sink_pad;
    if (!pad) {
        g_printerr("switch_source: target pad unavailable\n");
        return;
    }

    g_object_set(selector_element, "active-pad", pad, NULL);
    g_print("SOURCE_SWITCHED:%s\n", to_secondary ? "secondary" : "primary");
}

void join_secondary(void)
{
    if (!dual_ingest_active || !secondary_source_element) {
        return;
    }
    gst_element_set_state(secondary_source_element, GST_STATE_PLAYING);
    g_print("SECONDARY_JOINED\n");
}

void leave_secondary(void)
{
    if (!dual_ingest_active || !secondary_source_element) {
        return;
    }
    gst_element_set_state(secondary_source_element, GST_STATE_NULL);
    g_print("SECONDARY_LEFT\n");
}
