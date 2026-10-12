import AppKit
import IOKit
import IOKit.ps

/// The only place that calls the operating system (R-10, DD-11). Every member makes one direct call and returns plain
/// Swift values: it never decodes, formats or decides (that lives in the per-source files and `Metrics`, where it is
/// covered). Tests install a stub subclass (`Harness`), so they never touch real hardware. Excluded from coverage.
class System {
    /// Seam: the live system in production; tests replace it before creating any reader.
    static var current = System()

    // MARK: sysctl

    /// An integer sysctl (4 or 8 bytes), e.g. `hw.memsize`, `kern.memorystatus_level`.
    func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var v: Int32 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        case 8:
            var v: Int64 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        default:
            return nil
        }
    }

    /// A string sysctl, e.g. `machdep.cpu.brand_string`.
    func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// `vm.swapusage`: bytes of swap in use.
    func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : nil
    }

    // MARK: Host statistics

    private let host = mach_host_self() // one send right, kept (each call would leak another)

    /// `host_statistics(HOST_CPU_LOAD_INFO)`: the user, system, idle and nice ticks of all cores.
    func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    /// `host_statistics64(HOST_VM_INFO64)`.
    func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    func pageSize() -> Int { Int(vm_kernel_page_size) }

    // MARK: IOKit registry

    /// The first service matching `className` (0 if none). The caller keeps it for the app's lifetime (DD-3).
    func service(_ className: String) -> io_registry_entry_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
    }

    /// One registry property of `entry`, bridged to Swift.
    func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: SMC (R-9, DD-8)

    private var smc: io_connect_t = 0

    /// Opens the one `AppleSMC` user-client connection (type 0).
    func smcOpen() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &smc) == kIOReturnSuccess
    }

    func smcClose() {
        if smc != 0 { IOServiceClose(smc) }
        smc = 0
    }

    /// data8 = 9: the SMC result byte, a key's data size and four-char type.
    func smcKeyInfo(_ key: UInt32) -> (result: UInt8, size: UInt32, type: UInt32)? {
        guard let out = smcCall(key: key, command: 9) else { return nil }
        return (out[40], load(out, 28), load(out, 32))
    }

    /// data8 = 5: the SMC result byte and a key's value bytes; `size` comes from the cached key info.
    func smcRead(_ key: UInt32, size: UInt32) -> (result: UInt8, bytes: [UInt8])? {
        guard let out = smcCall(key: key, command: 5, size: size) else { return nil }
        return (out[40], Array(out[48..<48 + min(Int(size), 32)]))
    }

    /// data8 = 8: the SMC result byte and the key at `index` (0 ..< the `#KEY` count).
    func smcKey(at index: UInt32) -> (result: UInt8, key: UInt32)? {
        guard let out = smcCall(key: 0, command: 8, index: index) else { return nil }
        return (out[40], load(out, 0))
    }

    /// The struct-in/struct-out call, selector 2, on the 80-byte `SMCKeyData_t` laid out as in the plan's Private
    /// interface reference: key at 0, keyInfo.dataSize at 28, dataType at 32, result at 40, data8 at 42, data32 at 44,
    /// bytes at 48. Nil on a call error; the result byte is returned as is (`SMC` decides).
    private func smcCall(key: UInt32, command: UInt8, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        guard smc != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80), output = input
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            $0[42] = command
            $0.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        }
        var outSize = 80
        let result = input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in IOConnectCallStructMethod(smc, 2, i.baseAddress, 80, o.baseAddress, &outSize) }
        }
        return result == kIOReturnSuccess ? output : nil
    }

    private func load(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    // MARK: Power sources (R-7)

    /// The description dictionary of every power source.
    func powerSources() -> [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// The external adapter's details (`Watts`, …), nil without one.
    func adapterDetails() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }

    // MARK: Event sources (R-2)

    private var powerHandler: (() -> Void)?
    private var pressureSource: DispatchSourceMemoryPressure?

    /// The IOKit power-source run-loop notification (plug, unplug, charging start/stop), on the main run loop.
    /// Kept for the app's lifetime.
    func observePowerSources(_ handler: @escaping () -> Void) {
        powerHandler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            context.map { Unmanaged<System>.fromOpaque($0).takeUnretainedValue().powerHandler?() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// The dispatch memory-pressure source (normal, warning, critical) on the main queue. Kept for the app's lifetime.
    func observeMemoryPressure(_ handler: @escaping () -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        pressureSource = source
    }

    // MARK: Disk (R-8)

    /// The boot volume's resource values, from a fresh URL each time (resource values are cached on a URL object).
    func bootVolume() -> (available: Int64?, total: Int?, name: String?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey,
        ])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity, values?.volumeLocalizedName)
    }

    // MARK: Panel only (R-11–R-13)

    /// The running application's localized name for `pid` (R-12), nil when the process isn't an app.
    func appName(_ pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.localizedName }

    /// One byte-data property of the registry entry named `entry` (`pmgr`, `pmgr-child`): the DVFS tables (R-13).
    func registryData(_ entry: String, _ key: String) -> [UInt8]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(entry))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data)
            .map { [UInt8]($0) }
    }

    /// The number of IOReport CPU performance-state channels (0 when the copy fails; `Frequency.available` decides).
    func ioReportChannelCount() -> Int {
        guard let channels = IOReportCopyChannelsInGroup(Self.cpuStats, Self.coreStates, 0, 0, 0)?.takeRetainedValue() else { return 0 }
        return ((channels as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? 0
    }

    private static let cpuStats = "CPU Stats" as CFString, coreStates = "CPU Core Performance States" as CFString

    /// The subscription to "CPU Stats" / "CPU Core Performance States" (about 55 ms, DD-3): an opaque handle for
    /// `ioReportSample` and the subscribed channel names. Nil when IOReport is unavailable.
    func ioReportSubscribe() -> (handle: AnyObject, channels: [String])? {
        guard let copied = IOReportCopyChannelsInGroup(Self.cpuStats, Self.coreStates, 0, 0, 0)?.takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied) else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, channels, &subscribed, 0, nil)?.takeRetainedValue() else { return nil }
        subscribed?.release() // owned; the samples use the requested channels, as Stats
        let names = ((channels as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []).compactMap {
            IOReportChannelGetChannelName($0)?.takeUnretainedValue() as String?
        }
        return (IOReportHandle(subscription: subscription, channels: channels), names)
    }

    /// One sample of the subscribed channels: an opaque, owned sample dictionary.
    func ioReportSample(_ handle: AnyObject) -> AnyObject? {
        guard let h = handle as? IOReportHandle else { return nil }
        return IOReportCreateSamples(h.subscription, h.channels, nil)?.takeRetainedValue()
    }

    /// The change between two samples, every channel with its states' residencies, as plain values.
    func ioReportDelta(_ earlier: AnyObject, _ later: AnyObject) -> [IOReportChannel] {
        guard let delta = IOReportCreateSamplesDelta(earlier as! CFDictionary, later as! CFDictionary, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        return items.map { item in
            func text(_ s: Unmanaged<CFString>?) -> String { s.map { $0.takeUnretainedValue() as String } ?? "" }
            let states = (0..<max(0, IOReportStateGetCount(item))).map {
                IOReportChannel.State(name: text(IOReportStateGetNameForIndex(item, $0)), residency: IOReportStateGetResidency(item, $0))
            }
            return IOReportChannel(group: text(IOReportChannelGetGroup(item)), subgroup: text(IOReportChannelGetSubGroup(item)),
                                   name: text(IOReportChannelGetChannelName(item)), states: states)
        }
    }
}

/// An IOReport subscription and the channels it samples, kept for the app's lifetime once created.
private final class IOReportHandle {
    let subscription: AnyObject
    let channels: CFMutableDictionary
    init(subscription: AnyObject, channels: CFMutableDictionary) {
        self.subscription = subscription
        self.channels = channels
    }
}

// MARK: - IOReport (libIOReport, DD-7)

// Ownership (plan, Private interface reference): Copy/Create return an owned object (+1, taken retained); Get returns a
// borrowed one (+0), declared unmanaged and taken unretained, never released. Function list from exelban/Stats (MIT)
// `Modules/CPU/bridge.h`.
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64)
    -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(_ destination: CFDictionary, _ add: CFDictionary, _ null: CFTypeRef?)
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ null: UnsafeMutableRawPointer?, _ channels: CFMutableDictionary,
                                        _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                        _ zero: UInt64, _ null2: CFTypeRef?) -> Unmanaged<AnyObject>?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ subscription: AnyObject, _ channels: CFMutableDictionary, _ null: CFTypeRef?)
    -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ earlier: CFDictionary, _ later: CFDictionary, _ null: CFTypeRef?)
    -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ channel: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ channel: CFDictionary, _ index: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ channel: CFDictionary, _ index: Int32) -> Int64
