#include <assert.h>
#include <cJSON.h>
#include <setjmp.h>
#include <stdarg.h>
#include <cmocka.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../include/gst_pipeline.h"
#include "../include/unix_socket.h"

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
    };
    return cmocka_run_group_tests(tests, NULL, NULL);
}
