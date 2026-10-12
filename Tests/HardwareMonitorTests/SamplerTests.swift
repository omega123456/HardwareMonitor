import AppKit
import Testing
@testable import HardwareMonitor

/// Cadence, events, visibility, debounce and history (R-1, R-2, R-3a, R-21, DD-2, DD-4), on the fake scheduler and the
/// stub `System`.
extension Desktop {
    @MainActor @Suite struct SamplerTests {
        let h = Harness()

        /// R-1: launch runs one tick (and the disk read and the power state) at once; then exactly one tick every 1 s
        /// and one disk read every 60 s, with nothing else armed.
        @Test func launchTickAndCadence() throws {
            let app = h.launch()
            #expect(h.system.cpuReads == 1 && h.system.diskReads == 1 && h.system.sourceReads == 1)
            #expect(h.armed == [1, 60])
            #expect(h.scheduler.pending.map(\.tolerance) == [0.1, 5]) // 10 % of the wait, capped at 5 s
            h.advance(0.5)
            #expect(h.system.cpuReads == 1)
            h.advance(0.5)
            #expect(h.system.cpuReads == 2)
            #expect(h.armed == [1, 59])
            h.advance(59)
            #expect(h.system.cpuReads == 61 && h.system.diskReads == 2)
            #expect(h.armed == [1, 60])
            h.advance(60)
            #expect(h.system.cpuReads == 121 && h.system.diskReads == 3)
            #expect(h.armed.count == 2) // only the tick and the disk timer, ever
            #expect(h.system.sourceReads == 1) // the power state is not polled
            #expect(h.system.propertyReads.allSatisfy { $0 == "PerformanceStatistics" }) // the one GPU property (R-4)
            #expect(h.log.contains("tick: #60 took ") && h.log.contains("tick: #120 took "))
            #expect(app.visible)
        }

        /// Each tick reads every resolved temperature key and the three power keys (R-6, R-7); key info only once (R-9).
        @Test func tickReadsEveryKeyOnce() {
            let app = h.launch()
            let launchInfos = h.system.infoFetches.count
            h.system.valueFetches = []
            h.advance(Sampler.interval)
            #expect(Set(h.system.valueFetches) == Set(Fixture.m5CPU + Fixture.m5GPU + ["PSTR", "PDTR", "PPBR"]))
            #expect(h.system.valueFetches.count == 18 + 7 + 3)
            #expect(h.system.infoFetches.count == launchInfos)
            #expect(app.sampler.snapshot.cpuTemp == 61)
        }

        @Test func pausedLaunch() {
            h.locked = true
            let app = h.launch()
            #expect(!app.visible && app.sampler.paused)
            #expect(h.system.cpuReads == 0 && h.system.diskReads == 0 && h.system.sourceReads == 0)
            #expect(h.armed.isEmpty)
            #expect(Updater.paused)
            #expect(h.log.contains("visibility: hidden at launch"))
            h.locked = false
            h.distributed.post(name: AppDelegate.unlockedName, object: nil)
            #expect(h.system.cpuReads == 1 && h.system.diskReads == 1 && h.system.sourceReads == 1)
            #expect(h.armed == [1, 60])
            #expect(!Updater.paused)
        }

        @Test func displaysAsleepAtLaunch() {
            h.displaysAsleep = true
            let app = h.launch()
            #expect(!app.visible && h.system.cpuReads == 0)
        }

        /// R-2: pressure and power events re-read and redraw at once, without waiting for the tick.
        @Test func eventsRedraw() throws {
            let app = h.launch()
            h.advance(Sampler.interval)
            let button = try #require(app.statusItem.item.button)
            let image = button.image
            let reads = h.system.cpuReads
            h.system.ints["kern.memorystatus_vm_pressure_level"] = 4
            h.system.ints["kern.memorystatus_level"] = 9
            h.pressureEvent()
            #expect(app.sampler.snapshot.memory?.level == .critical && app.sampler.snapshot.memory?.fill == 91)
            #expect(button.image !== image)
            #expect(app.statusItem.glance?.columns[2].bottom == .bar(fill: 91, level: .critical))

            let pressured = button.image
            Fixture.charging.install(h.system)
            h.powerEvent()
            #expect(app.sampler.snapshot.source.state == .charging)
            #expect(app.statusItem.glance?.columns[3].badge == true)
            #expect(button.image !== pressured)
            #expect(h.system.cpuReads == reads) // no tick ran
        }

        /// R-21: leaving visible cancels every timer, pauses the updater and makes events be ignored; returning
        /// redraws, clears the histories, re-reads the power state, runs one tick and one disk read at once, re-arms
        /// the cadence and resumes the updater. A power change while hidden is reflected right after return.
        @Test func leaveAndReturn() throws {
            let app = h.launch()
            h.advance(5)
            #expect(app.sampler.snapshot.cpuHistory.samples == [nil, 38, 38, 38, 38, 38])
            #expect(app.sampler.snapshot.gpuHistory.samples.count == 6)

            h.ws.center.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(!app.visible && app.sampler.paused && Updater.paused)
            #expect(h.armed.isEmpty)
            #expect(h.log.contains("visibility: hidden (NSWorkspaceWillSleepNotification)"))

            // While hidden: nothing runs, and events are ignored.
            let reads = (h.system.cpuReads, h.system.diskReads, h.system.sourceReads)
            Fixture.charging.install(h.system)
            h.powerEvent()
            h.pressureEvent()
            h.advance(3600)
            #expect((h.system.cpuReads, h.system.diskReads, h.system.sourceReads) == reads)
            #expect(app.sampler.snapshot.source.state == .onBattery)

            h.ws.center.post(name: NSWorkspace.didWakeNotification, object: nil)
            #expect(app.visible && !app.sampler.paused && !Updater.paused)
            #expect((h.system.cpuReads, h.system.diskReads, h.system.sourceReads) == (reads.0 + 1, reads.1 + 1, reads.2 + 1))
            #expect(app.sampler.snapshot.source.state == .charging) // the power change while hidden
            #expect(app.statusItem.glance?.columns[3].badge == true)
            // Histories restart; the return tick has no CPU baseline: a gap, and the last % stays shown (R-3a).
            #expect(app.sampler.snapshot.cpuHistory.samples == [nil])
            #expect(app.sampler.snapshot.gpuHistory.samples == [12])
            #expect(app.sampler.snapshot.cpu == 38)
            #expect(h.armed == [1, 60])
            h.advance(Sampler.interval)
            #expect(app.sampler.snapshot.cpuHistory.samples == [nil, 38])
        }

        /// Each visibility condition alone hides HardwareMonitor; lock and unlock come from the distributed center.
        @Test func visibilityGate() {
            let app = h.launch()
            for (gone, back) in [(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                                 (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                                 (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
                h.ws.center.post(name: gone, object: nil)
                #expect(!app.visible && h.armed.isEmpty)
                h.ws.center.post(name: back, object: nil)
                #expect(app.visible && h.armed == [1, 60])
            }
            h.distributed.post(name: AppDelegate.locked, object: nil)
            #expect(!app.visible)
            h.ws.center.post(name: NSWorkspace.willSleepNotification, object: nil) // still hidden: nothing changes
            h.ws.center.post(name: NSWorkspace.didWakeNotification, object: nil)
            #expect(!app.visible && h.armed.isEmpty)
            h.distributed.post(name: AppDelegate.unlockedName, object: nil)
            #expect(app.visible)
            #expect(h.system.cpuReads == 5) // launch + one per return
            #expect(h.log.contains("visibility: hidden (com.apple.screenIsLocked)"))
            app.sampler.resume() // already visible: nothing
            #expect(h.system.cpuReads == 5)
        }

        /// R-3a: "—" before the first success, the last value kept through 2 failures, "—" from the 3rd; failures
        /// and the missing baseline are gaps in the history.
        @Test func debounceAndGaps() {
            let sampler = Sampler()
            sampler.start()
            #expect(sampler.snapshot.cpu == nil) // no baseline yet: "—" before the first success
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.cpu == 38 && sampler.snapshot.gpu == 12)
            h.system.gpuStats = nil
            h.system.ticks = nil
            h.advance(Sampler.interval)
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.gpu == 12 && sampler.snapshot.cpu == 38)
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.gpu == nil && sampler.snapshot.cpu == nil)
            #expect(sampler.snapshot.gpuHistory.samples == [12, 12, nil, nil, nil])
            #expect(sampler.snapshot.cpuHistory.samples == [nil, 38, nil, nil, nil])
            h.system.gpuStats = ["Device Utilization %": 20]
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.gpu == 20)

            // An SMC read that fails keeps the last temperature until the 3rd failure.
            h.system.smc["Tp00"] = nil
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.cpuTemp == 60) // the next hottest key
            for key in Fixture.m5CPU { h.system.smc[key] = nil }
            h.advance(2 * Sampler.interval)
            #expect(sampler.snapshot.cpuTemp == 60)
            h.advance(Sampler.interval)
            #expect(sampler.snapshot.cpuTemp == nil)
        }

        /// R-9: without the SMC, temperatures and power are unavailable and everything else still works.
        @Test func smcUnavailable() {
            let h = Harness(.smcUnavailable)
            let snapshot = h.snapshot()
            #expect(snapshot.cpuTemp == nil && snapshot.gpuTemp == nil && snapshot.system == nil && snapshot.dcIn == nil)
            #expect(snapshot.cpu == 38 && snapshot.memory?.percent == 72 && snapshot.disk != nil)
            #expect(h.system.infoFetches.isEmpty && h.system.valueFetches.isEmpty)
        }

        /// The disk timer's read also redraws.
        @Test func diskTimerRedraws() {
            let app = h.launch()
            h.system.volume = (61_000_000_000, 926_000_000_000, "Macintosh HD")
            h.advance(59)
            #expect(app.statusItem.glance?.columns[4].top.text == "412")
            h.advance(1)
            #expect(app.statusItem.glance?.columns[4].top == .init(text: "61", unit: "G", level: .warning, strong: true))
        }

        // MARK: Panel-only work (R-11)

        /// Opening starts `ps`, `top` and the clock baseline at once, then a round every 1 s from each round's start;
        /// nothing panel-only exists before the first open or after a close.
        @Test func panelRounds() async {
            let sampler = Sampler()
            var changes = 0
            sampler.onChange = { changes += 1 }
            sampler.start()
            #expect(h.armed == [1, 60] && h.system.subscriptions == 0 && h.system.samples == 0 && sampler.extras == nil)
            h.system.onSample = { [h] in h.now = h.now.addingTimeInterval(0.25) } // the sample's cost
            h.advance(Sampler.interval / 2) // half a tick in, so the tick and the rounds don't coincide

            sampler.panelOpened(rows: 8)
            #expect(h.system.subscriptions == 1 && h.system.samples == 1) // the baseline, at once
            #expect(sampler.extras?.clocks.map(\.label) == ["Super", "Performance"] && sampler.extras?.clocks.allSatisfy { $0.measuring } == true)
            #expect(sampler.extras?.cpu == .blank && sampler.extras?.memory == .measuring)
            #expect(h.armed == [0.25, 0.75, 4.75, 4.75, 59.25]) // the tick; re-armed 1 s after the round started; the 5 s process timeouts
            await h.until { h.launches("ps").count == 1 && h.launches("top").count == 1 && sampler.extras?.memory != .measuring
                && sampler.extras?.cpu != .blank }
            #expect(sampler.extras?.cpu == .rows(Fixture.procs().cpu) && sampler.extras?.memory == .rows(Fixture.procs().memory))
            #expect(changes >= 3)

            h.advance(0.75) // to the second round's start; its sample takes 0.25 s
            #expect(h.system.samples == 2 && sampler.extras?.clocks.map(\.mhz) == [2500, 1900])
            #expect(h.armed == [0.5, 1, 5, 5, 58.5]) // the tick, the next round 1 s after this one started (not after it ended)
            await h.until { h.launches("ps").count == 2 && h.launches("top").count == 2 }
            #expect(h.launches("ps").count == 2 && h.launches("top").count == 2)
            await settle(0.2)

            sampler.panelClosed()
            #expect(sampler.extras == nil && h.armed == [0.5, 58.5]) // the cadence is gone; tick and disk remain
            h.system.onSample = {}
            h.advance(30)
            await settle(0.2)
            #expect(h.launches("ps").count == 2 && h.launches("top").count == 2 && h.system.samples == 2)

            // Reopening: a new baseline (the dropped sample isn't reused), the lists measure again, the
            // subscription is kept.
            sampler.panelOpened(rows: 8)
            #expect(sampler.extras?.cpu == .blank && sampler.extras?.memory == .measuring && sampler.extras?.clocks.allSatisfy { $0.measuring } == true)
            #expect(h.system.subscriptions == 1 && h.system.deltas.count == 1)
            sampler.panelOpened(rows: 5) // already open: nothing
            #expect(sampler.extras?.rows == 8)
            await h.until { h.launches("top").count == 3 }
            sampler.panelClosed()
            sampler.panelClosed()
            await settle(0.2)
        }

        /// A slow `top` (1.6 s) is never overlapped by the 1 s rounds; `ps` runs every round.
        @Test func slowTopIsNeverOverlapped() async {
            Processes.commands[.top] = h.script("top", "sleep 1.6; cat <<'EOF'\n\(Fixture.topText)\nEOF")
            let sampler = Sampler()
            sampler.start()
            sampler.panelOpened(rows: 8)
            await h.until { h.launches("top").count == 1 && sampler.extras?.cpu != .blank } // ps is done, top sleeps
            h.advance(1)
            await h.until { h.launches("ps").count == 2 }
            await settle(0.2)
            #expect(h.launches("top").count == 1) // still in flight: skipped
            await h.until { sampler.extras?.memory != .measuring }
            #expect(sampler.extras?.memory == .rows(Fixture.procs().memory))
            h.advance(1)
            await h.until { h.launches("top").count == 2 && h.launches("ps").count == 3 }
            #expect(h.launches("top").count == 2 && h.launches("ps").count == 3)
            sampler.panelClosed()
        }

        /// Closing (any path ends here) terminates running children and discards their late output; pausing closes.
        @Test func closeTerminatesChildren() async throws {
            Processes.commands = [.ps: h.script("ps", "exec sleep 30"), .top: h.script("top", "exec sleep 30")]
            let sampler = Sampler()
            sampler.start()
            sampler.panelOpened(rows: 8)
            await h.until { h.launches("ps").count == 1 && h.launches("top").count == 1 }
            let pids = h.launches("ps") + h.launches("top")
            sampler.pause() // leaving visible closes the panel work too
            #expect(sampler.extras == nil && h.armed.isEmpty)
            await h.until { pids.allSatisfy { kill($0, 0) != 0 } }
            #expect(pids.allSatisfy { kill($0, 0) != 0 })
            #expect(h.log.contains("ps: terminated (panel closed)") && h.log.contains("top: terminated (panel closed)"))
            sampler.panelOpened(rows: 8) // paused: never opens
            #expect(sampler.extras == nil && h.launches("ps").count == 1)
        }

        /// A failed command shows "Unavailable" until the next success.
        @Test func failedListIsUnavailable() async {
            Processes.commands[.ps] = h.script("ps", "exit 1")
            let sampler = Sampler()
            sampler.start()
            sampler.panelOpened(rows: 8)
            await h.until { sampler.extras?.cpu == .unavailable }
            #expect(sampler.extras?.cpu == .unavailable)
            Processes.commands[.ps] = h.script("ps2", "cat <<'EOF'\n\(Fixture.psText)\nEOF")
            h.advance(1)
            await h.until { sampler.extras?.cpu != .unavailable }
            #expect(sampler.extras?.cpu == .rows(Fixture.procs().cpu))
            sampler.panelClosed()
        }

        /// With the processes tile left out (short screen), rounds only sample clocks: no process is launched.
        @Test func processesLeftOut() async {
            let sampler = Sampler()
            sampler.start()
            sampler.panelOpened(rows: 0)
            h.advance(3)
            await settle(0.3)
            #expect(h.launches("ps").isEmpty && h.launches("top").isEmpty)
            #expect(h.system.samples == 4 && sampler.extras?.rows == 0)
            sampler.panelClosed()
        }

        /// Without IOReport the clock rows are "—" from the first round; the launch line says so.
        @Test func ioReportUnavailable() {
            h.system.ioReport = false
            let app = h.launch()
            #expect(h.log.contains("launch: chip M5 Pro, SMC available, IOReport unavailable, CPU keys 18, GPU keys 7"))
            app.sampler.panelOpened(rows: 0)
            #expect(app.sampler.extras?.clocks == [ClockRow(label: "Super", mhz: nil), ClockRow(label: "Performance", mhz: nil)])
            app.sampler.panelClosed()
        }
    }
}
