#include "unix_socket.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>

int sock = -1;
static pthread_mutex_t socket_write_mutex = PTHREAD_MUTEX_INITIALIZER;

static int send_all(const char *message, size_t length)
{
    size_t sent_total = 0;

    while (sent_total < length) {
#ifdef MSG_NOSIGNAL
        ssize_t sent = send(sock, message + sent_total, length - sent_total, MSG_NOSIGNAL);
#else
        ssize_t sent = send(sock, message + sent_total, length - sent_total, 0);
#endif
        if (sent > 0) {
            sent_total += (size_t)sent;
            continue;
        }
        if (sent < 0 && errno == EINTR) {
            continue;
        }

        perror("send");
        return -1;
    }

    return 0;
}

static void send_frame(const char *prefix, const char *message)
{
    if (!message || sock < 0) {
        return;
    }

    const size_t prefix_len = prefix ? strlen(prefix) : 0;
    const size_t message_len = strlen(message);

    pthread_mutex_lock(&socket_write_mutex);
    if (prefix_len > 0 && send_all(prefix, prefix_len) < 0) {
        pthread_mutex_unlock(&socket_write_mutex);
        return;
    }
    if (send_all(message, message_len) == 0) {
        (void)send_all("\n", 1);
    }
    pthread_mutex_unlock(&socket_write_mutex);
}

void init_unix_socket(const char* socket_path)
{
    struct sockaddr_un addr;

    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        exit(1);
    }

    memset(&addr, 0, sizeof(struct sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(struct sockaddr_un)) < 0) {
        perror("connect");
        cleanup_socket();
        exit(1);
    }
    printf("Connected to the socket.\n");
}

void send_message_to_unix_socket(const char* message)
{
    send_frame(NULL, message);
}

void send_prefixed_message_to_unix_socket(const char *prefix, const char *message)
{
    send_frame(prefix, message);
}

void cleanup_socket()
{
    if (sock >= 0) {
        close(sock);
        sock = -1;
        printf("Socket closed.\n");
    }
}
