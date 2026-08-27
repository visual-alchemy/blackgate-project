#ifndef METADATA_PARSER_H
#define METADATA_PARSER_H

#include <gst/gst.h>

// MPEG Transport Stream program-table parsers. Return 0 on success, -1 on parse
// error (truncated, corrupt, or unknown stream type).

// Program Association Table — extracts PMT PID from TS packet payload.
// Returns 0 on success, -1 on error. Sets *pmt_pid if non-NULL.
int parse_pat(const unsigned char *data, int length, unsigned int *pmt_pid);

// Program Map Table — extracts first elementary stream PID and stream type.
// Returns 0 on success, -1 on error. Sets *elementary_pid and *stream_type.
int parse_pmt(const unsigned char *data, int length,
              unsigned int *elementary_pid, unsigned int *stream_type);

// A minimal bit-reader for H.264/HEVC/MPEG-2 bitstream parsing.
typedef struct {
    const unsigned char *data;
    int byte_position;
    int bit_position;
    int data_size;
} BitReader;

unsigned int read_bits(BitReader *br, int n);
unsigned int read_ue(BitReader *br);

// H.264 Sequence Parameter Set parser. Fills video_info on success.
// Returns 0 on success, -1 on error.
int parse_h264_sps(const unsigned char *nal_data, int nal_length);

// MPEG-2 Video Sequence Header parser. Fills video_info on success.
// Returns 0 on success, -1 on error.
int parse_mpeg2_sequence(const unsigned char *data, int length);

// HEVC/H.265 Sequence Parameter Set parser. Fills video_info on success.
// Returns 0 on success, -1 on error.
int parse_hevc_sps(const unsigned char *nal_data, int nal_length);

// GStreamer pad probe — inspects TS packets on the source pad for PAT/PMT
// and extracts video stream metadata (codec, resolution, framerate, interlace).
GstPadProbeReturn ts_probe_callback(GstPad *pad, GstPadProbeInfo *info,
                                     gpointer user_data);

#endif
