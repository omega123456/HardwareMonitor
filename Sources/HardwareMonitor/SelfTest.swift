import Foundation

/// `--self-test` (R-24): checks of the pure logic in `Metrics` with explicit failure counting (not `assert`, which is
/// compiled out of release builds). Returns false if any check failed.
enum SelfTest {
    private static var total = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failures.append(name) }
    }

    static func run() -> Bool {
        total = 0
        failures = []
        let groups: [(String, () -> Void)] = [
            ("visibility", visibility), ("chip", chip), ("temperature keys", temperatureKeys), ("prefix filter", prefixFilter),
            ("usage", usage), ("temperature", temperature), ("power state", powerState), ("formats", formats),
            ("levels", levels), ("missing values", missingValues), ("history", history), ("shown items", shownItems), ("columns", columns),
            ("accessibility", accessibility), ("updater", updateVersions),
            ("process parsing", processParsing), ("process naming", processNaming), ("ranking", ranking),
            ("clocks", clocks), ("power track", powerTrack), ("short screen", shortScreen), ("panel strings", panelStrings),
            ("panel labels", panelLabels),
        ]
        for (name, group) in groups {
            let before = total
            group()
            print("\(name): \(total - before) checks")
        }
        for f in failures { print("FAIL: \(f)") }
        print("self-test: \(total - failures.count)/\(total) checks passed")
        return failures.isEmpty
    }

    // MARK: Visibility (R-21)

    private static func visibility() {
        check("visible when all hold", Metrics.isVisible(awake: true, displaysAwake: true, sessionActive: true, unlocked: true))
        check("asleep", !Metrics.isVisible(awake: false, displaysAwake: true, sessionActive: true, unlocked: true))
        check("displays asleep (DarkWake)", !Metrics.isVisible(awake: true, displaysAwake: false, sessionActive: true, unlocked: true))
        check("session resigned", !Metrics.isVisible(awake: true, displaysAwake: true, sessionActive: false, unlocked: true))
        check("locked", !Metrics.isVisible(awake: true, displaysAwake: true, sessionActive: true, unlocked: false))
        check("launch: visible", Metrics.visibleAtLaunch(locked: false, displaysAsleep: false))
        check("launch: locked", !Metrics.visibleAtLaunch(locked: true, displaysAsleep: false))
        check("launch: displays asleep", !Metrics.visibleAtLaunch(locked: false, displaysAsleep: true))
    }

    // MARK: Chip and keys (R-6)

    private static func chip() {
        for g in 1...6 {
            for (suffix, variant) in [("", Chip.Variant.base), (" Pro", .pro), (" Max", .max), (" Ultra", .ultra)] {
                let c = Metrics.chip("Apple M\(g)\(suffix)")
                check("Apple M\(g)\(suffix)", c == Chip(generation: g, variant: variant) && c.name == "M\(g)\(suffix)")
            }
        }
        check("M10 is not M1", Metrics.chip("Apple M10 Pro").generation == 10)
        check("M10 is unknown", Metrics.temperatureKeys(Metrics.chip("Apple M10")) == nil)
        check("no m-token", Metrics.chip("Intel(R) Core(TM) i9").generation == nil && Metrics.chip("").name == "unknown")
        check("whole token only: 'Mac' is not a generation", Metrics.chip("Mac M3").generation == 3)
        check("lower-case brand", Metrics.chip("apple m2 max") == Chip(generation: 2, variant: .max))
    }

    private static func temperatureKeys() {
        func keys(_ brand: String) -> (cpu: [String], gpu: [String])? { Metrics.temperatureKeys(Metrics.chip(brand)) }
        check("M1 keys", keys("Apple M1")?.cpu.count == 10 && keys("Apple M1 Max")?.gpu == ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        check("M2 keys", keys("Apple M2")?.cpu.count == 12 && keys("Apple M2")?.gpu == ["Tg0f", "Tg0j"])
        check("M3 keys", keys("Apple M3 Pro")?.cpu.count == 16 && keys("Apple M3")?.gpu.count == 8)
        let m4 = keys("Apple M4"), m4Pro = keys("Apple M4 Pro"), m4Max = keys("Apple M4 Max"), m4Ultra = keys("Apple M4 Ultra")
        check("M4 base GPU", m4?.gpu.first == "Tg0G" && m4?.cpu.count == 12)
        check("M4 Pro/Max GPU", m4Pro?.gpu.first == "Tg1U" && m4Max?.gpu == m4Pro?.gpu && m4Pro?.cpu == m4?.cpu)
        check("M4 Ultra uses the Pro/Max GPU keys", m4Ultra?.gpu == m4Pro?.gpu)
        let m5 = keys("Apple M5 Pro")
        check("M5 keys", m5?.cpu.count == 18 && m5?.cpu.first == "Tp00" && m5?.gpu.count == 8 && m5?.gpu.last == "Tg1g")
        check("M6 keys", keys("Apple M6")?.cpu.count == 18 && keys("Apple M6")?.gpu.count == 12)
        check("unknown chip", keys("Apple M7") == nil && keys("") == nil)
    }

    private static func prefixFilter() {
        check("Tp is CPU", Metrics.fallbackSensor("Tp0A") == .cpu)
        check("Te is CPU", Metrics.fallbackSensor("Te05") == .cpu)
        check("Tg is GPU", Metrics.fallbackSensor("Tg1Z") == .gpu)
        check("others dropped", [ "TB0T", "Ts0P", "PSTR", "#KEY", "T", "tp00"].allSatisfy { Metrics.fallbackSensor($0) == nil })
    }

    // MARK: Usage (R-3, R-5)

    private static func usage() {
        check("CPU 38 %", Metrics.cpuPercent(from: [100, 50, 1000, 0], to: [130, 55, 1062, 3]) == 38)
        check("CPU idle", Metrics.cpuPercent(from: [1, 1, 1, 1], to: [1, 1, 101, 1]) == 0)
        check("CPU busy", Metrics.cpuPercent(from: [0, 0, 0, 0], to: [50, 40, 0, 10]) == 100)
        check("CPU counters wrap", Metrics.cpuPercent(from: [UInt32.max - 9, 0, 0, 0], to: [10, 0, 80, 0]) == 20)
        check("CPU no ticks", Metrics.cpuPercent(from: [5, 5, 5, 5], to: [5, 5, 5, 5]) == nil)
        check("CPU bad shape", Metrics.cpuPercent(from: [1], to: [2]) == nil)
        let page: UInt64 = 16384
        check("memory used", Metrics.memoryUsed(internal: 1000, purgeable: 100, wired: 200, compressed: 300, pageSize: page) == 1400 * page)
        check("purgeable above internal", Metrics.memoryUsed(internal: 10, purgeable: 20, wired: 1, compressed: 0, pageSize: 1) == 1)
        check("memory 72 %", Metrics.percent(23 * 1_073_741_824, of: 32 * 1_073_741_824) == 72)
        check("percent of 0", Metrics.percent(1, of: 0) == nil)
        check("percent clamped", Metrics.percent(5, of: 4) == 100)
        check("pressure normal", Metrics.pressure(1) == .normal && Metrics.pressure(nil) == .normal && Metrics.pressure(3) == .normal)
        check("pressure warning", Metrics.pressure(2) == .warning)
        check("pressure critical", Metrics.pressure(4) == .critical)
        check("bar fill", Metrics.pressureFill(82) == 18 && Metrics.pressureFill(nil) == nil && Metrics.pressureFill(140) == 0)
    }

    private static func temperature() {
        check("hottest plausible", Metrics.hottest([61.2, 58, 130, 9.9, 60]) == 61.2)
        check("boundaries are plausible", Metrics.hottest([10]) == 10 && Metrics.hottest([120]) == 120)
        check("none plausible", Metrics.hottest([0, 121, -5]) == nil && Metrics.hottest([]) == nil)
    }

    // MARK: Power (R-7)

    private static func powerState() {
        check("charging", Metrics.powerState(hasBattery: true, connected: true, charging: true) == .charging)
        check("connected, not charging", Metrics.powerState(hasBattery: true, connected: true, charging: false) == .connected)
        check("on battery", Metrics.powerState(hasBattery: true, connected: false, charging: false) == .onBattery)
        check("no battery", Metrics.powerState(hasBattery: false, connected: false, charging: true) == .noBattery)
        check("default source is a desktop", PowerSource().state == .noBattery)
    }

    // MARK: Formats (R-14)

    private static func formats() {
        func w(_ x: Double) -> String { let t = Metrics.watts(x); return t.value + t.unit }
        func b(_ x: Double) -> String { let t = Metrics.bytes(Int64(x)); return t.value + t.unit }
        check("4.2W", w(4.2) == "4.2W")
        check("9.94 → 9.9W", w(9.94) == "9.9W")
        check("9.96 → 10W", w(9.96) == "10W")
        check("188W", w(188) == "188W" && w(187.6) == "188W")
        check("8.8W", w(8.8) == "8.8W")
        check("0.0W", w(0) == "0.0W" && w(-3) == "0.0W")
        check("999G", b(999e9) == "999G" && b(999.4e9) == "999G")
        check("999.6 G → 1.0T", b(999.6e9) == "1.0T")
        check("1.2T", b(1.2e12) == "1.2T")
        check("1.8T", b(1.812e12) == "1.8T")
        check("412G", b(412e9) == "412G" && b(0) == "0G")
        check("degrees round", Metrics.degrees(84.5) == 85 && Metrics.degrees(84.4) == 84)
    }

    // MARK: Levels (R-15)

    private static func levels() {
        check("84.4 → neutral", Metrics.temperatureLevel(84.4) == .normal)
        check("84.5 → warning", Metrics.temperatureLevel(84.5) == .warning)
        check("85 → warning", Metrics.temperatureLevel(85) == .warning)
        check("94.4 → warning", Metrics.temperatureLevel(94.4) == .warning)
        check("94.5 → critical", Metrics.temperatureLevel(94.5) == .critical)
        check("95 → critical", Metrics.temperatureLevel(95) == .critical)
        check("disk 15 % → normal", Metrics.diskLevel(free: 15, total: 100) == .normal)
        check("disk below 15 % → warning", Metrics.diskLevel(free: 1499, total: 10000) == .warning)
        check("disk 5 % → warning", Metrics.diskLevel(free: 5, total: 100) == .warning)
        check("disk below 5 % → critical", Metrics.diskLevel(free: 499, total: 10000) == .critical)
        check("disk 61 of 926 → warning", Metrics.diskLevel(free: 61_000_000_000, total: 926_000_000_000) == .warning)
        check("disk 30 of 926 → critical", Metrics.diskLevel(free: 30_000_000_000, total: 926_000_000_000) == .critical)
        check("disk without total", Metrics.diskLevel(free: 0, total: 0) == .normal)
        // Usage (owner, 2026-10-14): the 30-sample mean, on at ≥ 85, off below 75, never critical.
        func busy(_ samples: [Int?], was: Level = .normal) -> Level {
            var h = History()
            samples.forEach { h.append($0) }
            return Metrics.usageLevel(h, was: was)
        }
        check("usage: short history → normal", busy(Array(repeating: 100, count: 29)) == .normal)
        check("usage: mean 85 → warning", busy(Array(repeating: 85, count: 30)) == .warning)
        check("usage: mean 84 → normal", busy(Array(repeating: 84, count: 30)) == .normal)
        check("usage: 3 s spike → normal", busy(Array(repeating: 20, count: 27) + [100, 100, 100]) == .normal)
        check("usage: only the last 30 count", busy(Array(repeating: 100, count: 60) + Array(repeating: 10, count: 30)) == .normal)
        check("usage: stays on at 75", busy(Array(repeating: 75, count: 30), was: .warning) == .warning)
        check("usage: off below 75", busy(Array(repeating: 74, count: 30), was: .warning) == .normal)
        check("usage: never critical", busy(Array(repeating: 100, count: 30), was: .warning) == .warning)
        check("usage: gaps skipped", busy(Array(repeating: nil, count: 20) + Array(repeating: 90, count: 10)) == .warning)
        check("usage: all gaps → normal", busy(Array(repeating: nil, count: 30), was: .warning) == .normal)
    }

    // MARK: Missing values and history (R-3a)

    private static func missingValues() {
        var d = Debounced<Int>()
        check("— before the first success", d.update(nil) == nil && d.shown == nil)
        check("first success shows", d.update(38) == 38)
        check("1st failure keeps", d.update(nil) == 38)
        check("2nd failure keeps", d.update(nil) == 38)
        check("3rd failure → —", d.update(nil) == nil && d.failures == 3)
        check("recovers", d.update(40) == 40 && d.failures == 0)
        _ = d.update(nil)
        _ = d.update(nil)
        check("a success resets the count", d.update(41) == 41 && d.update(nil) == 41 && d.update(nil) == 41)
    }

    private static func history() {
        var h = History()
        h.append(nil) // missing baseline: a gap
        h.append(38)
        check("gap stored", h.samples == [nil, 38])
        for i in 0..<130 { h.append(i) }
        check("120 samples kept, newest last", h.samples.count == 120 && h.samples.last == 129 && h.samples.first == 10)
        h.clear()
        check("cleared on return", h.samples.isEmpty)
    }

    // MARK: Columns (R-14)

    private static var normal: Snapshot {
        var s = Snapshot()
        s.cpu = 38
        s.cpuTemp = 61.2
        s.gpu = 12
        s.gpuTemp = 54
        s.memory = MemoryReading(used: 23 * 1_073_741_824, total: 32 * 1_073_741_824, percent: 72, level: .normal, fill: 18, swap: 0)
        s.system = 14
        s.dcIn = 0
        s.battery = -14
        s.source = PowerSource(hasBattery: true, connected: false, charging: false, percent: 64)
        s.disk = DiskReading(free: 412_000_000_000, total: 926_000_000_000, name: "Macintosh HD")
        return s
    }

    private static func shownItems() {
        let all = Set(Column.Glyph.allCases)
        check("all needed while open", Metrics.needed(shown: [.disk], panelOpen: true) == all)
        check("shown needed while closed", Metrics.needed(shown: [.cpu, .disk], panelOpen: false) == [.cpu, .disk])
        check("disk alone: no tick", !Metrics.perTick([.disk]))
        check("any other: tick", Metrics.perTick([.power, .disk]) && Metrics.perTick([.memory]))
        check("hide one of two", Metrics.toggled([.cpu, .gpu], .cpu) == [.gpu])
        check("show a hidden one", Metrics.toggled([.gpu], .disk) == [.gpu, .disk])
        check("the last one stays", Metrics.toggled([.gpu], .gpu) == [.gpu])
        check("can hide unless last", Metrics.canHide([.cpu, .gpu], .cpu) && !Metrics.canHide([.gpu], .gpu) && Metrics.canHide([.gpu], .cpu))
        check("stored hidden names", Metrics.shown(hidden: ["cpu", "power"]) == [.gpu, .memory, .disk])
        check("unknown names ignored", Metrics.shown(hidden: ["fan"]) == all)
        check("nothing shown means all", Metrics.shown(hidden: Column.Glyph.allCases.map(\.rawValue)) == all)
        check("menu names", Column.Glyph.allCases.map(Metrics.name) == ["CPU", "GPU", "Memory", "Power", "Disk"])
    }

    private static func columns() {
        var s = normal
        var c = Metrics.columns(s)
        check("five columns in order", c.map(\.glyph) == [.cpu, .gpu, .memory, .power, .disk])
        check("CPU top fg, bottom dim", c[0].top == .init(text: "38", unit: "%", strong: true) && c[0].bottom == .value(.init(text: "61", unit: "°")))
        check("memory bar", c[2].bottom == .bar(fill: 18, level: .normal))
        check("on battery: the drain, signed, fg", c[3].bottom == .value(.init(text: "−14", unit: "W", strong: true)) && !c[3].badge)
        s.battery = -4.2
        check("on battery: low drain, one decimal", Metrics.columns(s)[3].bottom == .value(.init(text: "−4.2", unit: "W", strong: true)))
        s.battery = nil
        check("on battery, battery missing: dim —", Metrics.columns(s)[3].bottom == .value(Metrics.missing))
        check("disk free over total", c[4].top.text == "412" && c[4].top.unit == "G" && c[4].bottom == .value(.init(text: "926", unit: "G")))
        s.source = PowerSource(hasBattery: true, connected: true, charging: true)
        s.dcIn = 61
        s.battery = 43
        c = Metrics.columns(s)
        check("charging: badge, battery (PPBR) fg, not DC-in", c[3].badge && c[3].bottom == .value(.init(text: "43", unit: "W", strong: true)))
        s.source.charging = false
        s.battery = 1.1
        check("connected: no badge, battery fg, one decimal", !Metrics.columns(s)[3].badge
              && Metrics.columns(s)[3].bottom == .value(.init(text: "1.1", unit: "W", strong: true)))
        s.battery = 9.96
        check("connected: battery rounds then switches format", Metrics.columns(s)[3].bottom == .value(.init(text: "10", unit: "W", strong: true)))
        s.battery = nil
        check("connected, PPBR missing: dim —", Metrics.columns(s)[3].bottom == .value(Metrics.missing))
        s.battery = -40
        check("connected, load above the charger: the drain", !Metrics.columns(s)[3].badge
              && Metrics.columns(s)[3].bottom == .value(.init(text: "−40", unit: "W", strong: true)))
        s.battery = -0.04
        check("held, a drain that rounds to 0.0: no sign", Metrics.columns(s)[3].bottom == .value(.init(text: "0.0", unit: "W", strong: true)))
        check("draining at −0.05 W, not at −0.04 W", Metrics.draining(-0.05) && !Metrics.draining(-0.04) && !Metrics.draining(nil) && !Metrics.draining(3))
        s.battery = 1.1
        s.source = PowerSource()
        check("desktop: dim —, never a bolt", !Metrics.columns(s)[3].badge && Metrics.columns(s)[3].bottom == .value(Metrics.missing))
        s.cpuTemp = 97
        s.memory?.level = .critical
        s.disk?.free = 30_000_000_000
        c = Metrics.columns(s)
        check("levels on the slots", c[0].bottom == .value(.init(text: "97", unit: "°", level: .critical))
              && c[2].top.level == .critical && c[2].bottom == .bar(fill: 18, level: .critical) && c[4].top.level == .critical)
        s.cpuLevel = .warning
        s.gpuLevel = .warning
        c = Metrics.columns(s)
        check("busy: amber usage", c[0].top == .init(text: "38", unit: "%", level: .warning, strong: true) && c[1].top.level == .warning)
        c = Metrics.columns(Snapshot())
        check("missing: dim — everywhere", c.allSatisfy { $0.top == Metrics.missing } && c[2].bottom == .bar(fill: nil, level: .normal))
    }

    // MARK: Accessibility (NFR-4)

    private static func accessibility() {
        var s = normal
        check("normal summary", Metrics.summary(s) == "CPU 38 percent, 61 degrees. GPU 12 percent, 54 degrees. "
              + "Memory 72 percent, normal pressure. Power 14 watts, on battery, discharging 14 watts. Disk 412 gigabytes free of 926")
        check("one item's label", Metrics.phrase(.memory, s) == "Memory 72 percent, normal pressure"
              && Metrics.phrase(.cpu, s) == "CPU 38 percent, 61 degrees")
        s.cpu = 82
        s.cpuTemp = 88
        check("CPU hot", Metrics.summary(s).hasPrefix("CPU 82 percent, 88 degrees, hot. "))
        s.gpuLevel = .warning
        check("GPU busy", Metrics.phrase(.gpu, s) == "GPU 12 percent, busy, 54 degrees")
        s.gpuLevel = .normal
        s.cpu = 100
        s.cpuTemp = 97
        check("CPU critical", Metrics.summary(s).hasPrefix("CPU 100 percent, 97 degrees, critical. "))
        s.cpu = nil
        s.cpuTemp = 61
        check("usage unavailable", Metrics.summary(s).hasPrefix("CPU usage unavailable, 61 degrees. "))
        s.cpu = 38
        s.cpuTemp = nil
        s.gpuTemp = nil
        check("temperature unavailable", Metrics.summary(s).hasPrefix("CPU 38 percent, temperature unavailable. GPU 12 percent, temperature unavailable. "))
        s.gpuTemp = 88
        check("GPU hot", Metrics.summary(s).contains("GPU 12 percent, 88 degrees, hot. "))
        s.memory?.level = .warning
        check("memory warning", Metrics.summary(s).contains("Memory 72 percent, warning pressure. "))
        s.memory?.level = .critical
        check("memory critical", Metrics.summary(s).contains("Memory 72 percent, critical pressure. "))
        s.memory = nil
        check("memory unavailable", Metrics.summary(s).contains("Memory unavailable. "))

        s.system = 18
        s.dcIn = 61
        s.battery = 43
        s.source = PowerSource(hasBattery: true, connected: true, charging: true, percent: 78)
        check("charging", Metrics.summary(s).contains("Power 18 watts, charging at 43 watts. "))
        s.battery = nil
        check("charging, PPBR unavailable", Metrics.summary(s).contains("Power 18 watts, charging. "))
        s.system = 20
        s.battery = 1.1
        s.source.charging = false
        check("connected, not charging", Metrics.summary(s).contains("Power 20 watts, battery 1.1 watts, not charging. "))
        s.battery = nil
        check("connected, PPBR unavailable", Metrics.summary(s).contains("Power 20 watts, not charging. "))
        s.system = 100
        s.battery = -40
        check("connected, load above the charger", Metrics.summary(s).contains("Power 100 watts, discharging 40 watts, not charging. "))
        s.system = 20
        s.battery = nil
        s.source = PowerSource()
        check("desktop", Metrics.summary(s).contains("Power 20 watts, no battery. "))
        s.system = 4.2
        s.source = PowerSource(hasBattery: true, connected: false)
        check("low draw", Metrics.summary(s).contains("Power 4.2 watts, on battery. "))
        s.system = nil
        check("power unavailable", Metrics.summary(s).contains("Power unavailable. "))

        func disk(_ free: Int64, _ total: Int64) -> String {
            var d = normal
            d.disk = DiskReading(free: free, total: total, name: "Macintosh HD")
            return Metrics.summary(d).components(separatedBy: ". ").last ?? ""
        }
        check("disk terabytes", disk(1_200_000_000_000, 1_812_000_000_000) == "Disk 1.2 terabytes free of 1.8")
        check("disk mixed units", disk(412_000_000_000, 2_000_000_000_000) == "Disk 412 gigabytes free of 2.0 terabytes")
        check("disk low", disk(61_000_000_000, 926_000_000_000) == "Disk 61 gigabytes free of 926, low")
        check("disk critical", disk(30_000_000_000, 926_000_000_000) == "Disk 30 gigabytes free of 926, critical")
        s = normal
        s.disk = nil
        check("disk unavailable", Metrics.summary(s).hasSuffix(". Disk unavailable"))
    }

    // MARK: Updater

    private static func updateVersions() {
        check("update: 1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
        check("update: v-prefixed tag is newer", Updater.isNewer("v1.1.0", than: "1.0.0"))
        check("update: 1.0 equals 1.0.0", !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("1.0.0", than: "1.0"))
        check("update: older is not newer", !Updater.isNewer("1.9.9", than: "2.0.0"))
    }

    // MARK: Processes (R-12)

    /// The verified `ps` and `top` outputs (plan, Test fixtures → `procs`), abridged.
    static let psText = """
          PID  %CPU COMM
         4801  69.6 npm exec ccstatusline@latest
        34705  28.2 Docker Desktop Helper (Renderer)
          415   9.6 WindowServer
          407   0.4 bluetoothd
        garbage line
        """
    static let topText = """
        Disks: 229114158/2988G read, 740434316/5429G written.

        PID    COMMAND          MEM  
        36196  com.docker.sailo 9229M
        7771   Vivaldi Helper ( 1214M
        0*     kernel_task      512K+
        5555   Finder           1.2G-
        12     bad              12Q
        """

    private static func processParsing() {
        let ps = Metrics.parsePS(psText)
        check("ps: header and garbage skipped", ps.count == 4)
        check("ps: name with spaces", ps.first == ProcessRow(pid: 4801, command: "npm exec ccstatusline@latest", value: 69.6))
        check("ps: parentheses kept", ps[1].command == "Docker Desktop Helper (Renderer)" && ps[1].value == 28.2)
        check("ps: nothing parseable", Metrics.parsePS("  PID  %CPU COMM\n").isEmpty && Metrics.parsePS("").isEmpty)
        check("ps: comma decimal", Metrics.parsePS("1 2,5 x").first?.value == 2.5)
        check("ps: negative %CPU rejected", Metrics.parsePS("1 -2 x").isEmpty)
        let top = Metrics.parseTop(topText)
        check("top: rows after the header only", top.count == 4)
        check("top: 16-character truncation", top[0] == ProcessRow(pid: 36196, command: "com.docker.sailo", value: 9229 * 1_048_576))
        check("top: truncated name with a space", top[1].command == "Vivaldi Helper (" && top[1].value == 1214 * 1_048_576)
        check("top: * after the pid, + after MEM, K", top[2] == ProcessRow(pid: 0, command: "kernel_task", value: 512 * 1024))
        check("top: - after MEM, G", top[3].pid == 5555 && top[3].command == "Finder" && top[3].value == 1.2 * 1_073_741_824)
        check("top: no header", Metrics.parseTop("36196  com.docker.sailo 9229M").isEmpty)
        check("top: bytes", Metrics.topBytes("640B") == 640 && Metrics.topBytes("9229") == nil && Metrics.topBytes("M") == nil)
    }

    private static func processNaming() {
        check("app name wins", Metrics.displayName(command: "Vivaldi", appName: "Vivaldi Browser") == "Vivaldi Browser")
        check("command without an app", Metrics.displayName(command: "kernel_task", appName: nil) == "kernel_task")
        check("Docker rule", Metrics.displayName(command: "com.apple.Virtualization.VirtualMachine", appName: "Docker Desktop") == "Docker")
        check("Docker rule needs both", Metrics.displayName(command: "com.apple.Virtualization.VirtualMachine", appName: "UTM") == "UTM"
              && Metrics.displayName(command: "com.docker.backend", appName: "Docker Desktop") == "Docker Desktop")
        var lookups = 0
        let rows = (0..<40).map { ProcessRow(pid: Int32($0), command: "p\($0)", value: 1) }
        let named = Metrics.named(rows) { lookups += 1; return $0 == 3 ? "App" : nil }
        check("at most 16 name lookups per refresh", lookups == 16 && named.prefix(16).allSatisfy { $0.name != nil } && named[16].name == nil)
        check("looked-up name shown", named[3].display == "App" && named[4].display == "p4")
        lookups = 0
        _ = Metrics.named(named) { _ in lookups += 1; return nil }
        check("named rows are not looked up again", lookups == 16 && Metrics.named(named.prefix(16).map { $0 }) { _ in lookups += 1; return nil }.count == 16
              && lookups == 16)
    }

    private static func ranking() {
        func row(_ pid: Int32, _ v: Double) -> ProcessRow { ProcessRow(pid: pid, command: "p\(pid)", value: v) }
        func pids(_ rows: [ProcessRow]) -> [Int32] { rows.map(\.pid) }
        let u = Metrics.cpuUnit
        check("first fill is a plain sort", pids(Metrics.rank(shown: [], fresh: [row(1, 5), row(2, 50), row(3, 20)], slots: 2, unit: u)) == [2, 3])
        check("ties by pid", pids(Metrics.rank(shown: [], fresh: [row(9, 5), row(4, 5)], slots: 2, unit: u)) == [4, 9])
        let shown = [row(1, 50), row(2, 20)]
        check("challenger at exactly 10 % stays out",
              pids(Metrics.rank(shown: shown, fresh: [row(1, 50), row(2, 20), row(3, 22)], slots: 2, unit: u)) == [1, 2])
        check("challenger just above 10 % and one unit swaps in",
              pids(Metrics.rank(shown: shown, fresh: [row(1, 50), row(2, 20), row(3, 22.1)], slots: 2, unit: u)) == [1, 3])
        check("challenger at exactly one display unit stays out",
              pids(Metrics.rank(shown: [row(1, 50), row(2, 2)], fresh: [row(1, 50), row(2, 2), row(3, 3)], slots: 2, unit: u)) == [1, 2])
        check("challenger just above one unit swaps in",
              pids(Metrics.rank(shown: [row(1, 50), row(2, 2)], fresh: [row(1, 50), row(2, 2), row(3, 3.01)], slots: 2, unit: u)) == [1, 3])
        check("shown values update",
              Metrics.rank(shown: shown, fresh: [row(1, 45), row(2, 21)], slots: 2, unit: u).map(\.value) == [45, 21])
        check("absent shown row dropped, slot filled from the best others",
              pids(Metrics.rank(shown: shown, fresh: [row(2, 20), row(5, 1), row(6, 3)], slots: 2, unit: u)) == [2, 6])
        check("empty slots fill in value order",
              pids(Metrics.rank(shown: [row(1, 50)], fresh: [row(1, 50), row(7, 2), row(8, 9), row(9, 4)], slots: 3, unit: u)) == [1, 8, 9])
        check("adjacent rows keep their order within the threshold",
              pids(Metrics.rank(shown: shown, fresh: [row(1, 21), row(2, 22)], slots: 2, unit: u)) == [1, 2])
        check("adjacent rows swap beyond the threshold",
              pids(Metrics.rank(shown: shown, fresh: [row(1, 21), row(2, 23.2)], slots: 2, unit: u)) == [2, 1])
        check("names carried over", Metrics.rank(shown: [ProcessRow(pid: 1, command: "a", value: 5, name: "A")],
                                                fresh: [row(1, 6)], slots: 1, unit: u).first?.display == "A")
        check("memory unit is 0.1 GB", Metrics.beats(0.2e9, 0.1e9 - 1e6, unit: Metrics.memoryUnit) == false
              && Metrics.beats(1.2 * 1_073_741_824, 1_073_741_824, unit: Metrics.memoryUnit))
        check("CPU text", Metrics.cpuText(69.6) == "70%" && Metrics.cpuText(0.4) == "<1%" && Metrics.cpuText(0.5) == "1%"
              && Metrics.cpuText(250) == "250%")
        check("memory text", Metrics.memoryText(9229 * 1_048_576) == "9.0 GB" && Metrics.memoryText(8930 * 1_048_576) == "8.7 GB"
              && Metrics.memoryText(512 * 1024) == "<0.1 GB")
    }

    // MARK: Clocks (R-13)

    /// A DVFS table property: 8-byte entries, the frequency in the little-endian low 32 bits, a voltage above.
    static func dvfsBytes(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { v in [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: v >> $0) } + [0x34, 0x03, 0, 0] }
    }

    /// One core's states: the leading off states, then the residency of each active state.
    static func channel(_ name: String, _ residencies: [Int64], off: [String] = ["IDLE", "DOWN"]) -> IOReportChannel {
        IOReportChannel(group: "CPU Stats", subgroup: "CPU Core Performance States", name: name,
                        states: off.map { .init(name: $0, residency: 500) }
                            + residencies.enumerated().map { .init(name: "V\($0.offset)", residency: $0.element) })
    }

    private static func clocks() {
        check("DVFS kHz on M4+", Metrics.dvfsTable(dvfsBytes([1_344_000, 4_608_000]), generation: 5) == [1344, 4608])
        check("DVFS Hz on M1–M3", Metrics.dvfsTable(dvfsBytes([600_000_000, 3_204_000_000]), generation: 1) == [600, 3204])
        check("DVFS kHz on M4", Metrics.dvfsTable(dvfsBytes([1_000_000]), generation: 4) == [1000])
        check("DVFS short data", Metrics.dvfsTable([1, 2, 3], generation: 5).isEmpty)
        check("M1–M4 keys", Metrics.dvfsKeys(generation: 3) == [.efficiency: "voltage-states1-sram", .performance: "voltage-states5-sram"])
        check("M5+ keys", Metrics.dvfsKeys(generation: 5)[.performance] == "voltage-states22-sram"
              && Metrics.dvfsKeys(generation: 5)[.superCore] == "voltage-states5-sram")
        let m6 = Metrics.clockTables(generation: 6) { $0 == "voltage-states5-sram" ? dvfsBytes([2_000_000]) : $0 == "voltage-states22-sram" ? [] : nil }
        check("M6: empty Performance uses Super", m6[.performance] == [2000] && m6[.superCore] == [2000] && m6[.efficiency] == nil)
        check("three core types: mapping", Metrics.coreType("PCPU3", hasSuper: true) == .superCore
              && Metrics.coreType("MCPU10", hasSuper: true) == .performance && Metrics.coreType("ECPU0", hasSuper: true) == nil)
        check("two core types: mapping", Metrics.coreType("PCPU3", hasSuper: false) == .performance
              && Metrics.coreType("ECPU0", hasSuper: false) == .efficiency && Metrics.coreType("GPU0", hasSuper: false) == nil)
        check("super cores ⇔ MCPU", Metrics.hasSuper(["PCPU0", "MCPU00"]) && !Metrics.hasSuper(["ECPU0", "PCPU0"]))
        check("row labels", Metrics.clockRows(hasSuper: true).map(\.label) == ["Super", "Performance"]
              && Metrics.clockRows(hasSuper: false).map(\.label) == ["Efficiency", "Performance"])
        check("core: residency-weighted mean", Metrics.coreMHz(channel("P", [100, 0, 300]).states, table: [1000, 2000, 3000]) == 2500)
        check("core: leading OFF skipped only", Metrics.coreMHz(channel("P", [1, 1], off: ["OFF"]).states, table: [1000, 3000]) == 2000
              && Metrics.coreMHz(channel("P", [1, 1], off: []).states + [.init(name: "IDLE", residency: 9)], table: [1, 2]) == nil)
        check("core: table length mismatch", Metrics.coreMHz(channel("P", [1, 1]).states, table: [1000, 2000, 3000]) == nil)
        check("core: no active residency is 0", Metrics.coreMHz(channel("P", [0, 0]).states, table: [1000, 2000]) == 0)

        // M5 Pro: PCPU0–5 active (Super, 15-entry table), MCPU00–05 parked, MCPU10–15 active (Performance, 20 entries).
        let superTable = (0..<15).map { 1000 + Double($0) * 250 }, perfTable = (0..<20).map { 1000 + Double($0) * 200 }
        func at(_ mhz: Double, _ table: [Double]) -> [Int64] { table.map { $0 == mhz ? 1000 : 0 } }
        let m5 = (0..<6).map { channel("PCPU\($0)", at($0 < 3 ? 3000 : 2000, superTable)) }
            + (0..<6).map { channel("MCPU0\($0)", at(0, perfTable)) }
            + (0..<6).map { channel("MCPU1\($0)", at(3800, perfTable)) }
            + [IOReportChannel(group: "CPU Stats", subgroup: "CPU Core States", name: "PCPU0", states: [.init(name: "V0", residency: 9)])]
        let tables: [CoreType: [Double]] = [.superCore: superTable, .performance: perfTable, .efficiency: [600, 900]]
        let rows = Metrics.clocks(m5, tables: tables, hasSuper: true)
        check("M5: Super 2.5 GHz", rows.first == ClockRow(label: "Super", mhz: 2500) && Metrics.gigahertz(2500) == "2.5 GHz")
        check("M5: parked cluster counts 0", rows.last == ClockRow(label: "Performance", mhz: 1900))
        let parked = Metrics.clocks((0..<6).map { channel("MCPU0\($0)", at(0, perfTable)) }, tables: tables, hasSuper: true)
        check("M5: floored at the table minimum", parked == [ClockRow(label: "Super", mhz: nil), ClockRow(label: "Performance", mhz: 1000)])
        check("missing table: —", Metrics.clocks(m5, tables: [:], hasSuper: true).allSatisfy { $0.mhz == nil })
        // M1: ECPU0–3 + PCPU0–3, Hz tables.
        let m1 = (0..<4).map { channel("ECPU\($0)", [0, 0, 0, 1, 1]) } + (0..<4).map { channel("PCPU\($0)", [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]) }
        let m1Tables = Metrics.clockTables(generation: 1) {
            $0 == "voltage-states1-sram" ? dvfsBytes([600, 900, 1200, 1500, 2000].map { $0 * 1_000_000 })
                : dvfsBytes((0..<15).map { UInt32(600 + $0 * 200) * 1_000_000 })
        }
        check("M1 tables", m1Tables[.efficiency]?.count == 5 && m1Tables[.performance]?.last == 3400 && m1Tables[.superCore] == nil)
        let m1Rows = Metrics.clocks(m1, tables: m1Tables, hasSuper: Metrics.hasSuper(m1.map(\.name)))
        check("M1: Efficiency and Performance", m1Rows == [ClockRow(label: "Efficiency", mhz: 1750), ClockRow(label: "Performance", mhz: 2700)])
        check("GHz rounding", Metrics.gigahertz(1949) == "1.9 GHz" && Metrics.gigahertz(1950) == "2.0 GHz" && Metrics.gigahertz(4608) == "4.6 GHz")
    }

    // MARK: Panel (R-17)

    private static func powerTrack() {
        check("scale: the rating", Metrics.trackScale(rating: 96, dcIn: 61, system: 18, battery: 43) == 96)
        check("scale: unknown rating → DC-in", Metrics.trackScale(rating: nil, dcIn: 61, system: 18, battery: 30) == 61)
        check("scale: unknown rating → system + battery", Metrics.trackScale(rating: nil, dcIn: 40, system: 18, battery: 30) == 48)
        check("scale: zero rating counts as unknown", Metrics.trackScale(rating: 0, dcIn: nil, system: 18, battery: nil) == 18)
        var s = normal
        check("on battery: hidden", Metrics.track(s) == nil)
        s.source = PowerSource(hasBattery: true, connected: true, charging: true, percent: 78, adapterWatts: 96)
        s.system = 18
        s.dcIn = 61
        s.battery = 43
        check("charging: system and battery", Metrics.track(s)! == (18.0 / 96, 43.0 / 96))
        s.source.charging = false
        check("connected: system only", Metrics.track(s)! == (18.0 / 96, nil))
        s.source.adapterWatts = 20
        s.system = 30
        check("clamped to 100 %", Metrics.track(s)! == (1, nil))
        s.source = PowerSource()
        s.system = 20
        s.dcIn = nil
        check("desktop, nothing known: the system", Metrics.track(s)! == (1, nil))
        s.system = 0
        check("zero scale", Metrics.track(s)! == (0, nil))
        s.system = nil
        check("no system reading", Metrics.track(s) == nil)
    }

    private static func shortScreen() {
        check("8 rows fit", Metrics.processRows(height8: 679, height5: 619, space: 679) == 8)
        check("5 rows", Metrics.processRows(height8: 679, height5: 619, space: 678) == 5 && Metrics.processRows(height8: 679, height5: 619, space: 619) == 5)
        check("left out", Metrics.processRows(height8: 679, height5: 619, space: 618) == 0)
    }

    private static func panelStrings() {
        var h = History()
        check("peak, empty", Metrics.peak(h) == ("Peak 0 s", nil))
        for v in [nil, 10, 74, nil, 30] { h.append(v) }
        check("Peak N s", Metrics.peak(h) == ("Peak 5 s", 74))
        for _ in 0..<115 { h.append(20) }
        check("Peak 2 min at 120 samples", Metrics.peak(h) == ("Peak 2 min", 74))
        check("panel watts", Metrics.panelWatts(4.2) == "4.2 W" && Metrics.panelWatts(9.96) == "10 W" && Metrics.panelWatts(18.2) == "18 W")
        check("disk text", Metrics.diskText(412_000_000_000) == ("412", "GB") && Metrics.diskText(1_200_000_000_000) == ("1.2", "TB")
              && Metrics.diskText(999_600_000_000) == ("1.0", "TB"))
        check("binary GB", Metrics.gibibytes(23 * 1_073_741_824) == "23.0" && Metrics.gibibytes(32 * 1_073_741_824, whole: true) == "32")
        let now = Date(timeIntervalSince1970: 1000)
        check("fresh: no footer", Metrics.staleFooter(now.addingTimeInterval(-6), now: now) == nil && Metrics.staleFooter(nil, now: now) == nil)
        check("Stale · 14 s ago", Metrics.staleFooter(now.addingTimeInterval(-14), now: now) == "Stale · 14 s ago")
        var s = normal
        s.cpuTemp = 88
        var t = Metrics.usageTile(.cpu, "CPU", usage: 82, temp: 88, history: h)
        check("hot: header and amber temperature, usage normal", t.word == Run(text: "Hot", level: .warning)
              && t.rows[0].value == Run(text: "88 °C", level: .warning) && t.value == Run(text: "82"))
        t = Metrics.usageTile(.cpu, "CPU", usage: 96, busy: .warning, temp: 70, history: h)
        check("busy: Busy and amber usage", t.word == Run(text: "Busy", level: .warning) && t.value == Run(text: "96", level: .warning)
              && t.label.hasPrefix("CPU, 96 percent, busy, "))
        t = Metrics.usageTile(.cpu, "CPU", usage: 96, busy: .warning, temp: 97, history: h)
        check("busy and critical: the temperature word wins", t.word == Run(text: "! Critical", level: .critical)
              && t.value.level == .warning)
        t = Metrics.usageTile(.cpu, "CPU", usage: 100, temp: 97, history: h)
        check("critical: ! Critical and ! 97 °C", t.word == Run(text: "! Critical", level: .critical)
              && t.rows[0].value == Run(text: "! 97 °C", level: .critical))
        t = Metrics.usageTile(.gpu, "GPU", usage: nil, temp: nil, history: h)
        check("missing: — Unavailable, no graphic", t.value.text == "—" && t.unit == "Unavailable" && t.graphic == .none
              && t.rows[0].value == Run(text: "— Unavailable", dim: true))
        t = Metrics.memoryTile(s.memory)
        check("memory tile", t.word == Run(text: "Normal") && t.value == Run(text: "72") && t.rows.map(\.value.text) == ["23.0 of 32 GB", "0.0 GB"])
        s.memory?.level = .critical
        check("memory critical", Metrics.memoryTile(s.memory).value == Run(text: "! 72", level: .critical) && Metrics.memoryTile(s.memory).graphic == .gauge(.critical))
        t = Metrics.diskTile(DiskReading(free: 30_000_000_000, total: 926_000_000_000, name: "Macintosh HD"))
        check("disk critical", t.word == Run(text: "! Critical", level: .critical) && t.value == Run(text: "! 30", level: .critical)
              && t.unit == "GB free" && t.rows.map(\.value.text) == ["896 GB", "926 GB"])
        t = Metrics.diskTile(DiskReading(free: 1_200_000_000_000, total: 1_812_000_000_000, name: "Macintosh HD"))
        check("disk terabytes", t.value.text == "1.2" && t.unit == "TB free" && t.rows.map(\.value.text) == ["612 GB", "1.8 TB"] && t.word?.dim == true)
        t = Metrics.powerTile(normal)
        check("power on battery", t.word == Run(text: "On battery", dim: true) && t.graphic == .none
              && t.rows.map(\.value) == [Run(text: "14 W"), Run(text: "−14 W · 64%"), Run(text: "Not connected", dim: true)])
        s = normal
        s.source = PowerSource(hasBattery: true, connected: true, charging: false, percent: 85, adapterWatts: 65)
        s.system = 4.4
        s.dcIn = 4.6
        s.battery = 0.2
        t = Metrics.powerTile(s)
        check("power held, low draw", t.word == Run(text: "Idle", dim: true) && t.value.text == "4.4"
              && t.rows.map(\.value.text) == ["4.4 W", "Held at 85%", "4.6 W of 65 W"])
        s.battery = -40
        check("power connected, load above the charger: the drain", Metrics.powerTile(s).rows[1].value.text == "−40 W · 85%")
        s.source = PowerSource(hasBattery: true, connected: true, charging: true, percent: 78)
        s.battery = nil
        t = Metrics.powerTile(s)
        check("charging: bolt, PPBR missing: only N%, rating unknown", t.bolt && t.word == Run(text: "Charging")
              && t.rows.map(\.value.text) == ["4.4 W", "78%", "4.6 W"])
        s.source = PowerSource()
        s.system = nil
        t = Metrics.powerTile(s)
        check("desktop, system missing", t.rows[1].value.text == "—" && t.value.text == "—" && t.unit == "Unavailable" && t.graphic == .none)
        let rows = [ProcessRow(pid: 1, command: "a", value: 69.6), ProcessRow(pid: 2, command: "b", value: 0.2)]
        let list = Metrics.processList(.rows(rows), memory: false, slots: 8)
        check("CPU list", list.rows == [.init(name: "a", value: "70%"), .init(name: "b", value: "<1%")] && list.note == nil && list.message == nil)
        check("5 of 8", Metrics.processList(.measuring, memory: true, slots: 5).note == "5 of 8")
        check("Measuring…", Metrics.processList(.measuring, memory: true, slots: 8).message == "Measuring…")
        check("Unavailable", Metrics.processList(.unavailable, memory: false, slots: 8).message == "Unavailable")
        let panel = Metrics.panel(normal, PanelExtras(rows: 0), now: Date())
        check("panel: five tiles, lists left out", panel.tiles.map(\.title) == ["CPU", "GPU", "Memory", "Disk", "Power"] && panel.lists == nil)
    }

    private static func panelLabels() {
        var h = History()
        for _ in 0..<120 { h.append(38) }
        h.append(74)
        let clocks = [ClockRow(label: "Super", mhz: 2500), ClockRow(label: "Performance", mhz: 1900)]
        check("CPU tile", Metrics.usageTile(.cpu, "CPU", usage: 38, temp: 61, history: h, clocks: clocks).label
              == "CPU, 38 percent, temperature 61 degrees, peak over 2 minutes 74 percent, super cores 2.5 gigahertz, performance cores 1.9 gigahertz")
        var short = History()
        for _ in 0..<40 { short.append(47) }
        check("CPU tile, short history, measuring", Metrics.usageTile(.cpu, "CPU", usage: 31, temp: 58, history: short,
                                                                      clocks: clocks.map { ClockRow(label: $0.label, mhz: nil, measuring: true) }).label
              == "CPU, 31 percent, temperature 58 degrees, peak over 40 seconds 47 percent, super cores measuring, performance cores measuring")
        check("CPU tile, clocks unavailable, hot", Metrics.usageTile(.cpu, "CPU", usage: 82, temp: 88, history: short,
                                                                     clocks: [ClockRow(label: "Efficiency", mhz: nil)]).label
              == "CPU, 82 percent, temperature 88 degrees, hot, peak over 40 seconds 47 percent, efficiency cores unavailable")
        check("GPU tile", Metrics.usageTile(.gpu, "GPU", usage: 12, temp: nil, history: History()).label
              == "GPU, 12 percent, temperature unavailable, peak over 0 seconds unavailable")
        check("Memory tile", Metrics.memoryTile(normal.memory).label
              == "Memory, 72 percent, normal pressure, used 23.0 of 32 gigabytes, swap 0.0 gigabytes")
        check("Memory unavailable", Metrics.memoryTile(nil).label == "Memory, unavailable")
        check("Disk tile", Metrics.diskTile(normal.disk).label
              == "Disk, Macintosh HD, 412 gigabytes free, used 514 gigabytes, total 926 gigabytes")
        check("Disk low", Metrics.diskTile(DiskReading(free: 61_000_000_000, total: 926_000_000_000, name: "Macintosh HD")).label
              .hasSuffix("total 926 gigabytes, low"))
        check("Disk terabytes", Metrics.diskTile(DiskReading(free: 1_200_000_000_000, total: 1_812_000_000_000, name: "X")).label
              == "Disk, X, 1.2 terabytes free, used 612 gigabytes, total 1.8 terabytes")
        check("Disk unavailable", Metrics.diskTile(nil).label == "Disk, unavailable")
        var s = normal
        s.system = 18
        s.dcIn = 61
        s.battery = 43
        s.source = PowerSource(hasBattery: true, connected: true, charging: true, percent: 78, adapterWatts: 65)
        check("Power tile, charging", Metrics.powerTile(s).label
              == "Power, 18 watts system draw, charging, battery plus 43 watts, 78 percent, adapter 61 watts of 65")
        s.system = 14
        s.battery = -12
        s.source = PowerSource(hasBattery: true, connected: false, charging: false, percent: 64)
        check("Power tile, on battery", Metrics.powerTile(s).label
              == "Power, 14 watts system draw, on battery, battery minus 12 watts, 64 percent, adapter not connected")
        s.source = PowerSource(hasBattery: true, connected: true, percent: 85)
        s.dcIn = 21
        check("Power tile, connected, draining", Metrics.powerTile(s).label
              == "Power, 14 watts system draw, idle, battery minus 12 watts, 85 percent, adapter 21 watts")
        s.battery = 0
        check("Power tile, held", Metrics.powerTile(s).label == "Power, 14 watts system draw, idle, battery held at 85 percent, adapter 21 watts")
        s.source = PowerSource()
        s.system = nil
        s.dcIn = nil
        check("Power tile, desktop, unavailable", Metrics.powerTile(s).label
              == "Power, system draw unavailable, idle, no battery, adapter unavailable")
        let rows = [ProcessRow(pid: 1, command: "npm exec ccstatusline@latest", value: 69.6),
                    ProcessRow(pid: 2, command: "Docker Desktop Helper (Renderer)", value: 28.2), ProcessRow(pid: 3, command: "x", value: 0.1)]
        check("Top by CPU", Metrics.processList(.rows(rows), memory: false, slots: 8).label
              == "Top by CPU. npm exec ccstatusline at latest, 70 percent. Docker Desktop Helper (Renderer), 28 percent. x, less than 1 percent.")
        check("Top by memory", Metrics.processList(.rows([ProcessRow(pid: 1, command: "com.docker.sailo", value: 9229 * 1_048_576),
                                                           ProcessRow(pid: 2, command: "k", value: 1024)]), memory: true, slots: 8).label
              == "Top by memory. com.docker.sailo, 9.0 gigabytes. k, less than 0.1 gigabytes.")
        check("Top by memory. Measuring.", Metrics.processList(.measuring, memory: true, slots: 8).label == "Top by memory. Measuring.")
        check("Top by CPU. (blank)", Metrics.processList(.blank, memory: false, slots: 8) == ProcessList(glyph: .cpu, title: "Top by CPU",
              note: nil, rows: [], message: nil, slots: 8, label: "Top by CPU."))
        check("Top by memory. Unavailable.", Metrics.processList(.unavailable, memory: true, slots: 8).label == "Top by memory. Unavailable.")
        check("Top by CPU, 5 of 8", Metrics.processList(.rows(rows), memory: false, slots: 5).label.hasPrefix("Top by CPU, 5 of 8. npm exec"))
    }
}
