import IOKit

/// GPU utilisation (R-4): the `IOAccelerator` entry is looked up once and kept (DD-3); each tick reads only its
/// `PerformanceStatistics` property.
final class GPU {
    private let entry = System.current.service("IOAccelerator")

    func read() -> Int? {
        guard entry != 0, let stats = System.current.property(entry, "PerformanceStatistics") as? [String: Any],
              let usage = stats["Device Utilization %"] as? Int else { return nil }
        return max(0, min(100, usage))
    }
}
