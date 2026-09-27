import Charts
import SwiftUI

enum PulseTheme {
    static let canvasTop = Color(red: 0.040, green: 0.050, blue: 0.067)
    static let canvasBottom = Color(red: 0.025, green: 0.030, blue: 0.040)
    static let sidebar = Color(red: 0.030, green: 0.036, blue: 0.047)
    static let panel = Color(red: 0.063, green: 0.075, blue: 0.094)
    static let stroke = Color.white.opacity(0.085)
    static let cyan = Color(red: 0.28, green: 0.72, blue: 0.87)
    static let violet = Color(red: 0.58, green: 0.48, blue: 0.80)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PulseTheme.canvasTop, PulseTheme.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassPanel: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PulseTheme.panel)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(PulseTheme.stroke)
            }
            .overlay(alignment: .top) {
                if let tint {
                    Rectangle()
                        .fill(tint.opacity(0.72))
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

extension View {
    func glassPanel(tint: Color? = nil) -> some View { modifier(GlassPanel(tint: tint)) }
}

struct MetricCard: View {
    let title: String
    let icon: String
    let value: String
    let subtitle: String
    let tint: Color
    let samples: [MetricSample]
    var timeDomain: ClosedRange<Date>? = nil
    var comparison: TelemetrySeries? = nil
    var barMaximum: Double? = nil
    let metric: (MetricSample) -> Double?

    private var currentMetricValue: Double? {
        samples.reversed().lazy
            .filter { resolvedTimeDomain.contains($0.timestamp) }
            .compactMap(metric)
            .first { $0.isFinite }
    }

    private var observedMaximum: Double {
        samples.lazy
            .filter { resolvedTimeDomain.contains($0.timestamp) }
            .compactMap(metric)
            .filter(\.isFinite)
            .max() ?? currentMetricValue ?? 0
    }

    private var resolvedMaximum: Double {
        if let barMaximum { return max(0.001, barMaximum) }
        return max(1, observedMaximum * 1.15)
    }

    private var barProgress: Double {
        min(1, max(0, (currentMetricValue ?? 0) / resolvedMaximum))
    }

    private var scaleLabel: String {
        if let barMaximum, abs(barMaximum - 100) < 0.001 { return "100%" }
        return L10n.format("metric.recent_peak", MetricFormat.watts(observedMaximum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let comparison {
                    HStack(spacing: 5) {
                        Circle().fill(comparison.color).frame(width: 6, height: 6)
                        Text(comparison.name).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 30, weight: .medium, design: .default)).monospacedDigit()
                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            VStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<24, id: \.self) { index in
                        let threshold = Double(index + 1) / 24
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(threshold <= barProgress ? tint : Color.white.opacity(0.055))
                            .overlay {
                                if threshold <= barProgress {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(.white.opacity(index.isMultiple(of: 3) ? 0.08 : 0.025))
                                }
                            }
                    }
                }
                .frame(height: 28)

                HStack {
                    Text("0")
                    Spacer()
                    Text(scaleLabel)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .frame(height: 62)
        }
        .padding(16)
        .glassPanel()
    }

    private var resolvedTimeDomain: ClosedRange<Date> {
        timeDomain ?? samples.timeBounds
    }
}

struct TelemetrySeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let value: (MetricSample) -> Double?
}

struct TelemetryChart: View {
    let title: String
    let subtitle: String
    let icon: String
    let samples: [MetricSample]
    let series: [TelemetrySeries]
    var suffix: String = ""
    var timeDomain: ClosedRange<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PulseTheme.cyan)
                        .frame(width: 26, height: 26)
                        .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(title).font(.headline)
                }
                Spacer()
                HStack(spacing: 14) {
                    ForEach(series) { item in
                        HStack(spacing: 5) {
                            Circle().fill(item.color).frame(width: 7, height: 7)
                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            Chart {
                ForEach(series) { item in
                    ForEach(points(for: item)) { point in
                        LineMark(
                            x: .value(L10n.text("chart.time"), point.timestamp),
                            y: .value(item.name, point.value),
                            series: .value(L10n.text("chart.metric_segment"), point.seriesID)
                        )
                        .foregroundStyle(item.color)
                        .lineStyle(.init(lineWidth: 1.6))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(number, format: .number.precision(.fractionLength(0...1)))\(suffix)")
                        }
                    }
                }
            }
            .chartXScale(domain: resolvedTimeDomain)
            .chartPlotStyle { plot in
                plot
                    .background(.black.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(minHeight: 210)
        }
        .padding(20)
        .glassPanel()
    }

    private var resolvedTimeDomain: ClosedRange<Date> {
        timeDomain ?? samples.timeBounds
    }

    private func points(for item: TelemetrySeries) -> [ChartValuePoint] {
        chartPoints(
            samples: samples,
            series: item.name,
            limit: 180,
            domain: resolvedTimeDomain,
            value: item.value
        )
    }
}

private struct ChartValuePoint: Identifiable {
    let bucket: Int64
    let timestamp: Date
    let value: Double
    let seriesID: String
    var id: String { "\(seriesID)-\(bucket)" }
}

private struct ChartBucket {
    var timestampTotal = 0.0
    var valueTotal = 0.0
    var count = 0
}

private func chartPoints(
    samples: [MetricSample],
    series: String,
    limit: Int,
    domain: ClosedRange<Date>,
    value: (MetricSample) -> Double?
) -> [ChartValuePoint] {
    guard limit > 1 else { return [] }
    let span = Swift.max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
    let bucketWidth = Swift.max(1, ceil(span / Double(limit - 1)))
    var buckets: [Int64: ChartBucket] = [:]

    for sample in samples where domain.contains(sample.timestamp) {
        guard let number = value(sample), number.isFinite else { continue }
        let bucket = Int64(floor(sample.timestamp.timeIntervalSince1970 / bucketWidth))
        var aggregate = buckets[bucket] ?? ChartBucket()
        aggregate.timestampTotal += sample.timestamp.timeIntervalSince1970
        aggregate.valueTotal += number
        aggregate.count += 1
        buckets[bucket] = aggregate
    }

    var segment = 0
    var previousBucket: Int64?
    return buckets.keys.sorted().compactMap { bucket in
        guard let aggregate = buckets[bucket], aggregate.count > 0 else { return nil }
        if let previousBucket, bucket - previousBucket > 1 { segment += 1 }
        previousBucket = bucket
        return ChartValuePoint(
            bucket: bucket,
            timestamp: Date(timeIntervalSince1970: aggregate.timestampTotal / Double(aggregate.count)),
            value: aggregate.valueTotal / Double(aggregate.count),
            seriesID: "\(series)-\(segment)"
        )
    }
}

private extension Array where Element == MetricSample {
    var timeBounds: ClosedRange<Date> {
        let start = first?.timestamp ?? Date()
        let end = Swift.max(start.addingTimeInterval(1), last?.timestamp ?? start)
        return start...end
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.16)) }
        .foregroundStyle(color)
    }
}
