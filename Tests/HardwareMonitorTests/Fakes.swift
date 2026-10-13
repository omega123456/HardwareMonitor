import AppKit
import ServiceManagement
import Testing
@testable import HardwareMonitor

/// Every test that swaps the global seams (`System`, `Env`, `StatusItem`, …) is nested in this suite, so none run
/// concurrently.
@Suite(.serialized) struct Desktop {}

/// Own notification center (system workspace events never arrive), switchable Increase Contrast, Reduce
/// Transparency (`solid`) and Reduce Motion (`still`).
final class FakeWorkspace: NSWorkspace {
    let center = NotificationCenter()
    var contrast = false, solid = false, still = false

    override var notificationCenter: NotificationCenter { center }
    override var accessibilityDisplayShouldIncreaseContrast: Bool { contrast }
    override var accessibilityDisplayShouldReduceTransparency: Bool { solid }
    override var accessibilityDisplayShouldReduceMotion: Bool { still }
}

/// The hover panel's window, never ordered onto a real screen: ordering in and out only flips `shown`.
final class OffscreenPanel: HoverPanel {
    var shown = false
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

/// The `Env` one-shot scheduler, fired by hand: `Harness.advance` moves the fake clock and fires what's due, in order.
final class FakeScheduler {
    final class Item: Cancellable {
        let at: Date
        let tolerance: TimeInterval
        let fire: () -> Void
        var cancelled = false
        init(_ at: Date, _ tolerance: TimeInterval, _ fire: @escaping () -> Void) {
            self.at = at
            self.tolerance = tolerance
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    var items: [Item] = []
    var pending: [Item] { items.filter { !$0.cancelled }.sorted { $0.at < $1.at } }
}

/// The stub `System` (R-10, NFR-6): raw values as the real calls would return them, and counters of every call the
/// tests assert on. Nothing reaches real hardware.
final class StubSystem: System {
    var ints: [String: Int] = [:]
    var strings: [String: String] = [:]
    var swap: UInt64? = 0

    /// `HOST_CPU_LOAD_INFO` ticks (user, system, idle, nice), advanced by `tickStep` before every read.
    var ticks: [UInt32]? = [1000, 1000, 1000, 1000]
    var tickStep: [UInt32] = [38, 0, 62, 0]
    var cpuReads = 0

    var vm: vm_statistics64? = vm_statistics64()
    var page = 16384

    /// The IOAccelerator entry (0: none) and its `PerformanceStatistics`.
    var accelerator: io_registry_entry_t = 7
    var gpuStats: [String: Any]? = ["Device Utilization %": 12]
    var propertyReads: [String] = []

    /// SMC keys: four-char type and value bytes. `#KEY` (the count) is answered from them unless `keyCount` overrides
    /// it; enumeration is in name order. A missing key answers result 0x84 (key not found) with zeroed data.
    var smcAvailable = true
    var keyCount: Int?
    var smc: [String: (type: String, bytes: [UInt8])] = [:]
    var infoFetches: [String] = [], valueFetches: [String] = []
    var smcClosed = false

    var sources: [[String: Any]] = []
    var adapter: [String: Any]?
    var sourceReads = 0

    var volume: (available: Int64?, total: Int?, name: String?) = (nil, nil, nil)
    var diskReads = 0

    var pressureHandler: (() -> Void)?, powerHandler: (() -> Void)?

    /// Panel only: running-app names, the `pmgr` table bytes ("entry/key"), and IOReport (a subscription with the
    /// delta's channel names; every delta returns `channels`).
    var appNames: [Int32: String] = [:]
    var nameLookups: [Int32] = []
    var registry: [String: [UInt8]] = [:]
    var registryReads = 0
    var ioReport = true
    var channels: [IOReportChannel] = []
    var subscriptions = 0, samples = 0
    var deltas: [(Int, Int)] = []

    /// A `flt ` key (little-endian float).
    func setFloat(_ key: String, _ value: Double) {
        let bits = Float(value).bitPattern
        smc[key] = ("flt ", [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) })
    }

    /// A `ui16` or `si16` key (little-endian).
    func setInt16(_ key: String, _ value: Int, signed: Bool = false) {
        let bits = UInt16(truncatingIfNeeded: value)
        smc[key] = (signed ? "si16" : "ui16", [UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)])
    }

    private var keyNames: [String] { smc.keys.sorted() }

    override func sysctlInt(_ name: String) -> Int? { ints[name] }
    override func sysctlString(_ name: String) -> String? { strings[name] }
    override func swapUsed() -> UInt64? { swap }

    override func cpuTicks() -> [UInt32]? {
        cpuReads += 1
        ticks = ticks.map { zip($0, tickStep).map { $0 &+ $1 } }
        return ticks
    }

    override func vmStatistics() -> vm_statistics64? { vm }
    override func pageSize() -> Int { page }

    override func service(_ className: String) -> io_registry_entry_t { className == "IOAccelerator" ? accelerator : 0 }
    override func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        propertyReads.append(key)
        return entry == accelerator && key == "PerformanceStatistics" ? gpuStats : nil
    }

    override func smcOpen() -> Bool { smcAvailable }
    override func smcClose() { smcClosed = true }

    override func smcKeyInfo(_ key: UInt32) -> (result: UInt8, size: UInt32, type: UInt32)? {
        let name = SMC.name(key)
        infoFetches.append(name)
        if name == "#KEY" { return (0, 4, SMC.code("ui32")) }
        return smc[name].map { (0, UInt32($0.bytes.count), SMC.code($0.type)) } ?? (0x84, 0, 0)
    }

    override func smcRead(_ key: UInt32, size: UInt32) -> (result: UInt8, bytes: [UInt8])? {
        let name = SMC.name(key)
        valueFetches.append(name)
        if name == "#KEY" { return (0, [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(keyCount ?? smc.count) >> $0) }) }
        return smc[name].map { (0, $0.bytes) } ?? (0x84, [UInt8](repeating: 0, count: Int(size)))
    }

    override func smcKey(at index: UInt32) -> (result: UInt8, key: UInt32)? {
        Int(index) < keyNames.count ? (0, SMC.code(keyNames[Int(index)])) : (0x84, 0)
    }

    override func powerSources() -> [[String: Any]] {
        sourceReads += 1
        return sources
    }

    override func adapterDetails() -> [String: Any]? { adapter }
    override func observePowerSources(_ handler: @escaping () -> Void) { powerHandler = handler }
    override func observeMemoryPressure(_ handler: @escaping () -> Void) { pressureHandler = handler }

    override func bootVolume() -> (available: Int64?, total: Int?, name: String?) {
        diskReads += 1
        return volume
    }

    override func appName(_ pid: Int32) -> String? {
        nameLookups.append(pid)
        return appNames[pid]
    }

    override func registryData(_ entry: String, _ key: String) -> [UInt8]? {
        registryReads += 1
        return registry["\(entry)/\(key)"]
    }

    override func ioReportChannelCount() -> Int { ioReport ? channels.count : 0 }

    override func ioReportSubscribe() -> (handle: AnyObject, channels: [String])? {
        guard ioReport else { return nil }
        subscriptions += 1
        return (NSObject(), channels.map(\.name))
    }

    /// Called on every sample (a test can move the clock to model the sample's cost).
    var onSample: () -> Void = {}

    override func ioReportSample(_ handle: AnyObject) -> AnyObject? {
        samples += 1
        onSample()
        return NSNumber(value: samples)
    }

    override func ioReportDelta(_ earlier: AnyObject, _ later: AnyObject) -> [IOReportChannel] {
        deltas.append(((earlier as! NSNumber).intValue, (later as! NSNumber).intValue))
        return channels
    }
}

/// The history generator (plan, Test fixtures): the artifact's sparkline formula at half steps (1 s samples over its
/// 2 s curve) for samples 0–118, sample 119 = the shown usage; `have` keeps only the newest samples (a short history),
/// `gaps` are missing samples.
struct Spark {
    var base: Double, amp: Double, seed: Double
    var have = History.capacity
    var gaps: [Int] = []

    func history(usage: Int?) -> History {
        var h = History()
        let n = History.capacity
        for i in (n - have)..<n {
            let x = Double(i) / 2
            let v = base + amp * sin(x / 6 + seed) + 0.55 * amp * sin(x / 2.1 + 3 * seed) + 0.3 * amp * sin(1.7 * x + seed)
            h.append(gaps.contains(i) ? nil : i == n - 1 ? usage : Int(max(1, min(99, v)).rounded()))
        }
        return h
    }
}

/// The plan's fixtures (Data & State → Test fixtures) as readable values, installed as raw stub `System` values so the
/// real readers decode them: an M5 Pro with its SMC keys (Tg1g absent), VM counts, power-source dictionaries and
/// boot-volume values.
struct Fixture {
    var cpu: UInt32 = 38, cpuTemp: Double? = 61
    var gpu = 12, gpuTemp: Double? = 54
    var usedGiB = 23.0, totalGiB = 32.0, pressure = 1, fill = 18, swapGiB = 0.0
    var smc = true
    var system = 14.0, dcIn = 0.0, battery: Double? = 14
    var hasBattery = true, connected = false, charging = false, percent = 64
    var adapter: Int?
    var free: Int64 = 412_000_000_000, total: Int64 = 926_000_000_000
    var cpuSpark = Spark(base: 38, amp: 16, seed: 1), gpuSpark = Spark(base: 12, amp: 5, seed: 4)

    /// On battery: CPU 38 %/61°, GPU 12 %/54°, memory 72 % normal (23.0 of 32 GB), 14 W, 412 of 926 GB.
    static let normal = Fixture()
    static let charging = Fixture(system: 18, dcIn: 61, battery: 43, connected: true, charging: true, percent: 78, adapter: 96)
    static let heldConnected = Fixture(cpu: 22, cpuTemp: 55, gpu: 35, gpuTemp: 50, usedGiB: 37.1, totalGiB: 64, swapGiB: 10.5,
                                       system: 20, dcIn: 21, battery: 1.1, connected: true, percent: 85, adapter: 65,
                                       cpuSpark: Spark(base: 22, amp: 9, seed: 3), gpuSpark: Spark(base: 35, amp: 8, seed: 5))
    static let memWarningGpuMissing = Fixture(cpu: 64, cpuTemp: 78, gpu: 31, gpuTemp: nil, usedGiB: 28.2, pressure: 2, fill: 62,
                                              swapGiB: 3.4, system: 12, battery: 12,
                                              cpuSpark: Spark(base: 64, amp: 20, seed: 2), gpuSpark: Spark(base: 31, amp: 11, seed: 7))
    static let memCritical = Fixture(usedGiB: 30.72, pressure: 4, fill: 91)
    static let cpuWarm = Fixture(cpu: 82, cpuTemp: 88, cpuSpark: Spark(base: 82, amp: 12, seed: 2))
    static let hotCPU = Fixture(cpu: 100, cpuTemp: 97, cpuSpark: Spark(base: 100, amp: 4, seed: 3))
    static let lowDisk = Fixture(free: 61_000_000_000)
    static let diskCritical = Fixture(free: 30_000_000_000)
    static let terabyte = Fixture(free: 1_200_000_000_000, total: 1_812_000_000_000)
    static let lowDrawBattery = Fixture(system: 4.2, battery: 4.2)
    static let lowDrawConnected = Fixture(system: 4.4, dcIn: 4.6, battery: 0.2, connected: true, percent: 85, adapter: 65)
    static let gpuGaps = Fixture(gpu: 24, gpuTemp: 52, gpuSpark: Spark(base: 24, amp: 10, seed: 6, gaps: [44, 45, 46, 47, 80, 81]))
    static let shortHistory = Fixture(cpu: 31, cpuTemp: 58, gpu: 9, gpuTemp: 49, cpuSpark: Spark(base: 31, amp: 12, seed: 4, have: 40),
                                      gpuSpark: Spark(base: 9, amp: 5, seed: 8, have: 40))
    static let smcUnavailable = Fixture(smc: false)
    /// A desktop: no battery, no B0AC/B0AV (the menu bar's bottom line is a dim "—"); the PDTR value only feeds the panel's
    /// "Adapter in" row and is this fixture's own choice.
    static let noBattery = Fixture(dcIn: 15, battery: nil, hasBattery: false)

    static let gib = 1_073_741_824.0
    static let m5CPU = "Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y".split(separator: " ").map(String.init)
    static let m5GPU = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c"] // Tg1g is absent on the M5 Pro

    func install(_ s: StubSystem) {
        s.strings["machdep.cpu.brand_string"] = "Apple M5 Pro"
        s.tickStep = [cpu, 0, 100 - cpu, 0]
        s.gpuStats = ["Device Utilization %": gpu, "In use system memory": 1]
        let memory = UInt64(totalGiB * Self.gib), used = UInt64(usedGiB * Self.gib) / UInt64(s.page)
        var vm = vm_statistics64()
        vm.wire_count = natural_t(used / 5)
        vm.compressor_page_count = natural_t(used / 10)
        vm.purgeable_count = 1000
        vm.internal_page_count = natural_t(used - used / 5 - used / 10 + 1000)
        s.vm = vm
        s.ints = ["hw.memsize": Int(memory), "kern.memorystatus_vm_pressure_level": pressure, "kern.memorystatus_level": 100 - fill]
        s.swap = UInt64(swapGiB * Self.gib)
        s.smcAvailable = smc
        s.smc = [:]
        // The first key is the hottest, the others 1–5 °C cooler; a missing temperature reads 0 (implausible).
        for (i, key) in Self.m5CPU.enumerated() { s.setFloat(key, cpuTemp.map { i == 0 ? $0 : $0 - 1 - Double(i % 5) } ?? 0) }
        for (i, key) in Self.m5GPU.enumerated() { s.setFloat(key, gpuTemp.map { i == 0 ? $0 : $0 - 1 - Double(i % 3) } ?? 0) }
        s.setFloat("PSTR", system)
        s.setFloat("PDTR", dcIn)
        if let battery { // 10 V, so the current in mA is the watts × 100; negative on battery
            s.setInt16("B0AC", Int((battery * 100).rounded()) * (connected ? 1 : -1), signed: true)
            s.setInt16("B0AV", 10000)
        }
        s.sources = hasBattery ? [[
            "Type": "InternalBattery", "Power Source State": connected ? "AC Power" : "Battery Power",
            "Is Charging": charging, "Current Capacity": percent, "Max Capacity": 100,
        ]] : []
        s.adapter = adapter.map { ["Watts": $0] }
        s.volume = (free, Int(total), "Macintosh HD")
        s.registry = Self.clocksM5.tables
        s.channels = Self.clocksM5.channels
    }

    // MARK: Panel only

    /// The `procs` fixture (plan, Test fixtures): `ps` and `top` output captured on the owner's Mac, `top` with two
    /// edge-case lines appended (a `*` after the pid, `+`/`-` after MEM).
    static let psText = """
          PID  %CPU COMM
         4801  69.6 npm exec ccstatusline@latest
        34705  28.2 Docker Desktop Helper (Renderer)
         4816  16.4 node
        36196  12.7 com.docker.sailor
          415   9.6 WindowServer
        89800   9.4 claude
        65603   6.3 stable
        48864   3.9 Stats
         1008   3.1 Vivaldi Helper
          385   2.5 launchservicesd
         4800   1.5 Vivaldi Helper (Renderer)
        47720   1.2 Microsoft Teams WebView Helper (Renderer)
        44825   1.1 Activity Monitor
          418   1.1 loginwindow
          407   1.0 bluetoothd
        """
    static let topText = """
        Disks: 229114158/2988G read, 740434316/5429G written.

        PID    COMMAND          MEM  
        36196  com.docker.sailo 9229M
        1008   Vivaldi Helper   8930M
        415    WindowServer     2411M
        65603  stable           1753M
        772    Vivaldi          1657M
        47720  Microsoft Teams  1304M
        7771   Vivaldi Helper ( 1214M
        71061  Vivaldi Helper ( 1064M
        0*     kernel_task      512K+
        5555   Finder           1.2G-
        """

    /// The lists as the first refresh ranks them (no app names).
    static func procs(slots: Int = 8) -> (cpu: [ProcessRow], memory: [ProcessRow]) {
        func ranked(_ rows: [ProcessRow], _ unit: Double) -> [ProcessRow] {
            Metrics.named(Metrics.rank(shown: [], fresh: rows, slots: slots, unit: unit)) { _ in nil }
        }
        return (ranked(Metrics.parsePS(psText), Metrics.cpuUnit), ranked(Metrics.parseTop(topText), Metrics.memoryUnit))
    }

    /// `clocksM5`: the M5 Pro layout. PCPU0–5 active (Super, 15-entry kHz table: three at 3.0 GHz, three at 2.0),
    /// MCPU00–05 parked, MCPU10–15 active (Performance, 20-entry kHz table, at 3.8 GHz): Super 2.5, Performance 1.9.
    static let clocksM5: (tables: [String: [UInt8]], channels: [IOReportChannel]) = {
        let superTable = (0..<15).map { UInt32(1000 + $0 * 250) }, perfTable = (0..<20).map { UInt32(1000 + $0 * 200) }
        func at(_ mhz: UInt32, _ table: [UInt32]) -> [Int64] { table.map { $0 == mhz ? 1000 : 0 } }
        return (["pmgr/voltage-states1-sram": SelfTest.dvfsBytes([600_000, 1_200_000]),
                 "pmgr/voltage-states5-sram": SelfTest.dvfsBytes(superTable.map { $0 * 1000 }),
                 "pmgr/voltage-states22-sram": SelfTest.dvfsBytes(perfTable.map { $0 * 1000 })],
                (0..<6).map { SelfTest.channel("PCPU\($0)", at($0 < 3 ? 3000 : 2000, superTable)) }
                    + (0..<6).map { SelfTest.channel("MCPU0\($0)", at(0, perfTable)) }
                    + (0..<6).map { SelfTest.channel("MCPU1\($0)", at(3800, perfTable)) })
    }()

    /// `clocksM1`: ECPU0–3 and PCPU0–3 with Hz tables: Efficiency 1.7 GHz, Performance 3.2 GHz.
    static let clocksM1: (tables: [String: [UInt8]], channels: [IOReportChannel]) = {
        let e = [600, 900, 1200, 1500, 2000].map { UInt32($0) }, p = (0..<15).map { UInt32(600 + $0 * 200) }
        return (["pmgr/voltage-states1-sram": SelfTest.dvfsBytes(e.map { $0 * 1_000_000 }),
                 "pmgr/voltage-states5-sram": SelfTest.dvfsBytes(p.map { $0 * 1_000_000 })],
                (0..<4).map { SelfTest.channel("ECPU\($0)", [0, 0, 1, 1, 2]) }
                    + (0..<4).map { SelfTest.channel("PCPU\($0)", p.map { $0 == 3200 ? 1 : 0 }) })
    }()
}

/// Installs fresh fakes behind every seam. One per test. Nothing reaches real hardware, the desktop, the login item,
/// defaults or the network, and no test waits for a timer in real time.
@MainActor
final class Harness {
    let system = StubSystem()
    let ws = FakeWorkspace()
    let distributed = NotificationCenter()
    let center = NotificationCenter()
    let scheduler = FakeScheduler()
    /// 2026-10-12 09:41:00 UTC, the artifact's "Mon 12 Oct 09:41".
    var now = Date(timeIntervalSince1970: 1_791_798_060)
    var defaults: UserDefaults
    var terminations = 0
    var locked = false, displaysAsleep = false

    var popUps: [NSMenu] = []
    /// Every panel fade: the window's frame and alpha before it, and the end state it animates to.
    var animations: [(startFrame: CGRect, startAlpha: CGFloat, endFrame: CGRect, endAlpha: CGFloat)] = []
    /// The outside-click monitor's handler while one is installed, and how many were installed in total.
    var clickMonitor: (() -> Void)?
    var monitorInstalls = 0
    /// The status item's window and its screen's visible frame: a 1728 × 1117 display with a 24 pt menu bar.
    var itemFrame = CGRect(x: 1400, y: 1093, width: 300, height: 24)
    var visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1093)
    /// The system appearance the right-click menu gets (System Settings → Appearance).
    var systemAppearance = NSAppearance(named: .aqua)!
    var loginStatus = SMAppService.Status.notRegistered
    var loginCalls: [String] = []
    var loginError: Error?
    var notices: [String] = []
    var asks: [String] = []
    var relaunches: [URL] = []
    let dir: URL

    init(_ fixture: Fixture = .normal) {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HardwareMonitorTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "local.hardwaremonitor.tests")!
        defaults.removePersistentDomain(forName: "local.hardwaremonitor.tests")

        fixture.install(system)
        System.current = system
        Env.workspace = ws
        Env.distributed = distributed
        Env.center = center
        Env.defaults = defaults
        Env.terminate = { [unowned self] in terminations += 1 }
        Env.now = { [unowned self] in now }
        Env.schedule = { [unowned self] at, tolerance, fire in
            let item = FakeScheduler.Item(at, tolerance, fire)
            scheduler.items.append(item)
            return item
        }
        Env.isSessionLocked = { [unowned self] in locked }
        Env.displaysAsleep = { [unowned self] in displaysAsleep }

        StatusItem.showsStatusItem = false
        StatusItem.popUp = { [unowned self] menu, _ in popUps.append(menu) }
        StatusItem.systemAppearance = { [unowned self] in systemAppearance }
        StatusItem.monitorClicks = { [unowned self] handler in
            monitorInstalls += 1
            clickMonitor = handler
            return { [unowned self] in clickMonitor = nil }
        }
        StatusItem.panelClass = OffscreenPanel.self
        StatusItem.anchor = { [unowned self] _ in (itemFrame, visibleFrame) }
        StatusItem.animate = { [unowned self] window, frame, alpha in // recorded, then the fade's end state at once
            animations.append((window.frame, window.alphaValue, frame, alpha))
            window.setFrame(frame, display: false)
            window.alphaValue = alpha
        }
        // The process commands: /bin/sh scripts that record their pid and print the `procs` fixture (NFR-6).
        Processes.commands = [.ps: script("ps", "cat <<'EOF'\n\(Fixture.psText)\nEOF"),
                              .top: script("top", "cat <<'EOF'\n\(Fixture.topText)\nEOF")]
        Style.appearanceOverride = nil
        LaunchAtLogin.service = .init(
            status: { [unowned self] in loginStatus },
            register: { [unowned self] in
                loginCalls.append("register")
                if let loginError { throw loginError }
                loginStatus = .requiresApproval
            },
            unregister: { [unowned self] in loginCalls.append("unregister"); loginStatus = .notRegistered },
            openSettings: { [unowned self] in loginCalls.append("settings") })
        Updater.resume() // clears a pause left by an earlier test
        Updater.isInstallable = false
        Updater.current = "1.0.0"
        Updater.bundleURL = dir.appendingPathComponent("HardwareMonitor.app")
        Updater.notice = { [unowned self] header, _ in notices.append(header) }
        Updater.ask = { [unowned self] version, _ in asks.append(version) }
        Updater.verify = { _ in }
        Updater.relaunch = { [unowned self] in relaunches.append($0) }
        EventLog.url = dir.appendingPathComponent("events.log")
        EventLog.enable()
    }

    var log: String { (try? String(contentsOf: EventLog.url, encoding: .utf8)) ?? "" }

    /// Moves the fake clock by `seconds`, firing every armed one-shot that comes due, in order.
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = scheduler.pending.first, next.at <= end {
            now = max(now, next.at)
            next.cancelled = true
            next.fire()
        }
        now = end
    }

    /// Pending one-shots, as seconds from now (to the microsecond, so date arithmetic doesn't leave float noise).
    var armed: [TimeInterval] { scheduler.pending.map { ($0.at.timeIntervalSince(now) * 1e6).rounded() / 1e6 } }

    /// A `/bin/sh` fixture script that appends its pid to `<name>.pids`, then runs `body`; returns its command line.
    @discardableResult
    func script(_ name: String, _ body: String) -> [String] {
        let url = dir.appendingPathComponent("\(name).sh")
        try! "echo $$ >> '\(dir.path)/\(name).pids'\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return ["/bin/sh", url.path]
    }

    /// The pids of every run of the script `name`, in launch order.
    func launches(_ name: String) -> [Int32] {
        ((try? String(contentsOf: dir.appendingPathComponent("\(name).pids"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Int32($0) }
    }

    /// A mouse-down in another app (outside the panel and the status item), as the global monitor sees it.
    func clickOutside() { clickMonitor?() }

    /// Waits (real time, polling the main queue) until `done` holds or `timeout` passes. Only for real processes.
    func until(_ timeout: Double = 5, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { await settle(0.02) }
    }

    /// The R-2 events, as the dispatch memory-pressure source and the power-source notification deliver them.
    func pressureEvent() { system.pressureHandler?() }
    func powerEvent() { system.powerHandler?() }

    /// The app launched as `HardwareMonitorMain` would after `NSApplication.run`.
    func launch() -> AppDelegate {
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return app
    }

    /// The snapshot after launch and one more tick (the first CPU % needs a baseline).
    func snapshot() -> Snapshot {
        let sampler = Sampler()
        sampler.start()
        advance(Sampler.interval)
        return sampler.snapshot
    }
}

/// A right/left mouse-up for click routing.
@MainActor
func mouseUp(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// Lets main-queue deliveries of real asynchronous work (URLSession, processes) run. Never used for timers: those go
/// through the fake scheduler.
func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }
