#include "PulseHardware.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

typedef void *PBSubscriptionRef;
typedef CFDictionaryRef (*CopyChannelsFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*MergeChannelsFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef PBSubscriptionRef (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesFn)(PBSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int64_t (*IntegerValueFn)(CFDictionaryRef, int32_t);
typedef CFStringRef (*ChannelStringFn)(CFDictionaryRef);
typedef CFStringRef (*StateNameFn)(CFDictionaryRef, int32_t);
typedef int32_t (*StateCountFn)(CFDictionaryRef);
typedef int64_t (*StateResidencyFn)(CFDictionaryRef, int32_t);

static void *g_io_report = NULL;
static CopyChannelsFn g_copy_channels = NULL;
static MergeChannelsFn g_merge_channels = NULL;
static CreateSubscriptionFn g_create_subscription = NULL;
static CreateSamplesFn g_create_samples = NULL;
static CreateDeltaFn g_create_delta = NULL;
static IntegerValueFn g_integer_value = NULL;
static ChannelStringFn g_channel_group = NULL;
static ChannelStringFn g_channel_subgroup = NULL;
static ChannelStringFn g_channel_name = NULL;
static ChannelStringFn g_channel_unit = NULL;
static StateNameFn g_state_name = NULL;
static StateCountFn g_state_count = NULL;
static StateResidencyFn g_state_residency = NULL;

static PBSubscriptionRef g_subscription = NULL;
static CFMutableDictionaryRef g_channels = NULL;
static CFDictionaryRef g_previous_sample = NULL;
static uint64_t g_previous_time = 0;
static mach_timebase_info_data_t g_timebase = {0, 0};
static io_connect_t g_smc = 0;
static double g_max_ane_bandwidth = 4.0;

typedef struct {
    pid_t pid;
    uint32_t parent_pid;
    int belongs_to_clipto;
} PBProcessEntry;

typedef struct {
    pid_t pid;
    uint64_t start_time;
    uint64_t cpu_time;
    uint64_t disk_read;
    uint64_t disk_write;
    uint64_t gpu_time;
} PBPreviousProcess;

static PBPreviousProcess *g_previous_clipto_processes = NULL;
static size_t g_previous_clipto_count = 0;
static uint64_t g_previous_clipto_time = 0;

typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    unsigned short release;
} SMCVersion;

typedef struct {
    unsigned short version;
    unsigned short length;
    unsigned int cpu_limit;
    unsigned int gpu_limit;
    unsigned int memory_limit;
} SMCPowerLimit;

typedef struct {
    unsigned int data_size;
    unsigned int data_type;
    char attributes;
} SMCKeyInfo;

typedef struct {
    unsigned int key;
    SMCVersion version;
    SMCPowerLimit power_limit;
    SMCKeyInfo key_info;
    char result;
    char status;
    char command;
    unsigned int data32;
    char bytes[32];
} SMCKeyData;

static unsigned int fourcc(const char *value) {
    return ((unsigned int)(unsigned char)value[0] << 24) |
           ((unsigned int)(unsigned char)value[1] << 16) |
           ((unsigned int)(unsigned char)value[2] << 8) |
           (unsigned int)(unsigned char)value[3];
}

static io_connect_t smc_open(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) != kIOReturnSuccess) return 0;
    io_object_t device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!device) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(device, mach_task_self(), 0, &connection);
    IOObjectRelease(device);
    return result == kIOReturnSuccess ? connection : 0;
}

static double smc_float(io_connect_t connection, const char *key) {
    if (!connection) return 0;
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    size_t output_size = sizeof(output);
    input.key = fourcc(key);
    input.command = 9;
    if (IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &output_size) != kIOReturnSuccess || output.result != 0) return 0;
    input.key_info = output.key_info;
    input.command = 5;
    memset(&output, 0, sizeof(output));
    output_size = sizeof(output);
    if (IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &output_size) != kIOReturnSuccess || output.result != 0) return 0;
    if (input.key_info.data_type == fourcc("flt ") && input.key_info.data_size >= 4) {
        float value = 0;
        memcpy(&value, output.bytes, sizeof(value));
        return value > 0 ? (double)value : 0;
    }
    return 0;
}

static int cf_string(CFStringRef string, char *buffer, size_t size) {
    if (!string || !buffer || size == 0) return 0;
    return CFStringGetCString(string, buffer, (CFIndex)size, kCFStringEncodingUTF8);
}

static double energy_to_watts(int64_t energy, CFStringRef unit_ref, double seconds) {
    if (energy < 0 || seconds <= 0) return 0;
    char unit[16] = {0};
    cf_string(unit_ref, unit, sizeof(unit));
    double joules = (double)energy;
    if (strcmp(unit, "mJ") == 0) joules /= 1e3;
    else if (strcmp(unit, "uJ") == 0) joules /= 1e6;
    else if (strcmp(unit, "nJ") == 0) joules /= 1e9;
    else joules /= 1e6;
    return joules / seconds;
}

static int has_token(const char *text, const char *token) {
    const char *position = text;
    size_t length = strlen(token);
    while ((position = strstr(position, token)) != NULL) {
        char before = position == text ? '\0' : position[-1];
        char after = position[length];
        int before_ok = before == '\0' || before == ' ' || before == '-' || before == '_' || before == '/';
        int after_ok = after == '\0' || after == ' ' || after == '-' || after == '_' || after == '/' || after == '+';
        if (before_ok && after_ok) return 1;
        position += length;
    }
    return 0;
}

static int direction(const char *name) {
    if (strstr(name, "RD+WR") || has_token(name, "RW")) return 0;
    if (has_token(name, "RD")) return 1;
    if (has_token(name, "WR")) return 2;
    return 0;
}

static int load_symbols(void) {
    g_io_report = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!g_io_report) return -1;
    g_copy_channels = (CopyChannelsFn)dlsym(g_io_report, "IOReportCopyChannelsInGroup");
    g_merge_channels = (MergeChannelsFn)dlsym(g_io_report, "IOReportMergeChannels");
    g_create_subscription = (CreateSubscriptionFn)dlsym(g_io_report, "IOReportCreateSubscription");
    g_create_samples = (CreateSamplesFn)dlsym(g_io_report, "IOReportCreateSamples");
    g_create_delta = (CreateDeltaFn)dlsym(g_io_report, "IOReportCreateSamplesDelta");
    g_integer_value = (IntegerValueFn)dlsym(g_io_report, "IOReportSimpleGetIntegerValue");
    g_channel_group = (ChannelStringFn)dlsym(g_io_report, "IOReportChannelGetGroup");
    g_channel_subgroup = (ChannelStringFn)dlsym(g_io_report, "IOReportChannelGetSubGroup");
    g_channel_name = (ChannelStringFn)dlsym(g_io_report, "IOReportChannelGetChannelName");
    g_channel_unit = (ChannelStringFn)dlsym(g_io_report, "IOReportChannelGetUnitLabel");
    g_state_name = (StateNameFn)dlsym(g_io_report, "IOReportStateGetNameForIndex");
    g_state_count = (StateCountFn)dlsym(g_io_report, "IOReportStateGetCount");
    g_state_residency = (StateResidencyFn)dlsym(g_io_report, "IOReportStateGetResidency");
    if (!g_copy_channels || !g_merge_channels || !g_create_subscription ||
        !g_create_samples || !g_create_delta || !g_integer_value ||
        !g_channel_group || !g_channel_subgroup || !g_channel_name || !g_channel_unit ||
        !g_state_name || !g_state_count || !g_state_residency) return -2;
    return 0;
}

typedef enum {
    PB_CHANNELS_ENERGY,
    PB_CHANNELS_MEMORY
} PBChannelFilter;

static int is_energy_channel(const char *name) {
    if (strcmp(name, "ECPU") == 0 || strcmp(name, "PCPU") == 0 ||
        strcmp(name, "MCPU") == 0 || strcmp(name, "CPU Energy") == 0 ||
        strcmp(name, "GPU Energy") == 0 || strcmp(name, "GPU") == 0 ||
        strcmp(name, "ANE") == 0 || strcmp(name, "DRAM") == 0) return 1;
    if (strstr(name, "CPU Energy") != NULL) return 1;
    if (strncmp(name, "GPU SRAM", 8) == 0) return 1;
    if (strstr(name, "ANE") != NULL || strstr(name, "NPU") != NULL ||
        strstr(name, "Neural") != NULL) return 1;
    return 0;
}

static CFMutableDictionaryRef filtered_channels(CFDictionaryRef source, PBChannelFilter filter) {
    if (!source) return NULL;
    CFArrayRef channels = CFDictionaryGetValue(source, CFSTR("IOReportChannels"));
    if (!channels || CFGetTypeID(channels) != CFArrayGetTypeID()) return NULL;

    int has_aggregate_dcs = 0;
    if (filter == PB_CHANNELS_MEMORY) {
        CFIndex count = CFArrayGetCount(channels);
        for (CFIndex index = 0; index < count; index++) {
            CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, index);
            char name[256] = {0};
            cf_string(g_channel_name(channel), name, sizeof(name));
            if (strcmp(name, "DCS RD") == 0 || strcmp(name, "DCS WR") == 0) {
                has_aggregate_dcs = 1;
                break;
            }
        }
    }

    CFMutableArrayRef selected = CFArrayCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks
    );
    if (!selected) return NULL;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex index = 0; index < count; index++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, index);
        char name[256] = {0};
        cf_string(g_channel_name(channel), name, sizeof(name));

        int include = 0;
        if (filter == PB_CHANNELS_ENERGY) {
            include = is_energy_channel(name);
        } else {
            include = strcmp(name, "DCS RD") == 0 || strcmp(name, "DCS WR") == 0;
            if (strncmp(name, "ANE", 3) == 0 && strstr(name, "DCS") == NULL && direction(name) != 0) {
                include = 1;
            }
            if (!has_aggregate_dcs && strstr(name, " DCS ") != NULL && direction(name) != 0) {
                include = 1;
            }
        }
        if (include) CFArrayAppendValue(selected, channel);
    }

    if (CFArrayGetCount(selected) == 0) {
        CFRelease(selected);
        return NULL;
    }
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (result) CFDictionarySetValue(result, CFSTR("IOReportChannels"), selected);
    CFRelease(selected);
    return result;
}

int pb_hardware_init(void) {
    if (g_subscription && g_channels) return 0;
    if (load_symbols() != 0) return -1;

    CFDictionaryRef all_energy = g_copy_channels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!all_energy) return -2;
    g_channels = filtered_channels(all_energy, PB_CHANNELS_ENERGY);
    CFRelease(all_energy);
    if (!g_channels) return -3;

    CFDictionaryRef gpu = g_copy_channels(CFSTR("GPU Stats"), NULL, 0, 0, 0);
    if (gpu) {
        g_merge_channels(g_channels, gpu, NULL);
        CFRelease(gpu);
    }

    CFDictionaryRef all_energy_counters = g_copy_channels(CFSTR("Energy Counters"), NULL, 0, 0, 0);
    CFMutableDictionaryRef energy_counters = filtered_channels(all_energy_counters, PB_CHANNELS_ENERGY);
    if (all_energy_counters) CFRelease(all_energy_counters);
    if (energy_counters) {
        g_merge_channels(g_channels, energy_counters, NULL);
        CFRelease(energy_counters);
    }

    CFDictionaryRef all_memory = g_copy_channels(CFSTR("AMC Stats"), NULL, 0, 0, 0);
    CFMutableDictionaryRef memory = filtered_channels(all_memory, PB_CHANNELS_MEMORY);
    if (all_memory) CFRelease(all_memory);
    if (memory) {
        g_merge_channels(g_channels, memory, NULL);
        CFRelease(memory);
    }

    CFMutableDictionaryRef subscribed_channels = NULL;
    g_subscription = g_create_subscription(NULL, g_channels, &subscribed_channels, 0, NULL);
    if (subscribed_channels) CFRelease(subscribed_channels);
    if (!g_subscription) {
        CFRelease(g_channels);
        g_channels = NULL;
        return -4;
    }
    mach_timebase_info(&g_timebase);
    g_smc = smc_open();
    return 0;
}

PBHardwareMetrics pb_hardware_sample(void) {
    PBHardwareMetrics metrics = {0};
    if (pb_hardware_init() != 0) return metrics;

    CFDictionaryRef current = g_create_samples(g_subscription, g_channels, NULL);
    uint64_t now = mach_absolute_time();
    if (!current) return metrics;
    if (!g_previous_sample) {
        g_previous_sample = current;
        g_previous_time = now;
        return metrics;
    }

    double seconds = 0;
    if (g_timebase.denom != 0 && now > g_previous_time) {
        seconds = (double)(now - g_previous_time) * (double)g_timebase.numer / (double)g_timebase.denom / 1e9;
    }
    CFDictionaryRef delta = g_create_delta(g_previous_sample, current, NULL);
    CFRelease(g_previous_sample);
    g_previous_sample = current;
    g_previous_time = now;
    if (!delta || seconds < 0.05) {
        if (delta) CFRelease(delta);
        return metrics;
    }

    CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!channels) {
        CFRelease(delta);
        return metrics;
    }

    double cpu_total = 0, cpu_clusters = 0;
    double gpu_named = 0, gpu_alias = 0, gpu_sram = 0;
    double ane = 0, dram = 0;
    int64_t dcs_read = 0, dcs_write = 0;
    int64_t fallback_read = 0, fallback_write = 0;
    int64_t ane_read = 0, ane_write = 0;

    CFIndex count = CFArrayGetCount(channels);
    for (CFIndex index = 0; index < count; index++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, index);
        char group[64] = {0};
        char name[256] = {0};
        cf_string(g_channel_group(channel), group, sizeof(group));
        cf_string(g_channel_name(channel), name, sizeof(name));
        int64_t value = g_integer_value(channel, 0);

        if (strcmp(group, "Energy Model") == 0 || strcmp(group, "Energy Counters") == 0) {
            if (value == INT64_MIN || value < 0) continue;
            double watts = energy_to_watts(value, g_channel_unit(channel), seconds);
            if (strcmp(name, "CPU Energy") == 0 || (strstr(name, "DIE_") && strstr(name, "CPU Energy"))) cpu_total += watts;
            else if (strcmp(name, "ECPU") == 0 || strcmp(name, "PCPU") == 0 || strstr(name, "ECPU Energy") || strstr(name, "PCPU Energy")) cpu_clusters += watts;
            else if (strcmp(name, "GPU Energy") == 0) gpu_named += watts;
            else if (strcmp(name, "GPU") == 0) gpu_alias += watts;
            else if (strncmp(name, "GPU SRAM", 8) == 0) gpu_sram += watts;
            else if (strstr(name, "ANE") || strstr(name, "NPU") || strstr(name, "Neural")) ane += watts;
            else if (strncmp(name, "DRAM", 4) == 0) dram += watts;
        } else if (strcmp(group, "GPU Stats") == 0) {
            char subgroup[128] = {0};
            cf_string(g_channel_subgroup(channel), subgroup, sizeof(subgroup));
            if (strcmp(subgroup, "GPU Performance States") == 0 && strcmp(name, "GPUPH") == 0) {
                int32_t state_count = g_state_count(channel);
                int64_t total_time = 0;
                int64_t active_time = 0;
                for (int32_t state = 0; state < state_count; state++) {
                    int64_t residency = g_state_residency(channel, state);
                    if (residency <= 0) continue;
                    total_time += residency;
                    char state_name[64] = {0};
                    cf_string(g_state_name(channel, state), state_name, sizeof(state_name));
                    if (strcmp(state_name, "OFF") != 0 && strcmp(state_name, "IDLE") != 0 &&
                        strcmp(state_name, "DOWN") != 0) {
                        active_time += residency;
                    }
                }
                if (total_time > 0) {
                    metrics.gpu_usage_percent = (double)active_time / (double)total_time * 100.0;
                    metrics.gpu_usage_valid = 1;
                }
            }
        } else if (strcmp(group, "AMC Stats") == 0) {
            if (value == INT64_MIN || value < 0) continue;
            int dir = direction(name);
            if (strcmp(name, "DCS RD") == 0) dcs_read += value;
            else if (strcmp(name, "DCS WR") == 0) dcs_write += value;
            else if (strncmp(name, "ANE", 3) == 0 && strstr(name, "DCS") == NULL) {
                if (dir == 1) ane_read += value;
                else if (dir == 2) ane_write += value;
            } else if (strstr(name, " DCS ") != NULL) {
                if (dir == 1) fallback_read += value;
                else if (dir == 2) fallback_write += value;
            }
        }
    }
    CFRelease(delta);

    metrics.cpu_power_watts = cpu_total > 0 ? cpu_total : cpu_clusters;
    metrics.gpu_power_watts = (gpu_named > 0 ? gpu_named : gpu_alias) + gpu_sram;
    metrics.ane_power_watts = ane;
    metrics.system_power_watts = smc_float(g_smc, "PSTR");
    if (metrics.system_power_watts <= 0) {
        metrics.system_power_watts = metrics.cpu_power_watts + metrics.gpu_power_watts + metrics.ane_power_watts + dram;
    }
    int64_t read_bytes = dcs_read > 0 ? dcs_read : fallback_read;
    int64_t write_bytes = dcs_write > 0 ? dcs_write : fallback_write;
    metrics.memory_read_gbps = (double)read_bytes / seconds / 1e9;
    metrics.memory_write_gbps = (double)write_bytes / seconds / 1e9;

    double ane_bandwidth = (double)(ane_read + ane_write) / seconds / 1e9;
    if (ane_bandwidth > g_max_ane_bandwidth * 1.03) g_max_ane_bandwidth = ane_bandwidth;
    if (metrics.ane_power_watts > 0) metrics.ane_usage_percent = metrics.ane_power_watts / 8.0 * 100.0;
    else if (ane_bandwidth > 0) metrics.ane_usage_percent = ane_bandwidth / g_max_ane_bandwidth * 100.0;
    if (metrics.ane_usage_percent > 100) metrics.ane_usage_percent = 100;
    metrics.valid = 1;
    return metrics;
}

static int path_belongs_to_clipto(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_pidpath(pid, path, sizeof(path));
    if (length <= 0) return 0;
    return strstr(path, "/Clipto.app/") != NULL;
}

static const PBPreviousProcess *previous_clipto_process(pid_t pid, uint64_t start_time) {
    for (size_t index = 0; index < g_previous_clipto_count; index++) {
        const PBPreviousProcess *entry = &g_previous_clipto_processes[index];
        if (entry->pid == pid && entry->start_time == start_time) return entry;
    }
    return NULL;
}

static PBPreviousProcess *current_clipto_process(PBPreviousProcess *processes, size_t count, pid_t pid) {
    for (size_t index = 0; index < count; index++) {
        if (processes[index].pid == pid) return &processes[index];
    }
    return NULL;
}

static void collect_clipto_gpu_time(PBPreviousProcess *processes, size_t count) {
    if (!processes || count == 0) return;
    CFMutableDictionaryRef matching = IOServiceMatching("IOAccelerator");
    if (!matching) return;
    io_iterator_t accelerators = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &accelerators) != kIOReturnSuccess) return;

    io_object_t accelerator = IOIteratorNext(accelerators);
    while (accelerator != 0) {
        io_iterator_t clients = 0;
        if (IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == kIOReturnSuccess) {
            io_object_t client = IOIteratorNext(clients);
            while (client != 0) {
                CFTypeRef creator_value = IORegistryEntryCreateCFProperty(
                    client, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0
                );
                char creator[128] = {0};
                pid_t pid = 0;
                if (creator_value && CFGetTypeID(creator_value) == CFStringGetTypeID() &&
                    cf_string((CFStringRef)creator_value, creator, sizeof(creator))) {
                    int parsed_pid = 0;
                    if (sscanf(creator, "pid %d,", &parsed_pid) == 1) pid = (pid_t)parsed_pid;
                }
                if (creator_value) CFRelease(creator_value);

                PBPreviousProcess *process = current_clipto_process(processes, count, pid);
                if (process) {
                    CFTypeRef usage_value = IORegistryEntryCreateCFProperty(
                        client, CFSTR("AppUsage"), kCFAllocatorDefault, 0
                    );
                    if (usage_value && CFGetTypeID(usage_value) == CFArrayGetTypeID()) {
                        CFArrayRef usages = (CFArrayRef)usage_value;
                        CFIndex usage_count = CFArrayGetCount(usages);
                        for (CFIndex usage_index = 0; usage_index < usage_count; usage_index++) {
                            CFTypeRef item = CFArrayGetValueAtIndex(usages, usage_index);
                            if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
                            CFTypeRef time_value = CFDictionaryGetValue(
                                (CFDictionaryRef)item, CFSTR("accumulatedGPUTime")
                            );
                            int64_t gpu_time = 0;
                            if (time_value && CFGetTypeID(time_value) == CFNumberGetTypeID() &&
                                CFNumberGetValue((CFNumberRef)time_value, kCFNumberSInt64Type, &gpu_time) &&
                                gpu_time > 0) {
                                process->gpu_time += (uint64_t)gpu_time;
                            }
                        }
                    }
                    if (usage_value) CFRelease(usage_value);
                }
                IOObjectRelease(client);
                client = IOIteratorNext(clients);
            }
            IOObjectRelease(clients);
        }
        IOObjectRelease(accelerator);
        accelerator = IOIteratorNext(accelerators);
    }
    IOObjectRelease(accelerators);
}

PBAppMetrics pb_clipto_sample(void) {
    PBAppMetrics metrics = {0};
    int buffer_size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (buffer_size <= 0) return metrics;

    buffer_size += (int)(64 * sizeof(pid_t));
    pid_t *pids = calloc(1, (size_t)buffer_size);
    if (!pids) return metrics;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, buffer_size);
    if (bytes <= 0) {
        free(pids);
        return metrics;
    }

    size_t pid_count = (size_t)bytes / sizeof(pid_t);
    PBProcessEntry *processes = calloc(pid_count, sizeof(PBProcessEntry));
    if (!processes) {
        free(pids);
        return metrics;
    }

    size_t process_count = 0;
    for (size_t index = 0; index < pid_count; index++) {
        if (pids[index] <= 0) continue;
        struct proc_bsdinfo info = {0};
        int size = proc_pidinfo(pids[index], PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        if (size != sizeof(info)) continue;
        PBProcessEntry entry = {
            .pid = pids[index],
            .parent_pid = info.pbi_ppid,
            .belongs_to_clipto = path_belongs_to_clipto(pids[index])
        };
        processes[process_count++] = entry;
    }
    free(pids);

    // Some bundled tools can re-exec outside the app bundle. Include descendants
    // of an already identified Clipto process so the app group remains complete.
    int changed;
    do {
        changed = 0;
        for (size_t index = 0; index < process_count; index++) {
            if (processes[index].belongs_to_clipto) continue;
            for (size_t parent = 0; parent < process_count; parent++) {
                if (processes[parent].belongs_to_clipto &&
                    processes[parent].pid == (pid_t)processes[index].parent_pid) {
                    processes[index].belongs_to_clipto = 1;
                    changed = 1;
                    break;
                }
            }
        }
    } while (changed);

    size_t matched_count = 0;
    for (size_t index = 0; index < process_count; index++) {
        if (processes[index].belongs_to_clipto) matched_count++;
    }

    PBPreviousProcess *current = matched_count > 0
        ? calloc(matched_count, sizeof(PBPreviousProcess))
        : NULL;
    size_t current_count = 0;
    uint64_t cpu_delta = 0;
    uint64_t read_delta = 0;
    uint64_t write_delta = 0;
    uint64_t gpu_delta = 0;
    uint64_t now = mach_absolute_time();

    for (size_t index = 0; index < process_count; index++) {
        if (!processes[index].belongs_to_clipto) continue;
        metrics.process_count++;

        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(processes[index].pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        metrics.memory_bytes += (double)usage.ri_phys_footprint;

        PBPreviousProcess snapshot = {
            .pid = processes[index].pid,
            .start_time = usage.ri_proc_start_abstime,
            .cpu_time = usage.ri_user_time + usage.ri_system_time,
            .disk_read = usage.ri_diskio_bytesread,
            .disk_write = usage.ri_diskio_byteswritten,
            .gpu_time = 0
        };
        if (current && current_count < matched_count) current[current_count++] = snapshot;

        const PBPreviousProcess *previous = previous_clipto_process(snapshot.pid, snapshot.start_time);
        if (!previous) continue;
        if (snapshot.cpu_time >= previous->cpu_time) cpu_delta += snapshot.cpu_time - previous->cpu_time;
        if (snapshot.disk_read >= previous->disk_read) read_delta += snapshot.disk_read - previous->disk_read;
        if (snapshot.disk_write >= previous->disk_write) write_delta += snapshot.disk_write - previous->disk_write;
    }
    collect_clipto_gpu_time(current, current_count);
    for (size_t index = 0; index < current_count; index++) {
        const PBPreviousProcess *previous = previous_clipto_process(current[index].pid, current[index].start_time);
        if (previous && current[index].gpu_time >= previous->gpu_time) {
            gpu_delta += current[index].gpu_time - previous->gpu_time;
        }
    }
    free(processes);

    double seconds = 0;
    if (g_timebase.denom == 0) mach_timebase_info(&g_timebase);
    if (g_timebase.denom != 0 && now > g_previous_clipto_time) {
        seconds = (double)(now - g_previous_clipto_time) *
                  (double)g_timebase.numer / (double)g_timebase.denom / 1e9;
    }
    if (seconds >= 0.05 && g_previous_clipto_time != 0) {
        // rusage CPU times use mach absolute-time ticks, not nanoseconds.
        // Convert them with the same timebase used for the wall interval.
        double cpu_seconds = (double)cpu_delta *
                             (double)g_timebase.numer / (double)g_timebase.denom / 1e9;
        metrics.cpu_percent = cpu_seconds / seconds * 100.0;
        metrics.disk_read_bytes_per_second = (double)read_delta / seconds;
        metrics.disk_write_bytes_per_second = (double)write_delta / seconds;
        metrics.gpu_percent = (double)gpu_delta / seconds / 1e9 * 100.0;
        if (metrics.gpu_percent > 100.0) metrics.gpu_percent = 100.0;
        metrics.rates_valid = 1;
    }
    metrics.running = metrics.process_count > 0;

    free(g_previous_clipto_processes);
    g_previous_clipto_processes = current;
    g_previous_clipto_count = current_count;
    g_previous_clipto_time = now;
    return metrics;
}

void pb_hardware_shutdown(void) {
    if (g_previous_sample) { CFRelease(g_previous_sample); g_previous_sample = NULL; }
    if (g_channels) { CFRelease(g_channels); g_channels = NULL; }
    if (g_subscription) { CFRelease(g_subscription); g_subscription = NULL; }
    if (g_smc) { IOServiceClose(g_smc); g_smc = 0; }
    if (g_io_report) { dlclose(g_io_report); g_io_report = NULL; }
    free(g_previous_clipto_processes);
    g_previous_clipto_processes = NULL;
    g_previous_clipto_count = 0;
    g_previous_clipto_time = 0;
}
