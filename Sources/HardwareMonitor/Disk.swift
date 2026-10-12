import Foundation

/// The boot volume (R-8): Finder's "available" (purgeable space included), the total and the localized name.
enum Disk {
    static func read() -> DiskReading? {
        let v = System.current.bootVolume()
        guard let free = v.available, let total = v.total, total > 0, free >= 0 else { return nil }
        return DiskReading(free: free, total: Int64(total), name: v.name ?? "")
    }
}
