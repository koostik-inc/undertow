import SwiftUI

/// A tiny inline throughput trace for list rows: download as a filled area, upload as a line.
struct SparklineView: View {
    let samples: [ThroughputSample]
    var window: TimeInterval = 60

    var body: some View {
        Canvas { context, size in
            let now = Date.now
            let visible = samples.filter { now.timeIntervalSince($0.timestamp) <= window }
            guard visible.count > 1 else { return }

            let peak = max(visible.map { max($0.receivedBytesPerSecond, $0.sentBytesPerSecond) }.max() ?? 0, 1)
            let start = now.timeIntervalSinceReferenceDate - window

            func point(_ sample: ThroughputSample, _ value: Double) -> CGPoint {
                let x = CGFloat((sample.timestamp.timeIntervalSinceReferenceDate - start) / window) * size.width
                let y = size.height - CGFloat(value / peak) * (size.height - 2) - 1
                return CGPoint(x: min(max(x, 0), size.width), y: y)
            }

            var download = Path()
            var upload = Path()
            for (index, sample) in visible.enumerated() {
                let d = point(sample, sample.receivedBytesPerSecond)
                let u = point(sample, sample.sentBytesPerSecond)
                if index == 0 {
                    download.move(to: d)
                    upload.move(to: u)
                } else {
                    download.addLine(to: d)
                    upload.addLine(to: u)
                }
            }

            var area = download
            if let last = visible.last, let first = visible.first {
                area.addLine(to: CGPoint(x: point(last, 0).x, y: size.height))
                area.addLine(to: CGPoint(x: point(first, 0).x, y: size.height))
                area.closeSubpath()
            }

            context.fill(area, with: .color(TrafficColor.download.opacity(0.25)))
            context.stroke(download, with: .color(TrafficColor.download), lineWidth: 1.5)
            context.stroke(upload, with: .color(TrafficColor.upload), lineWidth: 1.5)
        }
        .accessibilityLabel("Recent throughput")
    }
}
