import AppKit
import Testing
@testable import HardwareMonitor

/// Serves GitHub's latest-release JSON and the release zip from memory.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: (URL) -> (status: Int, data: Data)? = { _ in nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, data) = Self.respond(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension Desktop {
    @MainActor @Suite struct UpdaterTests {
        let h = Harness()
        let zipURL = URL(string: "https://example.invalid/HardwareMonitor.zip")!

        init() {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            Updater.session = URLSession(configuration: config)
            Updater.isInstallable = true
        }

        func release(_ tag: String) -> Data {
            Data(#"{"tag_name":"\#(tag)","assets":[{"name":"notes.txt","browser_download_url":"https://example.invalid/n"},{"name":"HardwareMonitor.zip","browser_download_url":"\#(zipURL)"}]}"#.utf8)
        }

        /// A zipped HardwareMonitor.app whose Info.plist says `version`.
        func zip(version: String) throws -> Data {
            let root = h.dir.appendingPathComponent("build-\(version)")
            let contents = root.appendingPathComponent("HardwareMonitor.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleIdentifier": "local.hardwaremonitor"],
                                               format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let out = h.dir.appendingPathComponent("\(version).zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("HardwareMonitor.app").path, out.path]
            try ditto.run()
            ditto.waitUntilExit()
            return try Data(contentsOf: out)
        }

        func serve(release tag: String?, status: Int = 200, zip: Data? = nil) {
            let json = tag.map(release)
            StubProtocol.respond = { [zipURL] url in
                if url.host == "api.github.com" { return json.map { (status, $0) } }
                return url == zipURL ? zip.map { (200, $0) } : nil
            }
        }

        func check(manual: Bool) async {
            Updater.check(manual: manual)
            Updater.check(manual: manual) // busy: ignored
            await settle(0.3)
        }

        @Test func checks() async {
            serve(release: "v1.0.0")
            await check(manual: true)
            #expect(h.notices == ["HardwareMonitor is up to date"])
            serve(release: "v1.0.0", status: 500)
            await check(manual: true)
            #expect(h.notices.last == "Couldn't check for updates")
            serve(release: nil)
            await check(manual: false)
            #expect(h.notices.count == 2) // automatic checks fail silently
            #expect(h.log.contains("update check failed: status=0"))
            serve(release: "v2.0.0")
            await check(manual: false)
            #expect(h.asks == ["2.0.0"])
        }

        @Test func installs() async throws {
            var onUpdate: (() -> Void)?
            Updater.ask = { _, update in onUpdate = update }
            try FileManager.default.createDirectory(at: Updater.bundleURL, withIntermediateDirectories: true)
            func update(with zip: Data?) async {
                serve(release: "v2.0.0", zip: zip)
                h.notices = []
                h.relaunches = []
                onUpdate = nil
                Updater.check(manual: false)
                for _ in 0..<100 where onUpdate == nil { await settle(0.02) }
                onUpdate?()
                for _ in 0..<200 where h.notices.isEmpty && h.relaunches.isEmpty { await settle(0.02) }
            }

            // Not downloadable, not a zip, the wrong version, an unsigned bundle.
            await update(with: nil)
            #expect(h.notices == ["HardwareMonitor update failed"])
            await update(with: Data("not a zip".utf8))
            #expect(h.log.contains("could not be unpacked"))
            await update(with: try zip(version: "1.9.0"))
            #expect(h.log.contains("is not HardwareMonitor 2.0.0"))
            Updater.verify = { _ in throw CocoaError(.fileReadCorruptFile) }
            await update(with: try zip(version: "2.0.0"))
            #expect(h.notices == ["HardwareMonitor update failed"])
            Updater.verify = { _ in }

            // Verified: the bundle is replaced and the app relaunches.
            await update(with: try zip(version: "2.0.0"))
            #expect(h.relaunches == [Updater.bundleURL])
            #expect(h.log.contains("update installed, relaunching"))
            #expect(h.terminations == 1)
            #expect(Bundle(url: Updater.bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String == "2.0.0")

            // The relaunch can't start: reported, the app keeps running.
            Updater.relaunch = { _ in throw CocoaError(.executableNotLoadable) }
            await update(with: try zip(version: "2.0.0"))
            #expect(h.log.contains("update install failed"))
            #expect(h.notices == ["HardwareMonitor update failed"])
            #expect(h.terminations == 1)
        }

        @Test func schedule() async {
            serve(release: "v1.0.0")
            Updater.start() // checks now, then hourly
            Updater.start()
            await settle(0.2)
            #expect(h.log.contains("update check: 1.0.0 is current"))
            Updater.toggle()
            #expect(!Updater.isEnabled)
            Updater.start() // off: nothing
            Updater.toggle()
            #expect(Updater.isEnabled)
            await settle(0.2)
            Updater.toggle() // leaves the timer stopped
            Updater.isInstallable = false
            Updater.check(manual: false)
        }

        /// R-23 / R-21: while not visible the scheduled check is only noted; it runs on return.
        @Test func pausedCheckRunsOnResume() async {
            serve(release: "v1.0.0")
            Updater.pause()
            Updater.start() // the launch check is missed
            await settle(0.2)
            #expect(!h.log.contains("update check"))
            Updater.resume()
            await settle(0.2)
            #expect(h.log.contains("update check: 1.0.0 is current"))
            Updater.resume() // nothing missed: no second check
            await settle(0.2)
            #expect(h.log.components(separatedBy: "update check:").count == 2)
            Updater.toggle()
        }

        @Test func signatureCheck() throws {
            // The test runner's own signature has a designated requirement; an unsigned folder doesn't meet it.
            let folder = h.dir.appendingPathComponent("Unsigned.app")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try Updater.verifySignature(folder) }
        }
    }
}
