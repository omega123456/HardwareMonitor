import AppKit
import ServiceManagement

@main
enum HardwareMonitorMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTest.run() ? 0 : 1) } // before any UI (R-24)
        if args.contains("--log-events") { EventLog.enable() } else { EventLog.removeFile() }
        let app = NSApplication.shared // LSUIElement: no Dock icon, no main menu
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// A one-shot timer or delay that can be cancelled.
protocol Cancellable: AnyObject {
    func cancel()
}

extension Timer: Cancellable {
    func cancel() { invalidate() }
}

/// What HardwareMonitor observes and acts on outside itself, other than the hardware sources behind `System` (DD-11).
/// Tests substitute fakes (Tests/HardwareMonitorTests) so they never touch the real desktop, defaults or time;
/// production never changes these.
enum Env {
    static var workspace = NSWorkspace.shared
    /// Screen lock / unlock. A DistributedNotificationCenter in production; tests use a plain center.
    static var distributed: NotificationCenter = DistributedNotificationCenter.default()
    /// System colours and screen parameters.
    static var center = NotificationCenter.default
    static var defaults = UserDefaults.standard
    static var terminate: () -> Void = { NSApp.terminate(nil) }
    /// The only source of "now" in the app.
    static var now: () -> Date = Date.init
    /// The one-shot scheduler every timer goes through (DD-4): a tolerant one-shot timer in the common run-loop
    /// modes, so it keeps running while a menu is open. Tests fire them by hand.
    static var schedule: (_ at: Date, _ tolerance: TimeInterval, _ fire: @escaping () -> Void) -> Cancellable = { at, tolerance, fire in
        let timer = Timer(fire: at, interval: 0, repeats: false) { _ in fire() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    /// Launch state for the visibility rule (R-21).
    static var isSessionLocked: () -> Bool = {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    static var displaysAsleep: () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Arms a one-shot at `date` with a tolerance of 10 % of the wait, capped at 5 s (R-1, DD-4).
    @discardableResult
    static func at(_ date: Date, _ fire: @escaping () -> Void) -> Cancellable {
        schedule(date, min(max(date.timeIntervalSince(now()), 0) * 0.1, 5), fire)
    }

    @discardableResult
    static func after(_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> Cancellable {
        at(now().addingTimeInterval(seconds), fire)
    }
}

/// `--log-events`: millisecond-timestamped plain-text lines in ~/Library/Logs/HardwareMonitor/events.log
/// (HardwareMonitor Dev: ~/Library/Logs/HardwareMonitor Dev/events.log), cleared at each launch. The file only exists
/// while the flag is used (R-24).
enum EventLog {
    private static var handle: FileHandle?
    #if DEBUG
    private static let folder = "HardwareMonitor Dev"
    #else
    private static let folder = "HardwareMonitor"
    #endif
    static var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(folder)/events.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func enable() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil) // truncates
        handle = try? FileHandle(forWritingTo: url)
    }

    static func removeFile() { try? FileManager.default.removeItem(at: url) }

    static func write(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("\(formatter.string(from: Env.now())) \(line())\n".utf8))
    }
}

/// Launch at Login via SMAppService.mainApp; the status is always read live, never mirrored (R-22).
enum LaunchAtLogin {
    /// The login-item calls. Tests replace them so xctest is never registered as a login item.
    struct Service {
        var status: () -> SMAppService.Status = { SMAppService.mainApp.status }
        var register: () throws -> Void = { try SMAppService.mainApp.register() }
        var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
        var openSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    }
    static var service = Service()

    static var isEnabled: Bool { service.status() == .enabled }

    /// Enabled → unregister. Requires approval → open Login Items. Otherwise → register
    /// (and open Login Items if the system then asks for approval).
    static func toggle() {
        do {
            switch service.status() {
            case .enabled: try service.unregister()
            case .requiresApproval: service.openSettings()
            default:
                try service.register()
                if service.status() == .requiresApproval { service.openSettings() }
            }
        } catch {
            EventLog.write("launch at login failed: \(error)")
        }
        EventLog.write("launch at login status=\(service.status().rawValue)")
    }
}

/// Wiring, the visibility gate (R-21) and the redraw triggers (R-16).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var sampler: Sampler!
    private(set) var statusItem: StatusItem!
    private var awake = true, displaysAwake = true, sessionActive = true, unlocked = true
    private(set) var visible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.write("HardwareMonitor started pid=\(getpid())")
        unlocked = !Env.isSessionLocked()
        displaysAwake = !Env.displaysAsleep()
        visible = Metrics.visibleAtLaunch(locked: !unlocked, displaysAsleep: !displaysAwake)
        sampler = Sampler()
        statusItem = StatusItem(sampler: sampler)
        sampler.onChange = { [weak self] in self?.statusItem.update() }

        let ws = Env.workspace.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
        for name in [Self.locked, Self.unlockedName] {
            if let center = Env.distributed as? DistributedNotificationCenter {
                // Agent app: deliver immediately, not on activation.
                center.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil, suspensionBehavior: .deliverImmediately)
            } else {
                Env.distributed.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
        }
        // R-16: redraw triggers (all notifications, no polling). The appearance KVO lives in StatusItem. Nothing shown
        // depends on the clock, time zone or locale, so GlanceBar's triggers for those are not carried over.
        ws.addObserver(self, selector: #selector(redraw), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        for name in [NSColor.systemColorsDidChangeNotification, NSApplication.didChangeScreenParametersNotification] {
            Env.center.addObserver(self, selector: #selector(redraw), name: name, object: nil)
        }

        if !visible {
            EventLog.write("visibility: hidden at launch")
            statusItem.pause()
            sampler.pause()
            Updater.pause()
        }
        Updater.start()
        sampler.start()
    }

    func applicationWillTerminate(_ notification: Notification) { sampler.close() }

    static let locked = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    @objc private func redraw() { statusItem.update() }

    @objc private func visibilityChanged(_ n: Notification) {
        switch n.name {
        case NSWorkspace.willSleepNotification: awake = false
        case NSWorkspace.didWakeNotification: awake = true
        case NSWorkspace.screensDidSleepNotification: displaysAwake = false
        case NSWorkspace.screensDidWakeNotification: displaysAwake = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        case Self.locked: unlocked = false
        case Self.unlockedName: unlocked = true
        default: return
        }
        let now = Metrics.isVisible(awake: awake, displaysAwake: displaysAwake, sessionActive: sessionActive, unlocked: unlocked)
        guard now != visible else { return }
        visible = now
        EventLog.write("visibility: \(now ? "visible" : "hidden") (\(n.name.rawValue))")
        if now {
            statusItem.resume()
            sampler.resume() // redraw, clear histories, power state, one tick + one disk read, re-arm
            Updater.resume() // a missed check runs now
        } else {
            statusItem.pause() // closes the panel (its work stops with it)
            sampler.pause()
            Updater.pause()
        }
    }
}
