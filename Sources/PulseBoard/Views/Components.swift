import Charts
import SwiftUI

enum PulseTheme {
    static let canvasTop = Color(red: 0.045, green: 0.065, blue: 0.12)
    static let canvasBottom = Color(red: 0.018, green: 0.025, blue: 0.055)
    static let sidebar = Color(red: 0.025, green: 0.038, blue: 0.078)
    static let panel = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.10)
    static let cyan = Color(red: 0.15, green: 0.82, blue: 1.0)
    static let violet = Color(red: 0.60, green: 0.32, blue: 1.0)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PulseTheme.canvasTop, PulseTheme.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [PulseTheme.cyan.opacity(0.13), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 720
            )
            RadialGradient(
                colors: [PulseTheme.violet.opacity(0.10), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 640
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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint?.opacity(0.12) ?? PulseTheme.panel, PulseTheme.panel],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.16), tint?.opacity(0.20) ?? .white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
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
    let metric: (MetricSample) -> Double?

    private var points: [ChartValuePoint] {
        chartPoints(
            samples: samples,
            series: title,
            limit: 72,
            domain: resolvedTimeDomain,
            value: metric
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle().fill(tint).frame(width: 7, height: 7).shadow(color: tint, radius: 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Chart(points) { sample in
                AreaMark(
                    x: .value("时间", sample.timestamp),
                    y: .value(title, sample.value),
                    series: .value("连续区间", sample.seriesID)
                )
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value(title, sample.value),
                    series: .value("连续区间", sample.seriesID)
                )
                .foregroundStyle(tint)
                .lineStyle(.init(lineWidth: 2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: resolvedTimeDomain)
            .frame(height: 52)
        }
        .padding(17)
        .glassPanel(tint: tint)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PulseTheme.cyan)
                        .frame(width: 30, height: 30)
                        .background(PulseTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(title).font(.headline)
                }
                Spacer()
                HStack(spacing: 12) {
                    ForEach(series) { item in
                        HStack(spacing: 5) {
                            Circle().fill(item.color).frame(width: 7, height: 7)
                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.04), in: Capsule())
                    }
                }
            }
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            Chart {
                ForEach(series) { item in
                    ForEach(points(for: item)) { point in
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value(item.name, point.value),
                            series: .value("指标与连续区间", point.seriesID)
                        )
                        .foregroundStyle(item.color)
                        .lineStyle(.init(lineWidth: 2))
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
                    .background(.black.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.22)) }
        .foregroundStyle(color)
    }
}
