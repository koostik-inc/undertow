import SwiftUI
import Charts

/// Download and upload rates over time on a single shared axis, with a hover crosshair.
struct ThroughputChartView: View {
    let samples: [ThroughputSample]
    var window: ChartWindow = .oneMinute

    @State private var selectedTime: Date?

    private var visibleSamples: [ThroughputSample] {
        let cutoff = Date.now.addingTimeInterval(-window.seconds)
        return samples.filter { $0.timestamp >= cutoff }
    }

    private var selectedSample: ThroughputSample? {
        guard let selectedTime else { return nil }
        return visibleSamples.min { abs($0.timestamp.timeIntervalSince(selectedTime)) < abs($1.timestamp.timeIntervalSince(selectedTime)) }
    }

    private var yCeiling: Double {
        let peak = visibleSamples.map { max($0.receivedBytesPerSecond, $0.sentBytesPerSecond) }.max() ?? 0
        return max(peak * 1.15, 8 * 1024)
    }

    var body: some View {
        let now = Date.now
        let data = visibleSamples
        let headline = selectedSample ?? data.last

        VStack(alignment: .leading, spacing: 8) {
            // Legend with current values doubles as direct labels; text stays in text color.
            HStack(spacing: 16) {
                legendItem("Download", color: TrafficColor.download, value: headline?.receivedBytesPerSecond)
                legendItem("Upload", color: TrafficColor.upload, value: headline?.sentBytesPerSecond)
                Spacer()
                if let selectedSample {
                    Text(selectedSample.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(data) { sample in
                    AreaMark(x: .value("Time", sample.timestamp),
                             y: .value("Rate", sample.receivedBytesPerSecond),
                             series: .value("Direction", "Download"),
                             stacking: .unstacked)
                        .foregroundStyle(TrafficColor.download.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("Rate", sample.receivedBytesPerSecond),
                             series: .value("Direction", "Download"))
                        .foregroundStyle(TrafficColor.download)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)

                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("Rate", sample.sentBytesPerSecond),
                             series: .value("Direction", "Upload"))
                        .foregroundStyle(TrafficColor.upload)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }

                if let selectedSample {
                    RuleMark(x: .value("Selected", selectedSample.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", selectedSample.timestamp),
                              y: .value("Rate", selectedSample.receivedBytesPerSecond))
                        .foregroundStyle(TrafficColor.download)
                        .symbolSize(60)
                    PointMark(x: .value("Time", selectedSample.timestamp),
                              y: .value("Rate", selectedSample.sentBytesPerSecond))
                        .foregroundStyle(TrafficColor.upload)
                        .symbolSize(60)
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-window.seconds)...now)
            .chartYScale(domain: 0...yCeiling)
            .chartXSelection(value: $selectedTime)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(ByteFormatting.rate(rate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour().minute().second(), centered: false)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Throughput over the last \(window.label)")
        }
    }

    private func legendItem(_ title: String, color: Color, value: Double?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ByteFormatting.rate(value ?? 0))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}
