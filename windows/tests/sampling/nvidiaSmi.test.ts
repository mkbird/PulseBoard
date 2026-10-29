import assert from "node:assert/strict";
import test from "node:test";

import { aggregateNvidiaGPUs, parseNvidiaSmiCSV } from "../../src/platform/nvidiaSmiSampler.ts";
import { buildWindowsEnvironment, discoverWindowsCliptoPaths } from "../../src/platform/windowsEnvironment.ts";

test("nvidia-smi CSV parsing preserves missing values instead of inventing zeroes", () => {
  const readings = parseNvidiaSmiCSV([
    "0, GPU-a, NVIDIA GeForce RTX 5080, 13, 11166, 16303, 27.60, 360.00, 34, 610.88",
    '1, GPU-b, "NVIDIA, Test Adapter", N/A, 0, 24564, [Not Supported], 450.00, 51, 610.88',
  ].join("\r\n"));

  assert.equal(readings.length, 2);
  assert.equal(readings[0]?.utilization_percent, 13);
  assert.equal(readings[0]?.memory_used_bytes, 11_166 * 1_048_576);
  assert.equal(readings[1]?.name, "NVIDIA, Test Adapter");
  assert.equal(readings[1]?.utilization_percent, null);
  assert.equal(readings[1]?.power_draw_watts, null);
});

test("multi-GPU aggregation uses peak load and temperature plus summed memory and power", () => {
  const readings = parseNvidiaSmiCSV([
    "0, GPU-a, NVIDIA A, 80, 4000, 8000, 100, 200, 60, 610.88",
    "1, GPU-b, NVIDIA B, 20, 6000, 12000, 150, 300, 70, 610.88",
  ].join("\n"));
  const aggregate = aggregateNvidiaGPUs(readings, 1234);

  assert.equal(aggregate.available, true);
  assert.equal(aggregate.ts_ms, 1234);
  assert.equal(aggregate.gpu_usage, 80);
  assert.equal(aggregate.temperature_c, 70);
  assert.equal(aggregate.memory_used_bytes, 10_000 * 1_048_576);
  assert.equal(aggregate.memory_total_bytes, 20_000 * 1_048_576);
  assert.equal(aggregate.power_draw_watts, 250);
  assert.equal(aggregate.power_limit_watts, 500);
});

test("empty nvidia-smi output is unavailable with null metrics", () => {
  const aggregate = aggregateNvidiaGPUs([], 1234);
  assert.equal(aggregate.available, false);
  assert.equal(aggregate.gpu_usage, null);
  assert.equal(aggregate.power_draw_watts, null);
  assert.equal(aggregate.temperature_c, null);
});

test("Windows environment capabilities follow the latest nvidia-smi snapshot", () => {
  const paths = discoverWindowsCliptoPaths({ LOCALAPPDATA: "C:\\Temp" }, () => false);
  const readings = parseNvidiaSmiCSV(
    "0, GPU-a, NVIDIA A, 80, 4000, 8000, 100, 200, 60, 610.88",
  );
  const environment = buildWindowsEnvironment(
    8766,
    "C:\\Temp\\history.sqlite",
    paths,
    aggregateNvidiaGPUs(readings, 1234),
  );

  assert.equal(environment.nvidia_smi_available, true);
  assert.equal(environment.metric_capabilities.system_gpu, true);
  assert.equal(environment.metric_capabilities.power, true);
  assert.equal(environment.nvidia_gpus[0]?.name, "NVIDIA A");
  assert.equal(environment.nvidia_gpus[0]?.driver_version, "610.88");
});
