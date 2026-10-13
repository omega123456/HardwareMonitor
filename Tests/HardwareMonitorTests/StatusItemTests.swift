import AppKit
import ServiceManagement
import Testing
@testable import HardwareMonitor

extension Desktop {
    @MainActor @Suite struct StatusItemTests {
        let h = Harness()

        /// A launched sampler driving a status item, after the launch tick and one more (the first CPU %).
        func item() -> (StatusItem, Sampler) {
            let sampler = Sampler()
            let item = StatusItem(sampler: sampler)
            sampler.onChange = { [weak item] in item?.update() }
            sampler.start()
            h.advance(Sampler.interval)
            return (item, sampler)
        }

        func choose(_ title: String, in menu: NSMenu) {
            guard let entry = menu.items.first(where: { $0.title == title }) else { Issue.record("no \(title)"); return }
            NSApp.sendAction(entry.action!, to: entry.target, from: entry)
        }

        @Test func imageAndLabelFollowTheData() throws {
            let (item, sampler) = item()
            let button = try #require(item.items[.cpu]?.button)
            #expect(button.image?.isTemplate == false && button.image?.size.height == 22)
            #expect(button.accessibilityLabel() == "CPU 38 percent, 61 degrees")
            #expect(item.items[.memory]?.button?.accessibilityLabel() == "Memory 72 percent, normal pressure")
            #expect(h.log.contains("image: cpu updated ("))

            // R-16: same drawn content, so the image is not reassigned.
            let image = button.image
            h.advance(Sampler.interval)
            #expect(button.image === image)
            item.update()
            #expect(button.image === image)

            // A changed reading builds a new image and label.
            h.system.tickStep = [70, 0, 30, 0]
            h.advance(Sampler.interval)
            #expect(button.image !== image)
            #expect(sampler.snapshot.cpu == 70)
            #expect(button.accessibilityLabel()?.hasPrefix("CPU 70 percent, ") == true)
        }

        /// Before the first read every slot is a dim "—" at the full width (R-3a, R-14).
        @Test func missingValuesKeepTheWidth() throws {
            let sampler = Sampler()
            let item = StatusItem(sampler: sampler)
            let empty = try #require(item.glances[.cpu])
            #expect(empty.columns.allSatisfy { $0.top == Metrics.missing })
            sampler.onChange = { [weak item] in item?.update() }
            sampler.start()
            #expect(item.glances[.cpu] != empty)
            #expect(item.glances[.cpu]?.width == empty.width)
        }

        /// R-14: every state draws at the same width (slots reserved at the widest text, critical mark included).
        @Test func everyStateHasTheSameWidth() {
            let fixtures: [Fixture] = [.normal, .charging, .heldConnected, .lowDrawBattery, .memWarningGpuMissing, .memCritical,
                                       .cpuWarm, .hotCPU, .lowDisk, .diskCritical, .terabyte, .smcUnavailable, .noBattery,
                                       .drainingConnected]
            let columns = fixtures.map { f in
                f.install(h.system)
                return Metrics.columns(h.snapshot())
            }
            #expect(Set(columns.map { Glance(columns: $0).width }) == [293]) // measured; the plan's target is ≤ 280 (owner: 294, then 293 with the signed drain)
            #expect(Glance(columns: Metrics.columns(Snapshot()), dev: true).width == 328)
            // Each item on its own: one width per metric in every state.
            for g in Column.Glyph.allCases {
                #expect(Set(columns.map { Glance(columns: $0.filter { $0.glyph == g }).width }).count == 1, "\(g)")
            }
        }

        /// DD-10: a left click toggles the panel (also when hover opened it); right-click or ⌃-click closes it and
        /// pops up the menu, never a permanent one.
        @Test func clickRouting() {
            let (item, sampler) = item()
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.panelOpen && sampler.extras != nil && h.popUps.isEmpty)
            item.handle(nil) // no current event: a left click
            #expect(!item.panelOpen && sampler.extras == nil)
            item.handle(mouseUp(.leftMouseUp))
            item.handle(mouseUp(.rightMouseUp))
            #expect(!item.panelOpen && sampler.extras == nil && h.popUps.count == 1)
            #expect(h.log.contains("panel: closed (menu)"))
            item.handle(mouseUp(.leftMouseUp, flags: .control))
            #expect(h.popUps.count == 2 && !item.panelOpen)
            #expect(item.items.values.allSatisfy { $0.menu == nil }) // never a permanent menu (DD-10)
            #expect(StatusItem.isMenuClick(mouseUp(.rightMouseDown)))
            #expect(!StatusItem.isMenuClick(mouseUp(.leftMouseUp, flags: .command)))
            item.perform(NSSelectorFromString("clicked:"), with: item.items[.gpu]?.button) // the sending item anchors it
            #expect(item.panelOpen && item.anchored == .gpu)
            item.closePanel("test", animated: false)
            #expect(h.log.contains("menu: opened"))
        }

        /// The right-click menu follows the system's light/dark setting, not the (wallpaper-tinted) menu bar's.
        @Test func menuFollowsTheSystemAppearance() throws {
            Style.appearanceOverride = NSAppearance(named: .darkAqua) // a dark menu bar on a light system
            defer { Style.appearanceOverride = nil }
            let (item, _) = item()
            item.handle(mouseUp(.rightMouseUp))
            #expect(try #require(h.popUps.last).appearance?.name == .aqua)
            #expect(item.glances[.cpu]?.style.dark == true) // the image keeps following the menu bar
            h.systemAppearance = NSAppearance(named: .darkAqua)!
            item.handle(mouseUp(.leftMouseUp, flags: .control))
            #expect(try #require(h.popUps.last).appearance?.name == .darkAqua)
        }

        @Test func appearanceAndContrastChangeTheImage() throws {
            let (item, _) = item()
            let button = try #require(item.items[.cpu]?.button)
            let image = button.image
            h.ws.contrast = true
            item.update()
            #expect(button.image !== image)
            #expect(item.glances[.cpu]?.style.contrast == true)
            Style.appearanceOverride = NSAppearance(named: .darkAqua)
            defer { Style.appearanceOverride = nil }
            item.update()
            #expect(item.glances[.cpu]?.style.dark == true)
        }

        @Test func rightClickMenu() {
            let (item, _) = item()
            let menu = item.makeMenu()
            #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }.dropFirst(2)
                    == ["Show in Menu Bar", "CPU", "GPU", "Memory", "Power", "Disk", "-",
                        "Launch at Login", "Automatic Updates", "Check for Updates…", "-", "Quit HardwareMonitor"])
            #expect(menu.items.first?.title.hasPrefix("HardwareMonitor Dev ") == true && menu.items.first?.isEnabled == false)

            // Launch at Login: registering may need approval in System Settings; on again unregisters.
            choose("Launch at Login", in: menu)
            #expect(h.loginCalls == ["register", "settings"])
            choose("Launch at Login", in: menu) // requires approval: settings again
            h.loginStatus = .enabled
            #expect(item.makeMenu().items.first { $0.title == "Launch at Login" }?.state == .on)
            choose("Launch at Login", in: menu)
            h.loginError = CocoaError(.featureUnsupported)
            choose("Launch at Login", in: menu)
            #expect(h.loginCalls == ["register", "settings", "settings", "unregister", "register"])
            #expect(h.log.contains("launch at login failed"))

            // Updates: a development build can't update.
            choose("Check for Updates…", in: menu)
            #expect(h.notices == ["Updates unavailable"])
            choose("Automatic Updates", in: menu)
            #expect(!Updater.isEnabled)
            #expect(item.makeMenu().items.first { $0.title == "Automatic Updates" }?.state == .off)
            choose("Automatic Updates", in: menu)
            #expect(Updater.isEnabled)

            choose("Quit HardwareMonitor", in: menu)
            #expect(h.terminations == 1)
        }
    }

    /// The hover panel (R-17–R-19): hover and click, every close path, placement, fade, highlight, short screen.
    @MainActor @Suite struct PanelTests {
        let h = Harness()

        func item() -> (StatusItem, Sampler) {
            let sampler = Sampler()
            let item = StatusItem(sampler: sampler)
            sampler.onChange = { [weak item] in item?.update() }
            sampler.start()
            h.advance(Sampler.interval)
            return (item, sampler)
        }

        func shown(_ item: StatusItem) -> Bool { (item.panel as? OffscreenPanel)?.shown == true }

        /// Opens after a 300 ms hover (a quicker sweep never opens it) with the highlight, the outside-click
        /// monitor and the panel-only work.
        @Test func hoverOpens() async {
            let (item, sampler) = item()
            item.itemTrackers[.cpu]!.entered()
            item.itemTrackers[.cpu]!.exited() // a sweep across the menu bar
            h.advance(1)
            #expect(!item.panelOpen && item.panel == nil)
            item.itemTrackers[.cpu]!.entered()
            item.itemTrackers[.cpu]!.mouseMoved(with: NSEvent()) // moves don't re-arm
            #expect(h.armed.filter { $0 == 0.3 }.count == 1)
            h.advance(0.29)
            #expect(!item.panelOpen)
            h.advance(0.01)
            #expect(item.panelOpen && shown(item) && item.items[.cpu]?.button?.isHighlighted == true && h.monitorInstalls == 1)
            #expect(sampler.extras?.rows == 8 && h.system.samples == 1)
            #expect(h.log.contains("panel: opened (hover, 8 rows)"))
            #expect(item.panelView.panel?.content.tiles.count == 5 && item.panelView.panel?.content.lists?.count == 2)
            #expect(item.panelView.frame.size == CGSize(width: 368, height: 679)) // layout B with 8 rows
            item.itemTrackers[.cpu]!.entered() // already open: nothing
            #expect(h.armed.filter { $0 == 0.3 }.isEmpty)
            h.advance(1)
            await h.until { sampler.extras?.memory != .measuring }
            #expect(item.panelView.panel?.content.lists?.last?.rows.first == .init(name: "com.docker.sailo", value: "9.0 GB"))
            item.closePanel("test", animated: false)
            #expect(item.items[.cpu]?.button?.isHighlighted == false && h.clickMonitor == nil)
        }

        /// One shared panel: hovering another item while open moves it there at once with the highlight (its work
        /// carries on); a click on another item moves it, a click on the anchored one closes it.
        @Test func panelFollowsTheItems() throws {
            let (item, sampler) = item()
            item.itemTrackers[.gpu]!.entered()
            h.advance(0.3)
            #expect(item.panelOpen && item.anchored == .gpu && item.items[.gpu]?.button?.isHighlighted == true)
            #expect(item.items[.cpu]?.button?.isHighlighted == false)
            let extras = sampler.extras
            h.itemFrame.origin.x = 1000 // the disk item's window
            item.itemTrackers[.gpu]!.exited()
            item.itemTrackers[.disk]!.entered()
            #expect(item.anchored == .disk && item.items[.disk]?.button?.isHighlighted == true && item.items[.gpu]?.button?.isHighlighted == false)
            #expect(try #require(item.panel?.frame).maxX == 1300 && h.log.contains("panel: moved (disk)"))
            h.advance(1)
            #expect(item.panelOpen && sampler.extras?.rows == extras?.rows && h.monitorInstalls == 1) // the close was cancelled
            item.handle(mouseUp(.leftMouseUp), on: .memory)
            #expect(item.panelOpen && item.anchored == .memory)
            item.handle(mouseUp(.leftMouseUp), on: .memory)
            #expect(!item.panelOpen && sampler.extras == nil)
            item.handle(mouseUp(.leftMouseUp), on: .power)
            #expect(item.panelOpen && item.anchored == .power)
        }

        /// The "Show in Menu Bar" rows hide and show items (stored in defaults); the last shown one can't be hidden,
        /// from the menu or by ⌘-drag. Hiding the anchored item closes the panel; DEV is on the first shown item.
        @Test func showInMenuBar() {
            let (item, sampler) = item()
            func row(_ name: String) -> NSMenuItem? { item.makeMenu().items.first { $0.title == name } }
            func choose(_ name: String, in menu: NSMenu) {
                guard let entry = menu.items.first(where: { $0.title == name }) else { Issue.record("no \(name)"); return }
                NSApp.sendAction(entry.action!, to: entry.target, from: entry)
            }
            #expect(item.glances[.cpu]?.dev == StatusItem.dev && item.glances[.gpu]?.dev == false)
            item.handle(mouseUp(.leftMouseUp), on: .cpu)
            choose("CPU", in: item.makeMenu())
            #expect(!item.panelOpen && item.shown == [.gpu, .memory, .power, .disk])
            #expect(h.defaults.stringArray(forKey: StatusItem.hiddenKey) == ["cpu"] && sampler.snapshot.cpu == nil)
            #expect(item.glances[.gpu]?.dev == StatusItem.dev && h.log.contains("items: hidden [cpu]"))
            #expect(row("CPU")?.state == .off && row("GPU")?.state == .on)
            for name in ["GPU", "Memory", "Power"] { choose(name, in: item.makeMenu()) }
            #expect(item.shown == [.disk] && row("Disk")?.isEnabled == false && row("CPU")?.isEnabled == true)
            #expect(item.items[.disk]?.behavior.contains(.removalAllowed) == false)
            #expect(item.items[.cpu]?.behavior.contains(.removalAllowed) == true)
            item.setShown([]) // never empty
            #expect(item.shown == [.disk])
            choose("Memory", in: item.makeMenu())
            #expect(item.shown == [.memory, .disk] && item.items[.disk]?.behavior.contains(.removalAllowed) == true)
            #expect(sampler.snapshot.memory != nil) // read at once

            // A ⌘-drag out (the item turned invisible while shown) hides it like its row; the last one stays.
            item.visibilityChanged(.memory) // invisible in tests
            #expect(item.shown == [.disk])
            item.visibilityChanged(.disk)
            #expect(item.shown == [.disk])

            // The next launch restores the hidden items.
            let next = StatusItem(sampler: Sampler())
            #expect(next.shown == [.disk])
        }

        /// Leaving the item and the panel closes it 400 ms later; reaching the panel cancels that; a fade-out
        /// orders the window out after 120 ms (as GlanceBar).
        @Test func pointerLeaves() {
            let (item, sampler) = item()
            item.handle(mouseUp(.leftMouseUp))
            item.itemTrackers[.cpu]!.exited()
            h.advance(0.3)
            item.panelTracker.entered() // reached the panel in time
            h.advance(1)
            #expect(item.panelOpen)
            item.panelTracker.exited()
            item.itemTrackers[.cpu]!.entered() // back on the item
            h.advance(1)
            #expect(item.panelOpen)
            item.itemTrackers[.cpu]!.exited()
            item.panelTracker.exited() // one pending close only
            h.advance(0.39)
            #expect(item.panelOpen)
            h.advance(0.01)
            #expect(!item.panelOpen && sampler.extras == nil && shown(item)) // fading out
            #expect(h.animations.last?.endAlpha == 0 && h.animations.last?.endFrame.minY == h.animations.last.map { $0.startFrame.minY + 4 })
            h.advance(0.12)
            #expect(!shown(item))
            #expect(h.log.contains("panel: closed (pointer left)"))
        }

        /// Right-aligned 6 pt under the item, clamped 8 pt from the screen sides; fades in 4 pt down, instantly
        /// under Reduce Motion.
        @Test func placementAndFade() throws {
            let (item, _) = item()
            item.handle(mouseUp(.leftMouseUp))
            let frame = try #require(item.panel?.frame)
            #expect(frame == CGRect(x: 1700 - 368, y: 1093 - 6 - 679, width: 368, height: 679))
            #expect(h.animations.count == 1 && h.animations[0].startAlpha == 0 && h.animations[0].endAlpha == 1
                    && h.animations[0].startFrame == frame.offsetBy(dx: 0, dy: 4))
            item.handle(mouseUp(.leftMouseUp))
            #expect(StatusItem.placement(size: CGSize(width: 368, height: 600), item: CGRect(x: 100, y: 1000, width: 50, height: 24),
                                         visible: CGRect(x: 0, y: 0, width: 1728, height: 1000)).minX == 8)
            #expect(StatusItem.placement(size: CGSize(width: 368, height: 600), item: CGRect(x: 1700, y: 1000, width: 200, height: 24),
                                         visible: CGRect(x: 0, y: 0, width: 1728, height: 1000)).maxX == 1720)
            h.ws.still = true
            h.advance(1)
            let fades = h.animations.count
            item.handle(mouseUp(.leftMouseUp))
            #expect(shown(item) && item.panel?.alphaValue == 1 && h.animations.count == fades)
            item.handle(mouseUp(.leftMouseUp))
            #expect(!shown(item) && h.animations.count == fades) // closed at once
        }

        /// Every close path closes the panel at once, tells `Sampler`, which terminates the running children.
        @Test func everyClosePathStopsTheWork() async {
            Processes.commands = [.ps: h.script("ps", "exec sleep 30"), .top: h.script("top", "exec sleep 30")]
            let app = h.launch()
            let item = app.statusItem!
            let paths: [(String, () -> Void)] = [
                ("clicked outside", { h.clickOutside() }),
                ("space changed", { h.ws.center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }),
                ("screens changed", { h.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }),
                ("menu", { item.handle(mouseUp(.rightMouseUp)) }),
                ("click", { item.handle(mouseUp(.leftMouseUp)) }),
                ("pointer left", { item.itemTrackers[.cpu]!.exited(); h.advance(0.4) }),
                ("not visible", { h.ws.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil) }),
            ]
            for (i, (why, close)) in paths.enumerated() {
                item.handle(mouseUp(.leftMouseUp))
                #expect(item.panelOpen, "\(why)")
                h.advance(1)
                await h.until { h.launches("ps").count == i + 1 && h.launches("top").count == i + 1 }
                let pids = [h.launches("ps")[i], h.launches("top")[i]]
                close()
                #expect(!item.panelOpen && app.sampler.extras == nil && h.clickMonitor == nil, "\(why)")
                #expect(h.log.contains("panel: closed (\(why))"))
                await h.until { pids.allSatisfy { kill($0, 0) != 0 } }
                #expect(pids.allSatisfy { kill($0, 0) != 0 }, "\(why)")
                h.advance(5)
                await settle(0.1)
                #expect(h.launches("ps").count == i + 1, "nothing launched while closed: \(why)")
            }
            // Hidden: hovering and clicking can't open it; back to visible they can.
            item.itemTrackers[.cpu]!.entered()
            h.advance(1)
            item.handle(mouseUp(.leftMouseUp))
            #expect(!item.panelOpen)
            h.ws.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            item.handle(mouseUp(.leftMouseUp))
            #expect(item.panelOpen)
            item.closePanel("test", animated: false)
        }

        /// R-17 short screen, at each open: 5 rows with "5 of 8" when 8 don't fit; the processes tile left out (and
        /// no `ps`/`top`) when 5 don't fit either.
        @Test func shortScreen() async {
            let (item, sampler) = item()
            h.visibleFrame = CGRect(x: 0, y: 1093 - 6 - 8 - 679, width: 1728, height: 679) // exactly fits 8 rows
            item.handle(mouseUp(.leftMouseUp))
            #expect(sampler.extras?.rows == 8)
            item.handle(mouseUp(.leftMouseUp))
            h.visibleFrame.origin.y += 1
            item.handle(mouseUp(.leftMouseUp))
            #expect(sampler.extras?.rows == 5 && item.panelView.frame.height == 619)
            #expect(item.panelView.panel?.content.lists?.map(\.note) == ["5 of 8", "5 of 8"])
            h.advance(1)
            await h.until { sampler.extras?.memory != .measuring && sampler.extras?.cpu != .blank }
            #expect(item.panelView.panel?.content.lists?.map(\.rows.count) == [5, 5])
            item.handle(mouseUp(.leftMouseUp))
            let launched = (h.launches("ps").count, h.launches("top").count)
            h.visibleFrame.origin.y += 60
            item.handle(mouseUp(.leftMouseUp))
            #expect(sampler.extras?.rows == 0 && item.panelView.panel?.content.lists == nil && item.panelView.frame.height == 477)
            #expect(h.log.contains("panel: opened (click, 0 rows)"))
            h.advance(3)
            await settle(0.3)
            #expect(h.launches("ps").count == launched.0 && h.launches("top").count == launched.1)
            #expect(h.system.samples >= 4) // the rounds still sample clocks
            item.handle(mouseUp(.leftMouseUp))
        }

        /// R-19: the open panel follows every tick and round, rebuilt only when its value changes; the stale footer.
        @Test func liveWhileOpen() throws {
            Processes.commands = [.ps: h.script("ps", "exec sleep 30"), .top: h.script("top", "exec sleep 30")]
            let (item, sampler) = item()
            item.handle(mouseUp(.leftMouseUp))
            let first = try #require(item.panelView.panel)
            item.update()
            #expect(item.panelView.panel == first)
            h.system.tickStep = [70, 0, 30, 0]
            h.advance(2)
            #expect(item.panelView.panel?.content.tiles[0].value.text == "70")
            #expect(item.panelView.panel?.content.footer == nil)
            h.now = h.now.addingTimeInterval(6) // the run loop was delayed: no tick came
            item.update()
            #expect(item.panelView.panel?.content.footer == nil)
            h.now = h.now.addingTimeInterval(8)
            item.update()
            #expect(item.panelView.panel?.content.footer == "Stale · 14 s ago")
            #expect(item.panelView.frame.height == 702) // 679 + 8 pt gap + the 15 pt footer
            item.closePanel("test", animated: false)
            #expect(sampler.extras == nil)
        }
    }

    @MainActor @Suite struct AppTests {
        let h = Harness()

        @Test func launchWiresTheItemAndLogs() throws {
            let app = h.launch()
            #expect(app.visible)
            #expect(h.log.contains("launch: chip M5 Pro, SMC available, IOReport available, CPU keys 18, GPU keys 7"))
            h.advance(Sampler.interval)
            #expect(app.statusItem.glances[.cpu]?.columns.first?.top.text == "38")
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            #expect(h.system.smcClosed)
        }

        @Test func redrawTriggers() throws {
            let app = h.launch()
            let button = try #require(app.statusItem.items[.cpu]?.button)
            let image = button.image
            h.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            h.center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            #expect(button.image === image) // nothing visible changed
            h.ws.contrast = true
            h.ws.center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(button.image !== image)
            let contrast = button.image
            h.distributed.post(name: Notification.Name("com.apple.other"), object: nil)
            #expect(button.image === contrast)
        }

        @Test func eventLog() {
            EventLog.write("hello")
            #expect(h.log.contains(" hello\n"))
            EventLog.removeFile()
            #expect(!FileManager.default.fileExists(atPath: EventLog.url.path))
        }
    }
}
