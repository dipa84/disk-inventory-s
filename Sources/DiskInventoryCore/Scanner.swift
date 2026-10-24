import Darwin
import Foundation
import Synchronization

/// What to count and where to go (from the settings).
public struct ScanOptions: Sendable {
    /// files with several names and APFS clones count only once
    public var countSharedOnce = true
    /// go into other volumes mounted inside the folder (external disks in /Volumes);
    /// never those in /System/Volumes, which are the same disk seen from elsewhere
    public var crossVolumes = false
    /// folders with these names are not read (node_modules, .git…)
    public var skipNames: Set<String> = []

    public init(countSharedOnce: Bool = true, crossVolumes: Bool = false, skipNames: Set<String> = []) {
        self.countSharedOnce = countSharedOnce
        self.crossVolumes = crossVolumes
        self.skipNames = skipNames
    }
}

/// Reads a folder and everything in it, on all cores.
///
/// Each folder is a job: a thread opens it and reads it with `getattrlistbulk` (many entries per
/// call, with name, type and sizes together), queues the subfolders and moves on.
/// When a folder and all its subfolders have been read, whoever finishes the last one closes it:
/// it adds up the sizes, sorts the entries and tells the folder above. So sums and sorting run
/// in parallel too, and the root finishes last.
public final class DiskScanner: @unchecked Sendable {
    public let files = Atomic<Int>(0)
    public let folders = Atomic<Int>(0)
    public let bytes = Atomic<UInt64>(0)
    public let unreadable = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)

    private let threads: Int
    private let lock = NSCondition()
    private var jobs: [Job] = []
    private var finished = false
    private let registry: ExtensionRegistry
    private let mode: SizeMode
    private let options: ScanOptions
    /// files with several names and clones already counted, with the folder where they were counted
    private let hardlinks: Mutex<[FileKey: Folder]>

    private typealias Job = (folder: Folder, path: String)

    /// One scan per object. To reread part of a tree, pass its extension registry and its size
    /// mode.
    public init(threads: Int = 0, registry: ExtensionRegistry = ExtensionRegistry(), mode: SizeMode = .allocated,
                options: ScanOptions = ScanOptions()) {
        self.options = options
        // reading folders waits on the disk: a few more threads than cores help
        self.threads = threads > 0 ? threads : ProcessInfo.processInfo.activeProcessorCount * 2
        self.registry = registry
        self.mode = mode
        hardlinks = Mutex([:])
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Reads `path` and returns the tree; nil if cancelled or if `path` is not a folder.
    public func scan(_ path: String) -> Tree? {
        treeRoot = path
        let root = Folder(parent: nil, index: -1)
        guard run(root, path), !isCancelled else { return nil }
        let tree = Tree(root: root, rootPath: path, extensions: registry)
        tree.sizeMode = mode
        tree.hardlinks = hardlinks.withLock { $0 }
        return tree
    }

    /// Rereads a subfolder of the tree (Refresh): the new folder replaces the old one with
    /// `Tree.replace`.
    /// Files with several names counted outside the folder stay counted there; those inside are
    /// counted again. `Tree.replace` then takes the new list.
    public func rescan(_ folder: Folder, in tree: Tree) -> Folder? {
        treeRoot = tree.rootPath
        let fresh = Folder(parent: nil, index: folder.index)
        let outside = tree.hardlinks.filter { !$0.value.isInside(folder) }
        hardlinks.withLock { $0 = outside }
        guard run(fresh, tree.path(of: folder)), !isCancelled else { return nil }
        fresh.hardlinks = hardlinks.withLock { $0 }
        return fresh
    }

    // MARK: the data volume

    /// the tree's starting folder (also when part of it is reread)
    private var treeRoot = ""

    /// From “/” the firmlinks (/Users, /Applications…) lead into the data volume, but not to all
    /// of it: “macOS Install Data”, .Spotlight-V100 and other folders exist only there. So when the
    /// tree includes /System/Volumes/Data we read it like any folder, skipping only the folders the
    /// firmlinks lead to, which are already counted on the other side.
    private var includesDataVolume: Bool { ["/", "/System", "/System/Volumes"].contains(treeRoot) }

    private static let dataVolume = "/System/Volumes/Data"

    /// where the firmlinks lead, in the data volume (from /usr/share/firmlinks: “/Users\tUsers”)
    private static let firmlinkTargets: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            return parts.count == 2 ? dataVolume + "/" + parts[1] : nil
        })
    }()

    private func run(_ root: Folder, _ path: String) -> Bool {
        // the root is opened even if it is a symbolic link (/tmp)
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        jobs = [(root, path)]
        finished = false
        let group = DispatchGroup()
        for _ in 0 ..< threads {
            group.enter()
            let t = Thread { [self] in
                work()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        return true
    }

    private func work() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var cache = ExtensionCache()
        while true {
            lock.lock()
            while jobs.isEmpty && !finished { lock.wait() }
            if finished {
                lock.unlock()
                return
            }
            let job = jobs.removeLast()
            lock.unlock()

            let folder = job.folder
            var subjobs: [Job] = []
            if !isCancelled {
                list(job, buffer, &cache, &subjobs)
            }
            if !subjobs.isEmpty {
                folder.pending.add(subjobs.count, ordering: .relaxed)
                lock.lock()
                jobs.append(contentsOf: subjobs)
                if subjobs.count == 1 { lock.signal() } else { lock.broadcast() }
                lock.unlock()
            }
            complete(folder)
        }
    }

    /// Reading `folder` is done: if it is not waiting for anyone, close it and go up.
    private func complete(_ folder: Folder) {
        var f = folder
        while true {
            let (_, left) = f.pending.subtract(1, ordering: .acquiringAndReleasing)
            guard left == 0 else { return }
            f.finish(mode)
            guard let p = f.parent else {
                lock.lock()
                finished = true
                lock.broadcast()
                lock.unlock()
                return
            }
            f = p
        }
    }

    static let bufferSize = 256 * 1024

    private static func mountedAt(_ fs: statfs, _ path: String) -> Bool {
        withUnsafeBytes(of: fs.f_mntonname) { raw in
            path.withCString { strcmp(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0) == 0 }
        }
    }

    // values from <sys/attr.h>
    private static let ATTR_CMN_NAME: UInt32 = 0x0000_0001
    private static let ATTR_CMN_DEVID: UInt32 = 0x0000_0002
    private static let ATTR_CMN_OBJTYPE: UInt32 = 0x0000_0008
    private static let ATTR_CMN_ACCESSMASK: UInt32 = 0x0002_0000
    private static let ATTR_CMN_FILEID: UInt32 = 0x0200_0000
    private static let ATTR_CMN_ERROR: UInt32 = 0x2000_0000
    private static let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let ATTR_DIR_MOUNTSTATUS: UInt32 = 0x0000_0008
    private static let DIR_MNTSTATUS_MNTPOINT: UInt32 = 0x0000_0001
    private static let ATTR_FILE_LINKCOUNT: UInt32 = 0x0000_0001
    private static let ATTR_FILE_TOTALSIZE: UInt32 = 0x0000_0002
    private static let ATTR_FILE_ALLOCSIZE: UInt32 = 0x0000_0004
    // extended common attributes take the place of the fork ones (FSOPT_ATTR_CMN_EXTENDED)
    private static let FSOPT_ATTR_CMN_EXTENDED: UInt64 = 0x0000_0020
    private static let ATTR_CMNEXT_PRIVATESIZE: UInt32 = 0x0000_0008
    private static let ATTR_CMNEXT_CLONEID: UInt32 = 0x0000_0100
    private static let ATTR_CMNEXT_EXT_FLAGS: UInt32 = 0x0000_0200
    private static let EF_MAY_SHARE_BLOCKS: UInt64 = 0x0000_0001
    private static let VDIR: UInt32 = 2
    private static let VLNK: UInt32 = 5

    private func list(_ job: Job, _ buffer: UnsafeMutableRawPointer, _ cache: inout ExtensionCache, _ subjobs: inout [Job]) {
        let (folder, path) = (job.folder, job.path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            folder.unreadable = true
            unreadable.add(1, ordering: .relaxed)
            return
        }
        defer { close(fd) }
        // another volume mounted here stays an empty folder, as in the original.
        // getattrlistbulk does not always say so (/System/Volumes/Data), and the device number is the
        // same for the system and data volumes: ask where it is mounted.
        // Firmlinks (/Users, /Applications…) lead into the data volume but are not its mount point,
        // so they are followed.
        if folder.parent != nil && !(options.crossVolumes && !path.hasPrefix("/System/Volumes/"))
            && !(includesDataVolume && path == Self.dataVolume) {
            var fs = statfs()
            if fstatfs(fd, &fs) == 0 && Self.mountedAt(fs, path) {
                folder.mountPoint = true
                return
            }
        }
        folders.add(1, ordering: .relaxed)

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = Self.ATTR_CMN_RETURNED_ATTRS | Self.ATTR_CMN_NAME | Self.ATTR_CMN_ERROR | Self.ATTR_CMN_DEVID
            | Self.ATTR_CMN_OBJTYPE | Self.ATTR_CMN_ACCESSMASK | Self.ATTR_CMN_FILEID
        al.dirattr = Self.ATTR_DIR_MOUNTSTATUS
        al.fileattr = Self.ATTR_FILE_LINKCOUNT | Self.ATTR_FILE_TOTALSIZE | Self.ATTR_FILE_ALLOCSIZE
        al.forkattr = Self.ATTR_CMNEXT_PRIVATESIZE | Self.ATTR_CMNEXT_CLONEID | Self.ATTR_CMNEXT_EXT_FLAGS

        let base = path.hasSuffix("/") ? path : path + "/"
        // inside the data volume (read from “/”), the firmlink folders are already counted
        let checkFirmlinks = includesDataVolume && (path == Self.dataVolume || path.hasPrefix(Self.dataVolume + "/"))
        var files = 0
        var bytes: UInt64 = 0
        while true {
            let count = getattrlistbulk(fd, &al, buffer, Self.bufferSize, Self.FSOPT_ATTR_CMN_EXTENDED)
            if count <= 0 { break }
            var p = buffer
            for _ in 0 ..< count {
                let length = Int(p.load(as: UInt32.self))
                defer { p += length }
                var field = p + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & Self.ATTR_CMN_ERROR != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { continue }
                }
                guard returned.commonattr & Self.ATTR_CMN_NAME != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePtr = field + Int(nameRef.attr_dataoffset)
                // the length includes the trailing zero
                let name = UnsafeRawBufferPointer(start: namePtr, count: max(0, Int(nameRef.attr_length) - 1))
                field += MemoryLayout<attrreference_t>.size
                var dev: Int32 = 0
                if returned.commonattr & Self.ATTR_CMN_DEVID != 0 {
                    dev = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var type: UInt32 = 0
                if returned.commonattr & Self.ATTR_CMN_OBJTYPE != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var mode: UInt32 = 0
                if returned.commonattr & Self.ATTR_CMN_ACCESSMASK != 0 {
                    mode = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & Self.ATTR_CMN_FILEID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                var entry = Entry(alloc: 0, logical: 0, nameStart: 0, ext: cache.ext(of: name, registry), sub: -1, nameLen: 0, flags: [])
                if type == Self.VDIR {
                    entry.flags.insert(.directory)
                    var mounted = false
                    if returned.dirattr & Self.ATTR_DIR_MOUNTSTATUS != 0 {
                        mounted = field.loadUnaligned(as: UInt32.self) & Self.DIR_MNTSTATUS_MNTPOINT != 0
                        field += 4
                    }
                    let childPath = checkFirmlinks || mounted ? base + String(decoding: name, as: UTF8.self) : ""
                    if mounted && includesDataVolume && childPath == Self.dataVolume {
                        mounted = false
                    }
                    if mounted && !(options.crossVolumes && !base.hasPrefix("/System/Volumes/")) {
                        // another volume: it stays an empty folder, as in the original
                        entry.flags.insert(.mountPoint)
                    } else if checkFirmlinks && Self.firmlinkTargets.contains(childPath) {
                        entry.flags.insert(.firmlinked)
                    } else if !options.skipNames.isEmpty && options.skipNames.contains(String(decoding: name, as: UTF8.self)) {
                        entry.flags.insert(.skipped)
                    } else {
                        let sub = Folder(parent: folder, index: Int32(folder.entries.count))
                        entry.sub = Int32(folder.subfolders.count)
                        folder.subfolders.append(sub)
                        subjobs.append((sub, base + String(decoding: name, as: UTF8.self)))
                    }
                } else {
                    var links: UInt32 = 1
                    if returned.fileattr & Self.ATTR_FILE_LINKCOUNT != 0 {
                        links = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    if returned.fileattr & Self.ATTR_FILE_TOTALSIZE != 0 {
                        entry.logical = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                        field += 8
                    }
                    if returned.fileattr & Self.ATTR_FILE_ALLOCSIZE != 0 {
                        entry.alloc = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                        field += 8
                    }
                    var privateSize: UInt64 = 0, cloneID: UInt64 = 0, extFlags: UInt64 = 0
                    if returned.forkattr & Self.ATTR_CMNEXT_PRIVATESIZE != 0 {
                        privateSize = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                        field += 8
                    }
                    if returned.forkattr & Self.ATTR_CMNEXT_CLONEID != 0 {
                        cloneID = field.loadUnaligned(as: UInt64.self)
                        field += 8
                    }
                    if returned.forkattr & Self.ATTR_CMNEXT_EXT_FLAGS != 0 {
                        extFlags = field.loadUnaligned(as: UInt64.self)
                        field += 8
                    }
                    if type == Self.VLNK { entry.flags.insert(.symlink) }
                    if mode & 0o111 != 0 { entry.flags.insert(.executable) }
                    // APFS clones (cp -c, Finder copies) share blocks: the first one counts in full,
                    // the others only for what is their own
                    if options.countSharedOnce && extFlags & Self.EF_MAY_SHARE_BLOCKS != 0 && cloneID != 0 && links <= 1 {
                        let key = FileKey(dev: dev, id: cloneID, clone: true)
                        let seen = hardlinks.withLock { h in
                            if h[key] != nil { return true }
                            h[key] = folder
                            return false
                        }
                        if seen {
                            entry.flags.insert(.cloneSeen)
                            entry.alloc = min(entry.alloc, privateSize)
                        }
                    }
                    // a file with several names counts only once, as with du
                    if options.countSharedOnce && links > 1 && type != Self.VLNK {
                        let key = FileKey(dev: dev, id: fileID, clone: false)
                        let seen = hardlinks.withLock { h in
                            if h[key] != nil { return true }
                            h[key] = folder
                            return false
                        }
                        if seen {
                            entry.flags.insert(.hardlinkSeen)
                            entry.alloc = 0
                            entry.logical = 0
                        }
                    }
                    files += 1
                    bytes &+= entry.alloc
                }
                folder.append(name: name, entry: entry)
            }
        }
        self.files.add(files, ordering: .relaxed)
        self.bytes.add(bytes, ordering: .relaxed)
    }
}

/// Extensions a thread has already seen: short ones (up to 7 bytes) fit in an integer, so the
/// shared registry (with its lock) is touched only the first time.
struct ExtensionCache {
    private var short: [UInt64: UInt32] = [:]

    mutating func ext(of name: UnsafeRawBufferPointer, _ registry: ExtensionRegistry) -> UInt32 {
        let n = name.count
        guard n > 1 else { return 0 }
        var dot = n - 1
        while dot > 0 && name[dot] != UInt8(ascii: ".") { dot -= 1 }
        let len = n - dot - 1
        // no extension: “.DS_Store”, “Makefile”, “name.” or tails that are too long
        guard dot > 0, len > 0, len <= 15 else { return 0 }
        if len <= 7 {
            var key: UInt64 = 0
            for i in 0 ..< len { key = key << 8 | UInt64(lower(name[dot + 1 + i])) }
            key |= UInt64(len) << 60
            if let id = short[key] { return id }
            let id = registry.id(for: string(name, dot + 1, len))
            short[key] = id
            return id
        }
        return registry.id(for: string(name, dot + 1, len))
    }

    private func lower(_ c: UInt8) -> UInt8 {
        c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") ? c + 32 : c
    }

    private func string(_ name: UnsafeRawBufferPointer, _ start: Int, _ len: Int) -> String {
        String(decoding: name[start ..< start + len].map(lower), as: UTF8.self)
    }
}
