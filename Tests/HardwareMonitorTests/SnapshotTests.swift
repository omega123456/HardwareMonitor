import AppKit
import SnapshotTesting
import Testing
@testable import HardwareMonitor

private let imageStrategy = Snapshotting<NSImage, NSImage>.image(precision: 0.99, perceptualPrecision: 0.98)

/// Offscreen renders of the status image for every state in the plan's States table (UI/UX Wireframes → Status item
/// image), in dark and light plus the Increase Contrast cases, compared with the PNGs in __Snapshots__; and the
/// right-click menu as a text outline. Each fixture goes through the stub `System`, the real readers and `Sampler`.
/// Nothing is shown on screen; the appearance is pinned through `Style.appearanceOverride`.
extension Desktop {
    @MainActor @Suite struct SnapshotTests {
        enum ImageCase: String, CaseIterable {
            case normal, normalLight, charging, chargingLight, heldConnected, heldConnectedLight
            case lowDrawBattery, lowDrawBatteryLight, memWarningGpuMissing, memWarningGpuMissingLight
            case memCritical, memCriticalLight, cpuWarm, cpuWarmLight, hotCPU, hotCPULight
            case lowDisk, lowDiskLight, diskCritical, diskCriticalLight, terabyte, terabyteLight
            case smcUnavailable, smcUnavailableLight, noBattery, noBatteryLight
            case drainingConnected, drainingConnectedLight
            case normalNoDev, normalNoDevLight
            case normalContrast, memCriticalContrast, hotCPUContrast, normalLightContrast

            var light: Bool { rawValue.contains("Light") }
            var contrast: Bool { rawValue.hasSuffix("Contrast") }
            var dev: Bool { !rawValue.contains("NoDev") }
            var fixture: Fixture {
                switch rawValue.replacingOccurrences(of: "(NoDev)?(Light)?(Contrast)?$", with: "", options: .regularExpression) {
                case "charging": .charging
                case "heldConnected": .heldConnected
                case "lowDrawBattery": .lowDrawBattery
                case "memWarningGpuMissing": .memWarningGpuMissing
                case "memCritical": .memCritical
                case "cpuWarm": .cpuWarm
                case "hotCPU": .hotCPU
                case "lowDisk": .lowDisk
                case "diskCritical": .diskCritical
                case "terabyte": .terabyte
                case "smcUnavailable": .smcUnavailable
                case "noBattery": .noBattery
                case "drainingConnected": .drainingConnected
                default: .normal
                }
            }
        }

        /// The menu bar behind the image (the artifact's bar over its wallpaper, flattened), as GlanceBar's.
        static func backdrop(light: Bool) -> NSColor {
            light ? NSColor(srgbRed: 0.93, green: 0.92, blue: 0.94, alpha: 1) : NSColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1)
        }

        /// Draws the images at 2x over the backdrop, 4 pt margin and apart, through AppKit's drawing-handler path.
        static func render(_ glances: [Glance], light: Bool) -> NSImage {
            let images = glances.map { $0.image() }
            let size = NSSize(width: images.reduce(4) { $0 + $1.size.width + 4 }, height: Glance.height + 8)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            backdrop(light: light).setFill()
            NSRect(origin: .zero, size: size).fill()
            var x: CGFloat = 4
            for image in images {
                image.draw(in: NSRect(x: x, y: 4, width: image.size.width, height: Glance.height))
                x += image.size.width + 4
            }
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: size)
            out.addRepresentation(rep)
            return out
        }

        @Test(arguments: ImageCase.allCases)
        func statusImage(_ c: ImageCase) {
            let h = Harness(c.fixture)
            h.ws.contrast = c.contrast
            Style.appearanceOverride = NSAppearance(named: c.light ? .aqua : .darkAqua)
            defer { Style.appearanceOverride = nil }
            var snapshot = h.snapshot()
            // The usage level from the fixture's 2-minute history (a launch has too few samples for its window).
            snapshot.cpuLevel = Metrics.usageLevel(c.fixture.cpuSpark.history(usage: snapshot.cpu), was: .normal)
            snapshot.gpuLevel = Metrics.usageLevel(c.fixture.gpuSpark.history(usage: snapshot.gpu), was: .normal)
            let glance = Glance(columns: Metrics.columns(snapshot), dev: c.dev,
                                style: Style.current(for: NSAppearance(named: .aqua)!))
            assertSnapshot(of: Self.render([glance], light: c.light), as: imageStrategy, named: c.rawValue, testName: "StatusImage")
        }

        /// The five items as `StatusItem` builds them, in default order, with DEV on the first shown item. The open
        /// panel's highlight is the system's, drawn by the button, so it isn't in the images.
        @Test(arguments: [false, true])
        func separateItems(_ light: Bool) {
            let h = Harness()
            Style.appearanceOverride = NSAppearance(named: light ? .aqua : .darkAqua)
            defer { Style.appearanceOverride = nil }
            let sampler = Sampler()
            let item = StatusItem(sampler: sampler)
            sampler.onChange = { [weak item] in item?.update() }
            sampler.start()
            h.advance(Sampler.interval)
            item.handle(mouseUp(.leftMouseUp), on: .gpu)
            let glances = Column.Glyph.allCases.compactMap { item.glances[$0] }
            assertSnapshot(of: Self.render(glances, light: light), as: imageStrategy,
                           named: light ? "separateItemsLight" : "separateItems", testName: "StatusImage")
            item.closePanel("test", animated: false)
        }

        /// The hover panel (R-17, layout B + Panel states). Each case runs its fixture through the stub `System`, the
        /// readers and `Sampler`; the histories come from the plan's generator, the lists from the `procs` fixture
        /// (ranked as the first refresh) and the clock rows from `clocksM5`, unless the case says otherwise. `normal`
        /// (dark) is also the "procs loaded" and `clocksM5` case.
        enum PanelCase: String, CaseIterable {
            case normal, normalLight, charging, chargingLight, heldConnected, heldConnectedLight
            case memWarningGpuMissing, memWarningGpuMissingLight, memCritical, memCriticalLight, cpuWarm, cpuWarmLight
            case hotCPU, hotCPULight, lowDisk, lowDiskLight, diskCritical, diskCriticalLight, terabyte, terabyteLight
            case lowDrawBattery, lowDrawBatteryLight, lowDrawConnected, lowDrawConnectedLight
            case gpuGaps, shortHistory, stale, smcUnavailable, noBattery, drainingConnected
            case procsMemoryMeasuring, procsMemoryUnavailable, procsCPUUnavailable
            case clocksM1, clocksMeasuring, clocksUnavailable, shortScreen, shortScreenLeftOut
            case chargingContrast, chargingSolid

            var light: Bool { rawValue.hasSuffix("Light") }
            var fixture: Fixture {
                switch rawValue.replacingOccurrences(of: "(Light|Contrast|Solid)$", with: "", options: .regularExpression) {
                case "charging": .charging
                case "heldConnected": .heldConnected
                case "memWarningGpuMissing": .memWarningGpuMissing
                case "memCritical": .memCritical
                case "cpuWarm": .cpuWarm
                case "hotCPU": .hotCPU
                case "lowDisk": .lowDisk
                case "diskCritical": .diskCritical
                case "terabyte": .terabyte
                case "lowDrawBattery": .lowDrawBattery
                case "lowDrawConnected": .lowDrawConnected
                case "gpuGaps": .gpuGaps
                case "shortHistory": .shortHistory
                case "smcUnavailable": .smcUnavailable
                case "noBattery": .noBattery
                case "drainingConnected": .drainingConnected
                default: .normal
                }
            }

            var extras: PanelExtras {
                let procs = Fixture.procs(slots: self == .shortScreen ? 5 : 8)
                func clocks(_ f: (tables: [String: [UInt8]], channels: [IOReportChannel]), generation: Int) -> [ClockRow] {
                    Metrics.clocks(f.channels, tables: Metrics.clockTables(generation: generation) { f.tables["pmgr/\($0)"] },
                                   hasSuper: Metrics.hasSuper(f.channels.map(\.name)))
                }
                var e = PanelExtras(cpu: .rows(procs.cpu), memory: .rows(procs.memory), clocks: clocks(Fixture.clocksM5, generation: 5))
                switch self {
                case .procsMemoryMeasuring: e.memory = .measuring
                case .procsMemoryUnavailable: e.memory = .unavailable
                case .procsCPUUnavailable: e.cpu = .unavailable
                case .clocksM1: e.clocks = clocks(Fixture.clocksM1, generation: 1)
                case .clocksMeasuring: e.clocks = e.clocks.map { ClockRow(label: $0.label, mhz: nil, measuring: true) }
                case .clocksUnavailable: e.clocks = e.clocks.map { ClockRow(label: $0.label, mhz: nil) }
                case .shortScreen: e.rows = 5
                case .shortScreenLeftOut: e.rows = 0
                default: break
                }
                return e
            }
        }

        /// The panel's view (`PanelView.show`, the production path) drawn at 2x over a flat wallpaper colour.
        static func render(_ view: PanelView, light: Bool) -> NSImage {
            let size = view.bounds.size
            func bitmap() -> NSBitmapImageRep {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                return rep
            }
            let panel = bitmap(), out = bitmap()
            view.cacheDisplay(in: view.bounds, to: panel)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            (light ? NSColor(srgbRed: 0.79, green: 0.86, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.11, green: 0.17, blue: 0.31, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            panel.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(out)
            return image
        }

        @Test(arguments: PanelCase.allCases)
        func panel(_ c: PanelCase) {
            let h = Harness(c.fixture)
            h.ws.contrast = c == .chargingContrast
            h.ws.solid = c == .chargingSolid
            let appearance = NSAppearance(named: c.light ? .aqua : .darkAqua)!
            Style.appearanceOverride = appearance
            defer { Style.appearanceOverride = nil }
            var snapshot = h.snapshot()
            snapshot.cpuHistory = c.fixture.cpuSpark.history(usage: snapshot.cpu)
            snapshot.gpuHistory = c.fixture.gpuSpark.history(usage: snapshot.gpu)
            snapshot.cpuLevel = Metrics.usageLevel(snapshot.cpuHistory, was: .normal)
            snapshot.gpuLevel = Metrics.usageLevel(snapshot.gpuHistory, was: .normal)
            let now = c == .stale ? h.now.addingTimeInterval(14) : h.now
            let view = PanelView()
            view.appearance = appearance
            view.show(Panel(content: Metrics.panel(snapshot, c.extras, now: now), style: Style.current(for: appearance)))
            assertSnapshot(of: Self.render(view, light: c.light), as: imageStrategy, named: c.rawValue, testName: "Panel")
        }

        /// NSMenu can't be drawn offscreen (it renders only while tracking on a real display), so the menu is
        /// compared as text: ✓ for on, (disabled), separators as ---.
        enum MenuCase: String, CaseIterable { case defaults, loginOnUpdatesOff, lastShown }

        @Test(arguments: MenuCase.allCases)
        func menu(_ c: MenuCase) {
            let h = Harness()
            if c == .loginOnUpdatesOff {
                h.loginStatus = .enabled
                Updater.toggle()
            }
            if c == .lastShown { h.defaults.set(["cpu", "gpu", "memory", "power"], forKey: StatusItem.hiddenKey) }
            let item = StatusItem(sampler: Sampler())
            assertSnapshot(of: Self.outline(item.makeMenu()), as: .lines, named: c.rawValue, testName: "Menu")
        }

        static func outline(_ menu: NSMenu) -> String {
            menu.items.map { item in
                if item.isSeparatorItem { return "---" }
                // The debug header carries the host bundle's version, which isn't ours under swift test.
                let title = item.title.hasPrefix("HardwareMonitor Dev ") ? "HardwareMonitor Dev <version> (debug)" : item.title
                return (item.state == .on ? "✓ " : "  ") + title + (item.isEnabled ? "" : " (disabled)")
            }.joined(separator: "\n")
        }
    }
}
