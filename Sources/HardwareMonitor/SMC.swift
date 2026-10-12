import Foundation

/// SMC semantics on top of `System`'s raw struct call (R-9, DD-8): open once, key info fetched once per key and
/// cached (misses too), typed decoding, and key enumeration. No writes, no fan control.
final class SMC {
    struct Info: Equatable {
        var size: UInt32
        var type: String
    }

    /// False when the connection can't be opened: every SMC-backed value is then unavailable (R-9).
    let isOpen: Bool
    private var infos: [String: Info?] = [:]

    init() { isOpen = System.current.smcOpen() }

    /// Closed at quit.
    func close() { if isOpen { System.current.smcClose() } }

    /// The key's info, fetched once (data8 = 9) and cached; nil if the SMC lacks the key.
    func info(_ key: String) -> Info? {
        if let cached = infos[key] { return cached }
        let info = isOpen ? System.current.smcKeyInfo(Self.code(key)).flatMap {
            Self.ok($0.result) ? Info(size: $0.size, type: Self.name($0.type)) : nil
        } : nil
        infos[key] = info
        return info
    }

    /// The key's current value (data8 = 5), decoded by its type.
    func value(_ key: String) -> Double? {
        guard let info = info(key), let read = System.current.smcRead(Self.code(key), size: info.size), Self.ok(read.result) else { return nil }
        return Self.decode(read.bytes, type: info.type)
    }

    /// Every key name (data8 = 8 for each index below the `#KEY` count) that `keep` accepts. The filter sees only the
    /// name, so no info or value is fetched for a key it rejects (R-6).
    func keys(where keep: (String) -> Bool) -> [String] {
        guard let count = value("#KEY"), count > 0 else { return [] }
        return (0..<UInt32(count)).compactMap { System.current.smcKey(at: $0).flatMap { Self.ok($0.result) ? Self.name($0.key) : nil } }
            .filter(keep)
    }

    /// The call's result byte: only 0 is a success (0x84: key not found).
    static func ok(_ result: UInt8) -> Bool { result == 0 }

    /// A four-character code packed big-endian ("TC0P" → 0x54433050).
    static func code(_ key: String) -> UInt32 { key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    static func name(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    /// `flt ` (little-endian float), `ui8 `, `ui16`, `ui32` (big-endian) and `sp78` (signed 8.8 fixed point,
    /// big-endian). Other types and short data: nil.
    static func decode(_ b: [UInt8], type: String) -> Double? {
        func be(_ n: Int) -> UInt32? { b.count >= n ? b.prefix(n).reduce(0) { $0 << 8 | UInt32($1) } : nil }
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            return Double(Float(bitPattern: b.prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }))
        case "ui8 ": return be(1).map(Double.init)
        case "ui16": return be(2).map(Double.init)
        case "ui32": return be(4).map(Double.init)
        case "sp78": return be(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        default: return nil
        }
    }
}
