// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import DiskInventoryCore
import Foundation

// The tests: `swift run -c release dis-tests`. They build a fake folder in a temporary
// directory and check what the scan reads.

var failures = 0
var count = 0

func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    count += 1
    if !ok {
        failures += 1
        print("✗ \(what)  (line \(line))")
    }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("dis-tests-\(getpid())").path
try? fm.removeItem(atPath: base)
try! fm.createDirectory(atPath: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: base) }

func write(_ rel: String, _ bytes: Int) {
    let p = base + "/" + rel
    try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
}

// the fake folder
write("big.bin", 300_000)
write("a/one.txt", 1000)
write("a/two.jpg", 50_000)
write("a/b/three.JPG", 20_000)
write("a/b/c/four.pdf", 9_000)
write("Photos.app/Contents/MacOS/Photos", 70_000)
write("small", 10)
try! fm.createDirectory(atPath: base + "/empty", withIntermediateDirectories: true)
try! fm.linkItem(atPath: base + "/big.bin", toPath: base + "/a/same.bin")
try! fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: "big.bin")
// an APFS clone (like cp -c): the same blocks as original.dat, it must not count twice
write("cloned/original.dat", 2_000_000)
precondition(copyfile(base + "/cloned/original.dat", base + "/cloned/clone.dat", nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0,
             "the temporary directory is not on APFS")
let logicalTotal: UInt64 = 300_000 + 1000 + 50_000 + 20_000 + 9_000 + 70_000 + 10 + UInt64("big.bin".utf8.count) + 4_000_000

// MARK: scan

for threads in [1, 3, 16] {
    let scanner = DiskScanner(threads: threads)
    guard let tree = scanner.scan(base) else {
        check(false, "the scan reads the folder")
        continue
    }
    let r = tree.root
    check(r.logical == logicalTotal, "\(threads) threads: logical sum \(r.logical) == \(logicalTotal)")
    check(r.fileCount == 11, "\(threads) threads: 11 files (including the link and the hard link), not \(r.fileCount)")
    check(r.alloc >= r.logical - 2_020_000 && r.alloc < r.logical - 1_900_000,
          "\(threads) threads: space on disk counts the clone once (\(r.alloc) for \(r.logical) logical)")
    let cloned = r.subfolders.first { tree.path(of: $0).hasSuffix("/cloned") }!
    check(cloned.entries.filter { $0.flags.contains(.cloneSeen) }.count == 1, "\(threads) threads: one of the two is the clone")
    // sorted by size
    let sizes = r.entries.map(\.alloc)
    check(sizes == sizes.sorted(by: >), "\(threads) threads: entries sorted by size")
    check(r.name(at: 0) == "cloned", "\(threads) threads: the largest entry is cloned, not \(r.name(at: 0))")
    // the hard link counts once
    let a = r.subfolders.first { tree.path(of: $0).hasSuffix("/a") }!
    let same = a.entries.indices.first { a.name(at: $0) == "same.bin" }!
    let big = r.entries.indices.first { r.name(at: $0) == "big.bin" }!
    check(a.entries[same].flags.contains(.hardlinkSeen) != r.entries[big].flags.contains(.hardlinkSeen),
          "\(threads) threads: only one of big.bin's two names is marked as already counted")
    // paths
    let c = a.subfolders.first!.subfolders.first!
    check(tree.path(of: c) == base + "/a/b/c", "path of c: \(tree.path(of: c))")
    check(tree.path(of: c, entry: 0) == base + "/a/b/c/four.pdf", "path of four.pdf")
    check(c.depth == 3, "depth of c")
    // the symbolic link is not followed
    let link = r.entries.indices.first { r.name(at: $0) == "link" }!
    check(r.entries[link].flags.contains(.symlink) && r.entries[link].sub < 0, "the link is a leaf")

    // MARK: kinds
    let kinds = Kinds(extensions: tree.extensions.names)
    kinds.tally(r, mode: .allocated, openPackages: false)
    let app = r.entries.indices.first { r.name(at: $0) == "Photos.app" }!
    check(kinds.isPackage(r.entries[app]), "Photos.app is a package")
    let jpeg = kinds.kind(of: a.entries[a.entries.indices.first { a.name(at: $0) == "two.jpg" }!])
    let jpegUpper = kinds.kind(of: a.subfolders.first!.entries[0])
    check(jpeg == jpegUpper, "two.jpg and three.JPG are the same kind")
    check(kinds.kinds[jpeg].count == 2, "two JPEG images, not \(kinds.kinds[jpeg].count)")
    let pkg = kinds.kind(of: r.entries[app])
    check(kinds.kinds[pkg].count == 1, "a closed package counts as one item")
    kinds.tally(r, mode: .allocated, openPackages: true)
    check(kinds.kinds[pkg].count == 0, "an open package does not count as an item")
    let total = kinds.kinds.reduce(UInt64(0)) { $0 + $1.logical }
    check(total == logicalTotal, "the kinds add up to everything: \(total)")
}

// MARK: options

do {
    let skip = DiskScanner(options: ScanOptions(skipNames: ["b"])).scan(base)!
    let a = skip.root.subfolders.first { skip.path(of: $0).hasSuffix("/a") }!
    let b = a.entries.first { $0.isDirectory }!
    check(b.flags.contains(.skipped) && b.sub < 0 && b.alloc == 0, "folder b is skipped")
    check(skip.root.fileCount == 9, "without b, three.JPG and four.pdf are missing: \(skip.root.fileCount)")
    let all = DiskScanner(options: ScanOptions(countSharedOnce: false)).scan(base)!
    let once = DiskScanner().scan(base)!
    check(all.root.logical == once.root.logical + 300_000, "the hard link counts again in logical size too")
    check(all.root.alloc > once.root.alloc + 2_000_000, "counting everything, the clone and the hard link count again")
}

// MARK: the helper's file format

do {
    let tree = DiskScanner().scan(base)!
    let a = tree.root.subfolders.first { tree.path(of: $0).hasSuffix("/a") }!
    let data = FolderExport.write([(base + "/a", a), (base, tree.root)])
    let back = FolderExport.read(data, registry: tree.extensions, mode: .allocated)
    check(back?.count == 2, "two folders come back")
    if let a2 = back?[base + "/a"], let r2 = back?[base] {
        check(a2.alloc == a.alloc && a2.logical == a.logical && a2.fileCount == a.fileCount, "a comes back with the same sums")
        check((0 ..< a.entries.count).map(a.name(at:)) == (0 ..< a2.entries.count).map(a2.name(at:)), "a comes back with the same names")
        check(r2.logical == tree.root.logical && r2.fileCount == tree.root.fileCount, "the root comes back with the same sums")
        check(a2.entries.contains { $0.ext != 0 }, "extensions are worked out again")
    }
    check(FolderExport.read(data.prefix(data.count - 3), registry: tree.extensions, mode: .allocated) == nil, "a truncated file is rejected")
}

// MARK: treemap

do {
    let tree = DiskScanner().scan(base)!
    for (w, h) in [(800, 500), (300, 900), (37, 23)] {
        let map = Treemap(folder: tree.root, entry: -1, width: w, height: h, mode: .logical, minSide: 1) { f, i in
            !f.entries[i].isDirectory
        }
        var tiled = true
        for c in map.cells where c.childCount > 0 {
            let kids = map.cells[Int(c.firstChild) ..< Int(c.firstChild + c.childCount)]
            let area = kids.reduce(0) { $0 + $1.width * $1.height }
            if area != c.width * c.height { tiled = false }
            for k in kids where k.x0 < c.x0 || k.x1 > c.x1 || k.y0 < c.y0 || k.y1 > c.y1 { tiled = false }
        }
        check(tiled, "\(w)x\(h): the children cover the parent exactly")
        // a tile as big as its share, up to rounding
        let top = map.cells[Int(map.cells[0].firstChild)]
        let expected = Double(w * h) * Double(tree.root.entries[0].logical) / Double(tree.root.logical)
        check(abs(Double(top.width * top.height) - expected) / expected < 0.05 || w < 50,
              "\(w)x\(h): the largest tile's area is proportional")
        // lookup by point and by entry agree
        let path = map.path(at: w / 2, h / 2)
        let leaf = map.cells[path.last!]
        check(map.cell(folder: leaf.folder, entry: Int(leaf.entry)) == path.last!, "\(w)x\(h): tile found again")
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        pixels.initialize(repeating: 0, count: w * h)
        map.render(into: pixels) { _ in Palette.base[0] }
        var black = 0
        for i in 0 ..< w * h where pixels[i] == 0 { black += 1 }
        check(black == 0, "\(w)x\(h): every pixel is drawn (\(black) empty)")
        pixels.deallocate()
    }
}

// MARK: Trash and Refresh

do {
    let tree = DiskScanner().scan(base)!
    let r = tree.root
    let before = r.logical
    let a = r.subfolders.first { tree.path(of: $0).hasSuffix("/a") }!
    let i = a.entries.indices.first { a.name(at: $0) == "two.jpg" }!
    tree.remove(folder: a, entry: i)
    check(r.logical == before - 50_000, "removing two.jpg takes 50 000 bytes off the root")
    check(r.fileCount == 10, "and one file")
    check(r.entries[Int(a.index)].logical == a.logical, "a's entry has the new sum")

    // a new file in a/b, then Refresh a
    write("a/b/five.bin", 400_000)
    let fresh = DiskScanner(registry: tree.extensions).rescan(a, in: tree)!
    tree.replace(folder: a, with: fresh)
    check(r.logical == before + 400_000, "after Refresh the root has five.bin too (and two.jpg again)")
    check(r.name(at: 1) == "a", "now a comes right after cloned")
    check(tree.path(of: fresh) == base + "/a", "the new folder takes the old one's place")
    tree.setSizeMode(.logical)
    check(r.entries.map(\.logical) == r.entries.map(\.logical).sorted(by: >), "re-sorted by logical size")
}

print(failures == 0 ? "✓ \(count) tests" : "\(failures) of \(count) tests fail")
exit(failures == 0 ? 0 : 1)
