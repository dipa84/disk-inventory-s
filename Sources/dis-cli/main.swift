import CoreGraphics
import Foundation
import ImageIO
import DiskInventoryCore

// usage: dis-cli scan <folder> [--threads N]        the new scan, with timings
//        dis-cli original <folder>                  the way Disk Inventory X scans (one thread, NSURL)
//        dis-cli largest <folder>                   the largest entries, three levels deep
//        dis-cli unreadable <folder>                the folders that cannot be read
//        dis-cli map <folder> <file.png> [WxH]      the treemap as an image, with timings
//        dis-cli icon <folder.iconset>              the app icon: a small cushion treemap
//        dis-cli export <list> <output>             reads the folders in the list (one per line)
//                                                   and writes them for the app: the helper the
//                                                   app runs with the administrator password

func seconds(_ start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.3f s", s)
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
    guard args.count >= 4, let list = try? String(contentsOfFile: args[2], encoding: .utf8) else { exit(2) }
    var folders: [(path: String, folder: Folder)] = []
    for p in list.split(separator: "\n").map(String.init) where !p.isEmpty {
        if let tree = DiskScanner().scan(p) { folders.append((p, tree.root)) }
    }
    let out = URL(fileURLWithPath: args[3])
    do {
        try FolderExport.write(folders).write(to: out)
        // whoever asked must be able to read it (here we are the administrator)
        chmod(args[3], 0o644)
    } catch {
        print("cannot write \(args[3]): \(error)")
        exit(1)
    }
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
    // a fake folder of empty but “long” (sparse) files: the map measures it by logical size
    let fm = FileManager.default
    let fake = fm.temporaryDirectory.appendingPathComponent("dis-icon-\(getpid())").path
    try? fm.removeItem(atPath: fake)
    let files: [(String, Int)] = [
        ("a/1.k0", 300), ("a/2.k1", 140), ("a/3.k0", 90), ("a/4.k2", 60), ("a/5.k3", 40),
        ("b/1.k1", 200), ("b/2.k1", 80), ("b/3.k4", 50), ("b/4.k0", 30),
        ("c/1.k2", 150), ("c/2.k5", 60), ("c/3.k3", 40),
        ("d/1.k4", 90), ("d/2.k0", 40), ("e.k1", 70),
    ]
    for (name, mb) in files {
        let p = fake + "/" + name
        try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: nil)
        truncate(p, off_t(mb) << 20)
    }
    let tree = DiskScanner(mode: .logical).scan(fake)!
    try? fm.removeItem(atPath: fake)
    // each extension k<n> gets palette color n
    let names = tree.extensions.names
    func color(_ c: Cell) -> SIMD3<Double> {
        guard c.entry >= 0 else { return Palette.other }
        let ext = names[Int(c.folder.entries[Int(c.entry)].ext)]
        return Palette.base[Int(ext.dropFirst()) ?? 0]
    }
    let dir = args[2]
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (px, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                         (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        // the macOS icon shape: a rounded square of 824 in 1024, with a shadow
        let inset = Double(px) * 100 / 1024, side = Double(px) - 2 * inset
        let n = Int(side.rounded())
        let map = Treemap(folder: tree.root, entry: -1, width: n, height: n, mode: .logical, minSide: 1) { f, i in
            !f.entries[i].isDirectory
        }
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: n * n)
        map.render(into: pixels, color: color)
        let mapCtx = CGContext(data: pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = mapCtx.makeImage()!
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: inset, y: inset + Double(px) * 0.01, width: side, height: side)
        let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -Double(px) * 0.01), blur: Double(px) * 0.02,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        // a thin light line on the edge
        ctx.addPath(shape)
        ctx.setStrokeColor(gray: 1, alpha: 0.25)
        ctx.setLineWidth(max(1, Double(px) / 256))
        ctx.strokePath()
        let url = URL(fileURLWithPath: dir + "/icon_\(suffix).png")
        let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(out)
        pixels.deallocate()
    }
default:
    print("unknown command: \(args[1])")
    exit(2)
}
