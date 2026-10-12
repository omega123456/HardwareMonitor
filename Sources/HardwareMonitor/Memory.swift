import Foundation

/// Memory (R-5): VM statistics, the pressure sysctls and swap, read each tick and on every pressure event (R-2).
enum Memory {
    static func read() -> MemoryReading? {
        let system = System.current
        guard let vm = system.vmStatistics(), let total = system.sysctlInt("hw.memsize"), total > 0 else { return nil }
        let used = Metrics.memoryUsed(internal: UInt64(vm.internal_page_count), purgeable: UInt64(vm.purgeable_count),
                                      wired: UInt64(vm.wire_count), compressed: UInt64(vm.compressor_page_count),
                                      pageSize: UInt64(system.pageSize()))
        return MemoryReading(used: used, total: UInt64(total), percent: Metrics.percent(Double(used), of: Double(total)) ?? 0,
                             level: Metrics.pressure(system.sysctlInt("kern.memorystatus_vm_pressure_level")),
                             fill: Metrics.pressureFill(system.sysctlInt("kern.memorystatus_level")),
                             swap: system.swapUsed())
    }

    /// The dispatch memory-pressure source (normal, warning, critical masks).
    static func observe(_ handler: @escaping () -> Void) { System.current.observeMemoryPressure(handler) }
}
