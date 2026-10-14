// QuietGuard native telemetry. SMC wire format and M4 key mapping adapted from
// exelban/stats v3.0.17, Copyright (c) Serhiy Mytrovtsiy, MIT.
// See Vendor/Stats/LICENSE. Only read operations are implemented here.
#include "Bridge.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <IOKit/IOKitLib.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

int qg_read_process(int32_t pid, QGProcess *out) {
    if (!out || pid <= 0) return 0;
    struct proc_bsdinfo b = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
    memset(out, 0, sizeof(*out));
    out->pid = pid; out->ppid = b.pbi_ppid; out->uid = b.pbi_uid;
    out->start_sec = b.pbi_start_tvsec; out->start_usec = b.pbi_start_tvusec;
    strlcpy(out->name, b.pbi_name[0] ? b.pbi_name : b.pbi_comm, sizeof(out->name));
    proc_pidpath(pid, out->path, sizeof(out->path));
    struct rusage_info_v2 r = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r) == 0) {
        out->cpu_ns = r.ri_user_time + r.ri_system_time;
        out->resident_bytes = r.ri_resident_size;
        out->io_bytes = r.ri_diskio_bytesread + r.ri_diskio_byteswritten;
        out->cpu_valid = 1; out->io_valid = 1;
    } else {
        struct proc_taskinfo t = {0};
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t)) {
            out->cpu_ns = t.pti_total_user + t.pti_total_system;
            out->resident_bytes = t.pti_resident_size;
            out->cpu_valid = 1;
        }
    }
    // Recheck the process birth after gathering counters; discard an observed PID reuse.
    struct proc_bsdinfo again = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &again, sizeof(again)) != sizeof(again) ||
        again.pbi_start_tvsec != out->start_sec || again.pbi_start_tvusec != out->start_usec) return 0;
    return 1;
}

int qg_collect(QGProcess *out, int capacity) {
    if (!out || capacity <= 0) return 0;
    int needed = proc_listallpids(NULL, 0);
    if (needed <= 0 || needed > 100000) return 0;
    int slots = needed + 256;
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) return 0;
    int n = proc_listallpids(pids, slots * sizeof(pid_t));
    int written = 0;
    for (int i = 0; i < n && i < slots && written < capacity; i++) {
        if (qg_read_process(pids[i], &out[written])) written++;
    }
    free(pids);
    return written;
}

double qg_clock(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return (double)mach_continuous_time() * info.numer / info.denom / 1e9;
}

int qg_cpu_ticks(uint64_t *busy, uint64_t *total) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return 0;
    *busy = (uint64_t)info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_SYSTEM] + info.cpu_ticks[CPU_STATE_NICE];
    *total = *busy + info.cpu_ticks[CPU_STATE_IDLE];
    return 1;
}

// Fail closed; no root helper, process groups, arbitrary signals, or name-based kills.
int qg_signal_exact(int32_t pid, uint64_t sec, uint64_t usec, const char *path, int sig) {
    if (pid <= 1 || pid == getpid() || !path || !*path || sec == 0 ||
        (sig != SIGTERM && sig != SIGKILL)) return EINVAL;
    QGProcess current;
    if (!qg_read_process(pid, &current)) return ESRCH;
    if (current.uid != getuid() || current.uid == 0) return EPERM;
    if (current.start_sec != sec || current.start_usec != usec || strcmp(path, current.path)) return ESTALE;
    const char *prefixes[] = {"/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"};
    for (unsigned i = 0; i < sizeof(prefixes)/sizeof(prefixes[0]); i++)
        if (strncmp(path, prefixes[i], strlen(prefixes[i])) == 0) return EPERM;
    // Protect this app's complete live ancestor chain, including terminal / connector.
    int32_t ancestor = getppid();
    for (int depth = 0; depth < 64 && ancestor > 1; depth++) {
        if (ancestor == pid) return EPERM;
        QGProcess parent;
        if (!qg_read_process(ancestor, &parent) || parent.ppid == ancestor) break;
        ancestor = parent.ppid;
    }
    // macOS has no pidfd_send_signal. Identity rechecks narrow, but cannot eliminate,
    // the final syscall race; this limitation is documented in SECURITY.md.
    if (kill(pid, sig) == 0) return 0;
    return errno;
}

// Standard 80-byte AppleSMC request layout (read-only adaptation from Stats).
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } SMCLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimit limit;
    SMCKeyInfo info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} SMCData;
_Static_assert(sizeof(SMCData) == 80, "Unexpected SMC wire layout");
static io_connect_t smc = 0;
static int platform_known = -1;
static double reconnect_after = 0;
static uint32_t code(const char *s) {
    return ((uint32_t)(uint8_t)s[0]<<24) | ((uint32_t)(uint8_t)s[1]<<16) |
           ((uint32_t)(uint8_t)s[2]<<8) | (uint8_t)s[3];
}
static int smc_read(const char *key, double *value) {
    SMCData in = {0}, out = {0};
    in.key = code(key); in.command = 9;
    size_t length = sizeof(out);
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof(in), &out, &length) != KERN_SUCCESS ||
        length != sizeof(out) || out.result || !out.info.size || out.info.size > 32) return 0;
    uint32_t type = out.info.type, size = out.info.size;
    in.info.size = size; in.command = 5;
    memset(&out, 0, sizeof(out)); length = sizeof(out);
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof(in), &out, &length) != KERN_SUCCESS ||
        length != sizeof(out) || out.result) return 0;
    if (type == code("flt ") && size == 4) {
        float f; memcpy(&f, out.bytes, sizeof(f)); *value = f;
    } else if (type == code("sp78") && size == 2) {
        int16_t raw = (int16_t)(((uint16_t)out.bytes[0] << 8) | out.bytes[1]);
        *value = (double)raw / 256.0;
    } else return 0;
    return isfinite(*value) && *value >= 10 && *value <= 120;
}
int qg_temperature(double *maximum, double *average, int *count) {
    *count = 0; *maximum = NAN; *average = NAN;
    if (platform_known < 0) {
        char brand[256] = {0}; size_t size = sizeof(brand);
        platform_known = sysctlbyname("machdep.cpu.brand_string", brand, &size, NULL, 0) == 0 && strstr(brand, "Apple M4") != NULL;
    }
    if (!platform_known) return 0; // Unknown chips must not reuse M4 sensor guesses.
    if (!smc) {
        if (qg_clock() < reconnect_after) return 0;
        reconnect_after = qg_clock() + 60;
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service) return 0;
        kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &smc);
        IOObjectRelease(service);
        if (result != KERN_SUCCESS) { smc = 0; return 0; }
    }
    // Stats M4 CPU thermal zones, not a claim of one sensor per physical core.
    const char *keys[] = {"Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"};
    double sum = 0, peak = 0;
    for (unsigned i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
        double t;
        if (smc_read(keys[i], &t)) { sum += t; if (t > peak) peak = t; (*count)++; }
    }
    if (*count < 2) {
        if (*count == 0) { IOServiceClose(smc); smc = 0; }
        return 0;
    }
    *maximum = peak; *average = sum / *count;
    return 1;
}
