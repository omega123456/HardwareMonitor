import Foundation

/// CPU and GPU temperatures from the SMC (R-6): the chip's key lists are resolved once at launch (DD-3), and every
/// resolved key is read each tick; the shown value is the hottest plausible reading.
final class Thermal {
    let chip: Chip
    private(set) var cpuKeys: [String] = []
    private(set) var gpuKeys: [String] = []
    private let smc: SMC

    init(smc: SMC) {
        self.smc = smc
        chip = Metrics.chip(System.current.sysctlString("machdep.cpu.brand_string") ?? "")
        guard smc.isOpen else { return }
        if let table = Metrics.temperatureKeys(chip) {
            // Keys the SMC lacks are dropped (on the M5 Pro, Tg1g).
            cpuKeys = table.cpu.filter { smc.info($0) != nil }
            gpuKeys = table.gpu.filter { smc.info($0) != nil }
        } else {
            // Unknown chip (owner decision): enumerate once, keep Tp*/Te* (CPU) and Tg* (GPU) by name before any
            // info or value read, then only keys whose first value is plausible.
            for key in smc.keys(where: { Metrics.fallbackSensor($0) != nil }) where smc.value(key).map(Metrics.plausible) == true {
                if Metrics.fallbackSensor(key) == .cpu { cpuKeys.append(key) } else { gpuKeys.append(key) }
            }
        }
    }

    /// One tick: every resolved key of each asked-for group, the hottest plausible reading per group (nil if none or
    /// not asked for).
    func read(cpu: Bool, gpu: Bool) -> (cpu: Double?, gpu: Double?) {
        (cpu ? Metrics.hottest(cpuKeys.compactMap(smc.value)) : nil, gpu ? Metrics.hottest(gpuKeys.compactMap(smc.value)) : nil)
    }
}
