// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import DiskInventoryCore

// usage: dis-cli scan <folder> [--threads N]        the new scan, with timings
//        dis-cli original <folder>                  the way Disk Inventory X scans (one thread, NSURL)
//        dis-cli largest <folder>                   the largest entries, three levels deep
//        dis-cli unreadable <folder>                the folders that cannot be read
//        dis-cli map <folder> <file.png> [WxH]      the treemap as an image, with timings
//        dis-cli icon <folder.iconset> [style]      the app icon (glass, light or spotlight)
//        dis-cli icon-preview <file.png>            the icon styles side by side
//        dis-cli export <folder>…                   reads the folders and prints them for the app
//                                                   (FolderExport, LZFSE, base64): the helper the
//                                                   app runs with the administrator password

func seconds(_ start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.3f s", s)
}

func writePNG(_ image: CGImage, to path: String) {
    let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, image, nil)
    CGImageDestinationFinalize(out)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: dis-cli scan|original|largest|unreadable|map|icon|export … (see the source)")
    exit(2)
}
let path = args[2]
var threads = 0
if let i = args.firstIndex(of: "--threads"), i + 1 < args.count { threads = Int(args[i + 1]) ?? 0 }

switch args[1] {
case "scan":
    let start = ContinuousClock.now
    let scanner = DiskScanner(threads: threads)
    guard let tree = scanner.scan(path) else {
        print("cannot read \(path)")
        exit(1)
    }
    print("\(seconds(start))  \(tree.root.fileCount) files  \(scanner.folders.load(ordering: .relaxed)) folders  "
        + "\(gb(tree.root.alloc)) on disk  \(gb(tree.root.logical)) logical  "
        + "\(scanner.unreadable.load(ordering: .relaxed)) unreadable folders  \(tree.extensions.names.count) extensions")
case "largest":
    // the largest entries, three levels deep
    guard let tree = DiskScanner(threads: threads).scan(path) else { exit(1) }
    func show(_ f: Folder, _ depth: Int) {
        for i in f.entries.indices.prefix(depth == 0 ? 12 : 5) {
            let e = f.entries[i]
            print(String(repeating: "    ", count: depth) + "\(gb(e.alloc))  \(f.name(at: i))\(e.flags.contains(.mountPoint) ? " [volume]" : "")")
            if depth < 3, let sub = f.subfolder(at: i), e.alloc > 20_000_000_000 { show(sub, depth + 1) }
        }
    }
    show(tree.root, 0)
case "unreadable":
    // the folders that cannot be read
    guard let tree = DiskScanner(threads: threads).scan(path) else { exit(1) }
    var stack = [tree.root]
    while let f = stack.popLast() {
        for (i, e) in f.entries.enumerated() where e.flags.contains(.unreadable) && f.subfolder(at: i)?.unreadable == true {
            print(tree.path(of: f, entry: i))
        }
        stack.append(contentsOf: f.subfolders)
    }
case "export":
    // Running as root, so it writes no files: the result goes to standard output, which the app
    // reads. A file in the user's temporary folder could be swapped for a link by another program
    // and make root overwrite something else.
    var folders: [(path: String, folder: Folder)] = []
    for p in args.dropFirst(2) {
        if let tree = DiskScanner().scan(p) { folders.append((p, tree.root)) }
    }
    guard let packed = try? (FolderExport.write(folders) as NSData).compressed(using: .lzfse) else { exit(1) }
    print((packed as Data).base64EncodedString())
case "original":
    // the same keys FSItem.m asks for, with NSDirectoryEnumerator, one thread
    let start = ContinuousClock.now
    let keys: [URLResourceKey] = [.nameKey, .isVolumeKey, .isPackageKey, .isDirectoryKey, .typeIdentifierKey,
                                  .fileSizeKey, .totalFileAllocatedSizeKey]
    let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                           options: [], errorHandler: { _, _ in true })!
    var files = 0, total: UInt64 = 0
    for case let url as URL in e {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isVolume == true { e.skipDescendants() }
        if v.isDirectory != true {
            files += 1
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
    }
    print("\(seconds(start))  \(files) files  \(gb(total)) on disk")
case "map":
    guard args.count >= 4 else { exit(2) }
    let size = (args.count >= 5 ? args[4] : "2400x1500").split(separator: "x").compactMap { Int($0) }
    let (w, h) = (size[0], size[1])
    var start = ContinuousClock.now
    guard let tree = DiskScanner(threads: threads).scan(path) else { exit(1) }
    print("scan     \(seconds(start))")
    start = ContinuousClock.now
    let kinds = Kinds(extensions: tree.extensions.names)
    kinds.tally(tree.root, mode: .allocated, openPackages: false)
    print("kinds    \(seconds(start))  \(kinds.ranked(.allocated).count) kinds")
    for k in kinds.ranked(.allocated).prefix(12) {
        print("    \(kinds.kinds[k].name): \(gb(kinds.kinds[k].alloc)), \(kinds.kinds[k].count)")
    }
    start = ContinuousClock.now
    let map = Treemap(folder: tree.root, entry: -1, width: w, height: h, mode: .allocated, minSide: 2) { f, i in
        let e = f.entries[i]
        return !e.isDirectory || kinds.isPackage(e)
    }
    print("layout   \(seconds(start))  \(map.cells.count) tiles")
    let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
    pixels.initialize(repeating: 0, count: w * h)
    start = ContinuousClock.now
    map.render(into: pixels) { c in
        c.entry < 0 ? Palette.other : kinds.kinds[kinds.kind(of: c.folder.entries[Int(c.entry)])].color
    }
    print("drawing  \(seconds(start))")
    let ctx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(out)
case "icon":
    // the app icon in every size of an .iconset (iconutil makes the .icns)
    let style = args.count > 3 ? IconStyle(rawValue: args[3]) ?? .glass : .glass
    let dir = args[2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (px, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                         (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        writePNG(drawIcon(size: px, style: style), to: dir + "/icon_\(suffix).png")
    }
case "icon-preview":
    // every style side by side, large and at Dock and Finder sizes, to choose
    let styles = IconStyle.allCases
    let w = 560 * styles.count, h = 700
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // half light, half dark, as icons sit on both
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
    for (i, style) in styles.enumerated() {
        let x = CGFloat(i * 560)
        ctx.draw(drawIcon(size: 512, style: style), in: CGRect(x: x + 24, y: 170, width: 512, height: 512))
        for (j, size) in [128, 64, 32].enumerated() {
            let img = drawIcon(size: size * 2, style: style)
            ctx.draw(img, in: CGRect(x: x + 60 + CGFloat(j) * 170, y: 20, width: CGFloat(size), height: CGFloat(size)))
        }
    }
    writePNG(ctx.makeImage()!, to: args[2])
default:
    print("unknown command: \(args[1])")
    exit(2)
}
