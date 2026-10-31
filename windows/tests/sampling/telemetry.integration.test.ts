import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { WindowsTelemetryService } from "../../src/platform/telemetryService.js";
import type { LiveSample } from "../../src/platform/types.js";
import { WindowsHistoryStore } from "../../src/history/historyStore.js";

test("Windows telemetry samples processes and persists history", { timeout: 15_000 }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "cliptopulse-windows-test-"));
  const historyPath = path.join(directory, "history.sqlite");
  const legacy = new DatabaseSync(historyPath);
  legacy.exec(`
    PRAGMA foreign_keys=ON;
    CREATE TABLE samples (
      ts_ms INTEGER PRIMARY KEY NOT NULL, sys_cpu REAL NOT NULL,
      sys_mem_bytes REAL NOT NULL, sys_mem_pct REAL NOT NULL,
      disk_free_bytes REAL, disk_total_bytes REAL, clipto_cpu REAL,
      clipto_mem_bytes REAL, clipto_process_count INTEGER NOT NULL,
      cms_cpu REAL, cms_mem_bytes REAL, cms_process_count INTEGER NOT NULL
    );
    CREATE TABLE process_samples (
      ts_ms INTEGER NOT NULL, pid INTEGER NOT NULL, start_time INTEGER NOT NULL,
      name TEXT NOT NULL, is_cms INTEGER NOT NULL, cpu_seconds REAL,
      cpu_percent REAL, working_set_bytes REAL, private_memory_bytes REAL,
      PRIMARY KEY(ts_ms,pid,start_time),
      FOREIGN KEY(ts_ms) REFERENCES samples(ts_ms) ON DELETE CASCADE
    ) WITHOUT ROWID;
  `);
  legacy.close();
  const telemetry = new WindowsTelemetryService({
    historyPath,
    samplingIntervalMs: 500,
    retentionDays: 1,
  });

  try {
    const sample = await new Promise<LiveSample>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Sampler did not emit within 10 seconds")), 10_000);
      telemetry.once("sample", (value: LiveSample) => {
        clearTimeout(timeout);
        resolve(value);
      });
      telemetry.start();
    });

    assert.equal(sample.memory_total_bytes > 0, true);
    assert.equal(sample.cpu_usage >= 0 && sample.cpu_usage <= 100, true);
    assert.equal(Array.isArray(sample.process_readings), true);
    assert.equal(fs.existsSync(historyPath), true);

    const history = telemetry.queryHistory(sample.ts_ms - 1_000, sample.ts_ms + 1_000, 10);
    assert.equal(history.ok, true);
    assert.equal(history.points.length >= 1, true);
    assert.equal(history.points[0]?.clipto_process_count, sample.clipto_process_count);
    assert.equal(history.points[0]?.sys_gpu, sample.gpu_usage);
    assert.equal(history.points[0]?.gpu_power, sample.gpu_power_watts);
    assert.equal(history.points[0]?.clipto_vram_bytes, sample.clipto_vram_bytes);
    assert.equal(history.points[0]?.cms_vram_bytes, sample.cms_vram_bytes);
    assert.equal(history.points[0]?.clipto_gpu, sample.clipto_gpu_percent);

    const metrics = new WindowsHistoryStore(path.join(directory, "metrics.sqlite"));
    try {
      const ts = sample.ts_ms;
      metrics.append({ ...sample, ts_ms: ts, clipto_vram_bytes: null, cms_vram_bytes: null, clipto_gpu_percent: null });
      metrics.append({ ...sample, ts_ms: ts + 1_000, clipto_vram_bytes: 900, cms_vram_bytes: 300, clipto_gpu_percent: 50 });
      metrics.append({ ...sample, ts_ms: ts + 2_000, clipto_vram_bytes: 800, cms_vram_bytes: 500, clipto_gpu_percent: 80 });
      const bucket = metrics.queryHistory(ts, ts + 3_000, 1);
      assert.equal(bucket.points[0]?.clipto_vram_bytes, 850);
      const exact = metrics.queryHeadlineMetrics(ts, ts + 2_000, []) as Record<string, any>;
      assert.equal(exact.clipto_vram_bytes.max, 900);
      assert.equal(exact.cms_total_vram_bytes.max, 500);
      assert.equal(exact.clipto_gpu_percent.p95, 80);
      assert.equal(exact.clipto_vram_bytes.count, 2);
      const earlier = metrics.queryHeadlineMetrics(ts, ts + 2_000, [[ts, ts + 1_000]]) as Record<string, any>;
      assert.equal(earlier.cms_total_vram_bytes.max, 300);
      const old = metrics.queryHeadlineMetrics(ts, ts, []) as Record<string, any>;
      assert.equal(old.clipto_vram_bytes.max, null);
      assert.equal(old.clipto_vram_bytes.count, 0);
    } finally {
      metrics.close();
    }
  } finally {
    await telemetry.stop();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
