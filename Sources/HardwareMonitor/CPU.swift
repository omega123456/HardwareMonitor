import Foundation

/// CPU usage from `HOST_CPU_LOAD_INFO` tick deltas (R-3).
final class CPU {
    enum Usage: Equatable {
        case percent(Int)
        /// No previous read (launch, or the first tick after a return): not a failure (R-3a).
        case noBaseline
        case failed
    }

    private var last: [UInt32]?

    func read() -> Usage {
        guard let now = System.current.cpuTicks() else { return .failed }
        defer { last = now }
        guard let last else { return .noBaseline }
        return Metrics.cpuPercent(from: last, to: now).map(Usage.percent) ?? .failed
    }

    /// Drops the baseline (on leaving visible), so the first % after a return counts from the return tick (R-21).
    func reset() { last = nil }
}
