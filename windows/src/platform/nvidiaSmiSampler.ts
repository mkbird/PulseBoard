import { spawn } from "node:child_process";
import path from "node:path";

import type { NvidiaGPUReading } from "./types.js";

const MEBIBYTE = 1_048_576;
const QUERY_FIELDS = [
  "index",
  "uuid",
  "name",
  "utilization.gpu",
  "memory.used",
  "memory.total",
  "power.draw",
  "power.limit",
  "temperature.gpu",
  "driver_version",
].join(",");

export interface NvidiaSmiSnapshot {
  ts_ms: number;
  available: boolean;
  gpus: NvidiaGPUReading[];
  gpu_usage: number | null;
  memory_used_bytes: number | null;
  memory_total_bytes: number | null;
  power_draw_watts: number | null;
  power_limit_watts: number | null;
  temperature_c: number | null;
}

function finiteNumber(value: string): number | null {
  const trimmed = value.trim();
  if (!trimmed || /^(?:n\/a|not supported|\[not supported\])$/i.test(trimmed)) return null;
  const number = Number(trimmed);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function parseCSVLine(line: string): string[] {
  const values: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === "," && !quoted) {
      values.push(value.trim());
      value = "";
    } else {
      value += character;
    }
  }
  values.push(value.trim());
  return values;
}

/** Parses `nvidia-smi --format=csv,noheader,nounits` output. */
export function parseNvidiaSmiCSV(output: string): NvidiaGPUReading[] {
  const readings: NvidiaGPUReading[] = [];
  for (const line of output.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const fields = parseCSVLine(line);
    if (fields.length < 10) continue;
    const index = finiteNumber(fields[0] ?? "");
    if (index == null || !Number.isInteger(index)) continue;
    const memoryUsedMiB = finiteNumber(fields[4] ?? "");
    const memoryTotalMiB = finiteNumber(fields[5] ?? "");
    readings.push({
      index,
      uuid: fields[1] ?? "",
      name: fields[2] ?? "",
      utilization_percent: finiteNumber(fields[3] ?? ""),
      memory_used_bytes: memoryUsedMiB == null ? null : memoryUsedMiB * MEBIBYTE,
      memory_total_bytes: memoryTotalMiB == null ? null : memoryTotalMiB * MEBIBYTE,
      power_draw_watts: finiteNumber(fields[6] ?? ""),
      power_limit_watts: finiteNumber(fields[7] ?? ""),
      temperature_c: finiteNumber(fields[8] ?? ""),
      driver_version: fields[9] ?? "",
    });
  }
  return readings.sort((lhs, rhs) => lhs.index - rhs.index);
}

function sumAvailable(values: Array<number | null>): number | null {
  const available = values.filter((value): value is number => value != null && Number.isFinite(value));
  return available.length > 0 ? available.reduce((sum, value) => sum + value, 0) : null;
}

function maximumAvailable(values: Array<number | null>): number | null {
  const available = values.filter((value): value is number => value != null && Number.isFinite(value));
  return available.length > 0 ? Math.max(...available) : null;
}

/**
 * Multi-GPU semantics: utilization and temperature use the busiest/hottest GPU;
 * memory and board power are summed across all adapters.
 */
export function aggregateNvidiaGPUs(
  gpus: NvidiaGPUReading[],
  tsMs = Date.now(),
): NvidiaSmiSnapshot {
  return {
    ts_ms: tsMs,
    available: gpus.length > 0,
    gpus,
    gpu_usage: maximumAvailable(gpus.map((gpu) => gpu.utilization_percent)),
    memory_used_bytes: sumAvailable(gpus.map((gpu) => gpu.memory_used_bytes)),
    memory_total_bytes: sumAvailable(gpus.map((gpu) => gpu.memory_total_bytes)),
    power_draw_watts: sumAvailable(gpus.map((gpu) => gpu.power_draw_watts)),
    power_limit_watts: sumAvailable(gpus.map((gpu) => gpu.power_limit_watts)),
    temperature_c: maximumAvailable(gpus.map((gpu) => gpu.temperature_c)),
  };
}

function defaultExecutableCandidates(): string[] {
  const systemRoot = process.env.SystemRoot ?? "C:\\Windows";
  const programFiles = process.env.ProgramFiles ?? "C:\\Program Files";
  return [
    "nvidia-smi.exe",
    path.join(systemRoot, "System32", "nvidia-smi.exe"),
    path.join(programFiles, "NVIDIA Corporation", "NVSMI", "nvidia-smi.exe"),
  ];
}

function runNvidiaSmi(executable: string, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      executable,
      [`--query-gpu=${QUERY_FIELDS}`, "--format=csv,noheader,nounits"],
      { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] },
    );
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let settled = false;
    const finish = (callback: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback();
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(() => reject(new Error(`${executable} timed out after ${timeoutMs} ms`)));
    }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", (error) => finish(() => reject(error)));
    child.once("close", (code) => finish(() => {
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString("utf8"));
      } else {
        const detail = Buffer.concat(stderr).toString("utf8").trim();
        reject(new Error(`${executable} exited with code ${code ?? "unknown"}${detail ? `: ${detail}` : ""}`));
      }
    }));
  });
}

export async function queryNvidiaSmi(
  executableCandidates = defaultExecutableCandidates(),
  timeoutMs = 4_000,
): Promise<NvidiaSmiSnapshot> {
  let lastError: unknown;
  for (const executable of [...new Set(executableCandidates)]) {
    try {
      const output = await runNvidiaSmi(executable, timeoutMs);
      const readings = parseNvidiaSmiCSV(output);
      if (readings.length === 0) throw new Error(`${executable} returned no GPU rows`);
      return aggregateNvidiaGPUs(readings);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("nvidia-smi is unavailable");
}

/** Periodically samples NVIDIA hardware without keeping a console window open. */
export class NvidiaSmiSampler {
  readonly intervalMilliseconds: number;

  private timer: NodeJS.Timeout | null = null;
  private inFlight: Promise<void> | null = null;
  private stopped = true;
  private latestValue: NvidiaSmiSnapshot = aggregateNvidiaGPUs([], 0);
  private lastError = "";

  constructor(intervalMilliseconds = 1_000) {
    this.intervalMilliseconds = Math.max(500, intervalMilliseconds);
  }

  get latest(): NvidiaSmiSnapshot {
    return this.latestValue;
  }

  start(onWarning?: (message: string) => void): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.schedule(0, onWarning);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    await this.inFlight;
  }

  private schedule(delay: number, onWarning?: (message: string) => void): void {
    if (this.stopped) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      const work = this.poll(onWarning);
      this.inFlight = work;
      void work.finally(() => {
        if (this.inFlight === work) this.inFlight = null;
        this.schedule(this.intervalMilliseconds, onWarning);
      });
    }, delay);
  }

  private async poll(onWarning?: (message: string) => void): Promise<void> {
    try {
      this.latestValue = await queryNvidiaSmi();
      this.lastError = "";
    } catch (error) {
      this.latestValue = aggregateNvidiaGPUs([]);
      const message = error instanceof Error ? error.message : String(error);
      if (message !== this.lastError) onWarning?.(`NVIDIA telemetry unavailable: ${message}`);
      this.lastError = message;
    }
  }
}
