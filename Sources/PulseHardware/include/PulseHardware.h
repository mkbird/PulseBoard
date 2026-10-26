#ifndef PULSE_HARDWARE_H
#define PULSE_HARDWARE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double cpu_power_watts;
    double gpu_power_watts;
    double ane_power_watts;
    double system_power_watts;
    double memory_read_gbps;
    double memory_write_gbps;
    double gpu_usage_percent;
    double ane_usage_percent;
    int cpu_power_valid;
    int gpu_power_valid;
    int ane_power_valid;
    int gpu_usage_valid;
    int valid;
} PBHardwareMetrics;

typedef struct {
    double cpu_percent;
    double memory_bytes;
    double disk_read_bytes_per_second;
    double disk_write_bytes_per_second;
    double gpu_percent;
    unsigned int process_count;
    int running;
    int rates_valid;
    /* Summed GPU busy % of every process whose executable name contains "cms". */
    double cms_gpu_percent;
    int cms_gpu_valid;
} PBAppMetrics;

typedef struct {
    int32_t pid;
    /* Process start time as epoch microseconds; together with pid, a stable identity. */
    uint64_t start_time;
    char name[1024];
    /* Cumulative user + system CPU seconds, not an already-derived percentage. */
    double cpu_seconds;
    uint64_t memory_bytes;
    /* CPU and physical footprint must be ignored unless this is nonzero. */
    int usage_valid;
} PBCMSProcess;

typedef struct {
    PBCMSProcess *processes;
    size_t count;
    /* Zero on a failed/truncated PID enumeration or an allocation failure. */
    int enumeration_valid;
    /* Live PIDs whose executable name or stable identity could not be read. */
    size_t unreadable_count;
    /* mach_absolute_time seconds; this clock excludes time asleep. */
    double monotonic_seconds;
} PBCMSSnapshot;

int pb_hardware_init(void);
PBHardwareMetrics pb_hardware_sample(void);
PBAppMetrics pb_clipto_sample(void);
void pb_hardware_shutdown(void);
PBCMSSnapshot pb_cms_snapshot(void);
void pb_cms_snapshot_free(PBCMSSnapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif
