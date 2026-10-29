import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

import { NvidiaSmiSampler } from "./nvidiaSmiSampler.js";
import type {
  LiveCMSSession,
  LiveCMSProcess,
  LiveMetricStatistics,
  LiveSample,
  ProcessFrame,
  ProcessReadingWithCPU,
} from "./types.js";

interface CPUTimes {
  idle: number;
  total: number;
}

interface MutableStatistics {
  current: number | null;
  peak: number | null;
  integral: number;
  validDuration: number;
}

interface CMSProcessEntry {
  pid: number;
  startTime: number;
  name: string;
  state: "running" | "exited" | "unavailable";
  cpu: MutableStatistics;
  memory: MutableStatistics;
}

function emptyStatistics(): MutableStatistics {
  return { current: null, peak: null, integral: 0, validDuration: 0 };
}

function recordStatistics(
  stats: MutableStatistics,
  current: number | null,
  duration: number,
): void {
  const valid = current != null && Number.isFinite(current) && current >= 0 ? current : null;
  stats.current = valid;
  if (valid != null) {
    stats.peak = Math.max(stats.peak ?? valid, valid);
    if (duration > 0) {
      stats.integral += valid * duration;
      stats.validDuration += duration;
    }
  }
}

function snapshotStatistics(stats: MutableStatistics): LiveMetricStatistics {
  return {
    current: stats.current,
    average: stats.validDuration > 0 ? stats.integral / stats.validDuration : null,
    peak: stats.peak,
    valid_duration_sec: stats.validDuration,
  };
}

function processKey(pid: number, startTime: number): string {
  return `${pid}:${startTime}`;
}

export function isCMSProcessName(name: string): boolean {
  const normalized = name.toLowerCase();
  return normalized === "cms" || normalized.startsWith("cms_") || normalized.startsWith("cms-");
}

function aggregateCPUTimes(): CPUTimes {
  let idle = 0;
  let total = 0;
  for (const cpu of os.cpus()) {
    idle += cpu.times.idle;
    total += cpu.times.user + cpu.times.nice + cpu.times.sys + cpu.times.idle + cpu.times.irq;
  }
  return { idle, total };
}

function readSystemDiskCapacity(): { free: number | null; total: number | null } {
  try {
    const root = `${process.env.SystemDrive ?? "C:"}${path.sep}`;
    const stats = fs.statfsSync(root);
    return {
      free: Number(stats.bavail) * Number(stats.bsize),
      total: Number(stats.blocks) * Number(stats.bsize),
    };
  } catch {
    return { free: null, total: null };
  }
}

function powershellScript(intervalMilliseconds: number): string {
  return String.raw`
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
while ($true) {
  try {
    $rows = @(
      Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $p = $_
        $n = ([string]$p.ProcessName).ToLowerInvariant()
        $wanted = ($n -eq 'clipto') -or ($n -eq 'cbs') -or ($n -eq 'cbs-worker') -or
          ($n -eq 'dag-schedule-center') -or ($n -eq 'clipto_ffmpeg') -or
          $n.StartsWith('cms_') -or $n.StartsWith('cms-')
        if ($wanted) {
          $start = $null
          $cpu = $null
          $working = $null
          $private = $null
          try { $start = ([DateTimeOffset]$p.StartTime).ToUnixTimeMilliseconds() } catch {}
          try { $cpu = [double]$p.CPU } catch {}
          try { $working = [double]$p.WorkingSet64 } catch {}
          try { $private = [double]$p.PrivateMemorySize64 } catch {}
          [ordered]@{
            pid = [int]$p.Id
            name = [string]$p.ProcessName
            start_time = $start
            cpu_seconds = $cpu
            working_set_bytes = $working
            private_memory_bytes = $private
          }
        }
      }
    )
    $payload = [ordered]@{
      ts_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      ok = $true
      processes = $rows
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 5 -Compress))
    [Console]::Out.Flush()
  } catch {
    $payload = [ordered]@{
      ts_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      ok = $false
      error = $_.Exception.Message
      processes = @()
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 3 -Compress))
    [Console]::Out.Flush()
  }
  Start-Sleep -Milliseconds ${Math.max(500, Math.round(intervalMilliseconds))}
}`;
}

function encodePowerShell(script: string): string {
  return Buffer.from(script, "utf16le").toString("base64");
}

/**
 * Samples Windows and the Clipto process family without WMI or elevation.
 * Process CPU is derived from cumulative Get-Process CPU seconds; one core is 100%.
 */
export class WindowsProcessSampler extends EventEmitter {
  readonly intervalMilliseconds: number;

  private child: ChildProcessWithoutNullStreams | null = null;
  private stopping = false;
  private restartTimer: NodeJS.Timeout | null = null;
  private previousFrame: ProcessFrame | null = null;
  private previousSystemCPU: CPUTimes = aggregateCPUTimes();
  private latestSampleValue: LiveSample | null = null;
  private readonly sessionStartedAtMs = Date.now();
  private readonly cmsEntries = new Map<string, CMSProcessEntry>();
  private readonly cmsCPU = emptyStatistics();
  private readonly cmsMemory = emptyStatistics();
  private cmsRunningCount = 0;
  private cmsComplete = false;
  private cmsSuspended = false;
  private readonly nvidiaSampler: NvidiaSmiSampler;

  constructor(intervalMilliseconds = 1_000) {
    super();
    this.intervalMilliseconds = Math.max(500, intervalMilliseconds);
    this.nvidiaSampler = new NvidiaSmiSampler(this.intervalMilliseconds);
  }

  get latestSample(): LiveSample | null {
    return this.latestSampleValue;
  }

  get cmsSession(): LiveCMSSession {
    const processes: LiveCMSProcess[] = [...this.cmsEntries.values()]
      .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name) || lhs.pid - rhs.pid)
      .map((entry) => ({
        pid: entry.pid,
        start_time: entry.startTime,
        name: entry.name,
        state: entry.state,
        cpu: snapshotStatistics(entry.cpu),
        memory: snapshotStatistics(entry.memory),
      }));
    return {
      started_at_ms: this.sessionStartedAtMs,
      started_at_text: new Date(this.sessionStartedAtMs).toLocaleString("zh-CN", { hour12: false }),
      running_count: this.cmsRunningCount,
      total_instances: processes.length,
      is_complete: this.cmsComplete,
      is_suspended: this.cmsSuspended,
      cpu: snapshotStatistics(this.cmsCPU),
      memory: snapshotStatistics(this.cmsMemory),
      processes,
    };
  }

  get nvidiaAvailable(): boolean {
    return this.nvidiaSampler.latest.available;
  }

  get nvidiaSnapshot() {
    return this.nvidiaSampler.latest;
  }

  start(): void {
    if (this.child || this.restartTimer) return;
    this.stopping = false;
    this.nvidiaSampler.start((message) => this.emit("warning", message));
    this.launchPowerShell();
  }

  async stop(): Promise<void> {
    this.stopping = true;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    const child = this.child;
    this.child = null;
    if (!child || child.killed) {
      await this.nvidiaSampler.stop();
      return;
    }

    await Promise.all([new Promise<void>((resolve) => {
      const timeout = setTimeout(resolve, 2_000);
      child.once("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
      child.kill();
    }), this.nvidiaSampler.stop()]);
  }

  private launchPowerShell(): void {
    const encoded = encodePowerShell(powershellScript(this.intervalMilliseconds));
    const child = spawn(
      "powershell.exe",
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
      { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] },
    );
    this.child = child;

    const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => this.handleLine(line));
    child.stderr.on("data", (chunk: Buffer) => {
      const message = chunk.toString("utf8").trim();
      if (message) this.emit("warning", message);
    });
    child.once("error", (error) => this.emit("warning", error.message));
    child.once("exit", (code) => {
      lines.close();
      if (this.child === child) this.child = null;
      if (!this.stopping) {
        this.cmsSuspended = true;
        this.cmsComplete = false;
        this.emit("warning", `PowerShell sampler exited (${code ?? "unknown"}); restarting.`);
        this.restartTimer = setTimeout(() => {
          this.restartTimer = null;
          if (!this.stopping) this.launchPowerShell();
        }, 1_000);
      }
    });
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;
    let frame: ProcessFrame;
    try {
      frame = JSON.parse(line) as ProcessFrame;
    } catch {
      this.emit("warning", `Could not parse process sampler output: ${line.slice(0, 160)}`);
      return;
    }
    if (!frame.ok) {
      this.cmsSuspended = true;
      this.cmsComplete = false;
      this.emit("warning", frame.error ?? "Windows process enumeration failed.");
      return;
    }
    frame.processes = (Array.isArray(frame.processes) ? frame.processes : [])
      .filter((reading) => Number.isInteger(reading?.pid) && typeof reading?.name === "string")
      .map((reading) => ({
        pid: reading.pid,
        name: reading.name,
        start_time: Number.isFinite(reading.start_time) ? reading.start_time : 0,
        cpu_seconds: Number.isFinite(reading.cpu_seconds) ? reading.cpu_seconds : null,
        working_set_bytes: Number.isFinite(reading.working_set_bytes) ? reading.working_set_bytes : null,
        private_memory_bytes: Number.isFinite(reading.private_memory_bytes) ? reading.private_memory_bytes : null,
      }));
    this.consumeFrame(frame);
  }

  private consumeFrame(frame: ProcessFrame): void {
    const before = this.previousFrame;
    const duration = before ? (frame.ts_ms - before.ts_ms) / 1_000 : 0;
    const validDuration = duration > 0 && duration <= 30 ? duration : 0;
    const previousByKey = new Map(
      (before?.processes ?? []).map((reading) => [processKey(reading.pid, reading.start_time), reading]),
    );
    const readings: ProcessReadingWithCPU[] = frame.processes.map((reading) => {
      const previous = previousByKey.get(processKey(reading.pid, reading.start_time));
      let cpuPercent: number | null = null;
      if (
        validDuration > 0
        && reading.cpu_seconds != null
        && previous?.cpu_seconds != null
        && reading.cpu_seconds >= previous.cpu_seconds
      ) {
        cpuPercent = ((reading.cpu_seconds - previous.cpu_seconds) / validDuration) * 100;
      }
      return { ...reading, cpu_percent: cpuPercent, is_cms: isCMSProcessName(reading.name) };
    });

    const cmsReadings = readings.filter((reading) => reading.is_cms);
    const sumAvailable = (
      values: Array<number | null>,
      emptyValue: number | null,
    ): number | null => {
      const available = values.filter((value): value is number => value != null && Number.isFinite(value));
      return available.length > 0 ? available.reduce((sum, value) => sum + value, 0) : emptyValue;
    };

    const cliptoCPU = sumAvailable(readings.map((reading) => reading.cpu_percent), readings.length === 0 ? 0 : null);
    const cliptoMemory = sumAvailable(
      readings.map((reading) => reading.working_set_bytes ?? reading.private_memory_bytes),
      readings.length === 0 ? 0 : null,
    );
    const cmsCPU = sumAvailable(cmsReadings.map((reading) => reading.cpu_percent), cmsReadings.length === 0 ? 0 : null);
    const cmsMemory = sumAvailable(
      cmsReadings.map((reading) => reading.working_set_bytes ?? reading.private_memory_bytes),
      cmsReadings.length === 0 ? 0 : null,
    );

    const currentCPU = aggregateCPUTimes();
    const cpuDelta = currentCPU.total - this.previousSystemCPU.total;
    const idleDelta = currentCPU.idle - this.previousSystemCPU.idle;
    const systemCPU = cpuDelta > 0 ? Math.max(0, Math.min(100, ((cpuDelta - idleDelta) / cpuDelta) * 100)) : 0;
    this.previousSystemCPU = currentCPU;

    const memoryTotal = os.totalmem();
    const memoryUsed = Math.max(0, memoryTotal - os.freemem());
    const disk = readSystemDiskCapacity();
    const nvidia = this.nvidiaSampler.latest;
    const nvidiaIsFresh = nvidia.available
      && Math.abs(frame.ts_ms - nvidia.ts_ms) <= Math.max(5_000, this.intervalMilliseconds * 3);
    const sample: LiveSample = {
      ts_ms: frame.ts_ms,
      cpu_usage: systemCPU,
      gpu_usage: nvidiaIsFresh ? nvidia.gpu_usage : null,
      gpu_memory_used_bytes: nvidiaIsFresh ? nvidia.memory_used_bytes : null,
      gpu_memory_total_bytes: nvidiaIsFresh ? nvidia.memory_total_bytes : null,
      gpu_power_limit_watts: nvidiaIsFresh ? nvidia.power_limit_watts : null,
      gpu_temperature_c: nvidiaIsFresh ? nvidia.temperature_c : null,
      nvidia_gpus: nvidiaIsFresh ? nvidia.gpus : [],
      ane_usage: null,
      memory_usage: memoryTotal > 0 ? (memoryUsed / memoryTotal) * 100 : 0,
      memory_used_bytes: memoryUsed,
      memory_total_bytes: memoryTotal,
      memory_pressure: memoryTotal > 0 ? (memoryUsed / memoryTotal) * 100 : 0,
      swap_used_bytes: null,
      swap_total_bytes: null,
      ane_power_watts: null,
      cpu_power_watts: null,
      gpu_power_watts: nvidiaIsFresh ? nvidia.power_draw_watts : null,
      system_power_watts: null,
      memory_read_gbps: null,
      memory_write_gbps: null,
      disk_read_bps: null,
      disk_write_bps: null,
      disk_free_bytes: disk.free,
      disk_total_bytes: disk.total,
      net_down_bps: null,
      net_up_bps: null,
      thermal_state: "unknown",
      clipto_running: readings.length > 0,
      clipto_cpu_percent: cliptoCPU,
      clipto_memory_bytes: cliptoMemory,
      clipto_disk_read_bps: null,
      clipto_disk_write_bps: null,
      clipto_process_count: readings.length,
      clipto_gpu_percent: null,
      cms_cpu_percent: cmsCPU,
      cms_memory_bytes: cmsMemory,
      cms_process_count: cmsReadings.length,
      process_readings: readings,
    };

    this.updateCMSSession(cmsReadings, cmsCPU, cmsMemory, validDuration);
    this.previousFrame = frame;
    this.latestSampleValue = sample;
    this.emit("sample", sample, this.cmsSession);
  }

  private updateCMSSession(
    readings: ProcessReadingWithCPU[],
    totalCPU: number | null,
    totalMemory: number | null,
    duration: number,
  ): void {
    const currentKeys = new Set(readings.map((reading) => processKey(reading.pid, reading.start_time)));
    for (const entry of this.cmsEntries.values()) {
      if (!currentKeys.has(processKey(entry.pid, entry.startTime))) {
        entry.state = "exited";
        recordStatistics(entry.cpu, 0, duration);
        recordStatistics(entry.memory, 0, duration);
      }
    }

    for (const reading of readings) {
      const key = processKey(reading.pid, reading.start_time);
      let entry = this.cmsEntries.get(key);
      if (!entry) {
        entry = {
          pid: reading.pid,
          startTime: reading.start_time,
          name: reading.name,
          state: "running",
          cpu: emptyStatistics(),
          memory: emptyStatistics(),
        };
        this.cmsEntries.set(key, entry);
      }
      entry.name = reading.name;
      entry.state = reading.cpu_percent == null && reading.working_set_bytes == null
        ? "unavailable"
        : "running";
      recordStatistics(entry.cpu, reading.cpu_percent, duration);
      recordStatistics(entry.memory, reading.working_set_bytes ?? reading.private_memory_bytes, duration);
    }

    recordStatistics(this.cmsCPU, totalCPU, duration);
    recordStatistics(this.cmsMemory, totalMemory, duration);
    this.cmsRunningCount = readings.length;
    this.cmsComplete = true;
    this.cmsSuspended = false;
  }
}
