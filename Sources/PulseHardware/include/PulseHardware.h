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

int pb_hardware_init(void);
PBHardwareMetrics pb_hardware_sample(void);
void pb_hardware_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
