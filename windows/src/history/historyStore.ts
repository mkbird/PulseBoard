import fs from "node:fs";
import path from "node:path";
import { DatabaseSync, type StatementSync } from "node:sqlite";

import type { HistoryPayload, HistoryPoint, LiveSample } from "../platform/types.js";

type SQLiteValue = string | number | bigint | null;
type SQLiteRow = Record<string, SQLiteValue>;

function finiteOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function numeric(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function csvCell(value: unknown): string {
  if (value == null) return "";
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export function defaultWindowsHistoryPath(): string {
  const localAppData = process.env.LOCALAPPDATA
    ?? path.join(process.env.USERPROFILE ?? process.cwd(), "AppData", "Local");
  return path.join(localAppData, "CliptoPulse", "history.sqlite");
}

/** SQLite-backed Windows telemetry history. All times are Unix milliseconds. */
export class WindowsHistoryStore {
  readonly databasePath: string;

  private readonly database: DatabaseSync;
  private readonly insertSample: StatementSync;
  private readonly insertProcess: StatementSync;
  private lastPruneMs = 0;

  constructor(databasePath = defaultWindowsHistoryPath()) {
    this.databasePath = databasePath;
    fs.mkdirSync(path.dirname(databasePath), { recursive: true });
    this.database = new DatabaseSync(databasePath, { timeout: 2_000 });
    this.database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000;");
    this.database.exec(SCHEMA);
    this.migrateSampleColumns();
    this.insertSample = this.database.prepare(`
      INSERT INTO samples (
        ts_ms,sys_cpu,sys_gpu,sys_mem_bytes,sys_mem_pct,disk_free_bytes,disk_total_bytes,
        gpu_power,gpu_power_limit,gpu_memory_used_bytes,gpu_memory_total_bytes,gpu_temperature_c,
        clipto_cpu,clipto_mem_bytes,clipto_process_count,cms_cpu,cms_mem_bytes,cms_process_count,
        clipto_gpu,clipto_vram_bytes,clipto_gpu_shared_bytes,cms_gpu,cms_vram_bytes,cms_gpu_shared_bytes
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(ts_ms) DO UPDATE SET
        sys_cpu=excluded.sys_cpu,
        sys_gpu=excluded.sys_gpu,
        sys_mem_bytes=excluded.sys_mem_bytes,
        sys_mem_pct=excluded.sys_mem_pct,
        disk_free_bytes=excluded.disk_free_bytes,
        disk_total_bytes=excluded.disk_total_bytes,
        gpu_power=excluded.gpu_power,
        gpu_power_limit=excluded.gpu_power_limit,
        gpu_memory_used_bytes=excluded.gpu_memory_used_bytes,
        gpu_memory_total_bytes=excluded.gpu_memory_total_bytes,
        gpu_temperature_c=excluded.gpu_temperature_c,
        clipto_cpu=excluded.clipto_cpu,
        clipto_mem_bytes=excluded.clipto_mem_bytes,
        clipto_process_count=excluded.clipto_process_count,
        cms_cpu=excluded.cms_cpu,
        cms_mem_bytes=excluded.cms_mem_bytes,
        cms_process_count=excluded.cms_process_count,
        clipto_gpu=excluded.clipto_gpu,clipto_vram_bytes=excluded.clipto_vram_bytes,
        clipto_gpu_shared_bytes=excluded.clipto_gpu_shared_bytes,cms_gpu=excluded.cms_gpu,
        cms_vram_bytes=excluded.cms_vram_bytes,cms_gpu_shared_bytes=excluded.cms_gpu_shared_bytes;
    `);
    this.insertProcess = this.database.prepare(`
      INSERT INTO process_samples (
        ts_ms,pid,start_time,name,is_cms,cpu_seconds,cpu_percent,working_set_bytes,private_memory_bytes,
        gpu_percent,vram_bytes,gpu_shared_bytes
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(ts_ms,pid,start_time) DO UPDATE SET
        name=excluded.name,
        is_cms=excluded.is_cms,
        cpu_seconds=excluded.cpu_seconds,
        cpu_percent=excluded.cpu_percent,
        working_set_bytes=excluded.working_set_bytes,
        private_memory_bytes=excluded.private_memory_bytes,
        gpu_percent=excluded.gpu_percent,vram_bytes=excluded.vram_bytes,gpu_shared_bytes=excluded.gpu_shared_bytes;
    `);
  }

  append(sample: LiveSample, retentionDays = 120): void {
    this.database.exec("BEGIN IMMEDIATE;");
    try {
      this.insertSample.run(
        sample.ts_ms,
        sample.cpu_usage,
        sample.gpu_usage,
        sample.memory_used_bytes,
        sample.memory_usage,
        sample.disk_free_bytes,
        sample.disk_total_bytes,
        sample.gpu_power_watts,
        sample.gpu_power_limit_watts,
        sample.gpu_memory_used_bytes,
        sample.gpu_memory_total_bytes,
        sample.gpu_temperature_c,
        sample.clipto_cpu_percent,
        sample.clipto_memory_bytes,
        sample.clipto_process_count,
        sample.cms_cpu_percent,
        sample.cms_memory_bytes,
        sample.cms_process_count,
        sample.clipto_gpu_percent,
        sample.clipto_vram_bytes,
        sample.clipto_gpu_shared_bytes,
        sample.cms_gpu_percent,
        sample.cms_vram_bytes,
        sample.cms_gpu_shared_bytes,
      );
      for (const reading of sample.process_readings) {
        this.insertProcess.run(
          sample.ts_ms,
          reading.pid,
          reading.start_time,
          reading.name,
          reading.is_cms ? 1 : 0,
          reading.cpu_seconds,
          reading.cpu_percent,
          reading.working_set_bytes,
          reading.private_memory_bytes,
          reading.gpu_percent,
          reading.vram_bytes,
          reading.gpu_shared_bytes,
        );
      }
      this.database.exec("COMMIT;");
    } catch (error) {
      try { this.database.exec("ROLLBACK;"); } catch { /* preserve original error */ }
      throw error;
    }

    if (sample.ts_ms - this.lastPruneMs >= 60 * 60 * 1_000) {
      this.prune(sample.ts_ms - Math.max(1, retentionDays) * 86_400_000);
      this.lastPruneMs = sample.ts_ms;
    }
  }

  prune(beforeMs: number): void {
    this.database.prepare("DELETE FROM samples WHERE ts_ms < ?;").run(beforeMs);
    // process_samples rows are removed by ON DELETE CASCADE.
    this.database.exec("PRAGMA wal_checkpoint(PASSIVE);");
  }

  queryHistory(fromMs: number, toMs: number, maxPoints = 600): HistoryPayload {
    const safeFrom = Math.floor(Math.min(fromMs, toMs));
    const safeTo = Math.ceil(Math.max(fromMs + 1, toMs));
    const pointLimit = Math.max(1, Math.min(10_000, Math.floor(maxPoints)));
    const bucketMs = Math.max(1, Math.ceil((safeTo - safeFrom) / pointLimit));
    const statement = this.database.prepare(`
      SELECT
        MIN(ts_ms) AS ts_ms,
        AVG(sys_cpu) AS sys_cpu,
        AVG(sys_gpu) AS sys_gpu,
        AVG(sys_mem_bytes) AS sys_mem_bytes,
        AVG(sys_mem_pct) AS sys_mem_pct,
        AVG(gpu_power) AS gpu_power,
        AVG(gpu_power_limit) AS gpu_power_limit,
        AVG(gpu_memory_used_bytes) AS gpu_memory_used_bytes,
        AVG(gpu_memory_total_bytes) AS gpu_memory_total_bytes,
        MAX(gpu_temperature_c) AS gpu_temperature_c,
        AVG(clipto_cpu) AS clipto_cpu,
        AVG(clipto_mem_bytes) AS clipto_mem_bytes,
        AVG(clipto_gpu) AS clipto_gpu,
        AVG(clipto_vram_bytes) AS clipto_vram_bytes,
        AVG(clipto_gpu_shared_bytes) AS clipto_gpu_shared_bytes,
        MAX(clipto_process_count) AS clipto_process_count,
        AVG(cms_cpu) AS cms_cpu,
        AVG(cms_mem_bytes) AS cms_mem_bytes,
        AVG(cms_gpu) AS cms_gpu,
        AVG(cms_vram_bytes) AS cms_vram_bytes,
        AVG(cms_gpu_shared_bytes) AS cms_gpu_shared_bytes,
        MAX(cms_process_count) AS cms_process_count
      FROM samples
      WHERE ts_ms BETWEEN ? AND ?
      GROUP BY CAST((ts_ms - ?) / ? AS INTEGER)
      ORDER BY ts_ms;
    `);
    const rows = statement.all(safeFrom, safeTo, safeFrom, bucketMs) as SQLiteRow[];
    return {
      ok: true,
      from_ms: safeFrom,
      to_ms: safeTo,
      points: rows.map(historyPoint),
    };
  }

  /** Headline statistics use original simultaneous samples, never chart bucket averages. */
  queryHeadlineMetrics(fromMs: number, toMs: number, intervals: Array<[number, number]>): Record<string, unknown> {
    const windows = intervals.length ? intervals : [[fromMs, toMs]];
    const where = `ts_ms BETWEEN ? AND ? AND (${windows.map(() => "ts_ms BETWEEN ? AND ?").join(" OR ")})`;
    const args = [fromMs, toMs, ...windows.flat()];
    const fields: Record<string, string> = {
      clipto_cpu_percent: "clipto_cpu", clipto_gpu_percent: "clipto_gpu",
      clipto_memory_bytes: "clipto_mem_bytes", cms_total_memory_bytes: "cms_mem_bytes",
      clipto_vram_bytes: "clipto_vram_bytes", cms_total_vram_bytes: "cms_vram_bytes",
      cms_total_gpu_percent: "cms_gpu",
    };
    const result: Record<string, unknown> = {};
    for (const [key, column] of Object.entries(fields)) {
      const stats = this.database.prepare(`SELECT AVG(${column}) AS avg, MAX(${column}) AS max,
        MIN(${column}) AS min, COUNT(${column}) AS count FROM samples WHERE ${where}`).get(...args) as SQLiteRow;
      const count = numeric(stats.count);
      const percentile = count ? this.database.prepare(`SELECT ${column} AS value FROM samples
        WHERE ${where} AND ${column} IS NOT NULL ORDER BY ${column} LIMIT 1 OFFSET ?`)
        .get(...args, Math.max(0, Math.ceil(count * 0.95) - 1)) as SQLiteRow : undefined;
      result[key] = { avg: stats.avg, max: stats.max, min: stats.min, count, p95: percentile?.value ?? null };
    }
    return result;
  }

  exportSystemCSV(fromMs: number, toMs: number): string {
    const rows = this.database.prepare(`
      SELECT * FROM samples WHERE ts_ms BETWEEN ? AND ? ORDER BY ts_ms;
    `).all(Math.floor(fromMs), Math.ceil(toMs)) as SQLiteRow[];
    const header = [
      "timestamp_ms", "timestamp_iso", "cpu_percent", "gpu_percent", "memory_used_bytes", "memory_percent",
      "disk_free_bytes", "disk_total_bytes", "gpu_power_watts", "gpu_power_limit_watts",
      "gpu_memory_used_bytes", "gpu_memory_total_bytes", "gpu_temperature_c",
      "clipto_cpu_percent", "clipto_memory_bytes",
      "clipto_process_count", "cms_cpu_percent", "cms_memory_bytes", "cms_process_count",
      "clipto_gpu_percent", "clipto_vram_bytes", "clipto_gpu_shared_bytes",
      "cms_gpu_percent", "cms_vram_bytes", "cms_gpu_shared_bytes",
    ];
    const output = [header.join(",")];
    for (const row of rows) {
      const ts = numeric(row.ts_ms);
      output.push([
        ts, new Date(ts).toISOString(), row.sys_cpu, row.sys_gpu, row.sys_mem_bytes, row.sys_mem_pct,
        row.disk_free_bytes, row.disk_total_bytes, row.gpu_power, row.gpu_power_limit,
        row.gpu_memory_used_bytes, row.gpu_memory_total_bytes, row.gpu_temperature_c,
        row.clipto_cpu, row.clipto_mem_bytes,
        row.clipto_process_count, row.cms_cpu, row.cms_mem_bytes, row.cms_process_count,
        row.clipto_gpu, row.clipto_vram_bytes, row.clipto_gpu_shared_bytes,
        row.cms_gpu, row.cms_vram_bytes, row.cms_gpu_shared_bytes,
      ].map(csvCell).join(","));
    }
    return `\uFEFF${output.join("\r\n")}\r\n`;
  }

  exportCMSCSV(fromMs: number, toMs: number): string {
    const rows = this.database.prepare(`
      SELECT ts_ms,pid,start_time,name,cpu_seconds,cpu_percent,working_set_bytes,private_memory_bytes,
        gpu_percent,vram_bytes,gpu_shared_bytes
      FROM process_samples
      WHERE is_cms=1 AND ts_ms BETWEEN ? AND ?
      ORDER BY ts_ms,name,pid,start_time;
    `).all(Math.floor(fromMs), Math.ceil(toMs)) as SQLiteRow[];
    const header = [
      "timestamp_ms", "timestamp_iso", "pid", "start_time_ms", "name", "cpu_seconds",
      "cpu_percent", "working_set_bytes", "private_memory_bytes",
      "gpu_percent", "vram_bytes", "gpu_shared_bytes",
    ];
    const output = [header.join(",")];
    for (const row of rows) {
      const ts = numeric(row.ts_ms);
      output.push([
        ts, new Date(ts).toISOString(), row.pid, row.start_time, row.name, row.cpu_seconds,
        row.cpu_percent, row.working_set_bytes, row.private_memory_bytes,
        row.gpu_percent, row.vram_bytes, row.gpu_shared_bytes,
      ].map(csvCell).join(","));
    }
    return `\uFEFF${output.join("\r\n")}\r\n`;
  }

  close(): void {
    this.database.close();
  }

  /** Adds NVIDIA columns to databases created by earlier Windows builds. */
  private migrateSampleColumns(): void {
    const rows = this.database.prepare("PRAGMA table_info(samples);").all() as SQLiteRow[];
    const existing = new Set(rows.map((row) => String(row.name)));
    const columns: Record<string, string> = {
      sys_gpu: "REAL",
      gpu_power: "REAL",
      gpu_power_limit: "REAL",
      gpu_memory_used_bytes: "REAL",
      gpu_memory_total_bytes: "REAL",
      gpu_temperature_c: "REAL",
      clipto_gpu: "REAL", clipto_vram_bytes: "REAL", clipto_gpu_shared_bytes: "REAL",
      cms_gpu: "REAL", cms_vram_bytes: "REAL", cms_gpu_shared_bytes: "REAL",
    };
    for (const [name, declaration] of Object.entries(columns)) {
      if (!existing.has(name)) this.database.exec(`ALTER TABLE samples ADD COLUMN ${name} ${declaration};`);
    }
    const processColumns = new Set((this.database.prepare("PRAGMA table_info(process_samples)").all() as SQLiteRow[]).map(row => String(row.name)));
    for (const name of ["gpu_percent", "vram_bytes", "gpu_shared_bytes"]) {
      if (!processColumns.has(name)) this.database.exec(`ALTER TABLE process_samples ADD COLUMN ${name} REAL;`);
    }
  }
}

function historyPoint(row: SQLiteRow): HistoryPoint {
  const cliptoMemory = finiteOrNull(row.clipto_mem_bytes);
  const cmsMemory = finiteOrNull(row.cms_mem_bytes);
  return {
    ts_ms: numeric(row.ts_ms),
    sys_cpu: numeric(row.sys_cpu),
    sys_gpu: finiteOrNull(row.sys_gpu),
    gpu_memory_used_bytes: finiteOrNull(row.gpu_memory_used_bytes),
    gpu_memory_total_bytes: finiteOrNull(row.gpu_memory_total_bytes),
    gpu_power_limit_watts: finiteOrNull(row.gpu_power_limit),
    gpu_temperature_c: finiteOrNull(row.gpu_temperature_c),
    ane_usage: null,
    sys_mem_bytes: numeric(row.sys_mem_bytes),
    sys_mem_pct: numeric(row.sys_mem_pct),
    swap_used_bytes: null,
    clipto_cpu: finiteOrNull(row.clipto_cpu),
    clipto_mem_bytes: cliptoMemory,
    clipto_non_cms_mem_bytes: cliptoMemory == null
      ? null
      : Math.max(0, cliptoMemory - (cmsMemory ?? 0)),
    clipto_process_count: numeric(row.clipto_process_count),
    clipto_gpu: finiteOrNull(row.clipto_gpu),
    clipto_vram_bytes: finiteOrNull(row.clipto_vram_bytes),
    clipto_gpu_shared_bytes: finiteOrNull(row.clipto_gpu_shared_bytes),
    clipto_disk_read: null,
    clipto_disk_write: null,
    cms_cpu: finiteOrNull(row.cms_cpu),
    cms_mem_bytes: cmsMemory,
    cms_process_count: numeric(row.cms_process_count),
    cms_gpu: finiteOrNull(row.cms_gpu),
    cms_vram_bytes: finiteOrNull(row.cms_vram_bytes),
    cms_gpu_shared_bytes: finiteOrNull(row.cms_gpu_shared_bytes),
    sys_power: null,
    cpu_power: null,
    gpu_power: finiteOrNull(row.gpu_power),
    ane_power: null,
    dram_read_gbps: null,
    dram_write_gbps: null,
    disk_read_bps: null,
    disk_write_bps: null,
    net_down_bps: null,
    net_up_bps: null,
    thermal: "unknown",
  };
}

const SCHEMA = `
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS samples (
  ts_ms INTEGER PRIMARY KEY NOT NULL,
  sys_cpu REAL NOT NULL,
  sys_gpu REAL,
  sys_mem_bytes REAL NOT NULL,
  sys_mem_pct REAL NOT NULL,
  disk_free_bytes REAL,
  disk_total_bytes REAL,
  gpu_power REAL,
  gpu_power_limit REAL,
  gpu_memory_used_bytes REAL,
  gpu_memory_total_bytes REAL,
  gpu_temperature_c REAL,
  clipto_cpu REAL,
  clipto_mem_bytes REAL,
  clipto_process_count INTEGER NOT NULL,
  cms_cpu REAL,
  cms_mem_bytes REAL,
  cms_process_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS process_samples (
  ts_ms INTEGER NOT NULL,
  pid INTEGER NOT NULL,
  start_time INTEGER NOT NULL,
  name TEXT NOT NULL,
  is_cms INTEGER NOT NULL,
  cpu_seconds REAL,
  cpu_percent REAL,
  working_set_bytes REAL,
  private_memory_bytes REAL,
  PRIMARY KEY(ts_ms,pid,start_time),
  FOREIGN KEY(ts_ms) REFERENCES samples(ts_ms) ON DELETE CASCADE
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS samples_timestamp ON samples(ts_ms);
CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(ts_ms);
CREATE INDEX IF NOT EXISTS process_samples_identity ON process_samples(pid,start_time,ts_ms);
`;
