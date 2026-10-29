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
    },
  });

  assert.equal(values.length, REPORT_CSV_LABELS.length);
  assert.equal(REPORT_CSV_LABELS.at(-3), "NVIDIA GPU 显存已用峰值 (VRAM GB)");
  assert.equal(values.at(-3), "8.00");
  assert.equal(values.at(-2), "16.00");
  assert.match(values.at(-1) ?? "", /VRAM/);
});
