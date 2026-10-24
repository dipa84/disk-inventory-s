import Foundation
import Synchronization

/// Una voce di una cartella: un file, una sottocartella, un collegamento.
/// Compatta (32 byte) perché un disco intero ne ha milioni.
public struct Entry {
    /// byte occupati sul disco (blocchi allocati, tutte le fork)
    public var alloc: UInt64
    /// byte del contenuto (dimensione logica, tutte le fork)
    public var logical: UInt64
    /// dove comincia il nome in `Folder.names`
    var nameStart: UInt32
    /// estensione nel registro dell'albero (0 = nessuna)
    public var ext: UInt32
    /// la sottocartella in `Folder.subfolders`, -1 se non è una cartella
    public var sub: Int32
    var nameLen: UInt16
    public var flags: Flags

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let directory = Flags(rawValue: 1)
        /// un altro volume montato qui: non lo attraversiamo
        public static let mountPoint = Flags(rawValue: 2)
        public static let symlink = Flags(rawValue: 4)
        public static let executable = Flags(rawValue: 8)
        /// un collegamento fisso già contato altrove: occupa 0
        public static let hardlinkSeen = Flags(rawValue: 16)
        /// la cartella non si è lasciata leggere (permessi, Accesso completo al disco)
        public static let unreadable = Flags(rawValue: 32)
        /// un clone (APFS) di un file già contato: occupa solo i blocchi che ha di suo
        public static let cloneSeen = Flags(rawValue: 64)
        /// non un file: lo spazio libero o l'altro spazio del volume (`ext` dice quale)
        public static let special = Flags(rawValue: 128)
    }

    public var isDirectory: Bool { flags.contains(.directory) }

    public func size(_ mode: SizeMode) -> UInt64 { mode == .allocated ? alloc : logical }
}

public enum SizeMode: Sendable {
    /// quanto occupa sul disco: quello che si libera cancellando
    case allocated
    /// quanto è lungo il contenuto
    case logical
}

/// Una cartella letta dal disco. Le voci restano in ordine di grandezza (la più grande prima).
public final class Folder: @unchecked Sendable {
    public internal(set) unowned(unsafe) var parent: Folder?
    /// la posizione della voce che la rappresenta in `parent.entries`
    public internal(set) var index: Int32
    public internal(set) var entries: [Entry] = []
    public internal(set) var subfolders: [Folder] = []
    /// i nomi delle voci, UTF-8, uno dopo l'altro
    var names: [UInt8] = []
    public internal(set) var alloc: UInt64 = 0
    public internal(set) var logical: UInt64 = 0
    /// i file contenuti, a ogni profondità
    public internal(set) var fileCount: Int = 0
    public internal(set) var unreadable = false
    /// un altro volume montato qui: non lo attraversiamo
    public internal(set) var mountPoint = false
    /// la lettura propria più quella delle sottocartelle non ancora finite
    let pending = Atomic<Int>(1)
    /// dopo una nuova lettura (Aggiorna): i file con più nomi, da passare all'albero
    var hardlinks: [FileKey: Folder]?

    /// se è questa cartella o sta dentro `other`
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

    /// la profondità sotto la radice (la radice è 0)
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

    /// Somma le sottocartelle (già finite) e mette le voci in ordine di grandezza.
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
            } else {
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

/// L'albero di una scansione: la cartella di partenza e le estensioni incontrate.
public final class Tree: @unchecked Sendable {
    public let root: Folder
    /// i file con più nomi già contati e dove: chi rilegge una parte deve saperlo
    var hardlinks: [FileKey: Folder] = [:]
    /// il percorso della cartella di partenza
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

    /// Cambia fra dimensione su disco e dimensione logica: riordina tutto (in parallelo).
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

    public static let freeSpace: UInt32 = 1
    public static let otherSpace: UInt32 = 2

    /// Aggiunge (o toglie, con nil) alla cartella di partenza lo spazio libero del volume e
    /// l'altro spazio: quello occupato ma non contato (cartelle protette, istantanee, sistema).
    public func setSpecialSpace(free: UInt64?, other: UInt64?) {
        let r = root
        for i in r.entries.indices.reversed() where r.entries[i].flags.contains(.special) {
            let e = r.entries.remove(at: i)
            r.alloc &-= e.alloc
            r.logical &-= e.logical
        }
        for (size, kind, name) in [(free, Self.freeSpace, "Spazio libero"), (other, Self.otherSpace, "Altro spazio")] {
            guard let size, size > 0 else { continue }
            let entry = Entry(alloc: size, logical: size, nameStart: 0, ext: kind, sub: -1, nameLen: 0, flags: .special)
            Array(name.utf8).withUnsafeBytes { r.append(name: $0, entry: entry) }
            r.alloc &+= size
            r.logical &+= size
        }
        r.sortEntries(sizeMode)
    }

    /// Toglie una voce (portata nel Cestino) e aggiorna le somme fino alla radice.
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

    /// Mette al posto di una sottocartella la stessa cartella letta di nuovo.
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

/// un file sul disco: volume e numero (o, per i cloni, il numero del contenuto condiviso)
struct FileKey: Hashable { let dev: Int32; let id: UInt64; let clone: Bool }

/// Le estensioni incontrate (in minuscolo), condivise fra i fili della scansione.
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
