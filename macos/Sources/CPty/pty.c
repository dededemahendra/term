#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

/* Reads one int from fd, retrying on EINTR. Returns bytes read. */
static ssize_t read_int(int fd, int *out) {
    for (;;) {
        ssize_t n = read(fd, out, sizeof *out);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return n;
    }
}

int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               unsigned short cols, unsigned short rows, pid_t *pid_out) {
    struct winsize ws = { rows, cols, 0, 0 };
    /* The write end closes on a successful exec; a failed exec sends errno
     * through it so the parent can tell the two apart. */
    int status_pipe[2];
    if (pipe(status_pipe) != 0) {
        return -1;
    }
    fcntl(status_pipe[1], F_SETFD, FD_CLOEXEC);
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        int saved = errno;
        close(status_pipe[0]);
        close(status_pipe[1]);
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        close(status_pipe[0]);
        execve(path, argv, envp);
        int err = errno;
        write(status_pipe[1], &err, sizeof err);
        _exit(127);
    }
    close(status_pipe[1]);
    int exec_errno = 0;
    ssize_t n = read_int(status_pipe[0], &exec_errno);
    close(status_pipe[0]);
    if (n > 0) {
        waitpid(pid, NULL, 0);
        close(master);
        errno = exec_errno;
        return -1;
    }
    *pid_out = pid;
    return master;
}

int cpty_resize(int master_fd, unsigned short cols, unsigned short rows) {
    struct winsize ws = { rows, cols, 0, 0 };
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

double cpty_process_start_uptime(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }
    struct timeval start = info.kp_proc.p_starttime;
    struct timeval now;
    gettimeofday(&now, NULL);
    double age = (now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1e6;
    struct timespec uptime;
    clock_gettime(CLOCK_UPTIME_RAW, &uptime);
    return (uptime.tv_sec + uptime.tv_nsec / 1e9) - age;
}
