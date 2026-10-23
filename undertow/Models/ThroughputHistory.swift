import Foundation

/// One second of throughput, derived from consecutive cumulative byte counters.
nonisolated struct ThroughputSample: Hashable, Sendable, Identifiable {
    var timestamp: Date
    var receivedBytesPerSecond: Double
    var sentBytesPerSecond: Double

    var id: Date { timestamp }

    var totalBytesPerSecond: Double { receivedBytesPerSecond + sentBytesPerSecond }
}

/// A fixed-capacity rolling window of throughput samples for one tunnel.
nonisolated struct ThroughputHistory: Hashable, Sendable {
    /// Five minutes at one sample per second.
    static let defaultCapacity = 300

    private(set) var samples: [ThroughputSample] = []
    private var previous: TunnelRuntimeStatistics?
    let capacity: Int

    init(capacity: Int = ThroughputHistory.defaultCapacity) {
        self.capacity = capacity
    }

    var latest: ThroughputSample? { samples.last }

    var peakBytesPerSecond: Double {
        samples.map { max($0.receivedBytesPerSecond, $0.sentBytesPerSecond) }.max() ?? 0
    }

    /// Converts a new cumulative reading into a rate sample relative to the last reading.
    mutating func record(_ statistics: TunnelRuntimeStatistics) {
        defer { previous = statistics }
        guard let previous else {
            // First reading establishes the baseline; show it as idle so the chart keeps moving.
            record(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, at: statistics.timestamp)
            return
        }

        let elapsed = statistics.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return }

        // Counters reset when a tunnel reconnects; treat a decrease as zero traffic.
        let rxDelta = statistics.receivedBytes >= previous.receivedBytes
            ? statistics.receivedBytes - previous.receivedBytes : 0
        let txDelta = statistics.sentBytes >= previous.sentBytes
            ? statistics.sentBytes - previous.sentBytes : 0

        record(receivedBytesPerSecond: Double(rxDelta) / elapsed,
               sentBytesPerSecond: Double(txDelta) / elapsed,
               at: statistics.timestamp)
    }

    /// Records already-computed rates, e.g. an aggregate across tunnels.
    mutating func record(receivedBytesPerSecond: Double, sentBytesPerSecond: Double, at timestamp: Date = .now) {
        samples.append(ThroughputSample(timestamp: timestamp,
                                        receivedBytesPerSecond: receivedBytesPerSecond,
                                        sentBytesPerSecond: sentBytesPerSecond))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Records an explicit zero sample, keeping charts moving while a tunnel is idle or down.
    mutating func recordIdle(at timestamp: Date = .now) {
        record(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, at: timestamp)
    }

    /// Forgets the previous counters so the next reading starts a fresh baseline.
    mutating func resetBaseline() {
        previous = nil
    }

    /// Samples newer than `interval` seconds ago.
    func samples(within interval: TimeInterval, relativeTo now: Date = .now) -> [ThroughputSample] {
        let cutoff = now.addingTimeInterval(-interval)
        return samples.filter { $0.timestamp >= cutoff }
    }
}
