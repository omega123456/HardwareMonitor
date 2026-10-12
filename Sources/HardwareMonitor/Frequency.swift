import Foundation

/// Per-core-type clock speeds (R-13): the DVFS tables are read once and the IOReport subscription created on the
/// first panel open (DD-3); each panel round takes one sample and turns the delta against the previous one into the
/// clock rows through `Metrics`. The previous sample is dropped on close.
final class Frequency {
    private let tables: [CoreType: [Double]]
    private let subscription: AnyObject?
    private let hasSuper: Bool
    private var previous: AnyObject?

    init(generation: Int?) {
        let started = DispatchTime.now().uptimeNanoseconds
        let g = generation ?? 0
        // `pmgr`, plus `pmgr-child` on M6+ (Stats' `getFrequencies`).
        let entries = g >= 6 ? ["pmgr", "pmgr-child"] : ["pmgr"]
        tables = g > 0 ? Metrics.clockTables(generation: g) { key in
            entries.lazy.compactMap { System.current.registryData($0, key) }.first { !$0.isEmpty }
        } : [:]
        let subscribed = System.current.ioReportSubscribe()
        subscription = subscribed?.handle
        // Unavailable: the labels follow the generation (Super cores from M5).
        hasSuper = subscribed.map { Metrics.hasSuper($0.channels) } ?? (g >= 5)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        EventLog.write("IOReport: " + (subscribed.map { "subscribed, \($0.channels.count) channels" } ?? "unavailable")
                       + ", tables " + [CoreType.efficiency, .performance, .superCore].map { "\(tables[$0]?.count ?? 0)" }.joined(separator: "/")
                       + String(format: " (%.1f ms)", ms))
    }

    /// One round: a sample; nil rows ("Measuring…") while it is only the baseline; every row "—" without IOReport.
    func sample() -> [ClockRow] {
        let labels = Metrics.clockRows(hasSuper: hasSuper)
        guard let subscription, let now = System.current.ioReportSample(subscription) else {
            return labels.map { ClockRow(label: $0.label, mhz: nil) }
        }
        defer { previous = now }
        guard let previous else { return labels.map { ClockRow(label: $0.label, mhz: nil, measuring: true) } }
        return Metrics.clocks(System.current.ioReportDelta(previous, now), tables: tables, hasSuper: hasSuper)
    }

    /// Whether IOReport has any CPU performance-state channel (for the `--log-events` launch line, R-24).
    static var available: Bool { System.current.ioReportChannelCount() > 0 }

    /// Panel closed: the next open starts with a new baseline.
    func reset() { previous = nil }
}
