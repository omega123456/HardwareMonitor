import Foundation

/// The single scheduler and the source of truth for what is shown (DD-2): the 1 s tick, the 60 s disk read, the
/// event re-reads and, only while the panel is open, the 1 s panel round, all through `Env` one-shots (DD-4); R-3a
/// debounce and histories; pause and resume (R-21). Readers never schedule anything. Only the `needed` metrics are
/// read: the shown items' and, while the panel is open, all of them.
final class Sampler {
    static let interval: TimeInterval = 1, diskInterval: TimeInterval = 60, panelInterval: TimeInterval = 1
    static let topRounds = 6

    /// Called after anything shown may have changed.
    var onChange: () -> Void = {}
    private(set) var snapshot = Snapshot()
    private(set) var paused = false
    /// What only the open panel shows; nil while it is closed (R-11).
    private(set) var extras: PanelExtras?
    /// The metrics with a status item shown (set through `show`).
    private(set) var shown = Set(Column.Glyph.allCases)
    var needed: Set<Column.Glyph> { Metrics.needed(shown: shown, panelOpen: extras != nil) }

    private let smc = SMC()
    private let thermal: Thermal
    private let cpu = CPU()
    private let gpu = GPU()
    private let power: Power
    private var tickTimer: Cancellable?, diskTimer: Cancellable?, roundTimer: Cancellable?
    private let ps = Processes(.ps), top = Processes(.top)
    /// Created on the first panel open (DVFS tables and the IOReport subscription, DD-3).
    private var frequency: Frequency?
    private var rounds = 0, topBusy = false
    private var ticks = 0

    // R-3a: one debounce per reading.
    private var cpuUsage = Debounced<Int>(), gpuUsage = Debounced<Int>()
    private var cpuTemp = Debounced<Double>(), gpuTemp = Debounced<Double>()
    private var memory = Debounced<MemoryReading>()
    private var system = Debounced<Double>(), dcIn = Debounced<Double>(), battery = Debounced<Double>()
    private var disk = Debounced<DiskReading>()

    init() {
        thermal = Thermal(smc: smc)
        power = Power(smc: smc)
        EventLog.write("launch: chip \(thermal.chip.name), SMC \(smc.isOpen ? "available" : "unavailable"), "
                       + "IOReport \(Frequency.available ? "available" : "unavailable"), "
                       + "CPU keys \(thermal.cpuKeys.count), GPU keys \(thermal.gpuKeys.count)")
        // R-2: events re-read at once and redraw, without waiting for the tick.
        Memory.observe { [weak self] in self?.pressureChanged() }
        Power.observe { [weak self] in self?.powerChanged() }
    }

    /// Launch (R-1): the power state, the disk and one tick at once (it sets the CPU baseline), then the cadence. A
    /// launch while not visible does nothing here; `resume` runs the same steps on return.
    func start() {
        guard !paused else { return }
        readAtOnce(needed)
    }

    /// The power state, the disk read and a tick, each only if `metrics` needs it; the reads re-arm their cadence.
    private func readAtOnce(_ metrics: Set<Column.Glyph>) {
        if metrics.contains(.power) { snapshot.source = Power.source() }
        if metrics.contains(.disk) { readDisk() }
        if Metrics.perTick(metrics) {
            tickTimer?.cancel()
            tick()
        }
    }

    /// Leaving visible (R-21): every timer is cancelled and later events are ignored.
    func pause() {
        panelClosed()
        paused = true
        tickTimer?.cancel()
        diskTimer?.cancel()
        tickTimer = nil
        diskTimer = nil
    }

    /// Returning to visible (R-21): redraw from the last snapshot, clear the histories (the peak never spans sleep),
    /// re-read the power state and adapter rating, then one tick and one disk read at once, which re-arm the cadence.
    func resume() {
        guard paused else { return }
        paused = false
        onChange()
        snapshot.cpuHistory.clear()
        snapshot.gpuHistory.clear()
        cpu.reset()
        power.reset()
        readAtOnce(needed)
    }

    /// The shown items changed: newly needed metrics are read at once, ones no longer needed are forgotten.
    func show(_ shown: Set<Column.Glyph>) {
        let old = needed
        self.shown = shown
        reconfigure(from: old)
    }

    /// Applies a change of `needed`. A metric no longer needed is forgotten (its timers, values and history), so it
    /// starts at "—" when it is needed again (R-3a) and never shows a stale reading.
    private func reconfigure(from old: Set<Column.Glyph>) {
        let new = needed
        for g in old.subtracting(new) { forget(g) }
        if !Metrics.perTick(new) {
            tickTimer?.cancel()
            tickTimer = nil
        }
        guard !paused else { return }
        readAtOnce(new.subtracting(old))
    }

    private func forget(_ g: Column.Glyph) {
        switch g {
        case .cpu:
            cpuUsage = .init(); cpuTemp = .init()
            snapshot.cpu = nil; snapshot.cpuTemp = nil
            snapshot.cpuHistory.clear()
            cpu.reset()
        case .gpu:
            gpuUsage = .init(); gpuTemp = .init()
            snapshot.gpu = nil; snapshot.gpuTemp = nil
            snapshot.gpuHistory.clear()
        case .memory:
            memory = .init()
            snapshot.memory = nil
        case .power:
            system = .init(); battery = .init()
            power.reset()
            snapshot.system = nil; snapshot.battery = nil
        case .disk:
            diskTimer?.cancel()
            diskTimer = nil
            disk = .init()
            snapshot.disk = nil
        }
    }

    /// Closes the SMC connection at quit (R-9).
    func close() { smc.close() }

    /// One tick (R-1): every per-tick reading, one snapshot stamped with the tick time, the histories, the next
    /// one-shot 1 s later.
    private func tick() {
        let started = DispatchTime.now().uptimeNanoseconds
        let needed = self.needed
        var s = snapshot
        if needed.contains(.cpu) {
            switch cpu.read() {
            case .percent(let p):
                s.cpu = cpuUsage.update(p)
                s.cpuHistory.append(p)
            case .noBaseline: // keeps the last value; a gap in the history
                s.cpuHistory.append(nil)
            case .failed:
                s.cpu = cpuUsage.update(nil)
                s.cpuHistory.append(nil)
            }
        }
        if needed.contains(.gpu) {
            let g = gpu.read()
            s.gpu = gpuUsage.update(g)
            s.gpuHistory.append(g)
        }
        if needed.contains(.cpu) || needed.contains(.gpu) {
            let t = thermal.read(cpu: needed.contains(.cpu), gpu: needed.contains(.gpu))
            if needed.contains(.cpu) { s.cpuTemp = cpuTemp.update(t.cpu) }
            if needed.contains(.gpu) { s.gpuTemp = gpuTemp.update(t.gpu) }
        }
        if needed.contains(.memory) { s.memory = memory.update(Memory.read()) }
        if needed.contains(.power) {
            let p = power.read(dcIn: extras != nil) // PDTR: only the open panel shows it
            s.system = system.update(p.system)
            s.battery = battery.update(p.battery)
            if extras != nil { s.dcIn = dcIn.update(p.dcIn) }
        }
        s.time = Env.now()
        snapshot = s
        ticks += 1
        if ticks % 60 == 0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            EventLog.write("tick: #\(ticks) took \(String(format: "%.2f", ms)) ms")
        }
        tickTimer = Metrics.perTick(needed) ? Env.after(Self.interval) { [weak self] in self?.tick() } : nil
        onChange()
    }

    // MARK: Panel-only work (R-11): zero cost while the panel is closed

    /// The panel opened with `rows` per list (0: the processes tile is left out): a round at once (`ps` and the clock
    /// baseline), then one every 1 s from each round's start; `top` from the second round, every `topRounds`.
    func panelOpened(rows: Int) {
        guard !paused, extras == nil else { return }
        if frequency == nil { frequency = Frequency(generation: thermal.chip.generation) }
        let old = needed
        extras = PanelExtras(rows: rows)
        reconfigure(from: old) // the tiles of hidden items are read from now on
        snapshot.dcIn = dcIn.update(power.dcIn()) // the "Adapter in" row, read only while open
        rounds = 0
        topBusy = false
        round()
    }

    /// Any close path: cancels the cadence, terminates `ps`/`top`, discards late results, drops the clock sample and
    /// the extras.
    func panelClosed() {
        guard extras != nil else { return }
        roundTimer?.cancel()
        roundTimer = nil
        ps.cancel()
        top.cancel()
        frequency?.reset()
        let old = needed
        extras = nil
        dcIn = .init()
        snapshot.dcIn = nil
        reconfigure(from: old) // forgets the metrics only the panel needed
    }

    /// One round: `ps`, and `top` every `topRounds` (single flight each; skipped when the processes tile is left out),
    /// one clock sample (the first after opening is the baseline; a window that started while `top` ran only
    /// re-baselines and the rows keep the last clean reading, R-13), the next round 1 s after this one started.
    private func round() {
        guard let rows = extras?.rows else { return }
        let started = Env.now()
        if rows > 0 { // the processes tile is shown
            ps.start(slots: rows) { [weak self] in self?.listed($0, memory: false) }
            if rounds % Self.topRounds == 1 { top.start(slots: rows) { [weak self] in self?.listed($0, memory: true) } }
        }
        if let frequency {
            if topBusy { frequency.rebase() } else { extras?.clocks = frequency.sample() }
        }
        topBusy = top.inFlight
        rounds += 1
        roundTimer = Env.at(started.addingTimeInterval(Self.panelInterval)) { [weak self] in self?.round() }
        onChange()
    }

    private func listed(_ rows: [ProcessRow]?, memory: Bool) {
        guard extras != nil else { return }
        let list = rows.map(PanelExtras.List.rows) ?? .unavailable
        if memory { extras?.memory = list } else { extras?.cpu = list }
        onChange()
    }

    /// R-8: the boot volume, then the next read 60 s later.
    private func readDisk() {
        snapshot.disk = disk.update(Disk.read())
        diskTimer = Env.after(Self.diskInterval) { [weak self] in
            self?.readDisk()
            self?.onChange()
        }
    }

    private func pressureChanged() {
        guard !paused, needed.contains(.memory) else { return }
        snapshot.memory = memory.update(Memory.read())
        onChange()
    }

    private func powerChanged() {
        guard !paused, needed.contains(.power) else { return }
        snapshot.source = Power.source()
        onChange()
    }
}
