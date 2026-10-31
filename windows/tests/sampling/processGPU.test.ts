import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";
import { aggregateProcessGPU, GPU_INITIALIZE_POWERSHELL, GPU_SAMPLE_POWERSHELL } from "../../src/platform/processGPU.ts";
import type { ProcessGPUFrame } from "../../src/platform/types.ts";

test("group GPU usage aggregates the same engine before selecting the busiest, keeping RAM separate", () => {
  const frame: ProcessGPUFrame = {
    memory_ok: true, engines_ok: true, adapter_luids: ["nvidia"],
    memory: [
      { pid: 1, dedicated_bytes: 300, shared_bytes: 20 },
      { pid: 2, dedicated_bytes: 500, shared_bytes: 40 },
      { pid: 99, dedicated_bytes: 10_000, shared_bytes: 100 },
    ],
    engines: [
      { pid: 1, engine: "gpu0_engine0", utilization_percent: 40 },
      { pid: 2, engine: "gpu0_engine0", utilization_percent: 30 },
      { pid: 2, engine: "gpu0_engine1", utilization_percent: 65 },
      { pid: 99, engine: "gpu0_engine0", utilization_percent: 10 },
    ],
  };
  assert.deepEqual(aggregateProcessGPU(frame, [1, 2]), { dedicated_bytes: 800, shared_bytes: 60, gpu_percent: 70 });
  assert.equal(aggregateProcessGPU(frame, [2]).dedicated_bytes, 500);
  assert.equal(aggregateProcessGPU(frame, [2]).gpu_percent, 65);
  assert.equal(aggregateProcessGPU(frame, []).dedicated_bytes, 0);
  assert.equal(aggregateProcessGPU(undefined, [1]).dedicated_bytes, null);
  assert.equal(aggregateProcessGPU({ ...frame, engines_ok: false }, [1]).gpu_percent, null);
});

test("DXGI adapter identification and WDDM counter collection execute on Windows", { skip: process.platform !== "win32", timeout: 30_000 }, () => {
  const source = "$ErrorActionPreference='Stop'\n" + GPU_INITIALIZE_POWERSHELL + GPU_SAMPLE_POWERSHELL +
    "\n$gpuFrame | ConvertTo-Json -Compress -Depth 5";
  const result = execFileSync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(source, "utf16le").toString("base64")], { encoding: "utf8", windowsHide: true, timeout: 25_000 });
  const frame = JSON.parse(result.trim()) as ProcessGPUFrame;
  assert.equal(frame.error, "", frame.error);
  assert.ok(Array.isArray(frame.adapter_luids));
  if (!frame.adapter_luids.length) return;
  assert.equal(frame.memory_ok, true);
  assert.equal(frame.engines_ok, true);
  assert.ok(frame.memory.every(row => row.dedicated_bytes >= 0 && row.shared_bytes >= 0));
  assert.ok(frame.engines.every(row => row.engine.includes("luid_") && row.utilization_percent >= 0));
});
