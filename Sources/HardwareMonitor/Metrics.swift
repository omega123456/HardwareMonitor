import Foundation

// MARK: - Value types

/// A displayed value's state (R-15). Normal is neutral: no green anywhere.
enum Level: Equatable { case normal, warning, critical }

/// The chip from `machdep.cpu.brand_string` (R-6).
struct Chip: Equatable {
    enum Variant: String { case base, pro = "Pro", max = "Max", ultra = "Ultra" }
    /// The `m<number>` token's number; nil when the brand string has none.
    var generation: Int?
    var variant: Variant

    var name: String {
        guard let generation else { return "unknown" }
        return variant == .base ? "M\(generation)" : "M\(generation) \(variant.rawValue)"
    }
}

/// The power source's state (R-7). A desktop Mac (no battery) is always "connected, not charging".
enum PowerState: Equatable { case charging, connected, onBattery, noBattery }

/// The decoded IOKit power-source info and the adapter's rating (R-7).
struct PowerSource: Equatable {
    var hasBattery = false
    var connected = true
    var charging = false
    var percent: Int?
    var adapterWatts: Int?

    var state: PowerState { Metrics.powerState(hasBattery: hasBattery, connected: connected, charging: charging) }
}

/// One memory read (R-5): Activity Monitor's "Memory Used", the pressure level and bar fill, and swap.
struct MemoryReading: Equatable {
    var used: UInt64
    var total: UInt64
    var percent: Int
    var level: Level
    var fill: Int?
    var swap: UInt64?
}

/// The boot volume (R-8).
struct DiskReading: Equatable {
    var free: Int64
    var total: Int64
    var name: String
}

/// R-3a: a value as shown. "—" (nil) before the first successful read; after a success a failed read keeps the last
/// value, which turns "—" only after 3 consecutive failed reads.
struct Debounced<T: Equatable>: Equatable {
    private(set) var shown: T?
    private(set) var failures = 0

    /// Feeds one read (nil: failed) and returns the value to show.
    @discardableResult
    mutating func update(_ read: T?) -> T? {
        if let read {
            shown = read
            failures = 0
        } else {
            failures += 1
            if failures >= 3 { shown = nil }
        }
        return shown
    }
}

/// The last 120 usage samples (2 minutes at 1 s), oldest first; nil is a gap (R-3a, R-17).
struct History: Equatable {
    static let capacity = 120
    private(set) var samples: [Int?] = []

    mutating func append(_ sample: Int?) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    mutating func clear() { samples = [] }
}

/// What one tick (plus the events and the disk read) produced: the shown values after R-3a, kept in memory only.
struct Snapshot: Equatable {
    var cpu: Int?
    var cpuTemp: Double?
    var gpu: Int?
    var gpuTemp: Double?
    var memory: MemoryReading?
    var system: Double?   // PSTR, W
    var dcIn: Double?     // PDTR, W
    var battery: Double?  // PPBR, W, unsigned (its sign comes from the charging state)
    var source = PowerSource()
    var disk: DiskReading?
    var cpuHistory = History()
    var gpuHistory = History()
    var time: Date?
}

/// One column of the status image (R-14): a glyph and two stacked values.
struct Column: Equatable {
    /// Also the metric's identity: one status item each, in this default order (its raw value names it in defaults).
    enum Glyph: String, CaseIterable { case cpu, gpu, memory, power, disk }

    /// A value slot's text: digits, a smaller unit, the level, and fg (strong) or dim. The critical `!` is drawn from
    /// the level.
    struct Value: Equatable {
        var text: String
        var unit = ""
        var level = Level.normal
        var strong = false
    }

    enum Bottom: Equatable {
        case value(Value)
        /// The memory-pressure bar; a nil fill shows the missing "—".
        case bar(fill: Int?, level: Level)
    }

    var glyph: Glyph
    var badge = false // the charging bolt on the power glyph
    var top: Value
    var bottom: Bottom
}

// MARK: - Rules

/// Every decision rule and format, as static functions (covered by `SelfTest`, no UI).
enum Metrics {
    // MARK: Visibility (R-21)

    static func isVisible(awake: Bool, displaysAwake: Bool, sessionActive: Bool, unlocked: Bool) -> Bool {
        awake && displaysAwake && sessionActive && unlocked
    }

    /// At launch: visible unless the session is reported locked or the displays asleep.
    static func visibleAtLaunch(locked: Bool, displaysAsleep: Bool) -> Bool { !locked && !displaysAsleep }

    // MARK: Chip and temperature keys (R-6)

    /// The generation is the whole token `m<number>`, so "M10" is never read as M1; the variant follows Stats'
    /// `getPlatform` (Ultra, Max, Pro, otherwise base).
    static func chip(_ brand: String) -> Chip {
        let tokens = brand.lowercased().split { !$0.isLetter && !$0.isNumber }
        let generation = tokens.lazy.compactMap { $0.first == "m" ? Int($0.dropFirst()) : nil }.first
        let variant: Chip.Variant = tokens.contains("ultra") ? .ultra : tokens.contains("max") ? .max
            : tokens.contains("pro") ? .pro : .base
        return Chip(generation: generation, variant: variant)
    }

    private static func keys(_ list: String) -> [String] { list.split(separator: " ").map(String.init) }

    /// Temperature key tables from exelban/Stats (MIT) `Modules/Sensors/values.swift`, commit 0c0e551.
    private static let cpuKeys: [Int: [String]] = [
        1: keys("Tp09 Tp0T Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b"),
        2: keys("Tp1h Tp1t Tp1p Tp1l Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j"),
        3: keys("Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E"),
        4: keys("Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e"),
        5: keys("Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y"),
        6: keys("Tp0j Tp0g Tp09 Tp07 Tp0m Tp0L Tp0I Tp0d Tp0E Tp0G Tp0b Tp05 Te07 Te08 Te09 Te0c Te0h Te0i"),
    ]
    private static let gpuKeys: [Int: [String]] = [
        1: keys("Tg05 Tg0D Tg0L Tg0T"),
        2: keys("Tg0f Tg0j"),
        3: keys("Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A"),
        4: keys("Tg0G Tg0H Tg0K Tg0L Tg0d Tg0e Tg0j Tg0k"),
        5: keys("Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g"),
        6: keys("Tg1e Tg0d Tg0c Tg0b Tg1c Tg1d Tg07 Tg1f Tg09 Tg0a Tg1g Tg1h"),
    ]
    /// M4 Pro / Max, and (intentional divergence from Stats, which maps it to base) M4 Ultra.
    private static let m4ProGPUKeys = keys("Tg1U Tg1k Tg0K Tg0L Tg0d Tg0e Tg0j Tg0k")

    /// The chip's CPU and GPU temperature keys; nil for an unknown chip (the prefix fallback applies).
    static func temperatureKeys(_ chip: Chip) -> (cpu: [String], gpu: [String])? {
        guard let g = chip.generation, let cpu = cpuKeys[g], let gpu = gpuKeys[g] else { return nil }
        return (cpu, g == 4 && chip.variant != .base ? m4ProGPUKeys : gpu)
    }

    enum Sensor: Equatable { case cpu, gpu }

    /// The unknown-chip filter on enumerated key names, applied before any key-info or value read.
    static func fallbackSensor(_ key: String) -> Sensor? {
        key.hasPrefix("Tp") || key.hasPrefix("Te") ? .cpu : key.hasPrefix("Tg") ? .gpu : nil
    }

    static func plausible(_ celsius: Double) -> Bool { (10...120).contains(celsius) }

    /// The hottest plausible reading (10–120 °C); nil if none is plausible.
    static func hottest(_ readings: [Double]) -> Double? { readings.filter(plausible).max() }

    // MARK: Usage (R-3, R-5)

    /// CPU % from two `HOST_CPU_LOAD_INFO` reads (user, system, idle, nice): busy (user + system + nice) over total
    /// ticks, as a whole percent. Counters may wrap. Nil when no ticks passed.
    static func cpuPercent(from a: [UInt32], to b: [UInt32]) -> Int? {
        guard a.count == 4, b.count == 4 else { return nil }
        let d = zip(a, b).map { UInt64($1 &- $0) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return Int((Double(d[0] + d[1] + d[3]) / Double(total) * 100).rounded())
    }

    /// Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressor pages, in bytes.
    static func memoryUsed(internal app: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) -> UInt64 {
        ((app > purgeable ? app - purgeable : 0) + wired + compressed) * pageSize
    }

    /// A whole percent of `whole`, clamped to 0–100; nil when `whole` is 0.
    static func percent(_ part: Double, of whole: Double) -> Int? {
        whole > 0 ? max(0, min(100, Int((part / whole * 100).rounded()))) : nil
    }

    /// `kern.memorystatus_vm_pressure_level`: 2 is warning, 4 critical; anything else (1, missing) normal.
    static func pressure(_ level: Int?) -> Level { level == 2 ? .warning : level == 4 ? .critical : .normal }

    /// The pressure-bar fill: 100 − `kern.memorystatus_level`.
    static func pressureFill(_ memorystatusLevel: Int?) -> Int? { memorystatusLevel.map { max(0, min(100, 100 - $0)) } }

    // MARK: Power (R-7)

    static func powerState(hasBattery: Bool, connected: Bool, charging: Bool) -> PowerState {
        guard hasBattery else { return .noBattery }
        return !connected ? .onBattery : charging ? .charging : .connected
    }

    // MARK: Formats (R-14), each decided after rounding

    /// One decimal below 10 W, an integer from 10 W: 4.2 → "4.2", 9.96 → "10", 188 → "188".
    static func watts(_ w: Double) -> (value: String, unit: String) {
        let tenths = (max(0, w) * 10).rounded() / 10
        return (tenths < 10 ? String(format: "%.1f", tenths) : "\(Int(max(0, w).rounded()))", "W")
    }

    /// Decimal units as Finder: whole G below 1000 G, T with one decimal from there (999.6 G → "1.0T").
    static func bytes(_ b: Int64) -> (value: String, unit: String) {
        let gb = (Double(max(0, b)) / 1e9).rounded()
        if gb < 1000 { return ("\(Int(gb))", "G") }
        return (String(format: "%.1f", (Double(b) / 1e11).rounded() / 10), "T")
    }

    static func degrees(_ c: Double) -> Int { Int(c.rounded()) }

    // MARK: Levels (R-15), on the displayed value

    /// Warning at ≥ 85 °C, critical at ≥ 95 °C, after rounding (84.5 shows "85°" and is a warning).
    static func temperatureLevel(_ c: Double) -> Level {
        let shown = degrees(c)
        return shown >= 95 ? .critical : shown >= 85 ? .warning : .normal
    }

    /// Warning below 15 % free, critical below 5 % free, from the raw bytes.
    static func diskLevel(free: Int64, total: Int64) -> Level {
        guard total > 0 else { return .normal }
        let share = Double(free) / Double(total)
        return share < 0.05 ? .critical : share < 0.15 ? .warning : .normal
    }

    // MARK: Shown items and what they need read

    /// The metrics whose sources are read: the shown items' and, while the panel is open, every tile's.
    static func needed(shown: Set<Column.Glyph>, panelOpen: Bool) -> Set<Column.Glyph> {
        panelOpen ? Set(Column.Glyph.allCases) : shown
    }

    /// The 1 s tick is armed only while a per-tick metric is needed (the disk has its own 60 s read).
    static func perTick(_ needed: Set<Column.Glyph>) -> Bool { !needed.subtracting([.disk]).isEmpty }

    /// The metric's name in the right-click menu's "Show in Menu Bar" rows.
    static func name(_ g: Column.Glyph) -> String {
        switch g {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .power: "Power"
        case .disk: "Disk"
        }
    }

    /// At least one item is always shown: the last one can't be hidden.
    static func canHide(_ shown: Set<Column.Glyph>, _ g: Column.Glyph) -> Bool { shown.count > 1 || !shown.contains(g) }

    /// The menu toggle: shows `g`, or hides it unless it is the last one shown.
    static func toggled(_ shown: Set<Column.Glyph>, _ g: Column.Glyph) -> Set<Column.Glyph> {
        if !shown.contains(g) { return shown.union([g]) }
        return canHide(shown, g) ? shown.subtracting([g]) : shown
    }

    /// The shown set from the stored hidden names; unknown names are ignored, and nothing shown means all.
    static func shown(hidden: [String]) -> Set<Column.Glyph> {
        let shown = Set(Column.Glyph.allCases).subtracting(hidden.compactMap(Column.Glyph.init))
        return shown.isEmpty ? Set(Column.Glyph.allCases) : shown
    }

    // MARK: Status image (R-14)

    static let missing = Column.Value(text: "—")

    /// The five columns, in default order: CPU, GPU, Memory, Power, Disk (each item draws its own).
    static func columns(_ s: Snapshot) -> [Column] {
        func usage(_ glyph: Column.Glyph, _ usage: Int?, _ temp: Double?) -> Column {
            Column(glyph: glyph, top: usage.map { .init(text: "\($0)", unit: "%", strong: true) } ?? missing,
                   bottom: .value(temp.map { .init(text: "\(degrees($0))", unit: "°", level: temperatureLevel($0)) } ?? missing))
        }
        func watts(_ w: Double?) -> Column.Value {
            w.map { let t = Metrics.watts($0); return .init(text: t.value, unit: t.unit, strong: true) } ?? missing
        }
        let state = s.source.state
        let memory = Column(glyph: .memory,
                            top: s.memory.map { .init(text: "\($0.percent)", unit: "%", level: $0.level, strong: true) } ?? missing,
                            bottom: .bar(fill: s.memory?.fill, level: s.memory?.level ?? .normal))
        // Battery power (PPBR), live and fg while connected (charging or held), as Stats; a dim "—" on battery and on a
        // desktop. Deviation 3 (DC-in) reversed by the owner, 2026-10-12.
        let power = Column(glyph: .power, badge: state == .charging, top: watts(s.system),
                           bottom: .value(state == .onBattery || state == .noBattery ? missing : watts(s.battery)))
        let disk = Column(glyph: .disk,
                          top: s.disk.map { d in
                              let t = bytes(d.free)
                              return .init(text: t.value, unit: t.unit, level: diskLevel(free: d.free, total: d.total), strong: true)
                          } ?? missing,
                          bottom: .value(s.disk.map { let t = bytes($0.total); return .init(text: t.value, unit: t.unit) } ?? missing))
        return [usage(.cpu, s.cpu, s.cpuTemp), usage(.gpu, s.gpu, s.gpuTemp), memory, power, disk]
    }

    // MARK: Accessibility (R-16, NFR-4)

    /// One status item's label.
    static func phrase(_ g: Column.Glyph, _ s: Snapshot) -> String {
        switch g {
        case .cpu: usagePhrase("CPU", s.cpu, s.cpuTemp)
        case .gpu: usagePhrase("GPU", s.gpu, s.gpuTemp)
        case .memory: memoryPhrase(s.memory)
        case .power: powerPhrase(s)
        case .disk: diskPhrase(s.disk)
        }
    }

    /// Every item's label in default order, joined with ". ".
    static func summary(_ s: Snapshot) -> String { Column.Glyph.allCases.map { phrase($0, s) }.joined(separator: ". ") }

    private static func usagePhrase(_ name: String, _ usage: Int?, _ temp: Double?) -> String {
        let head = usage.map { "\(name) \($0) percent" } ?? "\(name) usage unavailable"
        guard let temp else { return head + ", temperature unavailable" }
        let word = switch temperatureLevel(temp) {
        case .normal: ""
        case .warning: ", hot"
        case .critical: ", critical"
        }
        return "\(head), \(degrees(temp)) degrees\(word)"
    }

    private static func memoryPhrase(_ m: MemoryReading?) -> String {
        guard let m else { return "Memory unavailable" }
        let word = switch m.level {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
        return "Memory \(m.percent) percent, \(word) pressure"
    }

    private static func powerPhrase(_ s: Snapshot) -> String {
        guard let system = s.system else { return "Power unavailable" }
        let head = "Power \(watts(system).value) watts"
        let battery = s.battery.map { watts($0).value }
        switch s.source.state {
        case .charging: return head + (battery.map { ", charging at \($0) watts" } ?? ", charging")
        case .connected: return head + (battery.map { ", battery \($0) watts" } ?? "") + ", not charging"
        case .noBattery: return head + ", no battery"
        case .onBattery: return head + ", on battery"
        }
    }

    private static func diskPhrase(_ d: DiskReading?) -> String {
        guard let d else { return "Disk unavailable" }
        func unit(_ u: String) -> String { u == "T" ? "terabytes" : "gigabytes" }
        let free = bytes(d.free), total = bytes(d.total)
        let of = free.unit == total.unit ? total.value : "\(total.value) \(unit(total.unit))"
        let word = switch diskLevel(free: d.free, total: d.total) {
        case .normal: ""
        case .warning: ", low"
        case .critical: ", critical"
        }
        return "Disk \(free.value) \(unit(free.unit)) free of \(of)\(word)"
    }
}

// MARK: - Panel (Phase 2): value types

/// One IOReport channel of a sample delta, as `System` returns it (R-13).
struct IOReportChannel: Equatable {
    struct State: Equatable {
        var name: String
        var residency: Int64
    }
    var group: String
    var subgroup: String
    var name: String
    var states: [State]
}

/// A core type and its DVFS table (R-13).
enum CoreType: Equatable { case efficiency, performance, superCore }

/// One clock row of the CPU tile: "Super" / "Efficiency" / "Performance" and MHz; nil is "—" (R-13).
struct ClockRow: Equatable {
    var label: String
    var mhz: Double?
    var measuring = false
}

/// One `ps`/`top` row (R-12): %CPU or bytes, and the display name once looked up (nil until then).
struct ProcessRow: Equatable {
    var pid: Int32
    var command: String
    var value: Double
    var name: String?

    var display: String { name ?? command }
}

/// What only the open panel shows (R-11–R-13), dropped on close.
struct PanelExtras: Equatable {
    /// `blank`: CPU before the first `ps` result (empty slots); `measuring`: memory before the first `top` result.
    enum List: Equatable { case blank, measuring, unavailable, rows([ProcessRow]) }
    var cpu = List.blank
    var memory = List.measuring
    var clocks: [ClockRow] = []
    /// Rows per list: 8, or 5 on a short screen; 0 leaves the processes tile out (R-17).
    var rows = 8
}

/// A run of text in the panel: its level's colour and weight, or dim (R-17).
struct Run: Equatable {
    var text: String
    var level = Level.normal
    var dim = false
}

/// One panel tile as drawn (R-17): header, primary value, graphic, key/value rows, and its accessibility label.
struct Tile: Equatable {
    enum Graphic: Equatable {
        case none
        /// The last 60 samples, newest at the right edge; nil is a gap.
        case spark([Int?])
        /// Memory's 3-segment gauge.
        case gauge(Level)
        /// The disk's capacity bar: the free share.
        case bar(fill: Double, level: Level)
        /// The power track: system and (while charging) battery shares of the scale.
        case track(system: Double, battery: Double?)
    }
    struct Row: Equatable {
        var label: String
        var swatch: CGFloat? = nil
        var value: Run
    }
    var glyph: Column.Glyph
    var title: String
    var word: Run?
    var bolt = false
    var value: Run
    var unit: String
    var graphic: Graphic
    var rows: [Row]
    var label: String
}

/// One "Top by …" list: title, the dim "5 of 8" note on a short screen, its rows (or one dim message) in `slots` lines.
struct ProcessList: Equatable {
    struct Line: Equatable {
        var name: String
        var value: String
    }
    var glyph: Column.Glyph
    var title: String
    var note: String?
    var rows: [Line]
    var message: String?
    var slots: Int
    var label: String
}

/// Everything the panel shows (R-17): tiles in the 2-2-1-1 grid, the process lists (nil: left out), the stale footer.
struct PanelContent: Equatable {
    var tiles: [Tile]
    var lists: [ProcessList]?
    var footer: String?
}

// MARK: - Panel (Phase 2): rules

extension Metrics {
    // MARK: Clocks (R-13; DVFS layout and per-type rule from exelban/Stats `getFrequencies`, `FrequencyReader`)

    /// The DVFS table property per core type: Efficiency `voltage-states1-sram`; Performance `…5-sram` on M1–M4 and
    /// `…22-sram` on M5+; Super `…5-sram` on M5+.
    static func dvfsKeys(generation: Int) -> [CoreType: String] {
        generation >= 5
            ? [.efficiency: "voltage-states1-sram", .performance: "voltage-states22-sram", .superCore: "voltage-states5-sram"]
            : [.efficiency: "voltage-states1-sram", .performance: "voltage-states5-sram"]
    }

    /// 8-byte entries; the little-endian low 32 bits are Hz on M1–M3 and kHz on M4+. Returns MHz.
    static func dvfsTable(_ bytes: [UInt8], generation: Int) -> [Double] {
        stride(from: 0, to: bytes.count - 7, by: 8).map { i in
            Double(bytes[i..<i + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) / (generation >= 4 ? 1e3 : 1e6)
        }
    }

    /// Every core type's table (MHz) from `read(key)`; on M6 an empty Performance table uses the Super one.
    static func clockTables(generation: Int, read: (String) -> [UInt8]?) -> [CoreType: [Double]] {
        var tables = dvfsKeys(generation: generation).compactMapValues { read($0).map { dvfsTable($0, generation: generation) } }
        if generation >= 6, tables[.performance]?.isEmpty ?? true { tables[.performance] = tables[.superCore] }
        return tables.filter { !$0.value.isEmpty }
    }

    /// Super cores exist ⇔ `MCPU*` channels exist. `ECPU*` → Efficiency, `MCPU*` → Performance, `PCPU*` → Super with
    /// super cores, else Performance. ECPU is ignored on a chip with three core types.
    static func coreType(_ channel: String, hasSuper: Bool) -> CoreType? {
        if channel.hasPrefix("ECPU") { return hasSuper ? nil : .efficiency }
        if channel.hasPrefix("MCPU") { return .performance }
        if channel.hasPrefix("PCPU") { return hasSuper ? .superCore : .performance }
        return nil
    }

    static func hasSuper(_ channels: [String]) -> Bool { channels.contains { $0.hasPrefix("MCPU") } }

    /// The rows shown, by channel family.
    static func clockRows(hasSuper: Bool) -> [(label: String, type: CoreType)] {
        hasSuper ? [("Super", .superCore), ("Performance", .performance)] : [("Efficiency", .efficiency), ("Performance", .performance)]
    }

    /// One core's residency-weighted mean MHz over the active states (leading IDLE/DOWN/OFF skipped); nil when the
    /// active-state count differs from the table, 0 with no active residency.
    static func coreMHz(_ states: [IOReportChannel.State], table: [Double]) -> Double? {
        let active = Array(states.drop { ["IDLE", "DOWN", "OFF"].contains($0.name) })
        guard !table.isEmpty, active.count == table.count else { return nil }
        let total = active.reduce(0.0) { $0 + Double(max(0, $1.residency)) }
        guard total > 0 else { return 0 }
        return zip(active, table).reduce(0.0) { $0 + Double(max(0, $1.0.residency)) * $1.1 } / total
    }

    /// The clock rows from one delta: per type, the mean over its matched cores, raised to the table's minimum
    /// (Stats' rule, no "Idle"); a type with no table or no matching core is nil ("—").
    static func clocks(_ delta: [IOReportChannel], tables: [CoreType: [Double]], hasSuper: Bool) -> [ClockRow] {
        var cores: [CoreType: [Double]] = [:]
        for c in delta where c.group == "CPU Stats" && c.subgroup == "CPU Core Performance States" {
            guard let type = coreType(c.name, hasSuper: hasSuper), let table = tables[type],
                  let mhz = coreMHz(c.states, table: table) else { continue }
            cores[type, default: []].append(mhz)
        }
        return clockRows(hasSuper: hasSuper).map { row in
            guard let values = cores[row.type], let minimum = tables[row.type]?.min() else { return ClockRow(label: row.label, mhz: nil) }
            return ClockRow(label: row.label, mhz: max(values.reduce(0, +) / Double(values.count), minimum))
        }
    }

    /// "2.5 GHz".
    static func gigahertz(_ mhz: Double) -> String { String(format: "%.1f GHz", (mhz / 100).rounded() / 10) }

    // MARK: Processes (R-12; command lines and naming rule from exelban/Stats `ProcessReader`)

    /// `ps -Aceo pid,pcpu,comm -r`: pid, %CPU and the rest of the line as the command (it may contain spaces).
    /// Unparseable lines (the header) are skipped.
    static func parsePS(_ text: String) -> [ProcessRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")), cpu.isFinite, cpu >= 0 else { return nil }
            let command = fields[2].trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : ProcessRow(pid: pid, command: command, value: cpu)
        }
    }

    /// `top -l 1 -o mem -n 8 -stats pid,command,mem`: the rows after the `PID … COMMAND … MEM` header. A `*` may
    /// follow the pid; the command is padded or truncated to 16 characters; MEM carries K/M/G (binary) and an optional
    /// trailing `+` or `-`. Returns bytes.
    static func parseTop(_ text: String) -> [ProcessRow] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: {
            let f = $0.split(whereSeparator: \.isWhitespace)
            return f.first == "PID" && f.contains("COMMAND") && f.contains("MEM")
        }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            var fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let mem = topBytes(String(fields.removeLast())) else { return nil }
            var pidText = String(fields[0])
            if pidText.hasSuffix("*") { pidText.removeLast() }
            guard let pid = Int32(pidText), let start = line.range(of: fields[0])?.upperBound,
                  let end = line.range(of: fields[fields.count - 1], options: .backwards, range: start..<line.endIndex)?.upperBound
            else { return nil }
            let command = line[start..<end].trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : ProcessRow(pid: pid, command: command, value: mem)
        }
    }

    /// "9229M", "512K+", "1.2G-", "640B" → bytes (binary units).
    static func topBytes(_ s: String) -> Double? {
        var t = Substring(s)
        if t.hasSuffix("+") || t.hasSuffix("-") { t = t.dropLast() }
        let scale: Double = switch t.last {
        case "K": 1024
        case "M": 1_048_576
        case "G": 1_073_741_824
        case "B": 1
        default: 0
        }
        guard scale > 0, let v = Double(t.dropLast()), v.isFinite, v >= 0 else { return nil }
        return v * scale
    }

    /// The app's localized name when one exists, otherwise the command; a `com.apple.Virtua…` command whose app name
    /// contains "Docker" shows as "Docker" (Stats' rule).
    static func displayName(command: String, appName: String?) -> String {
        guard let appName else { return command }
        return command.contains("com.apple.Virtua") && appName.contains("Docker") ? "Docker" : appName
    }

    static let maxNameLookups = 16

    /// Names the rows that have none, through `lookup`, at most 16 per refresh (R-12).
    static func named(_ rows: [ProcessRow], lookup: (Int32) -> String?) -> [ProcessRow] {
        var budget = maxNameLookups
        return rows.map { row in
            guard row.name == nil, budget > 0 else { return row }
            budget -= 1
            var r = row
            r.name = displayName(command: row.command, appName: lookup(row.pid))
            return r
        }
    }

    /// One display unit per list: 1 % for CPU, 0.1 GB for memory.
    static let cpuUnit = 1.0, memoryUnit = 0.1 * 1_073_741_824

    /// `a` beats `b` only by more than max(10 % of `b`, one display unit).
    static func beats(_ a: Double, _ b: Double, unit: Double) -> Bool {
        a - b > max(0.1 * b, unit) * (1 + 1e-9)
    }

    /// R-12 ordering with hysteresis, per list and refresh: update the shown rows from the new output (dropping
    /// absent ones), fill empty slots from the best others, swap in a challenger while it beats the lowest shown row,
    /// then order adjacent rows only where the lower one beats the upper one. The first fill is a plain sort.
    static func rank(shown: [ProcessRow], fresh: [ProcessRow], slots: Int, unit: Double) -> [ProcessRow] {
        var latest: [Int32: ProcessRow] = [:]
        for row in fresh where latest[row.pid] == nil { latest[row.pid] = row }
        var rows: [ProcessRow] = shown.prefix(slots).compactMap { old in
            latest[old.pid].map { var r = $0; r.name = old.name; return r }
        }
        let kept = Set(rows.map(\.pid))
        var others = latest.values.filter { !kept.contains($0.pid) }.sorted { ($0.value, $1.pid) > ($1.value, $0.pid) }
        while rows.count < slots, !others.isEmpty { rows.append(others.removeFirst()) }
        while let best = others.first, let low = rows.indices.min(by: { rows[$0].value < rows[$1].value }),
              beats(best.value, rows[low].value, unit: unit) {
            others.removeFirst()
            rows[low] = best
        }
        var swapped = true
        while swapped {
            swapped = false
            for i in rows.indices.dropLast() where beats(rows[i + 1].value, rows[i].value, unit: unit) {
                rows.swapAt(i, i + 1)
                swapped = true
            }
        }
        return rows
    }

    /// "70%", "<1%" below 1 after rounding; above 100 % is allowed (100 % = one core).
    static func cpuText(_ percent: Double) -> String {
        let p = Int(percent.rounded())
        return p < 1 ? "<1%" : "\(p)%"
    }

    /// "9.0 GB" (bytes ÷ 1024³, Activity Monitor's convention), "<0.1 GB" below that.
    static func memoryText(_ bytes: Double) -> String {
        let gb = (bytes / 1_073_741_824 * 10).rounded() / 10
        return gb < 0.1 ? "<0.1 GB" : String(format: "%.1f GB", gb)
    }

    /// Rows per list at open (R-17): 8 if the panel with 8 rows fits the space below the item, else 5, else 0 (the
    /// processes tile is left out).
    static func processRows(height8: CGFloat, height5: CGFloat, space: CGFloat) -> Int {
        height8 <= space ? 8 : height5 <= space ? 5 : 0
    }

    // MARK: Panel strings (R-17)

    /// "Peak 2 min" once 120 samples exist, otherwise "Peak N s" for the span covered; the highest sample.
    static func peak(_ h: History) -> (label: String, value: Int?) {
        (h.samples.count >= History.capacity ? "Peak 2 min" : "Peak \(h.samples.count) s", h.samples.compactMap { $0 }.max())
    }

    /// Panel watts: one decimal below 10 W after rounding, an integer from there.
    static func panelWatts(_ w: Double) -> String { watts(w).value + " W" }

    /// Panel disk figures: decimal units as Finder, whole GB below 1000 GB, TB with one decimal from there.
    static func diskText(_ b: Int64) -> (value: String, unit: String) {
        let t = bytes(b)
        return (t.value, t.unit == "T" ? "TB" : "GB")
    }

    /// Binary GB with one decimal ("23.0"); `whole` drops the decimal (32 GB of RAM reads "32").
    static func gibibytes(_ b: UInt64, whole: Bool = false) -> String {
        let gb = Double(b) / 1_073_741_824
        return whole ? "\(Int(gb.rounded()))" : String(format: "%.1f", gb)
    }

    /// The power track's scale (R-17): the adapter rating, or max(DC-in, system + battery) when it is unknown.
    static func trackScale(rating: Int?, dcIn: Double?, system: Double, battery: Double?) -> Double {
        if let rating, rating > 0 { return Double(rating) }
        return max(dcIn ?? 0, system + (battery ?? 0))
    }

    /// The track's segments as shares of the scale, each clamped to 100 %: system, plus battery only while charging.
    /// Nil on battery (the track is hidden, its slot kept) and without a system reading.
    static func track(_ s: Snapshot) -> (system: Double, battery: Double?)? {
        guard let system = s.system, s.source.state != .onBattery else { return nil }
        let charging = s.source.state == .charging
        let scale = trackScale(rating: s.source.adapterWatts, dcIn: s.dcIn, system: system, battery: charging ? s.battery : nil)
        guard scale > 0 else { return (0, nil) }
        func share(_ w: Double) -> Double { max(0, min(1, w / scale)) }
        return (share(system), charging ? s.battery.map(share) : nil)
    }

    /// "Stale · N s ago" when the latest snapshot is more than 6 s old (R-17), otherwise nil.
    static func staleFooter(_ time: Date?, now: Date) -> String? {
        guard let time else { return nil }
        let age = now.timeIntervalSince(time)
        return age > 6 ? "Stale · \(Int(age)) s ago" : nil
    }

    private static let unavailable = Run(text: "— Unavailable", dim: true)
    private static let dash = Run(text: "—", dim: true)

    private static func levelWord(_ l: Level) -> String {
        switch l {
        case .normal: ""
        case .warning: ", hot"
        case .critical: ", critical"
        }
    }

    /// The CPU or GPU tile: usage, sparkline, temperature (Hot / ! Critical), the peak; CPU adds the clock rows.
    static func usageTile(_ glyph: Column.Glyph, _ name: String, usage: Int?, temp: Double?, history: History,
                          clocks: [ClockRow]? = nil) -> Tile {
        let level = temp.map(temperatureLevel) ?? .normal
        let peak = peak(history)
        var rows = [
            Tile.Row(label: "Temperature", value: temp.map {
                Run(text: (level == .critical ? "! " : "") + "\(degrees($0)) °C", level: level)
            } ?? unavailable),
            Tile.Row(label: peak.label, value: peak.value.map { Run(text: "\($0)%") } ?? dash),
        ]
        var spoken = [name, usage.map { "\($0) percent" } ?? "usage unavailable",
                      temp.map { "temperature \(degrees($0)) degrees" + levelWord(level) } ?? "temperature unavailable",
                      "peak over " + (history.samples.count >= History.capacity ? "2 minutes" : "\(history.samples.count) seconds")
                          + (peak.value.map { " \($0) percent" } ?? " unavailable")]
        for c in clocks ?? [] {
            rows.append(Tile.Row(label: c.label, value: c.measuring ? Run(text: "Measuring…", dim: true)
                                 : c.mhz.map { Run(text: gigahertz($0)) } ?? dash))
            spoken.append("\(c.label.lowercased()) cores " + (c.measuring ? "measuring"
                          : c.mhz.map { gigahertz($0).replacingOccurrences(of: "GHz", with: "gigahertz") } ?? "unavailable"))
        }
        let word: Run? = switch level {
        case .normal: nil
        case .warning: Run(text: "Hot", level: .warning)
        case .critical: Run(text: "! Critical", level: .critical)
        }
        return Tile(glyph: glyph, title: name, word: word, value: Run(text: usage.map(String.init) ?? "—"),
                    unit: usage == nil ? "Unavailable" : "%", graphic: usage == nil ? .none : .spark(history.samples),
                    rows: rows, label: spoken.joined(separator: ", "))
    }

    static func memoryTile(_ m: MemoryReading?) -> Tile {
        guard let m else {
            return Tile(glyph: .memory, title: "Memory", value: Run(text: "—"), unit: "Unavailable", graphic: .none,
                        rows: [Tile.Row(label: "Used", value: dash), Tile.Row(label: "Swap", value: dash)],
                        label: "Memory, unavailable")
        }
        let (word, spoken) = switch m.level {
        case .normal: ("Normal", "normal")
        case .warning: ("Warning", "warning")
        case .critical: ("! Critical", "critical")
        }
        let used = "\(gibibytes(m.used)) of \(gibibytes(m.total, whole: true))", swap = m.swap.map { gibibytes($0) }
        return Tile(glyph: .memory, title: "Memory", word: Run(text: word, level: m.level),
                    value: Run(text: (m.level == .critical ? "! " : "") + "\(m.percent)", level: m.level), unit: "%",
                    graphic: .gauge(m.level),
                    rows: [Tile.Row(label: "Used", value: Run(text: used + " GB")),
                           Tile.Row(label: "Swap", value: swap.map { Run(text: $0 + " GB") } ?? dash)],
                    label: "Memory, \(m.percent) percent, \(spoken) pressure, used \(used) gigabytes, "
                        + (swap.map { "swap \($0) gigabytes" } ?? "swap unavailable"))
    }

    static func diskTile(_ d: DiskReading?) -> Tile {
        guard let d else {
            return Tile(glyph: .disk, title: "Disk", value: Run(text: "—"), unit: "Unavailable", graphic: .none,
                        rows: [Tile.Row(label: "Used", value: dash), Tile.Row(label: "Total", value: dash)],
                        label: "Disk, unavailable")
        }
        let level = diskLevel(free: d.free, total: d.total)
        let free = diskText(d.free), used = diskText(d.total - d.free), total = diskText(d.total)
        func spoken(_ t: (value: String, unit: String)) -> String { "\(t.value) " + (t.unit == "TB" ? "terabytes" : "gigabytes") }
        let word = switch level {
        case .normal: Run(text: d.name, dim: true)
        case .warning: Run(text: "Low", level: .warning)
        case .critical: Run(text: "! Critical", level: .critical)
        }
        return Tile(glyph: .disk, title: "Disk", word: word,
                    value: Run(text: (level == .critical ? "! " : "") + free.value, level: level), unit: free.unit + " free",
                    graphic: .bar(fill: d.total > 0 ? max(0, min(1, Double(d.free) / Double(d.total))) : 0, level: level),
                    rows: [Tile.Row(label: "Used", value: Run(text: "\(used.value) \(used.unit)")),
                           Tile.Row(label: "Total", value: Run(text: "\(total.value) \(total.unit)"))],
                    label: "Disk, \(d.name), \(spoken(free)) free, used \(spoken(used)), total \(spoken(total))"
                        + (level == .warning ? ", low" : level == .critical ? ", critical" : ""))
    }

    /// The power tile: "18 W system draw", the track, System / Battery / Adapter in, and the header word.
    static func powerTile(_ s: Snapshot) -> Tile {
        let state = s.source.state
        let percent = s.source.percent.map { "\($0)%" } ?? "—"
        let spokenPercent = s.source.percent.map { "\($0) percent" } ?? "percent unavailable"
        var battery: Run, spokenBattery: String
        switch state {
        case .noBattery:
            (battery, spokenBattery) = (dash, "no battery")
        case .connected:
            (battery, spokenBattery) = (Run(text: "Held at \(percent)"), "battery held at \(spokenPercent)")
        case .charging, .onBattery:
            let sign = state == .charging ? ("+", "plus") : ("−", "minus")
            if let w = s.battery {
                battery = Run(text: "\(sign.0)\(panelWatts(w)) · \(percent)")
                spokenBattery = "battery \(sign.1) \(watts(w).value) watts, \(spokenPercent)"
            } else {
                (battery, spokenBattery) = (Run(text: percent), "battery \(spokenPercent)")
            }
        }
        let adapter: Run, spokenAdapter: String
        if state == .onBattery {
            (adapter, spokenAdapter) = (Run(text: "Not connected", dim: true), "adapter not connected")
        } else if let dc = s.dcIn {
            let rating = s.source.adapterWatts
            adapter = Run(text: panelWatts(dc) + (rating.map { " of \($0) W" } ?? ""))
            spokenAdapter = "adapter \(watts(dc).value) watts" + (rating.map { " of \($0)" } ?? "")
        } else {
            (adapter, spokenAdapter) = (dash, "adapter unavailable")
        }
        let (word, spokenWord) = switch state {
        case .charging: (Run(text: "Charging"), "charging")
        case .connected, .noBattery: (Run(text: "Idle", dim: true), "idle")
        case .onBattery: (Run(text: "On battery", dim: true), "on battery")
        }
        let track = track(s)
        return Tile(glyph: .power, title: "Power", word: word, bolt: state == .charging,
                    value: Run(text: s.system.map { watts($0).value } ?? "—"),
                    unit: s.system == nil ? "Unavailable" : "W system draw",
                    graphic: track.map { .track(system: $0.system, battery: $0.battery) } ?? .none,
                    rows: [Tile.Row(label: "System", swatch: 0.85, value: s.system.map { Run(text: panelWatts($0)) } ?? dash),
                           Tile.Row(label: "Battery", swatch: 0.38, value: battery),
                           Tile.Row(label: "Adapter in", value: adapter)],
                    label: ["Power", s.system.map { "\(watts($0).value) watts system draw" } ?? "system draw unavailable",
                            spokenWord, spokenBattery, spokenAdapter].joined(separator: ", "))
    }

    /// "Top by CPU" / "Top by memory" (R-12, R-17): the rows, "Measuring…" / "Unavailable" on the first line, or blank slots.
    static func processList(_ list: PanelExtras.List, memory: Bool, slots: Int) -> ProcessList {
        let title = memory ? "Top by memory" : "Top by CPU"
        let note = slots < 8 ? "\(slots) of 8" : nil
        var p = ProcessList(glyph: memory ? .memory : .cpu, title: title, note: note, rows: [], message: nil, slots: slots, label: "")
        let head = title + (note.map { ", \($0)" } ?? "")
        switch list {
        case .blank:
            p.label = head + "."
        case .measuring:
            p.message = "Measuring…"
            p.label = head + ". Measuring."
        case .unavailable:
            p.message = "Unavailable"
            p.label = head + ". Unavailable."
        case .rows(let rows):
            p.rows = rows.prefix(slots).map { .init(name: $0.display, value: memory ? memoryText($0.value) : cpuText($0.value)) }
            p.label = ([head] + p.rows.map { row in
                let value = row.value.hasPrefix("<") ? "less than " + row.value.dropFirst() : row.value
                return row.name.replacingOccurrences(of: "@", with: " at ") + ", "
                    + value.replacingOccurrences(of: "%", with: " percent").replacingOccurrences(of: " GB", with: " gigabytes")
            }).joined(separator: ". ") + "."
        }
        return p
    }

    /// The whole panel from the snapshot and the extras (nil extras: before the first round).
    static func panel(_ s: Snapshot, _ e: PanelExtras, now: Date) -> PanelContent {
        PanelContent(tiles: [usageTile(.cpu, "CPU", usage: s.cpu, temp: s.cpuTemp, history: s.cpuHistory, clocks: e.clocks),
                             usageTile(.gpu, "GPU", usage: s.gpu, temp: s.gpuTemp, history: s.gpuHistory),
                             memoryTile(s.memory), diskTile(s.disk), powerTile(s)],
                     lists: e.rows > 0 ? [processList(e.cpu, memory: false, slots: e.rows), processList(e.memory, memory: true, slots: e.rows)] : nil,
                     footer: staleFooter(s.time, now: now))
    }
}
