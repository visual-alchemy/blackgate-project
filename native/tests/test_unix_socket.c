#include <assert.h>
#include <cJSON.h>
#include <setjmp.h>
#include <stdarg.h>
#include <cmocka.h>
#include <gst/app/gstappsrc.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../include/gst_pipeline.h"
#include "../include/ts_normalizer.h"
#include "../include/unix_socket.h"

#define TS_PACKET_SIZE 188
#define TS_TIMESTAMP_MASK ((1ULL << 33) - 1)

typedef struct {
    int server_fd;
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
} SocketFixture;

static int setup_socket_fixture(void **state)
{
    SocketFixture *fixture = calloc(1, sizeof(*fixture));
    assert_non_null(fixture);

    snprintf(fixture->socket_path, sizeof(fixture->socket_path),
             "/tmp/blackgate_unix_test_%ld", (long)getpid());
    unlink(fixture->socket_path);

    fixture->server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert_true(fixture->server_fd >= 0);

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, fixture->socket_path, sizeof(addr.sun_path) - 1);

    assert_int_equal(bind(fixture->server_fd, (struct sockaddr *)&addr, sizeof(addr)), 0);
    assert_int_equal(listen(fixture->server_fd, 4), 0);

    *state = fixture;
    return 0;
}

static int teardown_socket_fixture(void **state)
{
    SocketFixture *fixture = *state;
    cleanup_socket();
    close(fixture->server_fd);
    unlink(fixture->socket_path);
    free(fixture);
    return 0;
}

static void assert_received_frame(SocketFixture *fixture, const char *expected)
{
    int peer = accept(fixture->server_fd, NULL, NULL);
    assert_true(peer >= 0);

    char buffer[256] = {0};
    ssize_t received = recv(peer, buffer, sizeof(buffer) - 1, 0);
    assert_true(received > 0);
    assert_string_equal(buffer, expected);
    close(peer);
}

static void test_init_unix_socket(void **state)
{
    (void)state;

    SocketFixture *fixture = *state;
    init_unix_socket(fixture->socket_path);
    assert_int_not_equal(sock, -1);
}

static void test_send_message_to_unix_socket(void **state)
{
    (void)state;

    SocketFixture *fixture = *state;
    init_unix_socket(fixture->socket_path);
    send_message_to_unix_socket("Test message");
    assert_received_frame(fixture, "Test message\n");
}

static void test_send_prefixed_message_to_unix_socket(void **state)
{
    SocketFixture *fixture = *state;
    init_unix_socket(fixture->socket_path);
    send_prefixed_message_to_unix_socket("route_id:", "test-route");
    assert_received_frame(fixture, "route_id:test-route\n");
}

static void test_cleanup_socket(void **state)
{
    (void)state;

    SocketFixture *fixture = *state;
    init_unix_socket(fixture->socket_path);
    cleanup_socket();
    assert_int_equal(sock, -1);
}

static void test_create_pipeline(void **state)
{
    (void)state;

    const char *json_str =
        "{\"source\":{\"type\":\"srtsrc\",\"localaddress\":\"127.0.0.1\",\"localport\":8000,\"auto-reconnect\":true,"
        "\"keep-listening\":false,\"mode\":\"listener\"},\"sinks\":[{\"type\":\"srtsink\",\"localaddress\":\"127.0.0."
        "1\",\"localport\":8002,"
        "\"mode\":\"listener\"},{\"type\":\"udpsink\",\"host\":\"127.0.0.1\",\"port\":8003}]}";
    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);

    GstElement *pipeline = create_pipeline(json, "test_route_id");
    assert_non_null(pipeline);

    cleanup_pipeline(pipeline);
    cJSON_Delete(json);
}

static void assert_dual_ingest_initial_state(const char *active_source,
                                             gboolean secondary_locked)
{
    char json_str[512];
    snprintf(json_str, sizeof(json_str),
             "{\"primary_source\":{\"type\":\"srtsrc\",\"localaddress\":\"127.0.0.1\","
             "\"localport\":18101,\"mode\":\"listener\"},"
             "\"secondary_source\":{\"type\":\"srtsrc\",\"localaddress\":\"127.0.0.1\","
             "\"localport\":18102,\"mode\":\"listener\"},"
             "\"active_source\":\"%s\",\"auto_join\":false,"
             "\"sinks\":[{\"type\":\"fakesink\"}]}",
             active_source);

    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);

    GstElement *pipeline = create_pipeline(json, NULL);
    assert_non_null(pipeline);

    GstElement *selector = gst_bin_get_by_name(GST_BIN(pipeline), "input-selector");
    GstElement *secondary = gst_bin_get_by_name(GST_BIN(pipeline), "secondary_source");
    assert_non_null(selector);
    assert_non_null(secondary);

    GstPad *active_pad = NULL;
    g_object_get(selector, "active-pad", &active_pad, NULL);
    GstPad *expected_pad = gst_element_get_static_pad(
        selector, strcmp(active_source, "secondary") == 0 ? "sink_1" : "sink_0");

    assert_non_null(active_pad);
    assert_non_null(expected_pad);
    assert_ptr_equal(active_pad, expected_pad);
    assert_int_equal(gst_element_is_locked_state(secondary), secondary_locked);

    gst_object_unref(expected_pad);
    gst_object_unref(active_pad);
    gst_object_unref(secondary);
    gst_object_unref(selector);
    cleanup_pipeline(pipeline);
    cJSON_Delete(json);
}

static void test_dual_ingest_initial_primary_locks_secondary(void **state)
{
    (void)state;
    assert_dual_ingest_initial_state("primary", TRUE);
}

static void test_dual_ingest_initial_secondary_starts_secondary(void **state)
{
    (void)state;
    assert_dual_ingest_initial_state("secondary", FALSE);
}

static void test_seamless_sdi_keeps_nonblocking_selector_and_warm_secondary(void **state)
{
    (void)state;
    const char *json_str =
        "{\"primary_source\":{\"type\":\"srtsrc\",\"uri\":\"srt://127.0.0.1:18201?mode=listener\"},"
        "\"secondary_source\":{\"type\":\"srtsrc\",\"uri\":\"srt://127.0.0.1:18202?mode=listener\"},"
        "\"active_source\":\"primary\",\"auto_join\":false,"
        "\"seamless_sdi_failover\":true,\"sinks\":[{\"type\":\"fakesink\"}]}";

    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);
    GstElement *pipeline = create_pipeline(json, NULL);
    assert_non_null(pipeline);

    GstElement *selector = gst_bin_get_by_name(GST_BIN(pipeline), "input-selector");
    GstElement *primary = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    GstElement *secondary = gst_bin_get_by_name(GST_BIN(pipeline), "secondary_source");
    assert_non_null(selector);
    assert_non_null(primary);
    assert_non_null(secondary);

    gboolean sync_streams = FALSE;
    gboolean primary_do_timestamp = TRUE;
    gboolean secondary_do_timestamp = TRUE;
    gint sync_mode = 0;
    g_object_get(selector, "sync-streams", &sync_streams, "sync-mode", &sync_mode, NULL);
    g_object_get(primary, "do-timestamp", &primary_do_timestamp, NULL);
    g_object_get(secondary, "do-timestamp", &secondary_do_timestamp, NULL);

    assert_false(sync_streams);
    assert_int_equal(sync_mode, 0);
    assert_false(primary_do_timestamp);
    assert_false(secondary_do_timestamp);
    assert_false(gst_element_is_locked_state(secondary));

    gst_object_unref(primary);
    gst_object_unref(secondary);
    gst_object_unref(selector);
    cleanup_pipeline(pipeline);
    cJSON_Delete(json);
}

static GstBuffer *make_ts_buffer(gboolean include_keyframe, GstClockTime pts,
                                 guint16 video_pid)
{
    guint packet_count = 3;
    guint8 bytes[TS_PACKET_SIZE * 3];
    memset(bytes, 0xFF, sizeof(bytes));

    guint8 *pat = bytes;
    pat[0] = 0x47;
    pat[1] = 0x40;
    pat[2] = 0x00;
    pat[3] = 0x10;
    pat[4] = 0x00;
    const guint8 pat_section[] = {
        0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0x00, 0x01, 0xE1, 0x00, 0x00, 0x00, 0x00, 0x00};
    memcpy(pat + 5, pat_section, sizeof(pat_section));

    guint8 *pmt = bytes + TS_PACKET_SIZE;
    pmt[0] = 0x47;
    pmt[1] = 0x41;
    pmt[2] = 0x00;
    pmt[3] = 0x10;
    pmt[4] = 0x00;
    guint8 pmt_section[] = {
        0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0,
        0x00, 0x1B, 0xE1, 0x01, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00};
    pmt_section[8] = 0xE0 | ((video_pid >> 8) & 0x1F);
    pmt_section[9] = video_pid & 0xFF;
    pmt_section[13] = 0xE0 | ((video_pid >> 8) & 0x1F);
    pmt_section[14] = video_pid & 0xFF;
    memcpy(pmt + 5, pmt_section, sizeof(pmt_section));

    guint8 *video = bytes + (TS_PACKET_SIZE * 2);
    video[0] = 0x47;
    video[1] = 0x40 | ((video_pid >> 8) & 0x1F);
    video[2] = video_pid & 0xFF;
    video[3] = 0x10;
    const guint8 pes_and_sps[] = {
        0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x28, 0xAC, 0x2B, 0x40,
        0x78, 0x02, 0x27, 0xE5, 0xC0};
    memcpy(video + 4, pes_and_sps, sizeof(pes_and_sps));
    if (include_keyframe) {
        const guint8 idr[] = {0x00, 0x00, 0x01, 0x65, 0x88, 0x84};
        memcpy(video + 4 + sizeof(pes_and_sps), idr, sizeof(idr));
    }

    GstBuffer *buffer = gst_buffer_new_allocate(NULL, packet_count * TS_PACKET_SIZE, NULL);
    assert_non_null(buffer);
    gst_buffer_fill(buffer, 0, bytes, packet_count * TS_PACKET_SIZE);
    GST_BUFFER_PTS(buffer) = pts;
    GST_BUFFER_DTS(buffer) = pts;
    GST_BUFFER_DURATION(buffer) = GST_SECOND / 25;
    return buffer;
}

static void write_test_timestamp(guint8 *bytes, guint64 value)
{
    value &= TS_TIMESTAMP_MASK;
    bytes[0] = 0x20 | (((value >> 30) & 0x07) << 1) | 0x01;
    bytes[1] = (value >> 22) & 0xFF;
    bytes[2] = (((value >> 15) & 0x7F) << 1) | 0x01;
    bytes[3] = (value >> 7) & 0xFF;
    bytes[4] = ((value & 0x7F) << 1) | 0x01;
}

static void write_test_pcr(guint8 *bytes, guint64 value)
{
    value &= TS_TIMESTAMP_MASK;
    bytes[0] = (value >> 25) & 0xFF;
    bytes[1] = (value >> 17) & 0xFF;
    bytes[2] = (value >> 9) & 0xFF;
    bytes[3] = (value >> 1) & 0xFF;
    bytes[4] = ((value & 0x01) << 7) | 0x7E;
    bytes[5] = 0;
}

static void make_timed_packet(guint8 packet[TS_PACKET_SIZE], guint16 pid,
                              guint8 continuity, guint64 pcr, guint64 pts)
{
    memset(packet, 0xFF, TS_PACKET_SIZE);
    packet[0] = 0x47;
    packet[1] = 0x40 | ((pid >> 8) & 0x1F);
    packet[2] = pid & 0xFF;
    packet[3] = 0x30 | (continuity & 0x0F);
    packet[4] = 7;
    packet[5] = 0x10;
    write_test_pcr(packet + 6, pcr);

    guint8 *pes = packet + 12;
    pes[0] = 0x00;
    pes[1] = 0x00;
    pes[2] = 0x01;
    pes[3] = 0xE0;
    pes[4] = 0x00;
    pes[5] = 0x00;
    pes[6] = 0x80;
    pes[7] = 0x80;
    pes[8] = 0x05;
    write_test_timestamp(pes + 9, pts);
}

static void test_ts_normalizer_aligns_switch_timestamps_and_continuity(void **state)
{
    (void)state;
    BgTsNormalizer normalizer;
    BgTsNormalizeResult result;
    guint8 packet[TS_PACKET_SIZE];
    guint64 value = 0;

    bg_ts_normalizer_reset(&normalizer);

    make_timed_packet(packet, 0x0101, 7, 900000, 900000);
    assert_true(bg_ts_normalize(&normalizer, packet, sizeof(packet), 0, &result));
    assert_false(result.source_changed);
    assert_true(bg_ts_packet_get_pcr_90k(packet, &value));
    assert_int_equal(value, 900000);
    assert_true(bg_ts_packet_get_pts_90k(packet, &value));
    assert_int_equal(value, 900000);
    assert_int_equal(packet[3] & 0x0F, 7);

    make_timed_packet(packet, 0x0101, 8, 903600, 903600);
    assert_true(bg_ts_normalize(&normalizer, packet, sizeof(packet), 0, &result));

    make_timed_packet(packet, 0x0101, 2, 9000000, 9000000);
    assert_true(bg_ts_normalize(&normalizer, packet, sizeof(packet), 1, &result));
    assert_true(result.source_changed);
    assert_true(result.timestamps_rewritten);
    assert_int_equal(result.continuity_rewritten, 1);
    assert_true(bg_ts_packet_get_pcr_90k(packet, &value));
    assert_int_equal(value, 907200);
    assert_true(bg_ts_packet_get_pts_90k(packet, &value));
    assert_int_equal(value, 907200);
    assert_int_equal(packet[3] & 0x0F, 9);
}

static void test_ts_normalizer_handles_33_bit_wraparound(void **state)
{
    (void)state;
    BgTsNormalizer normalizer;
    BgTsNormalizeResult result;
    guint8 packet[TS_PACKET_SIZE];
    guint64 value = 0;

    bg_ts_normalizer_reset(&normalizer);

    guint64 near_wrap = TS_TIMESTAMP_MASK - 1799;
    make_timed_packet(packet, 0x0101, 14, near_wrap, near_wrap);
    assert_true(bg_ts_normalize(&normalizer, packet, sizeof(packet), 0, &result));

    make_timed_packet(packet, 0x0101, 1, 450000, 450000);
    assert_true(bg_ts_normalize(&normalizer, packet, sizeof(packet), 1, &result));
    assert_true(result.source_changed);
    assert_true(bg_ts_packet_get_pcr_90k(packet, &value));
    assert_int_equal(value, 1800);
    assert_true(bg_ts_packet_get_pts_90k(packet, &value));
    assert_int_equal(value, 1800);
    assert_int_equal(packet[3] & 0x0F, 15);
}

static void test_ts_normalizer_handles_prefixed_packet_alignment(void **state)
{
    (void)state;
    BgTsNormalizer normalizer;
    BgTsNormalizeResult result;
    guint8 buffer[5 + TS_PACKET_SIZE];
    guint64 value = 0;

    memset(buffer, 0, 5);
    make_timed_packet(buffer + 5, 0x0101, 3, 123456, 123456);
    bg_ts_normalizer_reset(&normalizer);

    assert_true(bg_ts_normalize(&normalizer, buffer, sizeof(buffer), 0, &result));
    assert_true(bg_ts_packet_get_pcr_90k(buffer + 5, &value));
    assert_int_equal(value, 123456);
    assert_int_equal(buffer[5 + 3] & 0x0F, 3);
}

static gboolean selector_is_on(GstElement *selector, const char *pad_name)
{
    GstPad *active = NULL;
    GstPad *expected = gst_element_get_static_pad(selector, pad_name);
    g_object_get(selector, "active-pad", &active, NULL);
    gboolean matches = active && expected && active == expected;
    if (active) gst_object_unref(active);
    if (expected) gst_object_unref(expected);
    return matches;
}

static void test_seamless_switch_waits_for_compatible_target_keyframe(void **state)
{
    (void)state;
    const char *json_str =
        "{\"primary_source\":{\"type\":\"appsrc\"},"
        "\"secondary_source\":{\"type\":\"appsrc\"},"
        "\"active_source\":\"primary\",\"auto_join\":true,"
        "\"seamless_sdi_failover\":true,\"sinks\":[{\"type\":\"fakesink\"}]}";

    cJSON *json = cJSON_Parse(json_str);
    assert_non_null(json);
    GstElement *pipeline = create_pipeline(json, NULL);
    assert_non_null(pipeline);

    GstElement *primary = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    GstElement *secondary = gst_bin_get_by_name(GST_BIN(pipeline), "secondary_source");
    GstElement *selector = gst_bin_get_by_name(GST_BIN(pipeline), "input-selector");
    assert_non_null(primary);
    assert_non_null(secondary);
    assert_non_null(selector);

    GstCaps *caps = gst_caps_new_simple("video/mpegts", "systemstream", G_TYPE_BOOLEAN, TRUE,
                                       "packetsize", G_TYPE_INT, TS_PACKET_SIZE, NULL);
    g_object_set(primary, "caps", caps, "format", GST_FORMAT_TIME, "is-live", TRUE, NULL);
    g_object_set(secondary, "caps", caps, "format", GST_FORMAT_TIME, "is-live", TRUE, NULL);
    gst_caps_unref(caps);

    assert_true(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE);
    gst_element_get_state(pipeline, NULL, NULL, GST_SECOND);

    assert_int_equal(gst_app_src_push_buffer(GST_APP_SRC(primary),
                                             make_ts_buffer(FALSE, 0, 0x0101)),
                     GST_FLOW_OK);
    assert_int_equal(gst_app_src_push_buffer(GST_APP_SRC(secondary),
                                             make_ts_buffer(FALSE, 0, 0x0101)),
                     GST_FLOW_OK);
    g_usleep(100 * 1000);

    switch_source("secondary");
    assert_true(selector_is_on(selector, "sink_0"));

    assert_int_equal(
        gst_app_src_push_buffer(GST_APP_SRC(secondary),
                                make_ts_buffer(TRUE, GST_SECOND / 25, 0x0101)),
        GST_FLOW_OK);

    gboolean switched = FALSE;
    for (guint i = 0; i < 20 && !switched; i++) {
        g_usleep(25 * 1000);
        switched = selector_is_on(selector, "sink_1");
    }
    assert_true(switched);

    // A changed program map must never flip the live selector. Backend will
    // receive SOURCE_SWITCH_REJECTED and use restart-based failover.
    assert_int_equal(
        gst_app_src_push_buffer(GST_APP_SRC(primary),
                                make_ts_buffer(FALSE, GST_SECOND * 2 / 25, 0x0102)),
        GST_FLOW_OK);
    g_usleep(100 * 1000);
    switch_source("primary");
    g_usleep(50 * 1000);
    assert_true(selector_is_on(selector, "sink_1"));

    gst_object_unref(selector);
    gst_object_unref(secondary);
    gst_object_unref(primary);
    cleanup_pipeline(pipeline);
    cJSON_Delete(json);
}

int main(void)
{
    gst_init(NULL, NULL);

    const struct CMUnitTest tests[] = {
        cmocka_unit_test_setup_teardown(test_init_unix_socket, setup_socket_fixture,
                                        teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_send_message_to_unix_socket, setup_socket_fixture,
                                        teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_send_prefixed_message_to_unix_socket,
                                        setup_socket_fixture, teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_cleanup_socket, setup_socket_fixture,
                                        teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_create_pipeline, setup_socket_fixture,
                                        teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_dual_ingest_initial_primary_locks_secondary,
                                        setup_socket_fixture, teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(test_dual_ingest_initial_secondary_starts_secondary,
                                        setup_socket_fixture, teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(
            test_seamless_sdi_keeps_nonblocking_selector_and_warm_secondary,
            setup_socket_fixture, teardown_socket_fixture),
        cmocka_unit_test_setup_teardown(
            test_seamless_switch_waits_for_compatible_target_keyframe,
            setup_socket_fixture, teardown_socket_fixture),
        cmocka_unit_test(test_ts_normalizer_aligns_switch_timestamps_and_continuity),
        cmocka_unit_test(test_ts_normalizer_handles_33_bit_wraparound),
        cmocka_unit_test(test_ts_normalizer_handles_prefixed_packet_alignment),
    };
    return cmocka_run_group_tests(tests, NULL, NULL);
}
