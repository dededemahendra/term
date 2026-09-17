#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/* Forks a child on a new pseudo terminal of the given size and execs
 * path with argv and envp. Returns the master fd, or -1 with errno set.
 * pid_out receives the child's pid. */
int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               unsigned short cols, unsigned short rows, pid_t *pid_out);

/* Tells the kernel the window size changed. Returns 0 or -1. */
int cpty_resize(int master_fd, unsigned short cols, unsigned short rows);

/* Seconds since boot at which this process started, on the same
 * timebase as CACurrentMediaTime and NSEvent.timestamp. */
double cpty_process_start_uptime(void);

#endif
