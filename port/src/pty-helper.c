// Own the PTY child independently of browser connections. stdin carries bounded
// length-prefixed input/resize frames; stdout is the unmodified PTY byte stream.
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static volatile sig_atomic_t stopping;
static void stop(int sig) { stopping = sig; }
static int write_all(int fd, const void *buf, size_t size) {
  const char *p = buf;
  while (size) {
    ssize_t n = write(fd, p, size);
    if (n < 0 && errno == EINTR && !stopping) continue;
    if (n <= 0) return -1;
    p += n; size -= (size_t)n;
  }
  return 0;
}
static unsigned dimension(const char *s) {
  char *end; long value = strtol(s, &end, 10);
  if (*end || value < 1 || value > 65535) return 0;
  return (unsigned)value;
}
int main(int argc, char **argv) {
  if (argc < 4) return 2;
  unsigned cols = dimension(argv[1]), rows = dimension(argv[2]);
  if (!cols || !rows || argv[3][0] != '/') return 2;
  struct winsize size = { .ws_col = cols, .ws_row = rows };
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop);
  int master;
  pid_t child = forkpty(&master, NULL, NULL, &size);
  if (child < 0) { perror("forkpty"); return 1; }
  if (!child) {
    signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
    execv(argv[3], argv + 3); perror("execv"); _exit(127);
  }
  unsigned char input[65541], output[16384]; size_t used = 0;
  struct pollfd fds[2] = { { 0, POLLIN, 0 }, { master, POLLIN, 0 } };
  while (!stopping) {
    int rc = poll(fds, 2, -1);
    if (rc < 0) { if (errno == EINTR) continue; break; }
    if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) break;
    if (fds[0].revents & POLLIN) {
      ssize_t n = read(0, input + used, sizeof(input) - used);
      if (n <= 0) break;
      used += (size_t)n;
      while (used >= 4) {
        uint32_t len; memcpy(&len, input, 4); len = ntohl(len);
        if (len < 1 || len > 65537) { stopping = SIGTERM; break; }
        if (used < len + 4) break;
        if (input[4] == 'I') {
          if (write_all(master, input + 5, len - 1)) { stopping = SIGTERM; break; }
        } else if (input[4] == 'R' && len == 5) {
          size.ws_col = (input[5] << 8) | input[6];
          size.ws_row = (input[7] << 8) | input[8];
          if (!size.ws_col || !size.ws_row || ioctl(master, TIOCSWINSZ, &size)) { stopping = SIGTERM; break; }
        } else { stopping = SIGTERM; break; }
        used -= len + 4; memmove(input, input + len + 4, used);
      }
    }
    if (fds[1].revents & (POLLIN | POLLHUP)) {
      ssize_t n = read(master, output, sizeof(output));
      if (n <= 0 || write_all(1, output, (size_t)n)) break;
    }
    if (fds[1].revents & (POLLERR | POLLNVAL)) break;
  }
  close(master);
  // The PTY child owns its process group. Bound shutdown so a child that
  // ignores SIGHUP cannot orphan descendants or wedge the controller.
  kill(-child, stopping ? stopping : SIGHUP);
  int status = 0;
  for (unsigned i = 0; i < 30; i++) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    if (result < 0 && errno == ECHILD) return 0;
    usleep(100000);
  }
  kill(-child, SIGKILL);
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
