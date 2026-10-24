import Foundation
import InventarioCore

// Le prove: `swift run inventario-prove`. Ognuna costruisce una cartella finta in una cartella
// temporanea e controlla quello che legge la scansione.

var failures = 0
var count = 0

func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    count += 1
    if !ok {
        failures += 1
        print("✗ \(what)  (riga \(line))")
    }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("inventario-prove-\(getpid())").path
try? fm.removeItem(atPath: base)
try! fm.createDirectory(atPath: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: base) }

func write(_ rel: String, _ bytes: Int) {
    let p = base + "/" + rel
    try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
}

// la cartella finta
write("grande.bin", 300_000)
write("a/uno.txt", 1000)
write("a/due.jpg", 50_000)
write("a/b/tre.JPG", 20_000)
write("a/b/c/quattro.pdf", 9_000)
write("Foto.app/Contents/MacOS/Foto", 70_000)
write("piccolo", 10)
try! fm.createDirectory(atPath: base + "/vuota", withIntermediateDirectories: true)
try! fm.linkItem(atPath: base + "/grande.bin", toPath: base + "/a/stesso.bin")
try! fm.createSymbolicLink(atPath: base + "/collegamento", withDestinationPath: "grande.bin")
// un clone APFS (come cp -c): stessi blocchi di quattro.pdf, non deve contare due volte
write("clonato/originale.dat", 2_000_000)
precondition(copyfile(base + "/clonato/originale.dat", base + "/clonato/clone.dat", nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0,
             "la cartella temporanea non è su APFS")
let logicalTotal: UInt64 = 300_000 + 1000 + 50_000 + 20_000 + 9_000 + 70_000 + 10 + UInt64("grande.bin".utf8.count) + 4_000_000

// MARK: scansione

for threads in [1, 3, 16] {
    let scanner = DiskScanner(threads: threads)
    guard let tree = scanner.scan(base) else {
        check(false, "la scansione legge la cartella")
        continue
    }
    let r = tree.root
    check(r.logical == logicalTotal, "\(threads) fili: somma logica \(r.logical) == \(logicalTotal)")
    check(r.fileCount == 11, "\(threads) fili: 11 file (compresi collegamento e collegamento fisso), non \(r.fileCount)")
    check(r.alloc >= r.logical - 2_020_000 && r.alloc < r.logical - 1_900_000,
          "\(threads) fili: lo spazio su disco conta il clone una volta sola (\(r.alloc) per \(r.logical) logici)")
    let cloned = r.subfolders.first { tree.path(of: $0).hasSuffix("/clonato") }!
    check(cloned.entries.filter { $0.flags.contains(.cloneSeen) }.count == 1, "\(threads) fili: uno dei due è il clone")
    // in ordine di grandezza
    let sizes = r.entries.map(\.alloc)
    check(sizes == sizes.sorted(by: >), "\(threads) fili: voci in ordine di grandezza")
    check(r.name(at: 0) == "clonato", "\(threads) fili: la voce più grande è clonato, non \(r.name(at: 0))")
    // il collegamento fisso conta una volta sola
    let a = r.subfolders.first { tree.path(of: $0).hasSuffix("/a") }!
    let stesso = a.entries.indices.first { a.name(at: $0) == "stesso.bin" }!
    check(a.entries[stesso].flags.contains(.hardlinkSeen) != r.entries[0].flags.contains(.hardlinkSeen),
          "\(threads) fili: uno solo dei due nomi di grande.bin è segnato come già contato")
    // i percorsi
    let c = a.subfolders.first!.subfolders.first!
    check(tree.path(of: c) == base + "/a/b/c", "percorso di c: \(tree.path(of: c))")
    check(tree.path(of: c, entry: 0) == base + "/a/b/c/quattro.pdf", "percorso di quattro.pdf")
    check(c.depth == 3, "profondità di c")
    // il collegamento simbolico non si segue
    let link = r.entries.indices.first { r.name(at: $0) == "collegamento" }!
    check(r.entries[link].flags.contains(.symlink) && r.entries[link].sub < 0, "il collegamento è una foglia")

    // MARK: tipi
    let kinds = Kinds(extensions: tree.extensions.names)
    kinds.tally(r, mode: .allocated, openPackages: false)
    let app = r.entries.indices.first { r.name(at: $0) == "Foto.app" }!
    check(kinds.isPackage(r.entries[app]), "Foto.app è un pacchetto")
    let jpeg = kinds.kind(of: a.entries[a.entries.indices.first { a.name(at: $0) == "due.jpg" }!])
    let jpegUpper = kinds.kind(of: a.subfolders.first!.entries[0])
    check(jpeg == jpegUpper, "due.jpg e tre.JPG sono dello stesso tipo")
    check(kinds.kinds[jpeg].count == 2, "due immagini JPEG, non \(kinds.kinds[jpeg].count)")
    let pkg = kinds.kind(of: r.entries[app])
    check(kinds.kinds[pkg].count == 1, "il pacchetto chiuso conta come un oggetto")
    kinds.tally(r, mode: .allocated, openPackages: true)
    check(kinds.kinds[pkg].count == 0, "il pacchetto aperto non conta come oggetto")
    let total = kinds.kinds.reduce(UInt64(0)) { $0 + $1.logical }
    check(total == logicalTotal, "i tipi sommano tutto: \(total)")
}

// MARK: mappa

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
        check(tiled, "\(w)x\(h): i figli coprono il padre esattamente")
        // un riquadro grande quanto la sua parte, a meno degli arrotondamenti
        let top = map.cells[Int(map.cells[0].firstChild)]
        let expected = Double(w * h) * Double(tree.root.entries[0].logical) / Double(tree.root.logical)
        check(abs(Double(top.width * top.height) - expected) / expected < 0.05 || w < 50,
              "\(w)x\(h): l'area di grande.bin è proporzionale")
        // la ricerca per punto e per voce si ritrovano
        let path = map.path(at: w / 2, h / 2)
        let leaf = map.cells[path.last!]
        check(map.cell(folder: leaf.folder, entry: Int(leaf.entry)) == path.last!, "\(w)x\(h): cella ritrovata")
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        pixels.initialize(repeating: 0, count: w * h)
        map.render(into: pixels) { _ in Palette.base[0] }
        var black = 0
        for i in 0 ..< w * h where pixels[i] == 0 { black += 1 }
        check(black == 0, "\(w)x\(h): ogni pixel è disegnato (\(black) vuoti)")
        pixels.deallocate()
    }
}

// MARK: Cestino e Aggiorna

do {
    let tree = DiskScanner().scan(base)!
    let r = tree.root
    let before = r.logical
    let a = r.subfolders.first { tree.path(of: $0).hasSuffix("/a") }!
    let i = a.entries.indices.first { a.name(at: $0) == "due.jpg" }!
    tree.remove(folder: a, entry: i)
    check(r.logical == before - 50_000, "togliere due.jpg toglie 50 000 byte dalla radice")
    check(r.fileCount == 10, "e un file")
    check(r.entries[Int(a.index)].logical == a.logical, "la voce di a ha la somma nuova")

    // un file nuovo in a/b, poi Aggiorna di a
    write("a/b/cinque.bin", 400_000)
    let fresh = DiskScanner(registry: tree.extensions).rescan(a, in: tree)!
    tree.replace(folder: a, with: fresh)
    check(r.logical == before + 400_000, "dopo Aggiorna la radice ha anche cinque.bin (e di nuovo due.jpg)")
    check(r.name(at: 1) == "a", "ora a viene subito dopo clonato")
    check(tree.path(of: fresh) == base + "/a", "la cartella nuova sta al posto della vecchia")
    tree.setSizeMode(.logical)
    check(r.entries.map(\.logical) == r.entries.map(\.logical).sorted(by: >), "riordinato per dimensione logica")
}

print(failures == 0 ? "✓ \(count) prove" : "\(failures) prove su \(count) non passano")
exit(failures == 0 ? 0 : 1)
