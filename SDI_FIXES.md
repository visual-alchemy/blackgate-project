# SDI Output Fixes — BlackGate Project

## Problem Summary

When a route has **SRT input + SRT output only**, everything works and VLC can receive the stream.
When **SDI output is added** to the same route, **both SRT output and SDI output fail** — nothing is received anywhere.

## Root Cause (Two-Stage Failure)

### Stage 1 — Caps Mismatch (Fixed in `88a657d`)

The UI `video_mode` values (e.g., `14` for 720p50) were passed directly as `mode=14` to `decklinkvideosink`. But GStreamer's `GstDecklinkModeEnum` uses completely different integers — `14` means **1080p50**, not 720p50. This caused a caps negotiation failure (`1280x720` vs `1920x1080`), making the entire SDI decode chain fail to link. Because `create_pipeline` destroys the whole pipeline if any sink fails, the working SRT output was also killed.

### Stage 2 — Hardware State Change Failure (Fixed in `8171849`)

After fixing the mode mapping, the pipeline linked successfully but still couldn't transition to `PLAYING`. Two suspected causes:
- **`sync=TRUE`** on `decklinkvideosink` — forces software clock sync on a hardware sink that manages its own timing
- **Integer mode values** — fragile across GStreamer versions; the container's plugin might use different enum ordering

## Fixes Applied (Commits on `sdi-output` branch)

| Commit | File | Change |
|--------|------|--------|
| `88a657d` | `lib/blackgate/route_handler.ex` | Added `sdi_video_mode_to_gst/1` to send explicit `width/height/framerate` to C pipeline |
| `88a657d` | `native/src/gst_pipeline.c` | Replaced broken `switch(video_mode)` with reading explicit dimensions from JSON |
| `76f9dd7` | `lib/blackgate/route_handler.ex` | Fixed mode mapping: UI `14` → GStreamer `17` (720p50), etc. using actual `GstDecklinkModeEnum` values |
| `b60799d` | `native/src/main.c` | Added per-element state dump + bus error logging when PLAYING fails |
| `8171849` | `lib/blackgate/route_handler.ex` | **Send mode as string** (`"1080p25"`, `"720p50"`) instead of integer |
| `8171849` | `native/src/gst_pipeline.c` | Use `gst_util_set_object_arg()` for string-to-enum parsing; **removed `sync=TRUE`** on video sink; set `sync=FALSE` on audio sink |

## Key Code Changes

### `lib/blackgate/route_handler.ex`

```elixir
def sink_from_record(%{"schema" => "SDI", "schema_options" => opts}) do
  video_mode = Map.get(opts, "video_mode", 0)
  {mode_str, width, height, framerate} = sdi_video_mode_to_gst(video_mode)

  props = %{
    "type" => "sdisink",
    "device-number" => Map.get(opts, "device_number", 0),
    "video-mode" => mode_str,      # "1080p25", "720p50", etc.
    "width" => width,              # explicit resolution
    "height" => height,
    "framerate" => framerate     # "25/1", "50/1", etc.
  }

  {:ok, props}
end

# UI video_mode -> {GStreamer mode string, width, height, framerate}
defp sdi_video_mode_to_gst(0),  do: {"auto",    1920, 1080, "25/1"}
defp sdi_video_mode_to_gst(9),  do: {"1080p25", 1920, 1080, "25/1"}
defp sdi_video_mode_to_gst(11), do: {"1080p30", 1920, 1080, "30/1"}
defp sdi_video_mode_to_gst(12), do: {"1080p50", 1920, 1080, "50/1"}
defp sdi_video_mode_to_gst(13), do: {"1080p60", 1920, 1080, "60/1"}
defp sdi_video_mode_to_gst(7),  do: {"1080i50", 1920, 1080, "25/1"}
defp sdi_video_mode_to_gst(8),  do: {"1080i60", 1920, 1080, "30/1"}
defp sdi_video_mode_to_gst(14), do: {"720p50",  1280,  720, "50/1"}
defp sdi_video_mode_to_gst(15), do: {"720p60",  1280,  720, "60/1"}
defp sdi_video_mode_to_gst(17), do: {"pal",      720,  576, "25/1"}
defp sdi_video_mode_to_gst(18), do: {"ntsc",     720,  480, "30/1"}
defp sdi_video_mode_to_gst(22), do: {"2160p25", 3840, 2160, "25/1"}
defp sdi_video_mode_to_gst(23), do: {"2160p30", 3840, 2160, "30/1"}
defp sdi_video_mode_to_gst(24), do: {"2160p50", 3840, 2160, "50/1"}
defp sdi_video_mode_to_gst(25), do: {"2160p60", 3840, 2160, "60/1"}
defp sdi_video_mode_to_gst(_),  do: {"1080p25", 1920, 1080, "25/1"}
```

### `native/src/gst_pipeline.c`

```c
// Read explicit width/height/framerate from JSON
int width  = (width_json     && cJSON_IsNumber(width_json))     ? width_json->valueint     : 1920;
int height = (height_json    && cJSON_IsNumber(height_json))    ? height_json->valueint    : 1080;
const char *framerate = (framerate_json && cJSON_IsString(framerate_json))
                        ? framerate_json->valuestring : "25/1";

char caps_str[256];
snprintf(caps_str, sizeof(caps_str),
         "video/x-raw, format=UYVY, width=%d, height=%d, framerate=%s",
         width, height, framerate);

GstCaps *caps = gst_caps_from_string(caps_str);
g_object_set(vcaps, "caps", caps, NULL);
gst_caps_unref(caps);

// Configure DeckLink sinks
g_object_set(videosink, "device-number", device_number, NULL);
gst_util_set_object_arg(G_OBJECT(videosink), "mode", video_mode_str);  // string -> enum
g_object_set(videosink, "sync", FALSE, NULL);   // hardware timing
g_object_set(audiosink, "device-number", device_number, "sync", FALSE, NULL);
```

### `native/src/main.c`

```c
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
}
```

## Diagnosis Results (May 11, 2026)

### Current Issue
When adding SDI output to a route, the pipeline fails to transition to PLAYING state, causing **both SRT output and SDI output to fail**.

### Root Cause Identified
**No DeckLink hardware available in the container**
```bash
sudo docker exec blackgate-project-blackgate-1 gst-device-monitor-1.0 | grep -i decklink
# Output: No DeckLink devices found
```

### Log Analysis
```
SDI sink 1: mode=1080p25 -> caps: video/x-raw, format=UYVY, width=1920, height=1080, framerate=25/1
SDI sink 1: pipeline created → DeckLink device 0 (mode 1080p25)
Unable to set the pipeline to the playing state.
Element 'decklinkvideosink0' state=NULL pending=VOID_PENDING ret=1
Element 'decklinkaudiosink0' state=NULL pending=VOID_PENDING ret=1
```

### Secondary Issue Fixed
**Bus watch race condition** - Two bus watches being created simultaneously:
- `gst_bus_add_watch()` in `gst_pipeline.c:1204`
- `gst_bus_poll()` in `main.c:89` (during error handling)

**Fix Applied**: Removed bus poll from error handling in `main.c` to avoid race condition.

### Expected Log Output (When Working)

```
SDI sink 1: mode=1080p25 -> caps: video/x-raw, format=UYVY, width=1920, height=1080, framerate=25/1
SDI sink 1: pipeline created → DeckLink device 0 (mode 1080p25)
Pipeline state changed from PAUSED to PLAYING
```

## Diagnostic Commands

### Check container logs for SDI/DeckLink errors:
```bash
sudo docker logs blackgate-project-blackgate-1 2>&1 | grep -iE "sdi|decklink|failed|error|Element|Bus error|state=|playing|Unable"
```

### Follow logs in real-time while starting a route:
```bash
sudo docker logs -f blackgate-project-blackgate-1 2>&1 | grep -iE "sdi|decklink|failed|error|Element|Bus error|state=|playing|Unable"
```

### Full container logs (last 200 lines):
```bash
sudo docker logs --tail=200 blackgate-project-blackgate-1
```

## Related Files

| File | Purpose |
|------|---------|
| `lib/blackgate/route_handler.ex` | Elixir sink configuration, mode mapping |
| `native/src/gst_pipeline.c` | C pipeline construction, element linking, caps negotiation |
| `native/src/main.c` | Pipeline lifecycle, state change, diagnostics |
| `web_app/src/pages/routes/RouteDestEdit.jsx` | UI video mode dropdown values |

## Notes

- The pipeline uses **decode mode** for SDI (MPEG-TS → raw video/audio → SDI), not passthrough.
- `avdec_h264` is a software decoder; if CPU is a bottleneck, consider `nvh264dec` or `vaapih264dec`.
- `decklinkvideosink` requires the BlackMagic DeckLink drivers inside the container.
- If the pipeline still fails after these fixes, the diagnostics in `main.c` will print the exact stuck element and bus error.
