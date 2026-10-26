#include "PulseHardware.h"

#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

/* No cached process state: each caller owns its snapshot and rate baselines. */
static double cms_seconds(uint64_t ticks, mach_timebase_info_data_t timebase) {
    return (double)ticks * (double)timebase.numer / (double)timebase.denom / 1e9;
}

static int cms_name_matches(const char *name) {
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        if ((p[0] == 'c' || p[0] == 'C') &&
            (p[1] == 'm' || p[1] == 'M') &&
            (p[2] == 's' || p[2] == 'S')) return 1;
    }
    return 0;
}

/* Returns 1 for a readable identity, -1 for an exited PID, and 0 otherwise. */
static int cms_identity(pid_t pid, struct proc_bsdinfo *info) {
    memset(info, 0, sizeof(*info));
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info));
    if (size != (int)sizeof(*info)) return errno == ESRCH ? -1 : 0;
    if (info->pbi_pid != (uint32_t)pid || info->pbi_start_tvsec == 0 ||
        info->pbi_start_tvusec >= 1000000 ||
        info->pbi_start_tvsec > (UINT64_MAX - info->pbi_start_tvusec) / 1000000) return 0;
    return 1;
}

static uint64_t cms_start_time(const struct proc_bsdinfo *info) {
    return info->pbi_start_tvsec * 1000000 + info->pbi_start_tvusec;
}

/* A full buffer may have omitted new PIDs; grow and enumerate again. */
static pid_t *cms_list_pids(size_t *count) {
    *count = 0;
    int needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (needed <= 0) return NULL;
    size_t capacity = (size_t)needed + 64 * sizeof(pid_t);
    for (unsigned int attempt = 0; attempt < 8; attempt++) {
        if (capacity > INT_MAX) return NULL;
        pid_t *pids = calloc(1, capacity);
        if (!pids) return NULL;
        int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)capacity);
        if (bytes > 0 && (size_t)bytes < capacity && bytes % sizeof(pid_t) == 0) {
            *count = (size_t)bytes / sizeof(pid_t);
            return pids;
        }
        free(pids);
        if (bytes <= 0 || bytes % sizeof(pid_t) != 0) return NULL;
        capacity *= 2;
    }
    return NULL;
}

PBCMSSnapshot pb_cms_snapshot(void) {
    PBCMSSnapshot snapshot = {0};
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return snapshot;
    snapshot.monotonic_seconds = cms_seconds(mach_absolute_time(), timebase);

    size_t pid_count = 0;
    pid_t *pids = cms_list_pids(&pid_count);
    if (!pids) return snapshot;
    if (pid_count > SIZE_MAX / sizeof(PBCMSProcess)) {
        free(pids);
        return snapshot;
    }
    PBCMSProcess *matches = calloc(pid_count, sizeof(PBCMSProcess));
    if (!matches) {
        free(pids);
        return snapshot;
    }

    for (size_t i = 0; i < pid_count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        /* Paths remain readable for many system processes whose BSD identity
           is denied. Exclude unrelated executables before asking for identity. */
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        errno = 0;
        int length = proc_pidpath(pid, path, sizeof(path));
        if (length <= 0 || !memchr(path, '\0', sizeof(path))) {
            if (errno != ESRCH) snapshot.unreadable_count++;
            continue;
        }
        const char *separator = strrchr(path, '/');
        const char *name = separator ? separator + 1 : path;
        size_t name_length = strlen(name);
        if (name_length == 0 || name_length >= sizeof(matches[0].name)) {
            snapshot.unreadable_count++;
            continue;
        }
        if (!cms_name_matches(name)) continue;

        struct proc_bsdinfo before = {0};
        int identity_status = cms_identity(pid, &before);
        if (identity_status != 1) {
            if (identity_status == 0) snapshot.unreadable_count++;
            continue;
        }
        /* The initial path lookup preceded the identity read. Recheck it
           inside the identity bracket to catch a PID reuse or exec race. */
        char confirmed_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        errno = 0;
        length = proc_pidpath(pid, confirmed_path, sizeof(confirmed_path));
        if (length <= 0 || !memchr(confirmed_path, '\0', sizeof(confirmed_path))) {
            if (errno != ESRCH) snapshot.unreadable_count++;
            continue;
        }
        if (strcmp(path, confirmed_path) != 0) {
            snapshot.unreadable_count++;
            continue;
        }

        struct rusage_info_v2 usage = {0};
        errno = 0;
        int usage_result = proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage);
        int usage_error = errno;
        if ((usage_result != 0 && usage_error == ESRCH) ||
            (usage_result == 0 && usage.ri_proc_exit_abstime != 0)) continue;

        /* Bracket path and rusage reads with the BSD start identity. Do not map
           epoch time onto the Mach clock: wall-clock adjustments make that unsafe. */
        struct proc_bsdinfo after = {0};
        identity_status = cms_identity(pid, &after);
        if (identity_status != 1) {
            if (identity_status == 0) snapshot.unreadable_count++;
            continue;
        }
        if (cms_start_time(&before) != cms_start_time(&after)) {
            snapshot.unreadable_count++;
            continue;
        }

        PBCMSProcess *process = &matches[snapshot.count++];
        process->pid = pid;
        process->start_time = cms_start_time(&before);
        memcpy(process->name, name, name_length + 1);
        if (usage_result == 0 && usage.ri_proc_start_abstime != 0 &&
            usage.ri_proc_start_abstime <= mach_absolute_time()) {
            /* XNU fill_task_rusage uses task_power_info's Mach-time counters. */
            process->cpu_seconds = cms_seconds(usage.ri_user_time, timebase) +
                                   cms_seconds(usage.ri_system_time, timebase);
            process->memory_bytes = usage.ri_phys_footprint;
            process->usage_valid = 1;
        }
    }

    free(pids);
    if (snapshot.count == 0) {
        free(matches);
    } else {
        snapshot.processes = matches;
    }
    snapshot.enumeration_valid = 1;
    snapshot.monotonic_seconds = cms_seconds(mach_absolute_time(), timebase);
    return snapshot;
}

void pb_cms_snapshot_free(PBCMSSnapshot *snapshot) {
    if (!snapshot) return;
    free(snapshot->processes);
    memset(snapshot, 0, sizeof(*snapshot));
}
