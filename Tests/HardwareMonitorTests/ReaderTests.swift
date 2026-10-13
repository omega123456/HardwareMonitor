import Foundation
import Testing
@testable import HardwareMonitor

/// Per-source decoding against stub `System` values (R-3–R-9): SMC types, the key-info cache and the enumeration
/// filter, chip key resolution, power-source dictionaries, disk values, VM counts, GPU and CPU deltas.
extension Desktop {
    @MainActor @Suite struct ReaderTests {
        let h = Harness()

        // MARK: SMC (R-9)

        @Test func decodesEveryType() {
            let flt = Float(61.25).bitPattern
            #expect(SMC.decode([0, 8, 16, 24].map { UInt8(truncatingIfNeeded: flt >> $0) }, type: "flt ") == 61.25) // little-endian
            #expect(SMC.decode([0xAB], type: "ui8 ") == 171)
            #expect(SMC.decode([0x02, 0x01], type: "ui16") == 258) // little-endian
            #expect(SMC.decode([0x18, 0xFC], type: "si16") == -1000)
            #expect(SMC.decode([1], type: "si16") == nil) // short data
            #expect(SMC.decode([0x00, 0x00, 0x07, 0xD0], type: "ui32") == 2000)
            #expect(SMC.decode([0x3D, 0x80], type: "sp78") == 61.5)
            #expect(SMC.decode([0xFF, 0x80], type: "sp78") == -0.5)
            #expect(SMC.decode([1, 2, 3], type: "flt ") == nil) // short data
            #expect(SMC.decode([], type: "ui8 ") == nil)
            #expect(SMC.decode([1, 2], type: "fpe2") == nil) // unknown type
            #expect(SMC.code("TC0P") == 0x5443_3050 && SMC.name(0x5443_3050) == "TC0P")
        }

        @Test func keyInfoIsFetchedOncePerKey() {
            let smc = SMC()
            h.system.infoFetches = []
            h.system.valueFetches = []
            #expect(smc.value("PSTR") == 14)
            #expect(smc.value("PSTR") == 14)
            #expect(smc.value("XXXX") == nil)
            #expect(smc.value("XXXX") == nil) // a miss is cached too
            #expect(h.system.infoFetches == ["PSTR", "XXXX"])
            #expect(h.system.valueFetches == ["PSTR", "PSTR"])
            #expect(smc.info("PSTR") == SMC.Info(size: 4, type: "flt "))
            h.system.smc["PSTR"] = nil // the value read fails: unavailable
            #expect(smc.value("PSTR") == nil)
            smc.close()
            #expect(h.system.smcClosed)
        }

        /// A call that succeeds with a non-zero result byte (0x84: key not found) is a miss: no info, no value, no key.
        @Test func nonZeroResultIsAMiss() {
            #expect(SMC.ok(0) && !SMC.ok(0x84) && !SMC.ok(1))
            let smc = SMC()
            #expect(smc.info("XXXX") == nil) // 0x84 with zeroed size/type
            #expect(smc.info("PSTR") == SMC.Info(size: 4, type: "flt "))
            h.system.smc["PSTR"] = nil // info cached; the read answers 0x84 with zeroed bytes (would decode to 0)
            #expect(smc.value("PSTR") == nil)
            h.system.smc = ["Tp01": ("flt ", [0, 0, 0, 0])]
            h.system.keyCount = 2 // index 1 answers 0x84: dropped
            #expect(SMC().keys(where: { _ in true }) == ["Tp01"])
        }

        @Test func unavailableSMCFetchesNothing() {
            h.system.smcAvailable = false
            let smc = SMC()
            #expect(!smc.isOpen)
            #expect(smc.value("PSTR") == nil && smc.keys(where: { _ in true }).isEmpty)
            smc.close()
            #expect(h.system.infoFetches.isEmpty && h.system.valueFetches.isEmpty && !h.system.smcClosed)
        }

        // MARK: Temperatures (R-6)

        @Test func knownChipDropsMissingKeys() {
            let thermal = Thermal(smc: SMC())
            #expect(thermal.chip == Chip(generation: 5, variant: .pro))
            #expect(thermal.cpuKeys == Fixture.m5CPU)
            #expect(thermal.gpuKeys == Fixture.m5GPU) // Tg1g dropped
            #expect(h.system.valueFetches.isEmpty) // resolving needs key info only
            h.system.setFloat("Tp08", 130) // implausible: ignored
            h.system.setFloat("Tp0C", 84.6)
            let t = thermal.read(cpu: true, gpu: true)
            #expect(t.cpu == Double(Float(84.6)) && t.gpu == 54)
            // A group not asked for reads no key.
            h.system.valueFetches = []
            #expect(thermal.read(cpu: false, gpu: true).cpu == nil)
            #expect(h.system.valueFetches == Fixture.m5GPU)
            h.system.valueFetches = []
            let none = thermal.read(cpu: false, gpu: false)
            #expect(none.cpu == nil && none.gpu == nil)
            #expect(h.system.valueFetches.isEmpty)
        }

        /// Unknown chip: the prefix filter runs on enumerated names before any info or value fetch; a key is kept
        /// only if its first value is plausible.
        @Test func unknownChipEnumerationFilter() {
            h.system.strings["machdep.cpu.brand_string"] = "Apple M10 Pro"
            h.system.smc = [:]
            h.system.setFloat("Tp01", 60)
            h.system.setFloat("Te02", 130) // implausible: dropped
            h.system.setFloat("Tg03", 50)
            h.system.setFloat("TB0T", 30) // battery: not CPU or GPU
            h.system.setFloat("Ts0P", 40)
            h.system.setFloat("PSTR", 14)
            let thermal = Thermal(smc: SMC())
            #expect(thermal.chip.name == "M10 Pro")
            #expect(thermal.cpuKeys == ["Tp01"] && thermal.gpuKeys == ["Tg03"])
            #expect(h.system.infoFetches == ["#KEY", "Te02", "Tg03", "Tp01"])
            #expect(h.system.valueFetches == ["#KEY", "Te02", "Tg03", "Tp01"])
            #expect(thermal.read(cpu: true, gpu: true).cpu == 60 && thermal.read(cpu: true, gpu: true).gpu == 50)
        }

        @Test func unknownChipWithoutTheKeyCount() {
            h.system.strings = [:]
            h.system.smc = [:] // #KEY reads 0
            let thermal = Thermal(smc: SMC())
            #expect(thermal.chip.name == "unknown" && thermal.cpuKeys.isEmpty && thermal.gpuKeys.isEmpty)
            #expect(thermal.read(cpu: true, gpu: true).cpu == nil)
        }

        // MARK: Power (R-7)

        @Test func powerKeys() {
            let power = Power(smc: SMC())
            h.system.setInt16("B0AC", -1000, signed: true) // unsigned: the sign comes from the charging state
            h.system.setInt16("B0AV", 12000)
            let p = power.read(dcIn: true)
            #expect(p.system == 14 && p.dcIn == 0 && p.battery == 12)
            h.system.valueFetches = []
            #expect(power.read(dcIn: false).dcIn == nil) // PDTR only for the open panel
            #expect(!h.system.valueFetches.contains("PDTR"))
            h.system.smc["B0AV"] = nil
            #expect(Power(smc: SMC()).read(dcIn: true).battery == nil)
        }

        @Test func powerSourceDictionaries() {
            func battery(_ state: String, charging: Bool, current: Int = 78, max: Int = 100) -> [[String: Any]] {
                [["Type": "UPS"], ["Type": "InternalBattery", "Power Source State": state, "Is Charging": charging,
                                   "Current Capacity": current, "Max Capacity": max]]
            }
            let charging = Power.decode(battery("AC Power", charging: true), adapter: ["Watts": 96, "Name": "96W USB-C"])
            #expect(charging == PowerSource(hasBattery: true, connected: true, charging: true, percent: 78, adapterWatts: 96))
            #expect(charging.state == .charging)
            let held = Power.decode(battery("AC Power", charging: false, current: 85), adapter: ["Watts": 65])
            #expect(held.state == .connected && held.percent == 85)
            let onBattery = Power.decode(battery("Battery Power", charging: false, current: 3200, max: 5000), adapter: nil)
            #expect(onBattery.state == .onBattery && onBattery.percent == 64 && onBattery.adapterWatts == nil)
            let desktop = Power.decode([], adapter: ["Watts": 150])
            #expect(desktop.state == .noBattery && desktop.connected && desktop.percent == nil && desktop.adapterWatts == 150)
            let odd = Power.decode([["Type": "InternalBattery"]], adapter: nil) // keys missing
            #expect(odd.state == .onBattery && odd.percent == nil)

            h.system.sources = battery("AC Power", charging: true)
            h.system.adapter = ["Watts": 61]
            #expect(Power.source().state == .charging && Power.source().adapterWatts == 61)
        }

        // MARK: Disk (R-8)

        @Test func diskValues() {
            #expect(Disk.read() == DiskReading(free: 412_000_000_000, total: 926_000_000_000, name: "Macintosh HD"))
            h.system.volume = (5, 10, nil)
            #expect(Disk.read() == DiskReading(free: 5, total: 10, name: ""))
            h.system.volume = (nil, 10, "X")
            #expect(Disk.read() == nil)
            h.system.volume = (5, nil, "X")
            #expect(Disk.read() == nil)
            h.system.volume = (5, 0, "X")
            #expect(Disk.read() == nil)
            h.system.volume = (-1, 10, "X")
            #expect(Disk.read() == nil)
        }

        // MARK: Memory (R-5)

        @Test func vmCounts() throws {
            var vm = vm_statistics64()
            vm.internal_page_count = 1_000_000
            vm.purgeable_count = 100_000
            vm.wire_count = 300_000
            vm.compressor_page_count = 200_000
            vm.active_count = 9_999_999 // not part of "Memory Used"
            h.system.vm = vm
            h.system.page = 16384
            h.system.ints = ["hw.memsize": 32 * 1_073_741_824, "kern.memorystatus_vm_pressure_level": 2, "kern.memorystatus_level": 38]
            h.system.swap = 3 * 1_073_741_824
            let m = try #require(Memory.read())
            #expect(m.used == 1_400_000 * 16384)
            #expect(m.total == 32 * 1_073_741_824 && m.percent == 67)
            #expect(m.level == .warning && m.fill == 62 && m.swap == 3 * 1_073_741_824)

            h.system.ints["kern.memorystatus_vm_pressure_level"] = nil
            h.system.ints["kern.memorystatus_level"] = nil
            h.system.swap = nil
            let partial = try #require(Memory.read())
            #expect(partial.level == .normal && partial.fill == nil && partial.swap == nil)
            h.system.ints["hw.memsize"] = nil
            #expect(Memory.read() == nil)
            h.system.ints["hw.memsize"] = 1
            h.system.vm = nil
            #expect(Memory.read() == nil)
        }

        // MARK: GPU (R-4)

        @Test func gpuUtilisation() {
            #expect(GPU().read() == 12)
            h.system.gpuStats = ["Device Utilization %": 140]
            #expect(GPU().read() == 100)
            h.system.gpuStats = ["Renderer Utilization %": 5]
            #expect(GPU().read() == nil)
            h.system.gpuStats = nil
            #expect(GPU().read() == nil)
            h.system.gpuStats = ["Device Utilization %": 5]
            h.system.accelerator = 0 // no IOAccelerator entry
            #expect(GPU().read() == nil)
            #expect(Set(h.system.propertyReads) == ["PerformanceStatistics"])
        }

        // MARK: CPU (R-3)

        @Test func cpuDeltas() {
            let cpu = CPU()
            #expect(cpu.read() == .noBaseline)
            #expect(cpu.read() == .percent(38))
            h.system.tickStep = [10, 5, 85, 0]
            #expect(cpu.read() == .percent(15))
            h.system.tickStep = [0, 0, 0, 0]
            #expect(cpu.read() == .failed) // no ticks passed
            cpu.reset()
            #expect(cpu.read() == .noBaseline)
            h.system.ticks = nil
            #expect(cpu.read() == .failed)
        }

        // MARK: Clocks (R-13)

        /// The M5 Pro: kHz tables from `pmgr`, Super/Performance from the channel family; the first sample is the
        /// baseline ("Measuring…"), each later one a delta against the previous sample.
        @Test func frequencyM5() {
            let f = Frequency(generation: 5)
            #expect(h.system.subscriptions == 1 && h.system.registryReads == 3)
            #expect(h.log.contains("IOReport: subscribed, 18 channels, tables 2/20/15 ("))
            #expect(f.sample() == [ClockRow(label: "Super", mhz: nil, measuring: true), ClockRow(label: "Performance", mhz: nil, measuring: true)])
            #expect(f.sample() == [ClockRow(label: "Super", mhz: 2500), ClockRow(label: "Performance", mhz: 1900)])
            #expect(f.sample().map(\.mhz) == [2500, 1900])
            #expect(h.system.deltas.map { [$0.0, $0.1] } == [[1, 2], [2, 3]])
            f.reset() // panel closed: a new baseline
            #expect(f.sample().allSatisfy { $0.measuring })
            #expect(h.system.deltas.count == 2 && h.system.subscriptions == 1)
        }

        /// M1: Hz tables, Efficiency and Performance (no MCPU channels).
        @Test func frequencyM1() {
            h.system.registry = Fixture.clocksM1.tables
            h.system.channels = Fixture.clocksM1.channels
            let f = Frequency(generation: 1)
            _ = f.sample()
            #expect(f.sample() == [ClockRow(label: "Efficiency", mhz: 1675), ClockRow(label: "Performance", mhz: 3200)])
        }

        /// A table that never matches, or no tables at all, is "—" (never a wrong number); M6 reads `pmgr-child` too.
        @Test func frequencyMismatchAndM6() {
            h.system.registry["pmgr/voltage-states22-sram"] = SelfTest.dvfsBytes([1_000_000, 2_000_000]) // 2 entries ≠ 20 states
            let f = Frequency(generation: 5)
            _ = f.sample()
            #expect(f.sample() == [ClockRow(label: "Super", mhz: 2500), ClockRow(label: "Performance", mhz: nil)])

            h.system.registry = ["pmgr-child/voltage-states5-sram": Fixture.clocksM5.tables["pmgr/voltage-states5-sram"]!]
            let m6 = Frequency(generation: 6) // Performance (empty) uses the Super table
            _ = m6.sample()
            #expect(m6.sample().map(\.label) == ["Super", "Performance"])
            #expect(h.log.contains("tables 0/15/15"))

            h.system.registry = [:]
            let none = Frequency(generation: nil) // unknown chip: no tables
            _ = none.sample()
            #expect(none.sample().allSatisfy { $0.mhz == nil && !$0.measuring })
        }

        /// IOReport is available only with at least one CPU performance-state channel.
        @Test func frequencyAvailability() {
            #expect(Frequency.available)
            h.system.channels = []
            #expect(!Frequency.available)
            h.system.ioReport = false
            #expect(!Frequency.available)
        }

        /// Without IOReport every row is "—" at once, labelled by generation; nothing is sampled.
        @Test func frequencyUnavailable() {
            h.system.ioReport = false
            #expect(Frequency(generation: 5).sample() == [ClockRow(label: "Super", mhz: nil), ClockRow(label: "Performance", mhz: nil)])
            #expect(Frequency(generation: 3).sample().map(\.label) == ["Efficiency", "Performance"])
            #expect(h.system.samples == 0)
            #expect(h.log.contains("IOReport: unavailable"))
        }

        /// The DVFS bytes as `pmgr` stores them: kHz on M4+, Hz on M1–M3, 8-byte entries.
        @Test func dvfsBytes() {
            let real: [UInt8] = [0x00, 0x82, 0x14, 0x00, 0xfd, 0x02, 0x00, 0x00, 0xe0, 0x15, 0x19, 0x00, 0x1b, 0x03, 0x00, 0x00]
            #expect(Metrics.dvfsTable(real, generation: 5) == [1344, 1644]) // voltage-states22-sram on the M5 Pro
            #expect(Metrics.dvfsTable(SelfTest.dvfsBytes([2_064_000_000]), generation: 2) == [2064])
            #expect(Metrics.dvfsTable(real + [1, 2, 3], generation: 5).count == 2) // a partial entry is ignored
        }
    }
}
