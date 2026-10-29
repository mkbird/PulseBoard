import assert from "node:assert/strict";
import test from "node:test";

import { buildAlignedHardware } from "../../src/report/alignment.ts";

test("aligned report keeps NVIDIA board power separate from whole-system power", () => {
  const aligned = buildAlignedHardware([
    {
      ts_ms: 1_000,
      sys_cpu: 20,
      sys_gpu: 40,
      gpu_power: 10,
      gpu_memory_used_bytes: 4_000,
      gpu_temperature_c: 60,
    },
    {
      ts_ms: 2_000,
      sys_cpu: 30,
      sys_gpu: 80,
      gpu_power: 20,
      gpu_memory_used_bytes: 8_000,
      gpu_temperature_c: 70,
    },
  ], [[1_000, 2_000]], 1_000, 2_000);

  assert.equal(aligned.has_data, true);
  assert.equal(aligned.sys_gpu.avg, 60);
  assert.equal(aligned.gpu_power_watts.avg, 15);
  assert.equal(aligned.sys_power_watts.count, 0);
  assert.equal(aligned.gpu_temperature_c.max, 70);
  assert.ok(Math.abs(aligned.gpu_estimated_energy_wh - (15 / 3_600)) < 1e-9);
});
