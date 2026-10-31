export const REPORT_CSV_LABELS = [
  "Clipto 版本号",
  "端到端分析速度 (x)",
  "全 CMS Working Set 峰值 (RAM GB)",
  "全 CMS CPU P95 (%，单核=100)",
  "全 CMS GPU P95 (%)",
  "处理素材数",
  "素材总时长 (分钟)",
  "端到端处理耗时 (分钟)",
  "任务总数",
  "失败任务数",
  "全 CMS Working Set 平均 (RAM GB)",
  "全 CMS CPU 平均 (%)",
  "全 CMS GPU 平均 (%)",
  "Clipto Working Set 峰值 (RAM GB)",
  "系统物理内存已用峰值 (RAM GB)",
  "Swap 峰值 (GB)",
  "整机平均功耗 (W)",
  "累计耗电 (Wh)",
  "硬件采样覆盖率 (%)",
  "运行开始时间",
  "运行结束时间",
  "分析模板版本",
  "测试机型",
  "评测人",
  "Clipto 非 CMS Working Set 峰值 (RAM GB)",
  "Clipto 数据目录大小 (GB)",
  "Clipto 数据目录运行期间增长 (GB)",
  "平台标识",
  "操作系统",
  "可用指标",
  "系统内存口径",
  "进程内存口径",
  "进程 CPU 口径",
  "进程 GPU 口径",
  "进程 I/O 口径",
  "NVIDIA GPU 显存已用峰值 (VRAM GB)",
  "NVIDIA GPU 显存总容量 (VRAM GB)",
  "GPU 显存口径",
  "全 CMS 显存占用峰值 (VRAM GB)",
  "Clipto 进程组显存占用峰值 (VRAM GB)",
  "Clipto 进程组 CPU P95 (%)",
  "Clipto 进程组 GPU P95 (%)",
  "进程显存口径"
] as const;

type JSONMap = Record<string, any>;

function finite(value: unknown, digits: number): string {
  return typeof value === "number" && Number.isFinite(value) ? value.toFixed(digits) : "";
}

function bytesGB(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value)
    ? (value / 1_073_741_824).toFixed(2)
    : "";
}

function minutes(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) ? (value / 60_000).toFixed(1) : "";
}

function localMinute(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return "";
  const d = new Date(value);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function escapeCSV(value: string): string {
  return /[",\r\n]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value;
}

export function reportCSVValues(analysis: JSONMap, reporter = ""): string[] {
  const env = analysis.environment ?? {};
  const caps = env.metric_capabilities ?? {};
  const semantics = env.metric_semantics ?? {};
  const scope = analysis.scopes?.asset_analysis ?? {};
  const hw = analysis.aligned_hardware?.has_data ? analysis.aligned_hardware : undefined;
  const storage = analysis.aligned_hardware?.storage;
  const processGPU = caps.process_gpu === true;
  const power = caps.power === true;
  const available = [
    "CPU", "系统 RAM", "进程 Working Set",
    caps.system_gpu ? "系统 GPU / NVIDIA VRAM" : "",
    caps.process_gpu ? "进程 GPU" : "",
    caps.process_vram ? "进程 VRAM" : "",
    caps.ane ? "ANE" : "",
    caps.power ? "功耗" : "",
    caps.dram_bandwidth ? "DRAM 带宽" : "",
    caps.process_io ? "进程 I/O" : ""
  ].filter(Boolean).join(" / ");
  const storageGrowth = typeof storage?.start_bytes === "number" && typeof storage?.end_bytes === "number"
    ? storage.end_bytes - storage.start_bytes
    : undefined;

  return [
    String(analysis.app_version ?? ""),
    finite(scope.wall_speedup, 2),
    bytesGB(hw?.cms_total_memory_bytes?.max),
    finite(hw?.cms_total_cpu_percent?.p95, 1),
    processGPU ? finite(hw?.cms_total_gpu_percent?.p95, 1) : "",
    analysis.assets_total == null ? "" : String(analysis.assets_total),
    minutes(analysis.total_media_duration_ms),
    minutes(scope.wall_clock_ms),
    scope.total_tasks == null ? "" : String(scope.total_tasks),
    scope.failed_tasks == null ? "" : String(scope.failed_tasks),
    bytesGB(hw?.cms_total_memory_bytes?.avg),
    finite(hw?.cms_total_cpu_percent?.avg, 1),
    processGPU ? finite(hw?.cms_total_gpu_percent?.avg, 1) : "",
    bytesGB(hw?.clipto_memory_bytes?.max),
    bytesGB(hw?.sys_mem_bytes?.max),
    bytesGB(hw?.swap_used_bytes?.max),
    power ? finite(hw?.sys_power_watts?.avg, 2) : "",
    power ? finite(hw?.estimated_energy_wh, 2) : "",
    finite(hw?.coverage_percent, 1),
    localMinute(analysis.slice_start_ms),
    localMinute(analysis.slice_end_ms),
    String(analysis.template_version ?? ""),
    [
      env.chip_model,
      Array.isArray(env.nvidia_gpus) ? env.nvidia_gpus.map((gpu: JSONMap) => gpu.name).filter(Boolean).join(" + ") : "",
      env.physical_memory_text,
      env.os_name && env.os_version ? `${env.os_name} ${env.os_version}` : env.os_name
    ]
      .filter(Boolean).join(" / "),
    reporter,
    bytesGB(hw?.clipto_non_cms_memory_bytes?.max),
    bytesGB(storage?.end_bytes),
    bytesGB(storageGrowth),
    String(env.platform ?? ""),
    env.os_name && env.os_version ? `${env.os_name} ${env.os_version}` : String(env.os_name ?? ""),
    available,
    String(semantics.system_memory ?? ""),
    String(semantics.process_memory ?? ""),
    String(semantics.process_cpu ?? ""),
    processGPU ? String(semantics.process_gpu ?? "") : "",
    caps.process_io ? String(semantics.process_io ?? "") : "",
    caps.system_gpu ? bytesGB(hw?.gpu_memory_used_bytes?.max) : "",
    caps.system_gpu ? bytesGB(hw?.gpu_memory_total_bytes?.max) : "",
    caps.system_gpu ? String(semantics.gpu_memory ?? "NVIDIA 显存（VRAM）") : "",
    bytesGB(hw?.cms_total_vram_bytes?.max),
    bytesGB(hw?.clipto_vram_bytes?.max),
    finite(hw?.clipto_cpu_percent?.p95, 1),
    finite(hw?.clipto_gpu_percent?.p95, 1),
    String(semantics.process_vram ?? "")
  ];
}

export function generateReportCSV(analysis: JSONMap, reporter = "", includeLabels = false): string {
  const values = reportCSVValues(analysis, reporter);
  const rows = values.map((value, index) => includeLabels
    ? `${escapeCSV(REPORT_CSV_LABELS[index] ?? "")},${escapeCSV(value)}`
    : escapeCSV(value));
  return `\uFEFF${rows.join("\r\n")}\r\n`;
}

export function generateReportColumn(analysis: JSONMap, reporter = ""): string {
  return reportCSVValues(analysis, reporter).join("\n");
}
