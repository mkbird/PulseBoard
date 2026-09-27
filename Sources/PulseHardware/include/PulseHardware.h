#ifndef PULSE_HARDWARE_H
#define PULSE_HARDWARE_H

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
    double ane_usage_percent;
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
} PBAppMetrics;

int pb_hardware_init(void);
PBHardwareMetrics pb_hardware_sample(void);
PBAppMetrics pb_clipto_sample(void);
void pb_hardware_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
