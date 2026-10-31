import assert from "node:assert/strict";
import test from "node:test";

import { reportCSVValues, REPORT_CSV_LABELS } from "../../src/report/csv.ts";

test("report CSV keeps RAM and NVIDIA VRAM as separate rows", () => {
  const values = reportCSVValues({
    environment: {
      platform: "windows",
      metric_capabilities: { system_gpu: true },
      metric_semantics: { gpu_memory: "NVIDIA 显存（VRAM）" },
    },
    scopes: { asset_analysis: {} },
    aligned_hardware: {
      has_data: true,
      gpu_memory_used_bytes: { max: 8 * 1_073_741_824 },
      gpu_memory_total_bytes: { max: 16 * 1_073_741_824 },
      cms_total_vram_bytes: { max: 4 * 1_073_741_824 },
      clipto_vram_bytes: { max: 6 * 1_073_741_824 },
      clipto_gpu_percent: { p95: 72 },
    },
  });

  assert.equal(values.length, REPORT_CSV_LABELS.length);
  const value = (label: string) => values[REPORT_CSV_LABELS.findIndex(row => row === label)];
  assert.equal(value("NVIDIA GPU 显存已用峰值 (VRAM GB)"), "8.00");
  assert.equal(value("NVIDIA GPU 显存总容量 (VRAM GB)"), "16.00");
  assert.equal(value("全 CMS 显存占用峰值 (VRAM GB)"), "4.00");
  assert.equal(value("Clipto 进程组显存占用峰值 (VRAM GB)"), "6.00");
  assert.equal(value("Clipto 进程组 GPU P95 (%)"), "72.0");
});
