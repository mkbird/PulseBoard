export interface MetricCapabilities {
  system_gpu: boolean;
  ane: boolean;
  power: boolean;
  dram_bandwidth: boolean;
  process_gpu: boolean;
  process_io: boolean;
}

export interface MetricSemantics {
  system_memory: string;
  process_memory: string;
  gpu_memory: string;
  process_cpu: string;
  process_gpu: string;
  process_io: string;
  power: string;
}

export interface WindowsCliptoPaths {
  localAppData: string;
  installRoot: string;
  executablePath: string;
  dataRoot: string;
  dagscRoot: string;
  scheduleDatabasePath: string;
  cliptoInstalled: boolean;
  scheduleDatabaseExists: boolean;
}

export interface SystemEnvironmentInfo {
  platform: "windows";
  os_name: "Windows";
  os_version: string;
  /** Kept while the existing browser migrates to os_name/os_version. */
  macos_version: string;
  chip_model: string;
  physical_memory_bytes: number;
  physical_memory_text: string;
  logical_cores: number;
  hostname: string;
  username: string;
  lan_ips: string[];
  web_port: number;
  default_dagsc_dir: string;
  history_db_path: string;
  history_db_size_bytes: number;
  metric_capabilities: MetricCapabilities;
  metric_semantics: MetricSemantics;
  nvidia_smi_available: boolean;
  nvidia_gpus: NvidiaGPUInfo[];
  clipto_install_path: string;
  clipto_data_path: string;
  schedule_db_path: string;
  clipto_installed: boolean;
  schedule_db_exists: boolean;
}

export interface ProcessReading {
  pid: number;
  name: string;
  start_time: number;
  cpu_seconds: number | null;
  working_set_bytes: number | null;
  private_memory_bytes: number | null;
}

export interface ProcessFrame {
  ts_ms: number;
  ok: boolean;
  error?: string;
  processes: ProcessReading[];
}

export interface NvidiaGPUReading {
  index: number;
  uuid: string;
  name: string;
  utilization_percent: number | null;
  memory_used_bytes: number | null;
  memory_total_bytes: number | null;
  power_draw_watts: number | null;
  power_limit_watts: number | null;
  temperature_c: number | null;
  driver_version: string;
}

export type NvidiaGPUInfo = Pick<
  NvidiaGPUReading,
  "index" | "uuid" | "name" | "memory_total_bytes" | "power_limit_watts" | "driver_version"
>;

export interface LiveSample {
  ts_ms: number;
  cpu_usage: number;
  gpu_usage: number | null;
  gpu_memory_used_bytes: number | null;
  gpu_memory_total_bytes: number | null;
  gpu_power_limit_watts: number | null;
  gpu_temperature_c: number | null;
  nvidia_gpus: NvidiaGPUReading[];
  ane_usage: null;
  memory_usage: number;
  memory_used_bytes: number;
  memory_total_bytes: number;
  memory_pressure: number;
  swap_used_bytes: null;
  swap_total_bytes: null;
  ane_power_watts: null;
  cpu_power_watts: null;
  gpu_power_watts: number | null;
  system_power_watts: null;
  memory_read_gbps: null;
  memory_write_gbps: null;
  disk_read_bps: null;
  disk_write_bps: null;
  disk_free_bytes: number | null;
  disk_total_bytes: number | null;
  net_down_bps: null;
  net_up_bps: null;
  thermal_state: "unknown";
  clipto_running: boolean;
  clipto_cpu_percent: number | null;
  clipto_memory_bytes: number | null;
  clipto_disk_read_bps: null;
  clipto_disk_write_bps: null;
  clipto_process_count: number;
  clipto_gpu_percent: null;
  cms_cpu_percent: number | null;
  cms_memory_bytes: number | null;
  cms_process_count: number;
  process_readings: ProcessReadingWithCPU[];
}

export interface ProcessReadingWithCPU extends ProcessReading {
  cpu_percent: number | null;
  is_cms: boolean;
}

export interface LiveMetricStatistics {
  current: number | null;
  average: number | null;
  peak: number | null;
  valid_duration_sec: number;
}

export type LiveProcessState = "running" | "exited" | "unavailable";

export interface LiveCMSProcess {
  pid: number;
  start_time: number;
  name: string;
  state: LiveProcessState;
  cpu: LiveMetricStatistics;
  memory: LiveMetricStatistics;
}

export interface LiveCMSSession {
  started_at_ms: number;
  started_at_text: string;
  running_count: number;
  total_instances: number;
  is_complete: boolean;
  is_suspended: boolean;
  cpu: LiveMetricStatistics;
  memory: LiveMetricStatistics;
  processes: LiveCMSProcess[];
}

export interface HistoryPoint {
  ts_ms: number;
  sys_cpu: number;
  sys_gpu: number | null;
  gpu_memory_used_bytes: number | null;
  gpu_memory_total_bytes: number | null;
  gpu_power_limit_watts: number | null;
  gpu_temperature_c: number | null;
  ane_usage: null;
  sys_mem_bytes: number;
  sys_mem_pct: number;
  swap_used_bytes: null;
  clipto_cpu: number | null;
  clipto_mem_bytes: number | null;
  clipto_non_cms_mem_bytes: number | null;
  clipto_process_count: number;
  clipto_gpu: null;
  clipto_disk_read: null;
  clipto_disk_write: null;
  cms_cpu: number | null;
  cms_mem_bytes: number | null;
  cms_process_count: number;
  cms_gpu: null;
  sys_power: null;
  cpu_power: null;
  gpu_power: number | null;
  ane_power: null;
  dram_read_gbps: null;
  dram_write_gbps: null;
  disk_read_bps: null;
  disk_write_bps: null;
  net_down_bps: null;
  net_up_bps: null;
  thermal: "unknown";
}

export interface HistoryPayload {
  ok: true;
  from_ms: number;
  to_ms: number;
  points: HistoryPoint[];
}

export interface LivePayload {
  ok: true;
  sampling_interval_sec: number;
  retention_days: number;
  enhanced_available: boolean;
  latest: LiveSample | null;
  cms: LiveCMSSession;
}
