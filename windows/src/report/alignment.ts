type JSONMap = Record<string, any>;

function metric(values: unknown[]): JSONMap {
  const numbers = values.filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  if (!numbers.length) return { avg: null, max: null, min: null, p95: null, count: 0 };
  const sorted = [...numbers].sort((a, b) => a - b);
  const p95Index = Math.max(0, Math.ceil(sorted.length * 0.95) - 1);
  return {
    avg: numbers.reduce((sum, value) => sum + value, 0) / numbers.length,
    max: sorted[sorted.length - 1],
    min: sorted[0],
    p95: sorted[p95Index],
    count: numbers.length
  };
}

function formatTimestamp(ms: number): string {
  const date = new Date(ms);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

function inIntervals(timestamp: number, intervals: Array<[number, number]>): boolean {
  return intervals.some(([start, end]) => timestamp >= start && timestamp <= end);
}

function energyWh(points: JSONMap[], key: string): number | null {
  let wattMilliseconds = 0;
  let validSegments = 0;
  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1];
    const current = points[index];
    const before = previous[key];
    const after = current[key];
    const duration = current.ts_ms - previous.ts_ms;
    if (
      typeof before === "number" && Number.isFinite(before)
      && typeof after === "number" && Number.isFinite(after)
      && duration > 0 && duration <= 30_000
    ) {
      wattMilliseconds += ((before + after) / 2) * duration;
      validSegments += 1;
    }
  }
  return validSegments > 0 ? wattMilliseconds / 3_600_000 : null;
}

export function buildAlignedHardware(
  rawPoints: JSONMap[],
  intervals: Array<[number, number]>,
  fallbackStartMs: number,
  fallbackEndMs: number
): JSONMap {
  const normalizedIntervals = intervals.length ? intervals : [[fallbackStartMs, fallbackEndMs] as [number, number]];
  const points = rawPoints
    .filter(point => typeof point.ts_ms === "number" && inIntervals(point.ts_ms, normalizedIntervals))
    .sort((a, b) => a.ts_ms - b.ts_ms);
  const windowStart = points[0]?.ts_ms ?? fallbackStartMs;
  const windowEnd = points[points.length - 1]?.ts_ms ?? fallbackEndMs;

  if (!points.length) {
    return {
      has_data: false,
      window_start_ms: fallbackStartMs,
      window_end_ms: fallbackEndMs,
      window_start_text: formatTimestamp(fallbackStartMs),
      window_end_text: formatTimestamp(fallbackEndMs),
      sample_count: 0,
      cms_frame_count: 0,
      coverage_percent: 0,
      storage: null,
      time_series: []
    };
  }

  const activeDuration = normalizedIntervals.reduce((sum, [start, end]) => sum + Math.max(0, end - start), 0);
  const expectedSamples = Math.max(1, Math.floor(activeDuration / 1_000) + 1);
  const maxProcesses = points.reduce((max, point) => Math.max(max, Number(point.clipto_process_count ?? 0)), 0);

  return {
    has_data: true,
    window_start_ms: windowStart,
    window_end_ms: windowEnd,
    window_start_text: formatTimestamp(windowStart),
    window_end_text: formatTimestamp(windowEnd),
    sample_count: points.length,
    cms_frame_count: points.filter(point => point.cms_mem_bytes != null || point.cms_cpu != null).length,
    coverage_percent: Math.min(100, points.length / expectedSamples * 100),
    sys_cpu: metric(points.map(point => point.sys_cpu)),
    sys_gpu: metric(points.map(point => point.sys_gpu)),
    gpu_memory_used_bytes: metric(points.map(point => point.gpu_memory_used_bytes)),
    gpu_memory_total_bytes: metric(points.map(point => point.gpu_memory_total_bytes)),
    gpu_power_limit_watts: metric(points.map(point => point.gpu_power_limit_watts)),
    gpu_temperature_c: metric(points.map(point => point.gpu_temperature_c)),
    ane_usage: metric(points.map(point => point.ane_usage)),
    sys_mem_bytes: metric(points.map(point => point.sys_mem_bytes)),
    sys_mem_pct: metric(points.map(point => point.sys_mem_pct)),
    swap_used_bytes: metric(points.map(point => point.swap_used_bytes)),
    clipto_cpu_percent: metric(points.map(point => point.clipto_cpu)),
    clipto_memory_bytes: metric(points.map(point => point.clipto_mem_bytes)),
    clipto_non_cms_memory_bytes: metric(points.map(point => point.clipto_non_cms_mem_bytes)),
    clipto_gpu_percent: metric(points.map(point => point.clipto_gpu)),
    clipto_disk_read_bps: metric(points.map(point => point.clipto_disk_read)),
    clipto_disk_write_bps: metric(points.map(point => point.clipto_disk_write)),
    cms_total_cpu_percent: metric(points.map(point => point.cms_cpu)),
    cms_total_memory_bytes: metric(points.map(point => point.cms_mem_bytes)),
    cms_total_gpu_percent: metric(points.map(point => point.cms_gpu)),
    sys_power_watts: metric(points.map(point => point.sys_power)),
    cpu_power_watts: metric(points.map(point => point.cpu_power)),
    gpu_power_watts: metric(points.map(point => point.gpu_power)),
    ane_power_watts: metric(points.map(point => point.ane_power)),
    dram_read_gbps: metric(points.map(point => point.dram_read_gbps)),
    dram_write_gbps: metric(points.map(point => point.dram_write_gbps)),
    disk_read_bps: metric(points.map(point => point.disk_read_bps)),
    disk_write_bps: metric(points.map(point => point.disk_write_bps)),
    estimated_energy_wh: null,
    gpu_estimated_energy_wh: energyWh(points, "gpu_power"),
    worst_thermal_state: "unknown",
    clipto_max_processes: maxProcesses,
    cms_processes: [],
    clipto_members: [],
    storage: null,
    time_series: points
  };
}
