import Foundation
import InventarioCore

/// Lo spazio di un volume, per le voci che non sono file: quanto è grande, quanto è libero,
/// quanto occupano gli altri volumi dello stesso contenitore APFS (memoria virtuale, Preboot,
/// Recovery, aggiornamenti). Si misura una volta, alla fine della scansione.
struct VolumeSpace {
    /// il contenitore APFS intero (o il volume, se non è APFS)
    let total: UInt64
    /// libero davvero
    let free: UInt64
    /// in più, quello che il sistema libera da sé quando serve (cache, copie di iCloud): il
    /// Finder lo conta come disponibile
    let purgeable: UInt64
    /// gli altri volumi del contenitore; nil se non si sa (non APFS)
    let system: UInt64?

    /// nil se `root` non è un volume intero
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

    /// Da `diskutil apfs list`: il contenitore del volume e quanto occupano gli altri volumi.
    /// Leggendo «/» si leggono due volumi, Sistema e Dati (uniti dai firmlink).
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
        // /dev/disk3s3s1 è un'istantanea del volume disk3s3
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

    /// Le voci da mettere nella mappa, dato quanto ha contato la scansione.
    /// `unread`: ci sono cartelle non lette (allora il resto è loro, più i dati del file system)
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
