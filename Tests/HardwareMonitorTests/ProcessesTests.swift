import Foundation
import Testing
@testable import HardwareMonitor

/// The `ps`/`top` runner (R-11, R-12, NFR-6) with real `/bin/sh` fixture scripts: output delivered to main and
/// ranked, single flight, the 5 s timeout, cancel on close, late results discarded. Timers go through the fake
/// scheduler; only the child processes run in real time.
extension Desktop {
    @MainActor @Suite struct ProcessesTests {
        let h = Harness()

        private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

        @Test func deliversRankedRowsOnMain() async {
            h.system.appNames = [4801: "ccstatusline"]
            let ps = Processes(.ps)
            var result: [ProcessRow]??
            ps.start(slots: 8) { rows in
                #expect(Thread.isMainThread)
                result = .some(rows)
            }
            #expect(ps.inFlight)
            await h.until { result != nil }
            #expect(!ps.inFlight)
            let rows = try? #require(result ?? nil)
            #expect(rows?.map(\.display) == ["ccstatusline", "Docker Desktop Helper (Renderer)", "node", "com.docker.sailor",
                                             "WindowServer", "claude", "stable", "Stats"])
            #expect(h.system.nameLookups.count == 8) // only the rows shown
            #expect(h.log.contains("ps: exit 0 in ") && h.log.contains(" ms, 15 rows"))

            // The next refresh keeps the names: no lookups for rows already shown.
            result = nil
            ps.start(slots: 8) { result = .some($0) }
            await h.until { result != nil }
            #expect(h.system.nameLookups.count == 8)
        }

        @Test func topRowsAndFailures() async {
            let top = Processes(.top)
            var result: [ProcessRow]??
            top.start(slots: 5) { result = .some($0) }
            await h.until { result != nil }
            #expect((result ?? nil)?.map(\.command) == ["com.docker.sailo", "Vivaldi Helper", "WindowServer", "stable", "Vivaldi"])

            // A non-zero exit, and output without a parseable row, both fail.
            Processes.commands[.top] = h.script("fail", "echo 'PID COMMAND MEM'; echo '1 x 5M'; exit 3")
            result = nil
            top.start(slots: 5) { result = .some($0) }
            await h.until { result != nil }
            #expect(result == .some(nil))
            Processes.commands[.top] = h.script("empty", "echo hello")
            result = nil
            top.start(slots: 5) { result = .some($0) }
            await h.until { result != nil }
            #expect(result == .some(nil))
            #expect(h.log.contains("top: exit 3 in ") && h.log.contains(" ms, 0 rows"))

            Processes.commands[.top] = ["/nonexistent/top"]
            result = nil
            top.start(slots: 5) { result = .some($0) }
            #expect(result == .some(nil)) // a launch failure reports at once
            #expect(h.log.contains("top: launch failed"))
        }

        /// A slow `top` (1.6 s) is never overlapped: starts while it runs are skipped.
        @Test func singleFlight() async {
            Processes.commands[.top] = h.script("slow", "sleep 1.6; cat <<'EOF'\n\(Fixture.topText)\nEOF")
            let top = Processes(.top)
            var results = 0
            top.start(slots: 8) { _ in results += 1 }
            await h.until { h.launches("slow").count == 1 }
            for _ in 0..<3 { top.start(slots: 8) { _ in results += 1 } }
            await settle(0.5)
            #expect(h.launches("slow").count == 1 && top.inFlight)
            await h.until { results == 1 }
            #expect(results == 1 && !top.inFlight)
            top.start(slots: 8) { _ in results += 1 }
            await h.until { h.launches("slow").count == 2 }
            #expect(h.launches("slow").count == 2)
            top.cancel()
        }

        /// A hung command is terminated after 5 s and reported as failed; its late end is discarded.
        @Test func timeout() async throws {
            Processes.commands[.ps] = h.script("hung", "exec sleep 30")
            let ps = Processes(.ps)
            var results: [[ProcessRow]?] = []
            ps.start(slots: 8) { results.append($0) }
            await h.until { h.launches("hung").count == 1 }
            let pid = try #require(h.launches("hung").first)
            #expect(h.armed == [5])
            h.advance(4.9)
            #expect(alive(pid) && results.isEmpty)
            h.advance(0.1)
            #expect(results.count == 1 && results[0] == nil && !ps.inFlight)
            await h.until { !alive(pid) }
            #expect(!alive(pid))
            await settle(0.1)
            #expect(results.count == 1) // the terminated run's end is discarded
            #expect(h.log.contains("ps: timed out after 5 s, terminated"))
        }

        /// Cancel (any panel close) terminates the child and discards output that arrives afterwards.
        @Test func cancelTerminatesAndDiscards() async throws {
            Processes.commands[.ps] = h.script("hung", "exec sleep 30")
            let ps = Processes(.ps)
            var results = 0
            ps.start(slots: 8) { _ in results += 1 }
            await h.until { h.launches("hung").count == 1 }
            let pid = try #require(h.launches("hung").first)
            ps.cancel()
            #expect(!ps.inFlight && h.armed.isEmpty) // the timeout is cancelled too
            await h.until { !alive(pid) }
            #expect(!alive(pid))

            // A child that ignores the termination still finishes; its output is discarded.
            Processes.commands[.ps] = h.script("stubborn", "trap '' TERM; sleep 0.3; cat <<'EOF'\n\(Fixture.psText)\nEOF")
            ps.start(slots: 8) { _ in results += 1 }
            await h.until { h.launches("stubborn").count == 1 }
            await settle(0.1) // past the trap
            ps.cancel()
            await settle(0.6)
            #expect(results == 0)
            #expect(h.log.contains("ps: terminated (panel closed)"))
        }
    }
}
