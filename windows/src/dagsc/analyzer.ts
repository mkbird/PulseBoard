import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { basename, dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { backup, DatabaseSync } from "node:sqlite";

import type {
  ActiveSegment,
  DagscBatchSummary,
  DagscQueryOptions,
  RawTask,
  RawWorkflow,
  ResolvedScheduleDatabase,
  ScopeMetrics,
} from "./types.js";

type SQLiteValue = string | number | bigint | null;
type SQLiteRow = Record<string, SQLiteValue>;
type Interval = [number, number];

export class DagscError extends Error {
  readonly code: string;

  constructor(message: string, code = "DAGSC_ERROR") {
    super(message);
    this.name = "DagscError";
    this.code = code;
  }
}

function defaultDagscDirectory(): string {
  const local = process.env.LOCALAPPDATA || join(process.env.USERPROFILE || "", "AppData", "Local");
  return join(local, "Clipto", "dagsc_data");
}

function comparablePath(value: string): string {
  return normalize(resolve(value)).replace(/[\\/]+$/, "").toLocaleLowerCase("en-US");
}

export function resolveScheduleDatabase(inputPath = ""): ResolvedScheduleDatabase {
  const defaultDagscDir = defaultDagscDirectory();
  let raw = inputPath.trim();
  while (raw.length >= 2 && ((raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'")))) {
    raw = raw.slice(1, -1).trim();
  }
  if (raw.toLowerCase().startsWith("file://")) {
    try {
      raw = fileURLToPath(raw);
    } catch {
      throw new DagscError(`无效的数据库 URL：${raw}`, "INVALID_PATH");
    }
  }

  const target = resolve(raw || defaultDagscDir);
  if (!existsSync(target)) {
    throw new DagscError(`路径不存在：${target}`, "PATH_NOT_FOUND");
  }
  const info = statSync(target);
  let dagscRoot: string;
  let dbPath: string;

  if (info.isFile()) {
    const suffix = extname(target).toLowerCase();
    if (![".db", ".sqlite", ".sqlite3"].includes(suffix)) {
      throw new DagscError(`指定的文件不是数据库文件：${target}`, "INVALID_DATABASE_FILE");
    }
    dbPath = target;
    const parent = dirname(target);
    dagscRoot = basename(parent).toLowerCase() === "data" ? dirname(parent) : parent;
  } else {
    const candidates = [
      join(target, "data", "schedule.db"),
      join(target, "schedule.db"),
      join(target, "dagsc_data", "data", "schedule.db"),
    ];
    dbPath = candidates.find((candidate) => existsSync(candidate) && statSync(candidate).isFile()) || "";
    if (!dbPath) {
      throw new DagscError(
        `在目录 ${target} 下未找到 data\\schedule.db 或 schedule.db，请确认路径是否正确。`,
        "SCHEDULE_DB_NOT_FOUND",
      );
    }
    const parent = dirname(dbPath);
    dagscRoot = basename(parent).toLowerCase() === "data" ? dirname(parent) : parent;
  }

  return {
    dagscRoot,
    dbPath,
    defaultDagscDir,
    isDefaultDatabase: comparablePath(dagscRoot) === comparablePath(defaultDagscDir),
  };
}

function text(value: SQLiteValue | undefined): string {
  if (value === null || value === undefined) return "";
  return String(value);
}

function integer(value: unknown): number {
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "number") return Number.isFinite(value) ? Math.trunc(value) : 0;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : 0;
  }
  return 0;
}

function parseObject(raw: string): Record<string, unknown> | undefined {
  if (!raw) return undefined;
  try {
    const value: unknown = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value as Record<string, unknown>
      : undefined;
  } catch {
    return undefined;
  }
}

function loadWorkflows(db: DatabaseSync): RawWorkflow[] {
  const rows = db.prepare(`
    SELECT workflow_id, template_id, template_version, asset_id, status_text,
           created_at, started_at, finished_at, analysis_mode,
           asset_metadata, context_json
    FROM v_workflows
    ORDER BY created_at ASC;
  `).all() as SQLiteRow[];

  return rows.map((row) => {
    const workflowID = text(row.workflow_id);
    const templateID = text(row.template_id);
    const assetID = text(row.asset_id);
    const metadata = parseObject(text(row.asset_metadata));
    const context = parseObject(text(row.context_json));
    let filename = assetID ? `Asset #${assetID}` : "";
    let mediaDurationMs = 0;
    let fileSizeBytes = 0;
    let assetType = "unknown";
    if (templateID === "clipto_asset_analysis" && assetID) {
      if (typeof metadata?.filename === "string" && metadata.filename) filename = metadata.filename;
      mediaDurationMs = integer(context?.duration);
      fileSizeBytes = integer(context?.file_size_bytes);
      assetType = typeof context?.asset_type === "string" && context.asset_type
        ? context.asset_type
        : mediaDurationMs > 0 ? "video" : "unknown";
    }
    return {
      workflowID,
      templateID,
      templateVersion: text(row.template_version),
      assetID,
      statusText: text(row.status_text),
      createdAt: integer(row.created_at),
      startedAt: integer(row.started_at),
      finishedAt: integer(row.finished_at),
      analysisMode: text(row.analysis_mode),
      filename,
      assetType,
      mediaDurationMs,
      fileSizeBytes,
    };
  });
}

function loadTasks(db: DatabaseSync, workflowsByID: Map<string, RawWorkflow>): RawTask[] {
  const rows = db.prepare(`
    SELECT
      t.task_id, t.workflow_id, t.node_id, t.node_type, t.status_text, t.executor_text,
      t.dispatched_at, t.started_at, t.finished_at, w.template_id, w.asset_id,
      n.template_node_id, t.error_json
    FROM v_tasks t
    LEFT JOIN workflows w ON t.workflow_id = w.workflow_id
    LEFT JOIN nodes n ON t.workflow_id = n.workflow_id AND t.node_id = n.node_id;
  `).all() as SQLiteRow[];

  return rows.map((row) => {
    const workflowID = text(row.workflow_id);
    const startedAt = integer(row.started_at);
    const dispatchedAt = integer(row.dispatched_at);
    const finishedAt = integer(row.finished_at);
    const effStart = startedAt > 0 ? startedAt : dispatchedAt > 0 ? dispatchedAt : 0;
    const effEnd = Math.max(effStart, finishedAt);
    const workflow = workflowsByID.get(workflowID);
    const nodeType = text(row.node_type);
    return {
      taskID: text(row.task_id),
      workflowID,
      nodeID: text(row.node_id),
      nodeType,
      statusText: text(row.status_text),
      executorText: text(row.executor_text),
      dispatchedAt,
      startedAt,
      finishedAt,
      effStart,
      effEnd,
      durationMs: finishedAt > 0 && effStart > 0 && finishedAt >= effStart ? finishedAt - effStart : 0,
      zeroStartFixed: startedAt <= 0 && dispatchedAt > 0,
      templateID: text(row.template_id) || workflow?.templateID || "",
      assetID: text(row.asset_id) || workflow?.assetID || "",
      templateNodeID: text(row.template_node_id) || nodeType,
      errorJSON: text(row.error_json),
    };
  });
}

function loadTemplateVersion(db: DatabaseSync): string {
  try {
    const row = db.prepare(`
      SELECT template_version FROM workflow_templates
      WHERE template_id='clipto_asset_analysis'
      ORDER BY loaded_at DESC LIMIT 1;
    `).get() as SQLiteRow | undefined;
    const version = text(row?.template_version);
    return version ? `v${version}` : "";
  } catch {
    return "";
  }
}

function pad(value: number, width = 2): string {
  return String(value).padStart(width, "0");
}

export function formatTimestampMs(ms: number): string {
  if (!(ms > 0)) return "—";
  const date = new Date(ms);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

function formatNowSecond(): string {
  const date = new Date();
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function formatDayLocal(ms: number): string {
  if (!(ms > 0)) return "未知日期";
  const date = new Date(ms);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function formatTimeOnlyLocal(ms: number): string {
  if (!(ms > 0)) return "—";
  const date = new Date(ms);
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function detectCliptoVersion(dagscRoot: string): string {
  const local = process.env.LOCALAPPDATA || "";
  const candidates = [
    join(dirname(dagscRoot), "logs", "main.log"),
    join(dagscRoot, "logs", "main.log"),
    join(local, "Clipto", "logs", "main.log"),
  ];
  const pattern = /version:\s*['"](\d+\.\d+\.\d+[^'"]*)['"]/g;
  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue;
    try {
      const data = readFileSync(candidate);
      const tail = data.subarray(Math.max(0, data.length - 1024 * 1024)).toString("utf8");
      const matches = [...tail.matchAll(pattern)];
      const version = matches.at(-1)?.[1]?.trim();
      if (version) return `v${version}`;
    } catch {
      // Version detection must never block analysis.
    }
  }
  return "未知版本";
}

function discoverBatches(workflows: RawWorkflow[], tasks: RawTask[], batchGapMs: number): DagscBatchSummary[] {
  const workflowsByID = new Map(workflows.map((workflow) => [workflow.workflowID, workflow]));
  const validTasks = tasks.filter((task) => task.effStart > 0).sort((a, b) => a.effStart - b.effStart);
  const clusters: Array<{ startMs: number; endMs: number; taskCount: number; workflowIDs: Set<string> }> = [];
  for (const task of validTasks) {
    const start = task.effStart;
    const end = Math.max(start, task.effEnd);
    const last = clusters.at(-1);
    if (last && start - last.endMs <= batchGapMs) {
      last.endMs = Math.max(last.endMs, end);
      last.taskCount += 1;
      if (task.workflowID) last.workflowIDs.add(task.workflowID);
    } else {
      clusters.push({
        startMs: start,
        endMs: end,
        taskCount: 1,
        workflowIDs: new Set(task.workflowID ? [task.workflowID] : []),
      });
    }
  }

  return clusters.map((cluster, index) => {
    let assetCount = 0;
    let videoCount = 0;
    let imageCount = 0;
    let totalMediaDurationMs = 0;
    for (const workflowID of cluster.workflowIDs) {
      const workflow = workflowsByID.get(workflowID);
      if (!workflow || workflow.templateID !== "clipto_asset_analysis" || !workflow.assetID) continue;
      assetCount += 1;
      totalMediaDurationMs += workflow.mediaDurationMs;
      if (workflow.assetType === "image" || workflow.mediaDurationMs === 0) imageCount += 1;
      else videoCount += 1;
    }
    const day = formatDayLocal(cluster.startMs);
    const endDay = formatDayLocal(cluster.endMs);
    const endShort = endDay === day
      ? formatTimeOnlyLocal(cluster.endMs)
      : `${endDay.slice(5)} ${formatTimeOnlyLocal(cluster.endMs)}`;
    const batchNumber = index + 1;
    const assetDescription = assetCount > 0 ? `${assetCount} 素材` : "系统流";
    return {
      batch_id: `batch-${batchNumber}`,
      index: batchNumber,
      day,
      label: `批次 #${batchNumber} · ${day} ${formatTimeOnlyLocal(cluster.startMs)}~${endShort} (${assetDescription} · ${cluster.taskCount} 任务)`,
      start_ms: cluster.startMs,
      end_ms: cluster.endMs,
      start_text: formatTimestampMs(cluster.startMs),
      end_text: formatTimestampMs(cluster.endMs),
      duration_ms: Math.max(0, cluster.endMs - cluster.startMs),
      task_count: cluster.taskCount,
      asset_count: assetCount,
      video_count: videoCount,
      image_count: imageCount,
      total_media_duration_ms: totalMediaDurationMs,
    };
  });
}

function resolveEffectiveSlice(
  options: DagscQueryOptions,
  batchesDescending: DagscBatchSummary[],
  allTasks: RawTask[],
): { mode: string; batchID?: string; label: string; startMs: number; endMs: number } {
  const requestedMode = (options.sliceMode || "auto").toLowerCase();
  if (requestedMode === "all") {
    const starts = allTasks.filter((task) => task.effStart > 0).map((task) => task.effStart);
    const ends = allTasks.filter((task) => task.effEnd > 0).map((task) => task.effEnd);
    return {
      mode: "all",
      label: "全库汇总（包含所有历史批次）",
      startMs: starts.length
        ? starts.reduce((minimum, value) => Math.min(minimum, value), Number.POSITIVE_INFINITY)
        : 0,
      endMs: ends.reduce((maximum, value) => Math.max(maximum, value), 0),
    };
  }
  if (
    requestedMode === "custom"
    && Number.isFinite(options.customFromMs)
    && Number.isFinite(options.customToMs)
    && (options.customFromMs || 0) > 0
    && (options.customToMs || 0) >= (options.customFromMs || 0)
  ) {
    const startMs = options.customFromMs as number;
    const endMs = options.customToMs as number;
    return {
      mode: "custom",
      label: `自定义时间窗 (${formatTimestampMs(startMs)} ~ ${formatTimestampMs(endMs)})`,
      startMs,
      endMs,
    };
  }
  if (requestedMode === "batch" && options.batchID) {
    const found = batchesDescending.find((batch) => batch.batch_id === options.batchID);
    if (found) {
      return {
        mode: "batch",
        batchID: found.batch_id,
        label: found.label,
        startMs: found.start_ms,
        endMs: found.end_ms,
      };
    }
  }
  const bestBatch = batchesDescending.find((batch) => batch.asset_count > 0) || batchesDescending[0];
  if (bestBatch) {
    return {
      mode: "batch",
      batchID: bestBatch.batch_id,
      label: bestBatch.label,
      startMs: bestBatch.start_ms,
      endMs: bestBatch.end_ms,
    };
  }
  return { mode: "all", label: "全库汇总", startMs: 0, endMs: 0 };
}

export function mergeIntervalsWithGap(intervals: Interval[], maxGapMs: number): Interval[] {
  const valid = intervals
    .filter(([start, end]) => start > 0 && end >= start)
    .sort((a, b) => a[0] - b[0]);
  if (!valid.length) return [];
  const merged: Interval[] = [[valid[0][0], valid[0][1]]];
  for (const [start, end] of valid.slice(1)) {
    const last = merged[merged.length - 1];
    if (start - last[1] <= maxGapMs) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  }
  return merged;
}

function mergeIntervalsExactMs(intervals: Interval[]): number {
  return mergeIntervalsWithGap(intervals, 0).reduce((sum, [start, end]) => sum + Math.max(0, end - start), 0);
}

function round(value: number, digits: number): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function speedRatios(processingMs: number, mediaMs: number): { rtf: number; speedup: number } {
  return {
    rtf: mediaMs > 0 ? round(processingMs / mediaMs, 6) : 0,
    speedup: processingMs > 0 && mediaMs > 0 ? round(mediaMs / processingMs, 4) : 0,
  };
}

function taskEndpoint(task: RawTask | undefined, useFinish: boolean): Record<string, unknown> | null {
  if (!task) return null;
  const timestamp = useFinish ? task.effEnd : task.effStart;
  return {
    task_id: task.taskID,
    workflow_id: task.workflowID,
    template_id: task.templateID,
    asset_id: task.assetID,
    node_type: task.nodeType,
    template_node_id: task.templateNodeID,
    timestamp_ms: timestamp,
    timestamp_text: formatTimestampMs(timestamp),
    dispatched_at: task.dispatchedAt,
    started_at: task.startedAt,
    finished_at: task.finishedAt,
    duration_ms: task.durationMs,
  };
}

function computeScopeMetrics(tasks: RawTask[], totalMediaDurationMs: number, batchGapMs: number): ScopeMetrics {
  if (!tasks.length) {
    return {
      total_tasks: 0,
      succeeded_tasks: 0,
      failed_tasks: 0,
      zero_start_fixed_count: 0,
      wall_clock_ms: 0,
      span_wall_clock_ms: 0,
      active_batch_wall_ms: 0,
      batch_count_in_scope: 0,
      origin_start_ms: 0,
      origin_end_ms: 0,
      wall_rtf: 0,
      wall_speedup: 0,
      span_speedup: 0,
      cumulative_ms: 0,
      cumulative_rtf: 0,
      cumulative_speedup: 0,
      concurrency: 0,
      first_task: null,
      last_task: null,
      active_segments: [],
      by_node_type: [],
      by_template_node: [],
      timeline_spans: {},
    };
  }

  const validStartTasks = tasks.filter((task) => task.effStart > 0);
  const validEndTasks = validStartTasks.filter((task) => task.effEnd > 0);
  const firstTask = [...validStartTasks].sort((a, b) => a.effStart - b.effStart)[0];
  const lastTask = [...validEndTasks].sort((a, b) => b.effEnd - a.effEnd)[0];
  const minStartMs = firstTask?.effStart || 0;
  const maxFinishMs = lastTask?.effEnd || minStartMs;
  const spanWallClockMs = firstTask && lastTask && maxFinishMs >= minStartMs ? maxFinishMs - minStartMs : 0;
  const taskIntervals = validStartTasks.map((task): Interval => [task.effStart, Math.max(task.effStart, task.effEnd)]);
  const mergedBatches = mergeIntervalsWithGap(taskIntervals, batchGapMs);
  let virtualCursor = 0;
  const activeSegments: ActiveSegment[] = mergedBatches.map(([start, end], index) => {
    const duration = Math.max(0, end - start);
    const segment = {
      index,
      wall_start_ms: start,
      wall_end_ms: end,
      wall_start_text: formatTimestampMs(start),
      wall_end_text: formatTimestampMs(end),
      virtual_start_ms: virtualCursor,
      virtual_end_ms: virtualCursor + duration,
      duration_ms: duration,
      gap_before_ms: index > 0 ? Math.max(0, start - mergedBatches[index - 1][1]) : 0,
    };
    virtualCursor += duration;
    return segment;
  });
  const activeBatchWallMs = virtualCursor > 0 ? virtualCursor : spanWallClockMs;
  const wallClockMs = activeBatchWallMs;
  const cumulativeMs = tasks.reduce((sum, task) => sum + task.durationMs, 0);
  const wallRatio = speedRatios(wallClockMs, totalMediaDurationMs);
  const spanRatio = speedRatios(spanWallClockMs, totalMediaDurationMs);
  const cumulativeRatio = speedRatios(cumulativeMs, totalMediaDurationMs);

  function mapToVirtualTimeline(wallMs: number): [number, number] {
    for (const segment of activeSegments) {
      if (wallMs >= segment.wall_start_ms && wallMs <= segment.wall_end_ms) {
        return [segment.virtual_start_ms + wallMs - segment.wall_start_ms, segment.index];
      }
    }
    const last = activeSegments.at(-1);
    if (last && wallMs > last.wall_end_ms) return [last.virtual_end_ms, last.index];
    return [Math.max(0, wallMs - minStartMs), 0];
  }

  interface TypeGroup {
    nodeType: string;
    executors: Set<string>;
    count: number;
    succeeded: number;
    failed: number;
    sumMs: number;
    intervals: Interval[];
    minMs?: number;
    maxMs?: number;
    zeroStartFixed: number;
  }
  const typeGroups = new Map<string, TypeGroup>();
  const timelineSpans: Record<string, Array<[number, number, string, string, number]>> = {};
  for (const task of [...tasks].sort((a, b) => a.effStart - b.effStart)) {
    const nodeType = task.nodeType || "unknown";
    const group = typeGroups.get(nodeType) || {
      nodeType,
      executors: new Set<string>(),
      count: 0,
      succeeded: 0,
      failed: 0,
      sumMs: 0,
      intervals: [],
      zeroStartFixed: 0,
    };
    group.executors.add(task.executorText || "unspecified");
    group.count += 1;
    if (task.statusText === "succeeded") group.succeeded += 1;
    else if (task.statusText === "failed") group.failed += 1;
    group.sumMs += task.durationMs;
    group.minMs = group.minMs === undefined ? task.durationMs : Math.min(group.minMs, task.durationMs);
    group.maxMs = group.maxMs === undefined ? task.durationMs : Math.max(group.maxMs, task.durationMs);
    if (task.zeroStartFixed) group.zeroStartFixed += 1;
    if (task.effStart > 0 && task.effEnd >= task.effStart) {
      group.intervals.push([task.effStart, task.effEnd]);
      const [virtualStart, segmentIndex] = mapToVirtualTimeline(task.effStart);
      (timelineSpans[nodeType] ||= []).push([
        virtualStart,
        task.durationMs,
        task.assetID,
        task.templateNodeID || nodeType,
        segmentIndex,
      ]);
    }
    typeGroups.set(nodeType, group);
  }

  const byNodeType = [...typeGroups.values()]
    .sort((a, b) => b.sumMs - a.sumMs || a.nodeType.localeCompare(b.nodeType))
    .map((group) => {
      const activeUnionMs = mergeIntervalsExactMs(group.intervals);
      const ratio = speedRatios(group.sumMs, totalMediaDurationMs);
      return {
        node_type: group.nodeType,
        executor: [...group.executors].sort().join("/"),
        count: group.count,
        succeeded: group.succeeded,
        failed: group.failed,
        sum_ms: group.sumMs,
        active_union_ms: activeUnionMs,
        avg_ms: group.count ? round(group.sumMs / group.count, 2) : 0,
        min_ms: group.minMs || 0,
        max_ms: group.maxMs || 0,
        pct_cumulative: cumulativeMs > 0 ? round(group.sumMs * 100 / cumulativeMs, 4) : 0,
        pct_wall: wallClockMs > 0 ? round(group.sumMs * 100 / wallClockMs, 4) : 0,
        busy_pct: wallClockMs > 0 ? round(activeUnionMs * 100 / wallClockMs, 2) : 0,
        rtf: ratio.rtf,
        speedup: ratio.speedup,
        zero_start_fixed: group.zeroStartFixed,
      };
    });

  interface TemplateNodeGroup {
    templateNodeID: string;
    nodeType: string;
    executors: Set<string>;
    templates: Set<string>;
    count: number;
    sumMs: number;
    minMs?: number;
    maxMs?: number;
  }
  const templateGroups = new Map<string, TemplateNodeGroup>();
  for (const task of tasks) {
    const nodeType = task.nodeType || "unknown";
    const templateNodeID = task.templateNodeID || nodeType;
    const key = `${templateNodeID}\u0000${nodeType}`;
    const group = templateGroups.get(key) || {
      templateNodeID,
      nodeType,
      executors: new Set<string>(),
      templates: new Set<string>(),
      count: 0,
      sumMs: 0,
    };
    group.executors.add(task.executorText || "unspecified");
    if (task.templateID) group.templates.add(task.templateID);
    group.count += 1;
    group.sumMs += task.durationMs;
    group.minMs = group.minMs === undefined ? task.durationMs : Math.min(group.minMs, task.durationMs);
    group.maxMs = group.maxMs === undefined ? task.durationMs : Math.max(group.maxMs, task.durationMs);
    templateGroups.set(key, group);
  }
  const byTemplateNode = [...templateGroups.values()]
    .sort((a, b) => b.sumMs - a.sumMs || a.templateNodeID.localeCompare(b.templateNodeID))
    .map((group) => {
      const ratio = speedRatios(group.sumMs, totalMediaDurationMs);
      return {
        template_node_id: group.templateNodeID,
        node_type: group.nodeType,
        executor: [...group.executors].sort().join("/"),
        template_id: [...group.templates].sort().join("/"),
        count: group.count,
        sum_ms: group.sumMs,
        avg_ms: group.count ? round(group.sumMs / group.count, 2) : 0,
        min_ms: group.minMs || 0,
        max_ms: group.maxMs || 0,
        pct_cumulative: cumulativeMs > 0 ? round(group.sumMs * 100 / cumulativeMs, 4) : 0,
        rtf: ratio.rtf,
        speedup: ratio.speedup,
      };
    });

  return {
    total_tasks: tasks.length,
    succeeded_tasks: tasks.filter((task) => task.statusText === "succeeded").length,
    failed_tasks: tasks.filter((task) => task.statusText === "failed").length,
    zero_start_fixed_count: tasks.filter((task) => task.zeroStartFixed).length,
    wall_clock_ms: wallClockMs,
    span_wall_clock_ms: spanWallClockMs,
    active_batch_wall_ms: activeBatchWallMs,
    batch_count_in_scope: mergedBatches.length,
    origin_start_ms: minStartMs,
    origin_end_ms: maxFinishMs,
    wall_rtf: wallRatio.rtf,
    wall_speedup: wallRatio.speedup,
    span_speedup: spanRatio.speedup,
    cumulative_ms: cumulativeMs,
    cumulative_rtf: cumulativeRatio.rtf,
    cumulative_speedup: cumulativeRatio.speedup,
    concurrency: wallClockMs > 0 ? round(cumulativeMs / wallClockMs, 2) : 0,
    first_task: taskEndpoint(firstTask, false),
    last_task: taskEndpoint(lastTask, true),
    active_segments: activeSegments,
    by_node_type: byNodeType,
    by_template_node: byTemplateNode,
    timeline_spans: timelineSpans,
  };
}

function summarizeErrorJSON(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  const object = parseObject(trimmed);
  if (object) {
    for (const key of ["message", "error", "detail", "reason", "code"]) {
      const value = object[key];
      if (typeof value === "string" && value) return value.slice(0, 180);
    }
  }
  return trimmed.slice(0, 180);
}

async function backupDatabase(sourcePath: string, destinationPath: string): Promise<void> {
  const source = new DatabaseSync(sourcePath, { readOnly: true, timeout: 2_000 });
  try {
    let lastError: unknown;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        await backup(source, destinationPath, { rate: 256 });
        return;
      } catch (error) {
        lastError = error;
        if (attempt < 3) await new Promise((resolveDelay) => setTimeout(resolveDelay, 75 * (attempt + 1)));
      }
    }
    throw lastError;
  } finally {
    source.close();
  }
}

export async function analyzeDagsc(
  options: DagscQueryOptions = {},
  environment: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const resolvedDB = resolveScheduleDatabase(options.inputPath || "");
  const batchGapMs = Math.max(60_000, integer(options.batchGapMs || 15 * 60 * 1_000));
  const sourceStat = statSync(resolvedDB.dbPath);
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "cliptopulse-dagsc-"));
  const temporaryDatabase = join(temporaryDirectory, "schedule.db");
  let db: DatabaseSync | undefined;
  try {
    await backupDatabase(resolvedDB.dbPath, temporaryDatabase);
    db = new DatabaseSync(temporaryDatabase, { readOnly: true, timeout: 2_000 });
    const rawWorkflows = loadWorkflows(db);
    const workflowsByID = new Map(rawWorkflows.map((workflow) => [workflow.workflowID, workflow]));
    const rawTasks = loadTasks(db, workflowsByID);
    let workflows = rawWorkflows.filter((workflow) => workflow.templateID === "clipto_asset_analysis");
    let allTasks = rawTasks.filter((task) => task.templateID === "clipto_asset_analysis");
    const templateVersion = loadTemplateVersion(db);

    const ignoreBeforeMs = integer(options.ignoreBeforeMs);
    if (resolvedDB.isDefaultDatabase && ignoreBeforeMs > 0) {
      allTasks = allTasks.filter((task) => task.effStart >= ignoreBeforeMs);
      const keptIDs = new Set(allTasks.map((task) => task.workflowID));
      workflows = workflows.filter((workflow) => keptIDs.has(workflow.workflowID) || workflow.createdAt >= ignoreBeforeMs);
    }

    const batchesDescending = discoverBatches(workflows, allTasks, batchGapMs).reverse();
    const slice = resolveEffectiveSlice(options, batchesDescending, allTasks);
    const filteredTasks = slice.mode === "all"
      ? allTasks
      : allTasks.filter((task) => task.effStart > 0 && task.effStart <= slice.endMs && task.effEnd >= slice.startMs);
    const activeWorkflowIDs = new Set(filteredTasks.map((task) => task.workflowID));
    const filteredWorkflows = workflows.filter((workflow) => activeWorkflowIDs.has(workflow.workflowID));

    const workflowSummaries = new Map<string, {
      total: number; succeeded: number; failed: number; canceled: number; running: number;
      minStartedAt?: number; maxFinishedAt?: number;
    }>();
    const workflowOrder: string[] = [];
    for (const workflow of filteredWorkflows) {
      if (!workflowSummaries.has(workflow.templateID)) {
        workflowOrder.push(workflow.templateID);
        workflowSummaries.set(workflow.templateID, {
          total: 0, succeeded: 0, failed: 0, canceled: 0, running: 0,
        });
      }
      const summary = workflowSummaries.get(workflow.templateID)!;
      summary.total += 1;
      if (workflow.statusText === "succeeded") summary.succeeded += 1;
      else if (workflow.statusText === "failed") summary.failed += 1;
      else if (workflow.statusText === "canceled") summary.canceled += 1;
      else if (workflow.statusText === "running") summary.running += 1;
      if (workflow.startedAt > 0) {
        summary.minStartedAt = summary.minStartedAt === undefined
          ? workflow.startedAt : Math.min(summary.minStartedAt, workflow.startedAt);
      }
      if (workflow.finishedAt > 0) {
        summary.maxFinishedAt = summary.maxFinishedAt === undefined
          ? workflow.finishedAt : Math.max(summary.maxFinishedAt, workflow.finishedAt);
      }
    }
    const workflowsByTemplate = workflowOrder.map((templateID) => {
      const summary = workflowSummaries.get(templateID)!;
      return {
        template_id: templateID,
        total: summary.total,
        succeeded: summary.succeeded,
        failed: summary.failed,
        canceled: summary.canceled,
        running: summary.running,
        min_started_at: summary.minStartedAt ?? null,
        max_finished_at: summary.maxFinishedAt ?? null,
      };
    });

    interface AssetAccumulator {
      workflow: RawWorkflow;
      taskCount: number;
      firstTaskStart?: number;
      lastTaskFinish?: number;
      cumulativeTaskMs: number;
      typeMs: Map<string, number>;
    }
    const assets = new Map<string, AssetAccumulator>();
    let totalMediaDurationMs = 0;
    let totalMediaSizeBytes = 0;
    let videoAssetsCount = 0;
    let imageAssetsCount = 0;
    for (const workflow of filteredWorkflows) {
      if (!workflow.assetID) continue;
      totalMediaDurationMs += workflow.mediaDurationMs;
      totalMediaSizeBytes += workflow.fileSizeBytes;
      if (workflow.assetType === "image" || workflow.mediaDurationMs === 0) imageAssetsCount += 1;
      else videoAssetsCount += 1;
      assets.set(workflow.workflowID, {
        workflow,
        taskCount: 0,
        cumulativeTaskMs: 0,
        typeMs: new Map(),
      });
    }
    const assetTasks = filteredTasks.filter((task) => task.templateID === "clipto_asset_analysis");
    for (const task of assetTasks) {
      const asset = assets.get(task.workflowID);
      if (!asset) continue;
      asset.taskCount += 1;
      asset.cumulativeTaskMs += task.durationMs;
      if (task.effStart > 0) {
        asset.firstTaskStart = asset.firstTaskStart === undefined
          ? task.effStart : Math.min(asset.firstTaskStart, task.effStart);
      }
      if (task.finishedAt > 0) {
        asset.lastTaskFinish = asset.lastTaskFinish === undefined
          ? task.finishedAt : Math.max(asset.lastTaskFinish, task.finishedAt);
      }
      const nodeType = task.nodeType || "unknown";
      asset.typeMs.set(nodeType, (asset.typeMs.get(nodeType) || 0) + task.durationMs);
    }
    const byAsset = [...assets.values()].map((asset) => {
      const workflow = asset.workflow;
      const firstStart = asset.firstTaskStart ?? workflow.startedAt;
      const lastFinish = asset.lastTaskFinish ?? workflow.finishedAt;
      const wallSpanMs = lastFinish > firstStart && firstStart > 0 ? lastFinish - firstStart : 0;
      const wall = speedRatios(wallSpanMs, workflow.mediaDurationMs);
      const cumulative = speedRatios(asset.cumulativeTaskMs, workflow.mediaDurationMs);
      const top = [...asset.typeMs.entries()].sort((a, b) => b[1] - a[1])[0];
      return {
        asset_id: workflow.assetID,
        workflow_id: workflow.workflowID,
        filename: workflow.filename,
        asset_type: workflow.assetType,
        media_duration_ms: workflow.mediaDurationMs,
        file_size_bytes: workflow.fileSizeBytes,
        status: workflow.statusText,
        task_count: asset.taskCount,
        first_start_ms: firstStart,
        first_start_text: formatTimestampMs(firstStart),
        last_finish_ms: lastFinish,
        last_finish_text: formatTimestampMs(lastFinish),
        wall_span_ms: wallSpanMs,
        wall_rtf: wall.rtf,
        wall_speedup: wall.speedup,
        cumulative_task_ms: asset.cumulativeTaskMs,
        cum_rtf: cumulative.rtf,
        cum_speedup: cumulative.speedup,
        top_node_type: top?.[0] || "",
        top_node_ms: top?.[1] || 0,
      };
    }).sort((a, b) => {
      const aNumber = Number(a.asset_id);
      const bNumber = Number(b.asset_id);
      const aNumeric = Number.isFinite(aNumber) && a.asset_id.trim() !== "";
      const bNumeric = Number.isFinite(bNumber) && b.asset_id.trim() !== "";
      if (aNumeric && bNumeric) return aNumber - bNumber || a.first_start_ms - b.first_start_ms;
      if (aNumeric) return -1;
      if (bNumeric) return 1;
      return a.asset_id.localeCompare(b.asset_id);
    });

    const scope = computeScopeMetrics(assetTasks, totalMediaDurationMs, batchGapMs);
    const activeIntervals = scope.active_segments.length
      ? scope.active_segments.map((segment) => [segment.wall_start_ms, segment.wall_end_ms])
      : slice.startMs > 0 && slice.endMs >= slice.startMs ? [[slice.startMs, slice.endMs]] : [];
    const failedTaskSamples = assetTasks
      .filter((task) => task.statusText === "failed" || task.errorJSON)
      .slice(0, 20)
      .map((task) => ({
        task_id: task.taskID,
        workflow_id: task.workflowID,
        asset_id: task.assetID,
        node_type: task.nodeType,
        template_node_id: task.templateNodeID,
        status_text: task.statusText,
        timestamp_text: formatTimestampMs(task.finishedAt > 0 ? task.finishedAt : task.effStart),
        error_summary: summarizeErrorJSON(task.errorJSON),
      }));
    const effectiveStart = scope.active_segments[0]?.wall_start_ms ?? slice.startMs;
    const effectiveEnd = scope.active_segments.at(-1)?.wall_end_ms ?? slice.endMs;

    return {
      ok: true,
      app_version: detectCliptoVersion(resolvedDB.dagscRoot),
      template_version: templateVersion,
      detected_username: userInfo().username,
      default_dagsc_dir: resolvedDB.defaultDagscDir,
      dagsc_dir: resolvedDB.dagscRoot,
      db_path: resolvedDB.dbPath,
      db_size_bytes: sourceStat.size,
      db_mtime_text: formatTimestampMs(sourceStat.mtimeMs),
      analyzed_at_text: formatNowSecond(),
      slice_mode: slice.mode,
      selected_batch_id: slice.batchID ?? null,
      slice_label: slice.label,
      slice_start_ms: effectiveStart,
      slice_end_ms: effectiveEnd,
      slice_start_text: formatTimestampMs(effectiveStart),
      slice_end_text: formatTimestampMs(effectiveEnd),
      active_intervals_ms: activeIntervals,
      available_batches: batchesDescending,
      records_epoch_ms: resolvedDB.isDefaultDatabase ? ignoreBeforeMs : 0,
      workflows_total: filteredWorkflows.length,
      assets_total: byAsset.length,
      video_assets_count: videoAssetsCount,
      image_assets_count: imageAssetsCount,
      total_media_duration_ms: totalMediaDurationMs,
      total_media_size_bytes: totalMediaSizeBytes,
      workflows_by_template: workflowsByTemplate,
      scopes: { asset_analysis: scope },
      by_asset: byAsset,
      failed_task_samples: failedTaskSamples,
      environment,
      aligned_hardware: null,
    };
  } catch (error) {
    if (error instanceof DagscError) throw error;
    const message = error instanceof Error ? error.message : String(error);
    throw new DagscError(`读取 DAGSC 数据库失败：${message}`, "SQLITE_QUERY_FAILED");
  } finally {
    try { db?.close(); } catch { /* already closed */ }
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
