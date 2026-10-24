import CoreGraphics
import Foundation
import ImageIO
import InventarioCore

// uso: inventario-cli scan <cartella> [--fili N]   la scansione nuova, con i tempi
//      inventario-cli originale <cartella>          come la fa Disk Inventory X (un filo, NSURL)
//      inventario-cli mappa <cartella> <file.png> [LxA]   la mappa in un'immagine, con i tempi

func seconds(_ start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.3f s", s)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("uso: inventario-cli scan|originale <cartella> [--fili N]")
    exit(2)
}
let path = args[2]
var threads = 0
if let i = args.firstIndex(of: "--fili"), i + 1 < args.count { threads = Int(args[i + 1]) ?? 0 }

switch args[1] {
case "scan":
    let start = ContinuousClock.now
    let scanner = DiskScanner(threads: threads)
    guard let tree = scanner.scan(path) else {
        print("non riesco a leggere \(path)")
        exit(1)
    }
    print("\(seconds(start))  \(tree.root.fileCount) file  \(scanner.folders.load(ordering: .relaxed)) cartelle  "
        + "\(gb(tree.root.alloc)) su disco  \(gb(tree.root.logical)) logici  "
        + "\(scanner.unreadable.load(ordering: .relaxed)) cartelle non leggibili  \(tree.extensions.names.count) estensioni")
case "originale":
    // le stesse chiavi che chiede FSItem.m, con NSDirectoryEnumerator, un filo solo
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
    print("\(seconds(start))  \(files) file  \(gb(total)) su disco")
case "mappa":
    guard args.count >= 4 else { exit(2) }
    let size = (args.count >= 5 ? args[4] : "2400x1500").split(separator: "x").compactMap { Int($0) }
    let (w, h) = (size[0], size[1])
    var start = ContinuousClock.now
    guard let tree = DiskScanner(threads: threads).scan(path) else { exit(1) }
    print("scansione  \(seconds(start))")
    start = ContinuousClock.now
    let kinds = Kinds(extensions: tree.extensions.names)
    kinds.tally(tree.root, mode: .allocated, openPackages: false)
    print("tipi       \(seconds(start))  \(kinds.ranked(.allocated).count) tipi")
    for k in kinds.ranked(.allocated).prefix(12) {
        print("    \(kinds.kinds[k].name): \(gb(kinds.kinds[k].alloc)), \(kinds.kinds[k].count)")
    }
    start = ContinuousClock.now
    let map = Treemap(folder: tree.root, entry: -1, width: w, height: h, mode: .allocated, minSide: 2) { f, i in
        let e = f.entries[i]
        return !e.isDirectory || kinds.isPackage(e)
    }
    print("disposizione \(seconds(start))  \(map.cells.count) riquadri")
    let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
    pixels.initialize(repeating: 0, count: w * h)
    start = ContinuousClock.now
    map.render(into: pixels) { c in
        c.entry < 0 ? Palette.other : kinds.kinds[kinds.kind(of: c.folder.entries[Int(c.entry)])].color
    }
    print("disegno    \(seconds(start))")
    let ctx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(out)
default:
    print("comando sconosciuto: \(args[1])")
    exit(2)
}
