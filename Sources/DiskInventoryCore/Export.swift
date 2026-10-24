// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Folders read elsewhere (by the helper, with administrator rights) and handed to the app in a
/// file: a simple binary format, folder by folder, depth first.
///
///     file   = n:u32, n × (path, folder)
///     path   = length:u32, UTF-8 bytes
///     folder = state:u8 (1 unreadable, 2 another volume), entries:u32, entries × entry
///     entry  = flags:u16, alloc:u64, logical:u64, name (length:u16, bytes),
///              followed by its folder, if it is a folder that was read
public enum FolderExport {
    public static func write(_ folders: [(path: String, folder: Folder)]) -> Data {
        var out = Data()
        out.append(UInt32(folders.count))
        for (path, folder) in folders {
            let bytes = Array(path.utf8)
            out.append(UInt32(bytes.count))
            out.append(contentsOf: bytes)
            write(folder, &out)
        }
        return out
    }

    private static func write(_ f: Folder, _ out: inout Data) {
        out.append(UInt8((f.unreadable ? 1 : 0) | (f.mountPoint ? 2 : 0)))
        out.append(UInt32(f.entries.count))
        f.names.withUnsafeBufferPointer { names in
            for e in f.entries {
                out.append(e.flags.rawValue)
                out.append(e.alloc)
                out.append(e.logical)
                out.append(e.nameLen)
                out.append(contentsOf: names[Int(e.nameStart) ..< Int(e.nameStart) + Int(e.nameLen)])
                if e.sub >= 0 { write(f.subfolders[Int(e.sub)], &out) }
            }
        }
    }

    /// The folders by path, already summed and sorted; nil if the file is damaged.
    public static func read(_ data: Data, registry: ExtensionRegistry, mode: SizeMode) -> [String: Folder]? {
        var r = Reader(data: data)
        var cache = ExtensionCache()
        var result: [String: Folder] = [:]
        guard let n = r.u32() else { return nil }
        for _ in 0 ..< n {
            guard let len = r.u32(), let path = r.bytes(Int(len)),
                  let folder = read(&r, parent: nil, index: -1, &cache, registry, mode) else { return nil }
            result[String(decoding: path, as: UTF8.self)] = folder
        }
        return result
    }

    private static func read(_ r: inout Reader, parent: Folder?, index: Int32, _ cache: inout ExtensionCache,
                             _ registry: ExtensionRegistry, _ mode: SizeMode) -> Folder? {
        guard let state = r.u8(), let count = r.u32() else { return nil }
        let f = Folder(parent: parent, index: index)
        f.unreadable = state & 1 != 0
        f.mountPoint = state & 2 != 0
        for _ in 0 ..< count {
            guard let flags = r.u16(), let alloc = r.u64(), let logical = r.u64(), let len = r.u16(),
                  let name = r.bytes(Int(len)) else { return nil }
            var e = Entry(alloc: alloc, logical: logical, nameStart: 0, ext: 0, sub: -1, nameLen: 0,
                          flags: Entry.Flags(rawValue: flags))
            name.withUnsafeBytes { e.ext = cache.ext(of: $0, registry) }
            // the folder comes right after its entry, except for those the scan never opens
            // (other volumes, skipped, firmlinks): they are the only ones with `sub` < 0
            if e.isDirectory && e.flags.isDisjoint(with: [.mountPoint, .skipped, .firmlinked]) {
                guard let sub = read(&r, parent: f, index: Int32(f.entries.count), &cache, registry, mode) else { return nil }
                e.sub = Int32(f.subfolders.count)
                f.subfolders.append(sub)
            }
            name.withUnsafeBytes { f.append(name: $0, entry: e) }
        }
        f.finish(mode)
        return f
    }

    private struct Reader {
        let data: Data
        var at = 0

        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, at + n <= data.count else { return nil }
            defer { at += n }
            return Array(data[data.startIndex + at ..< data.startIndex + at + n])
        }

        mutating func value<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard let b = bytes(MemoryLayout<T>.size) else { return nil }
            return b.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        mutating func u8() -> UInt8? { value(UInt8.self) }
        mutating func u16() -> UInt16? { value(UInt16.self) }
        mutating func u32() -> UInt32? { value(UInt32.self) }
        mutating func u64() -> UInt64? { value(UInt64.self) }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
