import Foundation

struct SystemEnvironmentInfo: Codable, Sendable {
    let chipModel: String
    let physicalMemoryBytes: UInt64
    let physicalMemoryText: String
    let logicalCores: Int
    let macOSVersion: String
    let hostname: String
    let username: String
    let lanIPs: [String]
    let webPort: Int
    let defaultDagscDir: String
    let historyDBPath: String
    let historyDBSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case chipModel = "chip_model"
        case physicalMemoryBytes = "physical_memory_bytes"
        case physicalMemoryText = "physical_memory_text"
        case logicalCores = "logical_cores"
        case macOSVersion = "macos_version"
        case hostname
        case username
        case lanIPs = "lan_ips"
        case webPort = "web_port"
        case defaultDagscDir = "default_dagsc_dir"
        case historyDBPath = "history_db_path"
        case historyDBSizeBytes = "history_db_size_bytes"
    }
}

struct DAGSCBatchSummary: Codable, Sendable, Equatable {
    let batchID: String
    let index: Int
    let day: String
    let label: String
    let startMs: Int64
    let endMs: Int64
    let startText: String
    let endText: String
    let durationMs: Int64
    let taskCount: Int
    let assetCount: Int
    let videoCount: Int
    let imageCount: Int
    let totalMediaDurationMs: Int64

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case index
        case day
        case label
        case startMs = "start_ms"
        case endMs = "end_ms"
        case startText = "start_text"
        case endText = "end_text"
        case durationMs = "duration_ms"
        case taskCount = "task_count"
        case assetCount = "asset_count"
        case videoCount = "video_count"
        case imageCount = "image_count"
        case totalMediaDurationMs = "total_media_duration_ms"
    }
}

struct DAGSCWorkflowSummary: Codable, Sendable {
    let templateID: String
    let total: Int
    let succeeded: Int
    let failed: Int
    let canceled: Int
    let running: Int
    let minStartedAt: Int64?
    let maxFinishedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case templateID = "template_id"
        case total, succeeded, failed, canceled, running
        case minStartedAt = "min_started_at"
        case maxFinishedAt = "max_finished_at"
    }
}

struct DAGSCNodeTypeRow: Codable, Sendable {
    let nodeType: String
    let executor: String
    let count: Int
    let succeeded: Int
    let failed: Int
    let sumMs: Int64
    let activeUnionMs: Int64
    let avgMs: Double
    let minMs: Int64
    let maxMs: Int64
    let pctCumulative: Double
    let pctWall: Double
    let busyPct: Double
    let rtf: Double
    let speedup: Double
    let zeroStartFixed: Int

    enum CodingKeys: String, CodingKey {
        case nodeType = "node_type"
        case executor, count, succeeded, failed
        case sumMs = "sum_ms"
        case activeUnionMs = "active_union_ms"
        case avgMs = "avg_ms"
        case minMs = "min_ms"
        case maxMs = "max_ms"
        case pctCumulative = "pct_cumulative"
        case pctWall = "pct_wall"
        case busyPct = "busy_pct"
        case rtf, speedup
        case zeroStartFixed = "zero_start_fixed"
    }
}

struct DAGSCTemplateNodeRow: Codable, Sendable {
    let templateNodeID: String
    let nodeType: String
    let executor: String
    let templateID: String
    let count: Int
    let sumMs: Int64
    let avgMs: Double
    let minMs: Int64
    let maxMs: Int64
    let pctCumulative: Double
    let rtf: Double
    let speedup: Double

    enum CodingKeys: String, CodingKey {
        case templateNodeID = "template_node_id"
        case nodeType = "node_type"
        case executor
        case templateID = "template_id"
        case count
        case sumMs = "sum_ms"
        case avgMs = "avg_ms"
        case minMs = "min_ms"
        case maxMs = "max_ms"
        case pctCumulative = "pct_cumulative"
        case rtf, speedup
    }
}

struct DAGSCAssetRow: Codable, Sendable {
    let assetID: String
    let workflowID: String
    let filename: String
    let assetType: String
    let mediaDurationMs: Int64
    let fileSizeBytes: Int64
    let status: String
    let taskCount: Int
    let firstStartMs: Int64
    let firstStartText: String
    let lastFinishMs: Int64
    let lastFinishText: String
    let wallSpanMs: Int64
    let wallRtf: Double
    let wallSpeedup: Double
    let cumulativeTaskMs: Int64
    let cumRtf: Double
    let cumSpeedup: Double
    let topNodeType: String
    let topNodeMs: Int64

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case workflowID = "workflow_id"
        case filename
        case assetType = "asset_type"
        case mediaDurationMs = "media_duration_ms"
        case fileSizeBytes = "file_size_bytes"
        case status
        case taskCount = "task_count"
        case firstStartMs = "first_start_ms"
        case firstStartText = "first_start_text"
        case lastFinishMs = "last_finish_ms"
        case lastFinishText = "last_finish_text"
        case wallSpanMs = "wall_span_ms"
        case wallRtf = "wall_rtf"
        case wallSpeedup = "wall_speedup"
        case cumulativeTaskMs = "cumulative_task_ms"
        case cumRtf = "cum_rtf"
        case cumSpeedup = "cum_speedup"
        case topNodeType = "top_node_type"
        case topNodeMs = "top_node_ms"
    }
}

struct DAGSCTaskEndpoint: Codable, Sendable {
    let taskID: String
    let workflowID: String
    let templateID: String
    let assetID: String
    let nodeType: String
    let templateNodeID: String
    let timestampMs: Int64
    let timestampText: String
    let dispatchedAt: Int64
    let startedAt: Int64
    let finishedAt: Int64
    let durationMs: Int64

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case workflowID = "workflow_id"
        case templateID = "template_id"
        case assetID = "asset_id"
        case nodeType = "node_type"
        case templateNodeID = "template_node_id"
        case timestampMs = "timestamp_ms"
        case timestampText = "timestamp_text"
        case dispatchedAt = "dispatched_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationMs = "duration_ms"
    }
}

struct DAGSCFailedTaskSample: Codable, Sendable {
    let taskID: String
    let workflowID: String
    let assetID: String
    let nodeType: String
    let templateNodeID: String
    let statusText: String
    let timestampText: String
    let errorSummary: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case workflowID = "workflow_id"
        case assetID = "asset_id"
        case nodeType = "node_type"
        case templateNodeID = "template_node_id"
        case statusText = "status_text"
        case timestampText = "timestamp_text"
        case errorSummary = "error_summary"
    }
}

/// Compact [virtualStartMs, durMs, assetID, templateNodeID, segmentIndex] array for the Nsight swimlane.
struct DAGSCTimelineSpan: Codable, Sendable {
    let relStartMs: Int64
    let durationMs: Int64
    let assetID: String
    let templateNodeID: String
    let segmentIndex: Int

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(relStartMs)
        try container.encode(durationMs)
        try container.encode(assetID)
        try container.encode(templateNodeID)
        try container.encode(segmentIndex)
    }

    init(relStartMs: Int64, durationMs: Int64, assetID: String, templateNodeID: String, segmentIndex: Int = 0) {
        self.relStartMs = relStartMs
        self.durationMs = durationMs
        self.assetID = assetID
        self.templateNodeID = templateNodeID
        self.segmentIndex = segmentIndex
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        relStartMs = try container.decode(Int64.self)
        durationMs = try container.decode(Int64.self)
        assetID = try container.decode(String.self)
        templateNodeID = try container.decode(String.self)
        segmentIndex = (try? container.decode(Int.self)) ?? 0
    }
}

/// Maps one contiguous active batch segment [wallStartMs, wallEndMs] onto the stitched timeline [virtualStartMs, virtualEndMs].
struct DAGSCActiveSegment: Codable, Sendable {
    let index: Int
    let wallStartMs: Int64
    let wallEndMs: Int64
    let wallStartText: String
    let wallEndText: String
    let virtualStartMs: Int64
    let virtualEndMs: Int64
    let durationMs: Int64
    let gapBeforeMs: Int64

    enum CodingKeys: String, CodingKey {
        case index
        case wallStartMs = "wall_start_ms"
        case wallEndMs = "wall_end_ms"
        case wallStartText = "wall_start_text"
        case wallEndText = "wall_end_text"
        case virtualStartMs = "virtual_start_ms"
        case virtualEndMs = "virtual_end_ms"
        case durationMs = "duration_ms"
        case gapBeforeMs = "gap_before_ms"
    }
}

struct DAGSCScopeMetrics: Codable, Sendable {
    let totalTasks: Int
    let succeededTasks: Int
    let failedTasks: Int
    let zeroStartFixedCount: Int
    /// Effective active wall-clock duration (exact match with stitched swimlane total length).
    let wallClockMs: Int64
    /// Raw end-to-end span MAX(finished_at) - MIN(eff_start).
    let spanWallClockMs: Int64
    /// Merged active batch wall-clock ms.
    let activeBatchWallMs: Int64
    let batchCountInScope: Int
    let originStartMs: Int64
    let originEndMs: Int64
    let wallRtf: Double
    let wallSpeedup: Double
    let spanSpeedup: Double
    let cumulativeMs: Int64
    let cumulativeRtf: Double
    let cumulativeSpeedup: Double
    let concurrency: Double
    let firstTask: DAGSCTaskEndpoint?
    let lastTask: DAGSCTaskEndpoint?
    let activeSegments: [DAGSCActiveSegment]
    let byNodeType: [DAGSCNodeTypeRow]
    let byTemplateNode: [DAGSCTemplateNodeRow]
    let timelineSpans: [String: [DAGSCTimelineSpan]]

    enum CodingKeys: String, CodingKey {
        case totalTasks = "total_tasks"
        case succeededTasks = "succeeded_tasks"
        case failedTasks = "failed_tasks"
        case zeroStartFixedCount = "zero_start_fixed_count"
        case wallClockMs = "wall_clock_ms"
        case spanWallClockMs = "span_wall_clock_ms"
        case activeBatchWallMs = "active_batch_wall_ms"
        case batchCountInScope = "batch_count_in_scope"
        case originStartMs = "origin_start_ms"
        case originEndMs = "origin_end_ms"
        case wallRtf = "wall_rtf"
        case wallSpeedup = "wall_speedup"
        case spanSpeedup = "span_speedup"
        case cumulativeMs = "cumulative_ms"
        case cumulativeRtf = "cumulative_rtf"
        case cumulativeSpeedup = "cumulative_speedup"
        case concurrency
        case firstTask = "first_task"
        case lastTask = "last_task"
        case activeSegments = "active_segments"
        case byNodeType = "by_node_type"
        case byTemplateNode = "by_template_node"
        case timelineSpans = "timeline_spans"
    }
}

struct DAGSCScopesContainer: Codable, Sendable {
    let assetAnalysis: DAGSCScopeMetrics

    enum CodingKeys: String, CodingKey {
        case assetAnalysis = "asset_analysis"
    }
}

struct AlignedStatMetric: Codable, Sendable {
    let avg: Double?
    let max: Double?
    let min: Double?
    let p95: Double?
    let count: Int
}

struct AlignedCMSProcessItem: Codable, Sendable {
    let name: String
    let instanceCount: Int
    let avgCPUPercent: Double?
    let maxCPUPercent: Double?
    let avgMemoryBytes: Double?
    let maxMemoryBytes: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case instanceCount = "instance_count"
        case avgCPUPercent = "avg_cpu_percent"
        case maxCPUPercent = "max_cpu_percent"
        case avgMemoryBytes = "avg_memory_bytes"
        case maxMemoryBytes = "max_memory_bytes"
    }
}

struct AlignedTimeSeriesPoint: Codable, Sendable {
    let tsMs: Int64
    let sysCPU: Double
    let sysGPU: Double?
    let aneUsage: Double?
    let sysMemBytes: Double
    let sysMemPct: Double
    let swapUsedBytes: Double
    let cliptoCPU: Double?
    let cliptoMemBytes: Double?
    let cliptoGPU: Double?
    let cliptoDiskRead: Double?
    let cliptoDiskWrite: Double?
    let cmsCPU: Double?
    let cmsMemBytes: Double?
    let sysPower: Double?
    let cpuPower: Double?
    let gpuPower: Double?
    let anePower: Double?
    let dramReadGBps: Double?
    let dramWriteGBps: Double?
    let diskReadBps: Double
    let diskWriteBps: Double
    let netDownBps: Double
    let netUpBps: Double
    let thermal: String

    enum CodingKeys: String, CodingKey {
        case tsMs = "ts_ms"
        case sysCPU = "sys_cpu"
        case sysGPU = "sys_gpu"
        case aneUsage = "ane_usage"
        case sysMemBytes = "sys_mem_bytes"
        case sysMemPct = "sys_mem_pct"
        case swapUsedBytes = "swap_used_bytes"
        case cliptoCPU = "clipto_cpu"
        case cliptoMemBytes = "clipto_mem_bytes"
        case cliptoGPU = "clipto_gpu"
        case cliptoDiskRead = "clipto_disk_read"
        case cliptoDiskWrite = "clipto_disk_write"
        case cmsCPU = "cms_cpu"
        case cmsMemBytes = "cms_mem_bytes"
        case sysPower = "sys_power"
        case cpuPower = "cpu_power"
        case gpuPower = "gpu_power"
        case anePower = "ane_power"
        case dramReadGBps = "dram_read_gbps"
        case dramWriteGBps = "dram_write_gbps"
        case diskReadBps = "disk_read_bps"
        case diskWriteBps = "disk_write_bps"
        case netDownBps = "net_down_bps"
        case netUpBps = "net_up_bps"
        case thermal
    }
}

struct AlignedHardwareReport: Codable, Sendable {
    let hasData: Bool
    let sampleCount: Int
    let cmsFrameCount: Int
    let windowStartMs: Int64
    let windowEndMs: Int64
    let windowStartText: String
    let windowEndText: String
    let targetActiveSeconds: Double
    let coveredSeconds: Double
    let coveragePercent: Double
    let sysCPU: AlignedStatMetric
    let sysGPU: AlignedStatMetric
    let aneUsage: AlignedStatMetric
    let sysMemBytes: AlignedStatMetric
    let sysMemPct: AlignedStatMetric
    let swapUsedBytes: AlignedStatMetric
    let sysPowerWatts: AlignedStatMetric
    let cpuPowerWatts: AlignedStatMetric
    let gpuPowerWatts: AlignedStatMetric
    let anePowerWatts: AlignedStatMetric
    let estimatedEnergyWh: Double?
    let dramReadGBps: AlignedStatMetric
    let dramWriteGBps: AlignedStatMetric
    let diskReadBps: AlignedStatMetric
    let diskWriteBps: AlignedStatMetric
    let worstThermalState: String
    let cliptoActiveSamples: Int
    let cliptoMaxProcesses: Int
    let cliptoCPUPercent: AlignedStatMetric
    let cliptoMemoryBytes: AlignedStatMetric
    let cliptoGPUPercent: AlignedStatMetric
    let cliptoDiskReadBps: AlignedStatMetric
    let cliptoDiskWriteBps: AlignedStatMetric
    let cmsTotalCPUPercent: AlignedStatMetric
    /// Summed GPU busy % of CMS-named processes (from per-process IOAccelerator GPU time).
    let cmsTotalGPUPercent: AlignedStatMetric
    let cmsTotalMemoryBytes: AlignedStatMetric
    let cmsProcesses: [AlignedCMSProcessItem]
    let series: [AlignedTimeSeriesPoint]

    enum CodingKeys: String, CodingKey {
        case hasData = "has_data"
        case sampleCount = "sample_count"
        case cmsFrameCount = "cms_frame_count"
        case windowStartMs = "window_start_ms"
        case windowEndMs = "window_end_ms"
        case windowStartText = "window_start_text"
        case windowEndText = "window_end_text"
        case targetActiveSeconds = "target_active_seconds"
        case coveredSeconds = "covered_seconds"
        case coveragePercent = "coverage_percent"
        case sysCPU = "sys_cpu"
        case sysGPU = "sys_gpu"
        case aneUsage = "ane_usage"
        case sysMemBytes = "sys_mem_bytes"
        case sysMemPct = "sys_mem_pct"
        case swapUsedBytes = "swap_used_bytes"
        case sysPowerWatts = "sys_power_watts"
        case cpuPowerWatts = "cpu_power_watts"
        case gpuPowerWatts = "gpu_power_watts"
        case anePowerWatts = "ane_power_watts"
        case estimatedEnergyWh = "estimated_energy_wh"
        case dramReadGBps = "dram_read_gbps"
        case dramWriteGBps = "dram_write_gbps"
        case diskReadBps = "disk_read_bps"
        case diskWriteBps = "disk_write_bps"
        case worstThermalState = "worst_thermal_state"
        case cliptoActiveSamples = "clipto_active_samples"
        case cliptoMaxProcesses = "clipto_max_processes"
        case cliptoCPUPercent = "clipto_cpu_percent"
        case cliptoMemoryBytes = "clipto_memory_bytes"
        case cliptoGPUPercent = "clipto_gpu_percent"
        case cliptoDiskReadBps = "clipto_disk_read_bps"
        case cliptoDiskWriteBps = "clipto_disk_write_bps"
        case cmsTotalCPUPercent = "cms_total_cpu_percent"
        case cmsTotalGPUPercent = "cms_total_gpu_percent"
        case cmsTotalMemoryBytes = "cms_total_memory_bytes"
        case cmsProcesses = "cms_processes"
        case series
    }
}

struct DAGSCAnalysisResponse: Codable, Sendable {
    let ok: Bool
    let appVersion: String
    let templateVersion: String
    let detectedUsername: String
    let defaultDagscDir: String
    let dagscDir: String
    let dbPath: String
    let dbSizeBytes: Int64
    let dbMtimeText: String
    let analyzedAtText: String

    // Slice metadata
    let sliceMode: String
    let selectedBatchID: String?
    let sliceLabel: String
    let sliceStartMs: Int64
    let sliceEndMs: Int64
    let sliceStartText: String
    let sliceEndText: String
    let activeIntervalsMs: [[Int64]]
    let availableBatches: [DAGSCBatchSummary]
    /// Batches that started before this epoch are hidden (0 = none). Set by "清空全部记录".
    let recordsEpochMs: Int64

    // Scoped totals
    let workflowsTotal: Int
    let assetsTotal: Int
    let videoAssetsCount: Int
    let imageAssetsCount: Int
    let totalMediaDurationMs: Int64
    let totalMediaSizeBytes: Int64
    let workflowsByTemplate: [DAGSCWorkflowSummary]
    let scopes: DAGSCScopesContainer
    let byAsset: [DAGSCAssetRow]
    let failedTaskSamples: [DAGSCFailedTaskSample]

    // Hardware & CMS alignment
    let environment: SystemEnvironmentInfo
    var alignedHardware: AlignedHardwareReport?

    enum CodingKeys: String, CodingKey {
        case ok
        case appVersion = "app_version"
        case templateVersion = "template_version"
        case detectedUsername = "detected_username"
        case defaultDagscDir = "default_dagsc_dir"
        case dagscDir = "dagsc_dir"
        case dbPath = "db_path"
        case dbSizeBytes = "db_size_bytes"
        case dbMtimeText = "db_mtime_text"
        case analyzedAtText = "analyzed_at_text"
        case sliceMode = "slice_mode"
        case selectedBatchID = "selected_batch_id"
        case sliceLabel = "slice_label"
        case sliceStartMs = "slice_start_ms"
        case sliceEndMs = "slice_end_ms"
        case sliceStartText = "slice_start_text"
        case sliceEndText = "slice_end_text"
        case activeIntervalsMs = "active_intervals_ms"
        case availableBatches = "available_batches"
        case recordsEpochMs = "records_epoch_ms"
        case workflowsTotal = "workflows_total"
        case assetsTotal = "assets_total"
        case videoAssetsCount = "video_assets_count"
        case imageAssetsCount = "image_assets_count"
        case totalMediaDurationMs = "total_media_duration_ms"
        case totalMediaSizeBytes = "total_media_size_bytes"
        case workflowsByTemplate = "workflows_by_template"
        case scopes
        case byAsset = "by_asset"
        case failedTaskSamples = "failed_task_samples"
        case environment
        case alignedHardware = "aligned_hardware"
    }
}
