// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// An entry of a folder: a file, a subfolder, a link.
/// Compact (32 bytes) because a whole disk has millions of them.
public struct Entry {
    /// bytes taken on disk (allocated blocks, all forks)
    public var alloc: UInt64
    /// bytes of content (logical size, all forks)
    public var logical: UInt64
    /// where the name starts in `Folder.names`
    var nameStart: UInt32
    /// extension in the tree's registry (0 = none)
    public var ext: UInt32
    /// the subfolder in `Folder.subfolders`, -1 if it is not a folder
    public var sub: Int32
    var nameLen: UInt16
    public var flags: Flags

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let directory = Flags(rawValue: 1)
        /// another volume mounted here: we do not go through it
        public static let mountPoint = Flags(rawValue: 2)
        public static let symlink = Flags(rawValue: 4)
        public static let executable = Flags(rawValue: 8)
        /// a hard link already counted elsewhere: takes 0
        public static let hardlinkSeen = Flags(rawValue: 16)
        /// the folder could not be read (permissions, Full Disk Access)
        public static let unreadable = Flags(rawValue: 32)
        /// an (APFS) clone of a file already counted: takes only its own blocks
        public static let cloneSeen = Flags(rawValue: 64)
        /// not a file: free space, system volumes, folders not read or file system data (`ext` says which)
        public static let special = Flags(rawValue: 128)
        /// a folder skipped by the settings (node_modules, .git…): it was not read
        public static let skipped = Flags(rawValue: 256)
        /// in the data volume, a folder a firmlink leads to (/Users…): counted there
        public static let firmlinked = Flags(rawValue: 512)
    }

    public var isDirectory: Bool { flags.contains(.directory) }

    public func size(_ mode: SizeMode) -> UInt64 { mode == .allocated ? alloc : logical }
}

public enum SizeMode: Sendable {
    /// how much it takes on disk: what deleting frees
    case allocated
    /// how long the content is
    case logical
}

/// A folder read from disk. Entries stay sorted by size (largest first).
public final class Folder: @unchecked Sendable {
    public internal(set) unowned(unsafe) var parent: Folder?
    /// the position of the entry representing it in `parent.entries`
    public internal(set) var index: Int32
    public internal(set) var entries: [Entry] = []
    public internal(set) var subfolders: [Folder] = []
    /// the entries' names, UTF-8, one after the other
    var names: [UInt8] = []
    public internal(set) var alloc: UInt64 = 0
    public internal(set) var logical: UInt64 = 0
    /// the files contained, at any depth
    public internal(set) var fileCount: Int = 0
    public internal(set) var unreadable = false
    /// another volume mounted here: we do not go through it
    public internal(set) var mountPoint = false
    /// its own reading plus that of the subfolders not finished yet
    let pending = Atomic<Int>(1)
    /// after a reread (Refresh): files with several names, to hand to the tree
    var hardlinks: [FileKey: Folder]?

    /// whether it is this folder or inside `other`
    func isInside(_ other: Folder) -> Bool {
        var f: Folder? = self
        while let c = f {
            if c === other { return true }
            f = c.parent
        }
        return false
    }

    init(parent: Folder?, index: Int32) {
        self.parent = parent
        self.index = index
    }

    public func size(_ mode: SizeMode) -> UInt64 { mode == .allocated ? alloc : logical }

    public func name(at i: Int) -> String {
        let e = entries[i]
        return names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[Int(e.nameStart) ..< Int(e.nameStart) + Int(e.nameLen)]), as: UTF8.self)
        }
    }

    public func subfolder(at i: Int) -> Folder? {
        let s = entries[i].sub
        return s >= 0 ? subfolders[Int(s)] : nil
    }

    /// the depth below the root (the root is 0)
    public var depth: Int {
        var d = 0
        var f = parent
        while let p = f { d += 1; f = p.parent }
        return d
    }

    func append(name: UnsafeRawBufferPointer, entry: Entry) {
        var e = entry
        e.nameStart = UInt32(names.count)
        e.nameLen = UInt16(min(name.count, Int(UInt16.max)))
        names.append(contentsOf: name.prefix(Int(e.nameLen)))
        entries.append(e)
    }

    /// Adds up the (finished) subfolders and sorts the entries by size.
    func finish(_ mode: SizeMode) {
        var a: UInt64 = 0, l: UInt64 = 0, n = 0
        for i in entries.indices {
            if entries[i].sub >= 0 {
                let f = subfolders[Int(entries[i].sub)]
                entries[i].alloc = f.alloc
                entries[i].logical = f.logical
                if f.unreadable { entries[i].flags.insert(.unreadable) }
                if f.mountPoint { entries[i].flags.insert(.mountPoint) }
                n += f.fileCount
            } else if !entries[i].isDirectory && !entries[i].flags.contains(.special) {
                n += 1
            }
            a &+= entries[i].alloc
            l &+= entries[i].logical
        }
        alloc = a
        logical = l
        fileCount = n
        sortEntries(mode)
    }

    func sortEntries(_ mode: SizeMode) {
        if mode == .allocated {
            entries.sort { $0.alloc > $1.alloc }
        } else {
            entries.sort { $0.logical > $1.logical }
        }
        for i in entries.indices where entries[i].sub >= 0 {
            subfolders[Int(entries[i].sub)].index = Int32(i)
        }
    }
}

/// The tree of a scan: the starting folder and the extensions met.
public final class Tree: @unchecked Sendable {
    public let root: Folder
    /// files with several names already counted, and where: rereading a part needs to know
    var hardlinks: [FileKey: Folder] = [:]
    /// the path of the starting folder
    public let rootPath: String
    public let extensions: ExtensionRegistry
    public internal(set) var sizeMode: SizeMode = .allocated

    init(root: Folder, rootPath: String, extensions: ExtensionRegistry) {
        self.root = root
        self.rootPath = rootPath
        self.extensions = extensions
    }

    public var rootName: String {
        rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
    }

    public func path(of folder: Folder) -> String {
        var parts: [String] = []
        var f = folder
        while let p = f.parent {
            parts.append(p.name(at: Int(f.index)))
            f = p
        }
        var path = rootPath
        for part in parts.reversed() {
            if !path.hasSuffix("/") { path += "/" }
            path += part
        }
        return path
    }

    public func path(of folder: Folder, entry i: Int) -> String {
        let base = path(of: folder)
        return (base.hasSuffix("/") ? base : base + "/") + folder.name(at: i)
    }

    /// Switches between size on disk and logical size: re-sorts everything (in parallel).
    public func setSizeMode(_ mode: SizeMode) {
        guard mode != sizeMode else { return }
        sizeMode = mode
        var all: [Folder] = []
        var stack = [root]
        while let f = stack.popLast() {
            all.append(f)
            stack.append(contentsOf: f.subfolders)
        }
        all.withUnsafeBufferPointer { fs in
            DispatchQueue.concurrentPerform(iterations: fs.count) { fs[$0].sortEntries(mode) }
        }
    }

    /// The entries that are not files, in the starting folder when it is a whole volume.
    public enum Space: UInt32, CaseIterable, Sendable {
        /// the volume's free space
        case free = 1
        /// the other volumes of the same APFS container: virtual memory, Preboot, Recovery…
        case system = 2
        /// used but not counted, while there are folders that could not be read
        case unread = 3
        /// used but not counted, once everything was read: the file system's own data
        case filesystem = 4

        public var name: String {
            switch self {
            case .free: L("Free Space")
            case .system: L("System Volumes")
            case .unread: L("Folders Not Read")
            case .filesystem: L("File System Data")
            }
        }
    }

    /// Puts the space entries into the starting folder (removing the previous ones).
    public func setSpecialSpace(_ spaces: [(Space, UInt64)]) {
        let r = root
        for i in r.entries.indices.reversed() where r.entries[i].flags.contains(.special) {
            let e = r.entries.remove(at: i)
            r.alloc &-= e.alloc
            r.logical &-= e.logical
        }
        for (space, size) in spaces where size > 0 {
            let entry = Entry(alloc: size, logical: size, nameStart: 0, ext: space.rawValue, sub: -1, nameLen: 0, flags: .special)
            Array(space.name.utf8).withUnsafeBytes { r.append(name: $0, entry: entry) }
            r.alloc &+= size
            r.logical &+= size
        }
        r.sortEntries(sizeMode)
    }

    /// Removes an entry (moved to the Trash) and updates the sums up to the root.
    public func remove(folder: Folder, entry i: Int) {
        let e = folder.entries[i]
        let files = e.sub >= 0 ? folder.subfolders[Int(e.sub)].fileCount : 1
        folder.entries.remove(at: i)
        folder.sortEntries(sizeMode)
        var f: Folder? = folder
        while let c = f {
            c.alloc &-= e.alloc
            c.logical &-= e.logical
            c.fileCount -= files
            if let p = c.parent {
                let j = Int(c.index)
                p.entries[j].alloc = c.alloc
                p.entries[j].logical = c.logical
                p.sortEntries(sizeMode)
            }
            f = c.parent
        }
    }

    /// Replaces a subfolder with the same folder read again.
    public func replace(folder old: Folder, with new: Folder) {
        guard let parent = old.parent else { return }
        let i = Int(old.index)
        let e = parent.entries[i]
        new.parent = parent
        new.index = old.index
        if let h = new.hardlinks {
            hardlinks = h
            new.hardlinks = nil
        }
        parent.subfolders[Int(e.sub)] = new
        let dA = new.alloc &- e.alloc, dL = new.logical &- e.logical
        let dN = new.fileCount - old.fileCount
        var f: Folder? = parent
        var child = new
        while let c = f {
            let j = Int(child.index)
            c.entries[j].alloc = child.alloc
            c.entries[j].logical = child.logical
            c.entries[j].flags.remove(.unreadable)
            if child.unreadable { c.entries[j].flags.insert(.unreadable) }
            c.alloc &+= dA
            c.logical &+= dL
            c.fileCount += dN
            c.sortEntries(sizeMode)
            child = c
            f = c.parent
        }
    }
}

/// a file on disk: volume and number (or, for clones, the number of the shared content)
struct FileKey: Hashable { let dev: Int32; let id: UInt64; let clone: Bool }

/// The extensions met (lowercased), shared by the scan's threads.
public final class ExtensionRegistry: @unchecked Sendable {
    private let state = Mutex<(ids: [String: UInt32], names: [String])>(([:], [""]))

    public init() {}

    public func id(for ext: String) -> UInt32 {
        state.withLock { s in
            if let id = s.ids[ext] { return id }
            let id = UInt32(s.names.count)
            s.ids[ext] = id
            s.names.append(ext)
            return id
        }
    }

    public var names: [String] { state.withLock { $0.names } }
}
