import { EventEmitter } from "node:events";
import path from "node:path";

import { WindowsHistoryStore, defaultWindowsHistoryPath } from "../history/historyStore.js";
import { WindowsProcessSampler } from "./processSampler.js";
import type {
  HistoryPayload,
  LiveCMSSession,
  LivePayload,
  LiveSample,
  SystemEnvironmentInfo,
  WindowsCliptoPaths,
} from "./types.js";
import { buildWindowsEnvironment, discoverWindowsCliptoPaths } from "./windowsEnvironment.js";

export interface WindowsTelemetryOptions {
  samplingIntervalMs?: number;
  retentionDays?: number;
  historyPath?: string;
  appDataDirectory?: string;
}

/** High-level facade consumed by the Windows HTTP server. */
export class WindowsTelemetryService extends EventEmitter {
  readonly samplingIntervalMs: number;
  readonly retentionDays: number;
  readonly paths: WindowsCliptoPaths;

  private readonly sampler: WindowsProcessSampler;
  private readonly history: WindowsHistoryStore;
  private started = false;
  private stopped = false;

  constructor(options: WindowsTelemetryOptions = {}) {
    super();
    this.samplingIntervalMs = Math.max(500, options.samplingIntervalMs ?? 1_000);
    this.retentionDays = Math.max(1, Math.min(365, options.retentionDays ?? 120));
    this.paths = discoverWindowsCliptoPaths();
    const historyPath = options.historyPath
      ?? (options.appDataDirectory ? path.join(options.appDataDirectory, "history.sqlite") : defaultWindowsHistoryPath());
    this.history = new WindowsHistoryStore(historyPath);
    this.sampler = new WindowsProcessSampler(this.samplingIntervalMs);
  }

  get historyPath(): string {
    return this.history.databasePath;
  }

  start(): void {
    if (this.started || this.stopped) return;
    this.started = true;
    this.sampler.on("sample", this.handleSample);
    this.sampler.on("warning", this.handleWarning);
    this.sampler.start();
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.sampler.off("sample", this.handleSample);
    this.sampler.off("warning", this.handleWarning);
    await this.sampler.stop();
    this.history.close();
  }

  getEnvironment(webPort: number): SystemEnvironmentInfo {
    return buildWindowsEnvironment(
      webPort,
      this.history.databasePath,
      this.paths,
      this.sampler.nvidiaSnapshot,
    );
  }

  getLivePayload(): LivePayload {
    return {
      ok: true,
      sampling_interval_sec: this.samplingIntervalMs / 1_000,
      retention_days: this.retentionDays,
      enhanced_available: this.sampler.nvidiaAvailable,
      latest: this.sampler.latestSample,
      cms: this.sampler.cmsSession,
    };
  }

  queryHistory(fromMs: number, toMs: number, maxPoints = 600): HistoryPayload {
    return this.history.queryHistory(fromMs, toMs, maxPoints);
  }

  exportSystemCSV(fromMs: number, toMs: number): string {
    return this.history.exportSystemCSV(fromMs, toMs);
  }

  exportCMSCSV(fromMs: number, toMs: number): string {
    return this.history.exportCMSCSV(fromMs, toMs);
  }

  private readonly handleSample = (sample: LiveSample, cms: LiveCMSSession): void => {
    try {
      this.history.append(sample, this.retentionDays);
      this.emit("sample", sample, cms);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.emit("warning", `Could not persist telemetry: ${message}`);
    }
  };

  private readonly handleWarning = (message: string): void => {
    this.emit("warning", message);
  };
}

export type {
  HistoryPayload,
  LiveCMSSession,
  LivePayload,
  LiveSample,
  SystemEnvironmentInfo,
  WindowsCliptoPaths,
} from "./types.js";
