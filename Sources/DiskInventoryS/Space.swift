import Foundation
import DiskInventoryCore

/// A volume's space, for the entries that are not files: how big it is, how much is free,
/// how much the other volumes of the same APFS container take (virtual memory, Preboot,
/// Recovery, updates). Measured once, at the end of the scan.
struct VolumeSpace {
    /// the whole APFS container (or the volume, if not APFS)
    let total: UInt64
    /// really free
    let free: UInt64
    /// on top, what the system frees by itself when needed (caches, iCloud copies): the Finder
    /// counts it as available
    let purgeable: UInt64
    /// the container's other volumes; nil if unknown (not APFS)
    let system: UInt64?

    /// nil if `root` is not a whole volume
    static func measure(_ root: String) -> VolumeSpace? {
        var fs = statfs()
        guard statfs(root, &fs) == 0 else { return nil }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        guard mountedOn == root else { return nil }
        let device = withUnsafeBytes(of: fs.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        var total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
        var free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        var purgeable: UInt64 = 0
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let v = try? URL(fileURLWithPath: root).resourceValues(forKeys: keys), let important = v.volumeAvailableCapacityForImportantUsage,
           important > 0, UInt64(important) > free {
            purgeable = UInt64(important) - free
        }
        var system: UInt64?
        if let apfs = apfsContainer(device: device, root: root) {
            total = apfs.total
            free = apfs.free
            system = apfs.others
        }
        return VolumeSpace(total: total, free: free, purgeable: purgeable, system: system)
    }

    /// From `diskutil apfs list`: the volume's container and how much the other volumes take.
    /// Reading “/” reads two volumes, System and Data (joined by firmlinks).
    private static func apfsContainer(device: String, root: String) -> (total: UInt64, free: UInt64, others: UInt64)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["apfs", "list", "-plist"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        // /dev/disk3s3s1 is a snapshot of volume disk3s3
        let dev = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
        for c in containers {
            let volumes = c["Volumes"] as? [[String: Any]] ?? []
            guard let mine = volumes.first(where: { v in
                guard let id = v["DeviceIdentifier"] as? String else { return false }
                return dev == id || dev.hasPrefix(id + "s")
            }) else { continue }
            let mineID = mine["DeviceIdentifier"] as? String
            let rolesRead: Set<String> = root == "/" ? ["System", "Data"] : []
            var others: UInt64 = 0
            for v in volumes {
                let roles = Set(v["Roles"] as? [String] ?? [])
                let read = (v["DeviceIdentifier"] as? String) == mineID || !roles.isDisjoint(with: rolesRead)
                if !read { others += (v["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0 }
            }
            guard let total = (c["CapacityCeiling"] as? NSNumber)?.uint64Value,
                  let free = (c["CapacityFree"] as? NSNumber)?.uint64Value else { return nil }
            return (total, free, others)
        }
        return nil
    }

    /// The entries to put in the map, given how much the scan counted.
    /// `unread`: there are folders not read (then the rest is theirs, plus the file system data)
    func spaces(counted: UInt64, includePurgeable: Bool, unread: Bool) -> [(Tree.Space, UInt64)] {
        let free = includePurgeable ? self.free + purgeable : self.free
        let system = self.system ?? 0
        let used = free + system + counted
        var result: [(Tree.Space, UInt64)] = [(.free, free)]
        if system > 0 { result.append((.system, system)) }
        if total > used { result.append((unread ? .unread : .filesystem, total - used)) }
        return result
    }
}
