import Charts
import SwiftUI

struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}

extension View {
    func glassPanel() -> some View { modifier(GlassPanel()) }
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
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint, radius: 5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
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
        .padding(18)
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
                Label(title, systemImage: icon).font(.headline)
                Spacer()
                HStack(spacing: 12) {
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
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}
