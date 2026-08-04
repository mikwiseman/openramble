#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void trace_call(const char *name) {
    const char *path = getenv("WAI_NET_TRACE");
    if (path == NULL) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    dprintf(fd, "pid=%d call=%s\n", getpid(), name);
    close(fd);
}

static int is_network_socket(int fd) {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return 0;
    return address.ss_family == AF_INET || address.ss_family == AF_INET6;
}

int traced_connect(int socket, const struct sockaddr *address, socklen_t length) {
    if (address != NULL && (address->sa_family == AF_INET || address->sa_family == AF_INET6)) {
        trace_call("connect");
    }
    return (int)syscall(SYS_connect, socket, address, length);
}

ssize_t traced_send(int socket, const void *buffer, size_t length, int flags) {
    if (is_network_socket(socket)) trace_call("send");
    return (ssize_t)syscall(SYS_sendto, socket, buffer, length, flags, NULL, 0);
}

ssize_t traced_sendto(int socket, const void *buffer, size_t length, int flags,
                      const struct sockaddr *address, socklen_t addressLength) {
    if ((address != NULL && (address->sa_family == AF_INET || address->sa_family == AF_INET6))
        || is_network_socket(socket)) {
        trace_call("sendto");
    }
    return (ssize_t)syscall(SYS_sendto, socket, buffer, length, flags, address, addressLength);
}

int traced_getaddrinfo(const char *node, const char *service,
                       const struct addrinfo *hints, struct addrinfo **result) {
    static int (*original)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
    if (original == NULL) {
        void *library = dlopen("/usr/lib/system/libsystem_info.dylib", RTLD_NOW | RTLD_LOCAL);
        original = dlsym(library, "getaddrinfo");
    }
    trace_call("getaddrinfo");
    if (original == NULL) return EAI_SYSTEM;
    return original(node, service, hints, result);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee \
    };

DYLD_INTERPOSE(traced_connect, connect)
DYLD_INTERPOSE(traced_send, send)
DYLD_INTERPOSE(traced_sendto, sendto)
DYLD_INTERPOSE(traced_getaddrinfo, getaddrinfo)
