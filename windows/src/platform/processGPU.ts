import type { ProcessGPUFrame } from "./types.js";

/** Sum a group's simultaneous allocations; shared system memory stays separate. */
export function aggregateProcessGPU(frame: ProcessGPUFrame | undefined, pids: number[]) {
  const wanted = new Set(pids);
  const memory = frame?.memory_ok ? frame.memory.filter(row => wanted.has(row.pid)) : [];
  const engines = new Map<string, number>();
  if (frame?.engines_ok) {
    for (const row of frame.engines) {
      if (!wanted.has(row.pid)) continue;
      // Group by physical adapter AND engine before taking the busiest engine.
      engines.set(row.engine, (engines.get(row.engine) ?? 0) + row.utilization_percent);
    }
  }
  return {
    dedicated_bytes: frame?.memory_ok ? memory.reduce((sum, row) => sum + row.dedicated_bytes, 0) : null,
    shared_bytes: frame?.memory_ok ? memory.reduce((sum, row) => sum + row.shared_bytes, 0) : null,
    gpu_percent: frame?.engines_ok ? Math.min(100, Math.max(0, ...engines.values())) : null,
  };
}

/** A persistent PowerShell host loads DXGI once to identify NVIDIA adapter LUIDs. */
export const GPU_INITIALIZE_POWERSHELL = String.raw`
$nvidiaLuids = @()
$ProgressPreference = 'SilentlyContinue'
$gpuInitializationError = ''
try {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CliptoNvidiaAdapters {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Desc {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public uint LuidLow;
    public int LuidHigh;
    public uint Flags;
  }
  [DllImport("dxgi.dll", ExactSpelling=true)]
  static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  delegate int EnumAdapter(IntPtr self, uint index, out IntPtr adapter);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  delegate int GetDesc(IntPtr self, out Desc desc);
  static T Method<T>(IntPtr obj, int slot) where T:class {
    var address = Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * IntPtr.Size);
    return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
  }
  public static string[] GetLuids() {
    var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IntPtr factory;
    Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref iid, out factory));
    var result = new List<string>();
    try {
      var enumerate = Method<EnumAdapter>(factory, 12);
      for (uint i=0; ; i++) {
        IntPtr adapter;
        int status = enumerate(factory, i, out adapter);
        if (status == unchecked((int)0x887a0002)) break;
        Marshal.ThrowExceptionForHR(status);
        try {
          Desc desc;
          Marshal.ThrowExceptionForHR(Method<GetDesc>(adapter, 10)(adapter, out desc));
          if (desc.VendorId == 0x10de)
            result.Add(String.Format("luid_0x{0:x8}_0x{1:x8}", unchecked((uint)desc.LuidHigh), desc.LuidLow));
        } finally { Marshal.Release(adapter); }
      }
    } finally { Marshal.Release(factory); }
    return result.ToArray();
  }
}
'@
  $nvidiaLuids = @([CliptoNvidiaAdapters]::GetLuids())
} catch { $gpuInitializationError = $_.Exception.Message }
`;

export const GPU_SAMPLE_POWERSHELL = String.raw`
    $gpuMemoryOK = $false
    $gpuEnginesOK = $false
    $gpuMemory = @()
    $gpuEngines = @()
    $gpuError = $gpuInitializationError
    if ($nvidiaLuids.Count -gt 0) {
      try {
        $gpuMemory = @(
          Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -OperationTimeoutSec 2 -ErrorAction Stop | ForEach-Object {
            if ($_.Name -match '^pid_(\d+)_(luid_0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)$' -and $nvidiaLuids -contains $Matches[2]) {
              [ordered]@{ pid=[int]$Matches[1]; dedicated_bytes=[double]$_.DedicatedUsage; shared_bytes=[double]$_.SharedUsage }
            }
          }
        )
        $gpuMemoryOK = $true
      } catch { $gpuError = $_.Exception.Message }
      try {
        $gpuEngines = @(
          Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -OperationTimeoutSec 2 -ErrorAction Stop | ForEach-Object {
            if ($_.Name -match '^pid_(\d+)_(luid_0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)_eng_(\d+)_engtype_.+$' -and $nvidiaLuids -contains $Matches[2]) {
              [ordered]@{ pid=[int]$Matches[1]; engine=([string]$_.Name -replace '^pid_\d+_', ''); utilization_percent=[double]$_.UtilizationPercentage }
            }
          }
        )
        $gpuEnginesOK = $true
      } catch { $gpuError = $_.Exception.Message }
    }
    $gpuFrame = [ordered]@{ memory_ok=$gpuMemoryOK; engines_ok=$gpuEnginesOK; adapter_luids=$nvidiaLuids; memory=$gpuMemory; engines=$gpuEngines; error=$gpuError }
`;
