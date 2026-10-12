import AppKit

/// The hover panel's window (R-18, DD-12): borderless and non-activating; it never becomes key or main, so the
/// frontmost app keeps the keyboard.
class HoverPanel: NSPanel {
    required override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives one tracking area's events (an NSTrackingArea's owner), so the item's and the panel's areas stay apart.
final class Tracker: NSObject {
    var entered: () -> Void = {}, exited: () -> Void = {}
    @objc func mouseEntered(with event: NSEvent) { entered() }
    @objc func mouseExited(with event: NSEvent) { exited() }
    @objc func mouseMoved(with event: NSEvent) { entered() }

    /// Always active (HardwareMonitor is never the active app), enter/exit and moves, following the view's visible rect.
    func track(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }
}

/// The status item (R-14–R-20): image reassigned only when its value changes (R-16), the accessibility label
/// (NFR-4), left vs right/⌃ click routing, the right-click menu, and GlanceBar's hover panel (hover timers, click
/// toggle, placement, fade, outside-click monitor, Space/screen-change close) without its per-column hot logic. The
/// status item never holds a permanent `menu`: it would capture the left click (DD-10). Every open and close path
/// tells `Sampler`, which starts and stops the panel-only work (R-11).
final class StatusItem: NSObject {
    // Seams: tests hide the status item and capture the menu instead of tracking it.
    static var showsStatusItem = true
    static var popUp: (NSMenu, NSStatusBarButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 5 : -5), in: button)
    }
    /// Seam: the panel's window class (tests use one that is never ordered onto a real screen).
    static var panelClass: HoverPanel.Type = HoverPanel.self
    /// Seam: the status item's window frame and the visible frame of its screen, for placement and the short-screen
    /// check (R-17, R-18).
    static var anchor: (NSStatusBarButton) -> (item: CGRect, visible: CGRect)? = { button in
        guard let window = button.window, let screen = window.screen else { return nil }
        return (window.frame, screen.visibleFrame)
    }
    /// Seam: animates the panel's frame and alpha over the 120 ms fade. The animator only advances on a live run
    /// loop, so tests apply the end state at once.
    static var animate: (NSWindow, _ frame: CGRect, _ alpha: CGFloat) -> Void = { window, frame, alpha in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: .default)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }
    }

    /// Seam: the system appearance (System Settings → Appearance) for the right-click menu. An LSUIElement app sets no
    /// appearance of its own, so the app's effective appearance is the system's; the status button's follows the
    /// wallpaper-tinted menu bar instead.
    static var systemAppearance: () -> NSAppearance = { NSApp.effectiveAppearance }

    /// Seam: a global mouse-down monitor, installed only while the panel is open (ADR "outside-click global monitor"):
    /// it sees only clicks sent to other apps, i.e. outside the panel and the status item. Returns the remover.
    static var monitorClicks: (@escaping () -> Void) -> () -> Void = { handler in
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in handler() }
        return { monitor.map(NSEvent.removeMonitor) }
    }

    static let openDelay: TimeInterval = 0.3, closeDelay: TimeInterval = 0.4, fade: TimeInterval = 0.12

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sampler: Sampler
    /// The value of the image on the button (R-16).
    private(set) var glance: Glance?
    private(set) var paused = false
    /// The open panel: the item highlight and the panel-only work (DD-14, R-11).
    private(set) var panelOpen = false
    private(set) var panel: HoverPanel?
    let panelView = PanelView()
    /// The owners of the button's and the panel's tracking areas (tests send them events directly).
    let itemTracker = Tracker(), panelTracker = Tracker()
    /// The hover delays (only while hovering) and the pending order-out at the end of a fade-out.
    private var openTimer: Cancellable?, closeTimer: Cancellable?, fadeOut: Cancellable?
    /// Removes the outside-click monitor; set only while the panel is open.
    private var removeMonitor: (() -> Void)?
    private var appearanceObservation: NSKeyValueObservation?
    #if DEBUG
    static let dev = true
    #else
    static let dev = false
    #endif

    init(sampler: Sampler) {
        self.sampler = sampler
        super.init()
        item.isVisible = Self.showsStatusItem
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // DD-5: a changed menu-bar appearance (wallpaper, theme) builds a new image.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            }
            itemTracker.track(button)
        }
        itemTracker.entered = { [weak self] in self?.pointerEntered() }
        itemTracker.exited = { [weak self] in self?.pointerExited() }
        panelTracker.entered = { [weak self] in self?.cancelClose() }
        panelTracker.exited = { [weak self] in self?.armClose() }
        panelTracker.track(panelView.box)
        // R-18: a Space change or a screen-configuration change closes the panel.
        Env.workspace.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                     name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        Env.center.addObserver(self, selector: #selector(screensChanged),
                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        update()
    }

    deinit {
        removeMonitor?()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Recomputes the image value from the sampler's snapshot; reassigns the image and label only when it changed.
    /// While open, the panel is refreshed the same way (R-19).
    func update() {
        guard let button = item.button else { return }
        let value = Glance(columns: Metrics.columns(sampler.snapshot), highlighted: panelOpen, dev: Self.dev,
                           style: Style.current(for: button.effectiveAppearance))
        if value != glance {
            glance = value
            button.image = value.image()
            button.setAccessibilityLabel(Metrics.summary(sampler.snapshot))
            EventLog.write("image: updated (\(Int(value.width)) pt)")
        }
        if panelOpen { refreshPanel() }
    }

    // MARK: Visibility (R-21)

    /// Leaving visible: the panel closes at once and hovering can't open it.
    func pause() {
        closePanel("not visible", animated: false)
        cancel(&openTimer)
        paused = true
    }

    func resume() { paused = false }

    // MARK: Clicks (DD-10)

    @objc private func clicked() { handle(NSApp.currentEvent) }

    /// Right-click or ⌃-click closes the panel and opens the app menu; a left click toggles the panel, also when hover
    /// opened it (R-18).
    func handle(_ event: NSEvent?) {
        if Self.isMenuClick(event) {
            closePanel("menu", animated: false)
            showMenu()
        } else if panelOpen {
            closePanel("click")
        } else {
            openPanel("click")
        }
    }

    static func isMenuClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control)
    }

    func showMenu() {
        guard let button = item.button else { return }
        EventLog.write("menu: opened")
        let menu = makeMenu()
        // Without its own appearance the menu inherits the button's (the menu bar's, which follows the wallpaper);
        // it follows the system's light/dark setting like every other app menu.
        menu.appearance = Self.systemAppearance()
        Self.popUp(menu, button)
    }

    // MARK: Hover panel (R-17–R-19)

    private func cancel(_ timer: inout Cancellable?) {
        timer?.cancel()
        timer = nil
    }

    /// Opens after the pointer rests on the item for 300 ms; re-entering cancels a pending close.
    private func pointerEntered() {
        cancel(&closeTimer)
        guard !panelOpen, !paused, openTimer == nil else { return }
        openTimer = Env.after(Self.openDelay) { [weak self] in
            self?.openTimer = nil
            self?.openPanel("hover")
        }
    }

    /// Leaving before 300 ms never opens it (a sweep across the menu bar); leaving an open panel's item closes it
    /// 400 ms later unless the pointer reaches the panel.
    private func pointerExited() {
        cancel(&openTimer)
        armClose()
    }

    private func cancelClose() { cancel(&closeTimer) }

    private func armClose() {
        guard panelOpen, closeTimer == nil else { return }
        closeTimer = Env.after(Self.closeDelay) { [weak self] in
            self?.closeTimer = nil
            self?.closePanel("pointer left")
        }
    }

    private var reduceMotion: Bool { Env.workspace.accessibilityDisplayShouldReduceMotion }

    func openPanel(_ why: String) {
        guard !panelOpen, !paused, let button = item.button else { return }
        cancel(&openTimer)
        cancel(&closeTimer)
        cancel(&fadeOut)
        let window = panel ?? makePanel()
        panelOpen = true
        removeMonitor = Self.monitorClicks { [weak self] in self?.closePanel("clicked outside") }
        let rows = shortScreenRows(button)
        EventLog.write("panel: opened (\(why), \(rows) rows)")
        sampler.panelOpened(rows: rows) // R-11: ps, top and the clock baseline at once
        update() // builds the content (and the highlight)
        place(window) // on every open: a fade-out leaves the frame 4 pt up, and the item or screen may have moved
        if reduceMotion { // instant
            window.alphaValue = 1
            window.orderFrontRegardless()
        } else { // fade in while moving down 4 pt into place, 120 ms
            let target = window.frame
            if !window.isVisible { window.alphaValue = 0 }
            window.setFrame(target.offsetBy(dx: 0, dy: 4), display: false)
            window.orderFrontRegardless()
            Self.animate(window, target, 1)
        }
    }

    func closePanel(_ why: String, animated: Bool = true) {
        if !animated, fadeOut != nil { // a fade-out in progress ends now
            cancel(&fadeOut)
            panel?.orderOut(nil)
        }
        guard panelOpen else { return }
        cancel(&openTimer)
        cancel(&closeTimer)
        removeMonitor?()
        removeMonitor = nil
        panelOpen = false
        EventLog.write("panel: closed (\(why))")
        sampler.panelClosed() // R-11: cadence cancelled, children terminated, late results and extras dropped
        update()
        guard let window = panel else { return }
        if !animated || reduceMotion {
            window.orderOut(nil)
            return
        }
        // Fade out while moving back up 4 pt; ordered out when the 120 ms are over.
        Self.animate(window, window.frame.offsetBy(dx: 0, dy: 4), 0)
        fadeOut = Env.after(Self.fade) { [weak self] in
            self?.fadeOut = nil
            window.orderOut(nil)
        }
    }

    @objc private func spaceChanged() { closePanel("space changed", animated: false) }
    @objc private func screensChanged() { closePanel("screens changed", animated: false) }

    /// R-17 short screen, at each open: 8 rows if the panel with 8 rows (and the stale footer, if it shows) fits
    /// between the item's window bottom − 6 pt and the visible frame's bottom + 8 pt, else 5, else 0 (left out).
    private func shortScreenRows(_ button: NSStatusBarButton) -> Int {
        guard let anchor = Self.anchor(button) else { return 8 }
        let clocks = Metrics.clockRows(hasSuper: true).map { ClockRow(label: $0.label, mhz: nil, measuring: true) } // always two rows
        func height(_ rows: Int) -> CGFloat {
            PanelView.height(Metrics.panel(sampler.snapshot, PanelExtras(clocks: clocks, rows: rows), now: Env.now()))
        }
        return Metrics.processRows(height8: height(8), height5: height(5),
                                   space: anchor.item.minY - 6 - (anchor.visible.minY + 8))
    }

    /// The open panel's content, rebuilt only when it changes, then placed.
    private func refreshPanel() {
        guard let window = panel, let extras = sampler.extras else { return }
        let value = Panel(content: Metrics.panel(sampler.snapshot, extras, now: Env.now()),
                          style: Style.current(for: window.effectiveAppearance))
        guard value != panelView.panel else { return }
        let height = panelView.frame.height
        panelView.show(value)
        if panelView.frame.height != height { place(window) }
    }

    /// Right-aligned to the item, 6 pt below its window, clamped 8 pt from the visible frame's sides.
    private func place(_ window: NSWindow) {
        guard let button = item.button, let anchor = Self.anchor(button) else { return }
        window.setFrame(Self.placement(size: panelView.frame.size, item: anchor.item, visible: anchor.visible), display: true)
    }

    static func placement(size: CGSize, item: CGRect, visible: CGRect) -> CGRect {
        let x = max(visible.minX + 8, min(item.maxX - size.width, visible.maxX - 8 - size.width))
        return CGRect(x: x, y: item.minY - 6 - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> HoverPanel {
        let p = Self.panelClass.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu // DD-12: over full-screen apps' menu bars
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true // the native shadow, which never catches clicks
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = panelView
        panel = p
        return p
    }

    // MARK: Right-click menu (R-20), built each time it opens

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if Self.dev {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            add("HardwareMonitor Dev \(version) (debug)", to: menu).isEnabled = false
            menu.addItem(.separator())
        }
        add("Launch at Login", #selector(toggleLaunchAtLogin), to: menu, on: LaunchAtLogin.isEnabled)
        add("Automatic Updates", #selector(toggleUpdates), to: menu, on: Updater.isEnabled)
        add("Check for Updates…", #selector(checkForUpdates), to: menu)
        menu.addItem(.separator())
        add("Quit HardwareMonitor", #selector(quit), to: menu)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, to menu: NSMenu, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { Env.terminate() }
}
