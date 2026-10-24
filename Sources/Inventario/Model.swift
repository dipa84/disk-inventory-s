import AppKit
import InventarioCore

/// Una cosa che si può scegliere: una voce di una cartella, oppure (entry -1) la cartella di
/// partenza, che non ha una voce sopra di sé.
struct Item: Equatable {
    unowned(unsafe) let folder: Folder
    let entry: Int

    static func == (a: Item, b: Item) -> Bool { a.folder === b.folder && a.entry == b.entry }

    /// la voce che rappresenta una cartella
    init(_ folder: Folder) {
        if let p = folder.parent {
            self.folder = p
            entry = Int(folder.index)
        } else {
            self.folder = folder
            entry = -1
        }
    }

    init(folder: Folder, entry: Int) {
        self.folder = folder
        self.entry = entry
    }

    var isRoot: Bool { entry < 0 }
    var entryValue: Entry? { entry >= 0 && entry < folder.entries.count ? folder.entries[entry] : nil }

    /// la cartella che questa voce è, se è una cartella letta
    var contents: Folder? { entry < 0 ? folder : folder.subfolder(at: entry) }

    var parent: Item? {
        if entry < 0 { return nil }
        return Item(folder)
    }

    func size(_ mode: SizeMode) -> UInt64 {
        entry < 0 ? folder.size(mode) : folder.entries[entry].size(mode)
    }

    /// è ancora nell'albero? (dopo Cestino e Aggiorna le posizioni cambiano)
    var isValid: Bool { entry < 0 || entry < folder.entries.count }
}

/// Tutto quello che una finestra sa di una scansione.
final class Document {
    let tree: Tree
    let kinds: Kinds
    var openPackages = Prefs.openPackages
    /// lo spazio del volume, quando la cartella di partenza è un volume intero
    let space: VolumeSpace?
    /// quanto ha contato la scansione: il resto dello spazio usato è nascosto
    private let counted: UInt64
    var isVolume: Bool { space != nil }
    /// la tipologia scelta nell'elenco dei tipi: la mappa la mette in evidenza
    var highlightedKind: Int?

    init(tree: Tree, space: VolumeSpace?) {
        self.tree = tree
        self.space = space
        tree.setSpecialSpace([])
        counted = tree.root.alloc
        kinds = Kinds(extensions: tree.extensions.names)
        updateSpecialSpace()
        tally()
    }

    /// Rifà le voci dello spazio (dopo le preferenze). Restano quelle misurate alla lettura:
    /// il Cestino non libera spazio finché non si svuota.
    func updateSpecialSpace() {
        guard let space, Prefs.showSpace else {
            tree.setSpecialSpace([])
            return
        }
        tree.setSpecialSpace(space.spaces(counted: counted, includePurgeable: Prefs.purgeableIsFree))
    }

    func isSpecial(_ item: Item) -> Bool { item.entryValue?.flags.contains(.special) == true }

    /// che cosa vuol dire una voce particolare (per la barra in basso e i suggerimenti)
    static func note(_ e: Entry) -> String? {
        if e.flags.contains(.special) {
            switch Tree.Space(rawValue: e.ext) {
            case .free?: return L("lo spazio ancora disponibile")
            case .system?: return L("memoria virtuale, Preboot, Recovery, aggiornamenti di macOS")
            default: return L("cartelle protette, istantanee di Time Machine, dati del file system")
            }
        }
        if e.flags.contains(.unreadable) { return L("non leggibile: serve l'Accesso completo al disco") }
        if e.flags.contains(.mountPoint) { return L("un altro volume: non è contato qui") }
        if e.flags.contains(.skipped) { return L("saltata (Impostazioni › Scansione)") }
        if e.flags.contains(.hardlinkSeen) { return L("un altro nome di un file già contato altrove") }
        if e.flags.contains(.cloneSeen) { return L("un clone: conta solo quello che ha di suo") }
        return nil
    }

    var mode: SizeMode { tree.sizeMode }

    func tally() {
        kinds.tally(tree.root, mode: mode, openPackages: openPackages, colored: Prefs.coloredKinds)
    }

    func name(_ item: Item) -> String {
        item.isRoot ? tree.rootName : item.folder.name(at: item.entry)
    }

    func path(_ item: Item) -> String {
        item.isRoot ? tree.rootPath : tree.path(of: item.folder, entry: item.entry)
    }

    func kindName(_ item: Item) -> String {
        guard let e = item.entryValue else { return kinds.kinds[kinds.folderKindIndex].name }
        return kinds.kinds[kinds.kind(of: e)].name
    }

    /// nella mappa: si divide in riquadri o si disegna intera?
    func isLeaf(_ e: Entry) -> Bool {
        !e.isDirectory || (!openPackages && kinds.isPackage(e))
    }

    /// si può entrare (zoom, figli nell'elenco)? I pacchetti solo se li apriamo.
    func isContainer(_ item: Item) -> Bool {
        guard let e = item.entryValue else { return true }
        return e.sub >= 0 && !isLeaf(e)
    }
}

enum Format {
    private static let decimal: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let binary: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    static func size(_ n: UInt64) -> String {
        (Prefs.binaryUnits ? binary : decimal).string(fromByteCount: Int64(clamping: n))
    }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    static func percent(_ part: UInt64, of whole: UInt64) -> String {
        guard whole > 0 else { return "" }
        let p = Double(part) / Double(whole)
        return p.formatted(.percent.precision(.fractionLength(p >= 0.1 ? 0 : 1)))
    }
}
