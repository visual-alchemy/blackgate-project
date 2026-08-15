#ifndef PIPELINE_STATE_H
#define PIPELINE_STATE_H

#include <cjson/cJSON.h>
#include <glib.h>
#include <gst/gst.h>
#include <pthread.h>

/* ── Shared Types ─────────────────────────────────────────────────────── */

// DeckLink mode lookup entry: maps {w,h,fps_num,fps_den,interlaced} → mode string
typedef struct {
    int width;
    int height;
    int fps_num;
    int fps_den;
    gboolean interlaced;
    const char *mode_str;
    const char *caps_interlace_mode; // "interleaved" or NULL
} DeckLinkModeEntry;

// Context passed to SDI auto-detect decodebin callback
typedef struct {
    GstElement *pipeline;
    GstElement *vqueue;
    GstElement *vconvert;
    GstElement *vrate;
    GstElement *vscale;
    GstElement *vcaps;
    GstElement *vid_identity;
    GstElement *videosink;
    int device_number;
    char fallback_mode[32];
    int fallback_width;
    int fallback_height;
    char fallback_framerate[16];
} SdiAutoDetectCtx;

// Context passed to on_sdi_tsdemux_pad_added
typedef struct {
    GstElement *vdecodebin;
    GstElement *adecodebin;
} TsdemuxPadData;

// Parsed video metadata (written by ts_probe_callback, read by print_stats)
typedef struct {
    gint width;
    gint height;
    gint fps_num;
    gint fps_den;
    gboolean interlaced;
    gboolean fps_inferred;
    gboolean info_valid;
    guint16 pmt_pid;
    guint16 video_pid;
    guint8 video_stream_type;
    pthread_mutex_t mutex;
} VideoInfo;

// SDI audio health threshold
#define SDI_AUDIO_HEALTH_INTERVAL_SEC 10

// MPEG-TS constants (used by metadata parser)
#define TS_SYNC_BYTE 0x47
#define PAT_PID 0x0000
#define STREAM_TYPE_MPEG2_VIDEO 0x02
#define STREAM_TYPE_H264 0x1B
#define STREAM_TYPE_HEVC 0x24

/* ── Shared Globals ───────────────────────────────────────────────────── */

// Route identity
extern char global_route_id[128];

// Pipeline control
extern GstElement *source_element;
extern volatile gboolean running;
extern GMainLoop *loop;
extern GMainLoop *run_loop;

// SRT sink tracking (stats collection walks this array)
#define MAX_SINKS 32
extern GstElement *sink_elements[MAX_SINKS];
extern int sink_count;

// Tee element (metadata probe attaches here)
extern GstElement *tee_element;

// Dual-ingest (input-selector) state
extern GstElement *selector_element;
extern GstElement *primary_source_element;
extern GstElement *secondary_source_element;
extern GstPad *primary_sink_pad;
extern GstPad *secondary_sink_pad;
extern volatile gboolean dual_ingest_active;
extern volatile gboolean auto_join_enabled;

// Thumbnail capture
extern GstElement *thumbnail_appsink;

// Parsed video metadata (populated by metadata parser)
extern VideoInfo video_info;

// Stats thread
extern pthread_t stats_thread;

// SDI health probes — per-device counters
extern volatile gint64 sdi_audio_last_buffer_time[8];
extern volatile gint64 sdi_audio_buffer_count[8];
extern volatile gboolean sdi_audio_silence_reported[8];
extern volatile gint64 sdi_video_last_buffer_time[8];
extern volatile gint64 sdi_video_buffer_count[8];

// SDI videorate elements (stats collection)
extern GstElement *sdi_vrate_elements[8];

// SDI auto-detect mode strings per device
extern const char *sdi_detected_mode[8];

/* ── Shared Helpers ───────────────────────────────────────────────────── */

// DeckLink mode lookup (used by pipeline builder and auto-detect callbacks)
const DeckLinkModeEntry *lookup_decklink_mode(int width, int height,
                                               int fps_num, int fps_den,
                                               gboolean interlaced);

// Unix socket send (used by stats_serialize — defined in unix_socket.c)
void send_message_to_unix_socket(const char *message);

#endif /* PIPELINE_STATE_H */
