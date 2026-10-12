import Foundation

/// One of Stats' process lists (R-11, R-12, DD-15): its command runs off the main thread with single flight and a
/// 5 s timeout, its output is parsed and ranked on main, and names are looked up (through `System`) only for the rows
/// shown. Only `Sampler` starts it, and only while the panel is open.
final class Processes {
    enum Kind: String { case ps, top }

    /// Seam (DD-11): the command lines, exactly Stats'. Tests point them at `/bin/sh` fixture scripts.
    static var commands: [Kind: [String]] = [
        .ps: ["/bin/ps", "-Aceo", "pid,pcpu,comm", "-r"],
        .top: ["/usr/bin/top", "-l", "1", "-o", "mem", "-n", "8", "-stats", "pid,command,mem"],
    ]
    static let timeout: TimeInterval = 5

    let kind: Kind
    /// The rows shown after the last refresh (the ranking's memory), cleared on cancel.
    private var shown: [ProcessRow] = []
    /// The current run: its id (results from another id are discarded), terminate, and the timeout.
    private var run = 0
    private var terminate: (() -> Void)?
    private var timer: Cancellable?

    init(_ kind: Kind) { self.kind = kind }

    var inFlight: Bool { terminate != nil }

    /// Starts one run unless one is still in flight (single flight). `done` is called on main with the ranked and
    /// named rows (at most `slots`), or nil when the run failed, timed out or produced no parseable row.
    func start(slots: Int, _ done: @escaping ([ProcessRow]?) -> Void) {
        guard !inFlight, let command = Self.commands[kind], let exe = command.first else { return }
        run += 1
        let id = run, started = Env.now()
        do {
            terminate = try Self.launch(exe, Array(command.dropFirst())) { [weak self] status, output in
                guard let self, id == run, inFlight else { return } // cancelled or timed out: discarded
                finish()
                let fresh = kind == .ps ? Metrics.parsePS(output) : Metrics.parseTop(output)
                let ms = Int(Env.now().timeIntervalSince(started) * 1000)
                EventLog.write("\(kind.rawValue): exit \(status) in \(ms) ms, \(fresh.count) rows")
                guard status == 0, !fresh.isEmpty else { return done(nil) }
                let unit = kind == .ps ? Metrics.cpuUnit : Metrics.memoryUnit
                shown = Metrics.named(Metrics.rank(shown: shown, fresh: fresh, slots: slots, unit: unit), lookup: System.current.appName)
                done(shown)
            }
        } catch {
            EventLog.write("\(kind.rawValue): launch failed: \(error.localizedDescription)")
            return done(nil)
        }
        timer = Env.after(Self.timeout) { [weak self] in
            guard let self, id == run, inFlight else { return }
            terminate?()
            finish()
            EventLog.write("\(kind.rawValue): timed out after \(Int(Self.timeout)) s, terminated")
            done(nil)
        }
    }

    /// Panel closed: terminates a running child, discards its late output and forgets the shown rows.
    func cancel() {
        if inFlight { EventLog.write("\(kind.rawValue): terminated (panel closed)") }
        terminate?()
        finish()
        run += 1
        shown = []
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        terminate = nil
    }

    /// Runs `exe args` with stdout piped; reads and waits on a background queue (DD-6), then calls `done` on main
    /// with the exit status and the output as text. Returns "terminate".
    static func launch(_ exe: String, _ args: [String], _ done: @escaping (Int32, String) -> Void) throws -> () -> Void {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self) // untrusted text (NFR-6): never fails
            DispatchQueue.main.async { done(process.terminationStatus, text) }
        }
        return { process.terminate() }
    }
}
