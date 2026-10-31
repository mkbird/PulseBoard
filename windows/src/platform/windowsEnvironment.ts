import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import type {
  MetricCapabilities,
  MetricSemantics,
  SystemEnvironmentInfo,
  WindowsCliptoPaths,
} from "./types.js";
import type { NvidiaSmiSnapshot } from "./nvidiaSmiSampler.js";

const WINDOWS_CAPABILITIES: MetricCapabilities = {
  system_gpu: false,
  ane: false,
  power: false,
  dram_bandwidth: false,
  process_gpu: false,
  process_vram: false,
  process_io: false,
};

const WINDOWS_SEMANTICS: MetricSemantics = {
  system_memory: "系统物理内存（RAM）",
  process_memory: "进程 WorkingSet64（RAM，不含 GPU 显存）",
  gpu_memory: "NVIDIA 显存（VRAM，nvidia-smi memory.used / memory.total）",
  process_vram: "WDDM 专用 GPU 内存按 PID 合计；跨进程共享分配可能重复计数；共享 GPU 系统内存另计",
  process_cpu: "单核 = 100%",
  process_gpu: "WDDM 同一 NVIDIA GPU 引擎内按进程组合计，取最忙引擎（100% = 一个引擎满载）",
  process_io: "当前 Windows 版本未采集进程 I/O",
  power: "NVIDIA GPU 板卡功耗（nvidia-smi），不代表整机功耗",
};

function firstExisting(candidates: string[], fileExists: (candidate: string) => boolean): string {
  return candidates.find(fileExists) ?? candidates[0] ?? "";
}

export function discoverWindowsCliptoPaths(
  environment: NodeJS.ProcessEnv = process.env,
  fileExists: (candidate: string) => boolean = fs.existsSync,
): WindowsCliptoPaths {
  const localAppData = environment.LOCALAPPDATA
    ?? path.join(environment.USERPROFILE ?? os.homedir(), "AppData", "Local");
  const installCandidates = [
    path.join(localAppData, "Programs", "Clipto"),
    path.join(environment.ProgramFiles ?? "C:\\Program Files", "Clipto"),
    path.join(environment["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)", "Clipto"),
  ];
  const executableCandidates = installCandidates.map((root) => path.join(root, "Clipto.exe"));
  const executablePath = firstExisting(executableCandidates, fileExists);
  const installRoot = path.dirname(executablePath);
  const dataRoot = path.join(localAppData, "Clipto");
  const dagscRoot = path.join(dataRoot, "dagsc_data");
  const scheduleDatabasePath = path.join(dagscRoot, "data", "schedule.db");

  return {
    localAppData,
    installRoot,
    executablePath,
    dataRoot,
    dagscRoot,
    scheduleDatabasePath,
    cliptoInstalled: fileExists(executablePath),
    scheduleDatabaseExists: fileExists(scheduleDatabasePath),
  };
}

export function formatBytesCompact(bytes: number): string {
  const gib = bytes / 1_073_741_824;
  return `${Number.isInteger(gib) ? gib.toFixed(0) : gib.toFixed(1)} GB`;
}

export function buildWindowsEnvironment(
  webPort: number,
  historyPath: string,
  paths: WindowsCliptoPaths = discoverWindowsCliptoPaths(),
  nvidia: NvidiaSmiSnapshot | null = null,
  processGPU: { usage: boolean; memory: boolean } = { usage: false, memory: false },
): SystemEnvironmentInfo {
  const cpus = os.cpus();
  const osVersion = os.release();
  let historySize = 0;
  try {
    historySize = fs.statSync(historyPath).size;
  } catch {
    // A fresh profile has no history database yet.
  }
  const nvidiaAvailable = nvidia?.available === true;
  const capabilities: MetricCapabilities = {
    ...WINDOWS_CAPABILITIES,
    system_gpu: nvidiaAvailable && nvidia.gpu_usage != null,
    power: nvidiaAvailable && nvidia.power_draw_watts != null,
    process_gpu: processGPU.usage,
    process_vram: processGPU.memory,
  };

  return {
    platform: "windows",
    os_name: "Windows",
    os_version: osVersion,
    macos_version: `Windows ${osVersion}`,
    chip_model: cpus[0]?.model?.trim() || process.arch,
    physical_memory_bytes: os.totalmem(),
    physical_memory_text: formatBytesCompact(os.totalmem()),
    logical_cores: cpus.length,
    hostname: os.hostname(),
    username: os.userInfo().username,
    // The Windows MVP deliberately binds localhost only.
    lan_ips: [],
    web_port: webPort,
    default_dagsc_dir: `${paths.dagscRoot}${path.sep}`,
    history_db_path: historyPath,
    history_db_size_bytes: historySize,
    metric_capabilities: capabilities,
    metric_semantics: WINDOWS_SEMANTICS,
    nvidia_smi_available: nvidiaAvailable,
    nvidia_gpus: nvidiaAvailable
      ? nvidia.gpus.map((gpu) => ({
        index: gpu.index,
        uuid: gpu.uuid,
        name: gpu.name,
        memory_total_bytes: gpu.memory_total_bytes,
        power_limit_watts: gpu.power_limit_watts,
        driver_version: gpu.driver_version,
      }))
      : [],
    clipto_install_path: paths.installRoot,
    clipto_data_path: paths.dataRoot,
    schedule_db_path: paths.scheduleDatabasePath,
    clipto_installed: paths.cliptoInstalled,
    schedule_db_exists: paths.scheduleDatabaseExists,
  };
}

export { WINDOWS_CAPABILITIES, WINDOWS_SEMANTICS };
