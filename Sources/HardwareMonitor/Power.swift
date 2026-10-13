import Foundation
import IOKit.ps

/// Power numbers and state (R-7): the SMC power keys each tick, the power-source state and adapter rating at launch,
/// on every power event (R-2) and on every return to visible (R-21).
final class Power {
    private let smc: SMC

    init(smc: SMC) { self.smc = smc }

    /// `PSTR` (system draw) and `PDTR` (DC-in; key names from exelban/Stats), and battery power, unsigned: `B0AC`
    /// (battery current, mA, negative on battery) × `B0AV` (battery voltage, mV). Not `PPBR`: on an M5 Pro it reads
    /// ~1 W while the battery charges at ~25 W.
    func read() -> (system: Double?, dcIn: Double?, battery: Double?) {
        let battery = smc.value("B0AC").flatMap { mA in smc.value("B0AV").map { mV in abs(mA * mV) / 1e6 } }
        return (smc.value("PSTR"), smc.value("PDTR"), battery)
    }

    static func source() -> PowerSource { decode(System.current.powerSources(), adapter: System.current.adapterDetails()) }

    /// The internal battery's description (connected, charging, %) and the adapter's `Watts`. Without a battery: a
    /// desktop, always "connected, not charging".
    static func decode(_ sources: [[String: Any]], adapter: [String: Any]?) -> PowerSource {
        var s = PowerSource(adapterWatts: adapter?[kIOPSPowerAdapterWattsKey] as? Int)
        guard let battery = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else { return s }
        s.hasBattery = true
        s.connected = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        s.charging = battery[kIOPSIsChargingKey] as? Bool ?? false
        if let current = battery[kIOPSCurrentCapacityKey] as? Int, let max = battery[kIOPSMaxCapacityKey] as? Int {
            s.percent = Metrics.percent(Double(current), of: Double(max))
        }
        return s
    }

    /// The IOKit power-source run-loop notification.
    static func observe(_ handler: @escaping () -> Void) { System.current.observePowerSources(handler) }
}
