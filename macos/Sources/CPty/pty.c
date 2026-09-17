#include "cpty.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               unsigned short cols, unsigned short rows, pid_t *pid_out) {
    struct winsize ws = { rows, cols, 0, 0 };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        execve(path, argv, envp);
        _exit(127);
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
