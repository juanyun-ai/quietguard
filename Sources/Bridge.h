#ifndef QUIETGUARD_BRIDGE_H
#define QUIETGUARD_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid;
    uint64_t start_sec, start_usec, cpu_ns, resident_bytes, io_bytes;
    int32_t cpu_valid, io_valid;
    char name[256];
    char path[4096];
} QGProcess;
int qg_collect(QGProcess *out, int capacity);
int qg_read_process(int32_t pid, QGProcess *out);
double qg_clock(void);
int qg_cpu_ticks(uint64_t *busy, uint64_t *total);
int qg_temperature(double *maximum, double *average, int *count);
int qg_signal_exact(int32_t pid, uint64_t sec, uint64_t usec, const char *path, int signal_number);
#endif
