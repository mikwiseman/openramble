#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--control") == 0) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(9);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        (void)connect(fd, (struct sockaddr *)&address, sizeof(address));
        close(fd);
        return 0;
    }
    if (argc < 2) return 64;
    execv(argv[1], &argv[1]);
    perror("execv");
    return 71;
}
