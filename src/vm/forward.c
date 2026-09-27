#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef struct RiftForwarder {
    int listener;
    uint16_t guest_port;
    char guest_ip_path[PATH_MAX];
    atomic_bool stopping;
    pthread_t accept_thread;
    pthread_mutex_t lock;
    pthread_cond_t drained;
    unsigned clients;
} RiftForwarder;

typedef struct {
    RiftForwarder *forwarder;
    int client;
} RiftClient;

typedef struct {
    int from;
    int to;
    atomic_bool *stopping;
    atomic_bool *guest_done;
} RiftPipe;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void pause_briefly(void) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
    nanosleep(&delay, NULL);
}

static bool configure_stream(int fd) {
    const int one = 1;
    const struct timeval timeout = {.tv_sec = 0, .tv_usec = 250000};
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) == 0 &&
           setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
           setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

static bool guest_address(RiftForwarder *forwarder, struct sockaddr_in *address) {
    FILE *file = fopen(forwarder->guest_ip_path, "r");
    if (!file) return false;
    char text[64];
    const bool read = fgets(text, sizeof(text), file) != NULL;
    fclose(file);
    if (!read) return false;
    char *end = strchr(text, '\n');
    if (!end) return false;
    *end = 0;
    memset(address, 0, sizeof(*address));
    address->sin_family = AF_INET;
    address->sin_port = htons(forwarder->guest_port);
    return inet_pton(AF_INET, text, &address->sin_addr) == 1;
}

static int connect_guest(RiftForwarder *forwarder) {
    const double deadline = now_seconds() + 30.0;
    while (!atomic_load(&forwarder->stopping) && now_seconds() < deadline) {
        struct sockaddr_in address;
        if (!guest_address(forwarder, &address)) {
            pause_briefly();
            continue;
        }
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
            close(fd);
            return -1;
        }
        int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
        if (result < 0 && errno == EINPROGRESS) {
            struct pollfd pending = {.fd = fd, .events = POLLOUT};
            result = poll(&pending, 1, 250);
            if (result > 0) {
                int error = 0;
                socklen_t length = sizeof(error);
                result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0 ? 0 : -1;
            } else {
                result = -1;
            }
        }
        if (result == 0 && fcntl(fd, F_SETFL, 0) == 0) {
            if (configure_stream(fd)) return fd;
            close(fd);
            return -1;
        }
        close(fd);
        pause_briefly();
    }
    return -1;
}

static void copy_stream(RiftPipe *pipe) {
    char buffer[16384];
    while (!atomic_load(pipe->stopping) && (!pipe->guest_done || !atomic_load(pipe->guest_done))) {
        ssize_t received = recv(pipe->from, buffer, sizeof(buffer), 0);
        if (received == 0) break;
        if (received < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        for (ssize_t offset = 0; offset < received && !atomic_load(pipe->stopping);) {
            ssize_t sent = send(pipe->to, buffer + offset, (size_t)(received - offset), 0);
            if (sent > 0) {
                offset += sent;
            } else if (sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
                continue;
            } else {
                shutdown(pipe->to, SHUT_WR);
                return;
            }
        }
    }
    shutdown(pipe->to, SHUT_WR);
}

static void *copy_thread(void *opaque) {
    copy_stream((RiftPipe *)opaque);
    return NULL;
}

static void *client_thread(void *opaque) {
    RiftClient *client = opaque;
    RiftForwarder *forwarder = client->forwarder;
    int guest = connect_guest(forwarder);
    if (guest >= 0) {
        if (configure_stream(client->client)) {
            atomic_bool guest_done = false;
            RiftPipe request = {.from = client->client, .to = guest, .stopping = &forwarder->stopping, .guest_done = &guest_done};
            RiftPipe response = {.from = guest, .to = client->client, .stopping = &forwarder->stopping, .guest_done = NULL};
            pthread_t request_thread;
            if (pthread_create(&request_thread, NULL, copy_thread, &request) == 0) {
                copy_stream(&response);
                atomic_store(&guest_done, true);
                pthread_join(request_thread, NULL);
            }
        }
        close(guest);
    }
    close(client->client);
    pthread_mutex_lock(&forwarder->lock);
    forwarder->clients--;
    pthread_cond_signal(&forwarder->drained);
    pthread_mutex_unlock(&forwarder->lock);
    free(client);
    return NULL;
}

static void *accept_thread(void *opaque) {
    RiftForwarder *forwarder = opaque;
    while (!atomic_load(&forwarder->stopping)) {
        struct pollfd ready = {.fd = forwarder->listener, .events = POLLIN};
        int available = poll(&ready, 1, 250);
        if (available == 0 || (available < 0 && errno == EINTR)) continue;
        if (available < 0) break;
        int fd = accept(forwarder->listener, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        pthread_mutex_lock(&forwarder->lock);
        // ponytail: cap each VM at 16 proxy clients until real traffic warrants more.
        if (forwarder->clients >= 16 || atomic_load(&forwarder->stopping)) {
            pthread_mutex_unlock(&forwarder->lock);
            close(fd);
            continue;
        }
        RiftClient *client = malloc(sizeof(*client));
        if (!client) {
            pthread_mutex_unlock(&forwarder->lock);
            close(fd);
            continue;
        }
        client->forwarder = forwarder;
        client->client = fd;
        forwarder->clients++;
        pthread_t thread;
        if (pthread_create(&thread, NULL, client_thread, client) == 0) {
            pthread_detach(thread);
        } else {
            forwarder->clients--;
            close(fd);
            free(client);
        }
        pthread_mutex_unlock(&forwarder->lock);
    }
    return NULL;
}

RiftForwarder *rift_forward_start(const char *control_path, uint16_t host_port, uint16_t guest_port) {
    RiftForwarder *forwarder = calloc(1, sizeof(*forwarder));
    if (!forwarder) return NULL;
    int length = snprintf(forwarder->guest_ip_path, sizeof(forwarder->guest_ip_path), "%s/guest-ip", control_path);
    if (length < 0 || (size_t)length >= sizeof(forwarder->guest_ip_path)) {
        free(forwarder);
        return NULL;
    }
    forwarder->guest_port = guest_port;
    forwarder->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (forwarder->listener < 0) {
        free(forwarder);
        return NULL;
    }
    const int one = 1;
    setsockopt(forwarder->listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in host = {.sin_family = AF_INET, .sin_port = htons(host_port)};
    host.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(forwarder->listener, (struct sockaddr *)&host, sizeof(host)) < 0 || listen(forwarder->listener, 16) < 0) {
        fprintf(stderr, "rift-vm: cannot bind 127.0.0.1:%u: %s\n", host_port, strerror(errno));
        close(forwarder->listener);
        free(forwarder);
        return NULL;
    }
    if (fcntl(forwarder->listener, F_SETFL, O_NONBLOCK) < 0) {
        close(forwarder->listener);
        free(forwarder);
        return NULL;
    }
    if (pthread_mutex_init(&forwarder->lock, NULL) != 0) {
        close(forwarder->listener);
        free(forwarder);
        return NULL;
    }
    if (pthread_cond_init(&forwarder->drained, NULL) != 0) {
        pthread_mutex_destroy(&forwarder->lock);
        close(forwarder->listener);
        free(forwarder);
        return NULL;
    }
    if (pthread_create(&forwarder->accept_thread, NULL, accept_thread, forwarder) != 0) {
        pthread_cond_destroy(&forwarder->drained);
        pthread_mutex_destroy(&forwarder->lock);
        close(forwarder->listener);
        free(forwarder);
        return NULL;
    }
    return forwarder;
}

void rift_forward_stop(RiftForwarder *forwarder) {
    if (!forwarder) return;
    atomic_store(&forwarder->stopping, true);
    shutdown(forwarder->listener, SHUT_RDWR);
    pthread_join(forwarder->accept_thread, NULL);
    close(forwarder->listener);
    pthread_mutex_lock(&forwarder->lock);
    while (forwarder->clients != 0) pthread_cond_wait(&forwarder->drained, &forwarder->lock);
    pthread_mutex_unlock(&forwarder->lock);
    pthread_cond_destroy(&forwarder->drained);
    pthread_mutex_destroy(&forwarder->lock);
    free(forwarder);
}
