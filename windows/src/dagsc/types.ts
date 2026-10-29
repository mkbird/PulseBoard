export interface DagscQueryOptions {
  inputPath?: string;
  sliceMode?: "auto" | "batch" | "custom" | "all" | string;
  batchID?: string;
  customFromMs?: number;
  customToMs?: number;
  batchGapMs?: number;
  ignoreBeforeMs?: number;
}

export interface ResolvedScheduleDatabase {
  dagscRoot: string;
  dbPath: string;
  defaultDagscDir: string;
  isDefaultDatabase: boolean;
}

export interface RawWorkflow {
  workflowID: string;
  templateID: string;
  templateVersion: string;
  assetID: string;
  statusText: string;
  createdAt: number;
  startedAt: number;
  finishedAt: number;
  analysisMode: string;
  filename: string;
  assetType: string;
  mediaDurationMs: number;
  fileSizeBytes: number;
}

export interface RawTask {
  taskID: string;
  workflowID: string;
  nodeID: string;
  nodeType: string;
  statusText: string;
  executorText: string;
  dispatchedAt: number;
  startedAt: number;
  finishedAt: number;
  effStart: number;
  effEnd: number;
  durationMs: number;
  zeroStartFixed: boolean;
  templateID: string;
  assetID: string;
  templateNodeID: string;
  errorJSON: string;
}

export interface DagscBatchSummary {
  batch_id: string;
  index: number;
  day: string;
  label: string;
  start_ms: number;
  end_ms: number;
  start_text: string;
  end_text: string;
  duration_ms: number;
  task_count: number;
  asset_count: number;
  video_count: number;
  image_count: number;
  total_media_duration_ms: number;
}

export interface ActiveSegment {
  index: number;
  wall_start_ms: number;
  wall_end_ms: number;
  wall_start_text: string;
  wall_end_text: string;
  virtual_start_ms: number;
  virtual_end_ms: number;
  duration_ms: number;
  gap_before_ms: number;
}

export interface ScopeMetrics extends Record<string, unknown> {
  total_tasks: number;
  wall_clock_ms: number;
  active_segments: ActiveSegment[];
}
