import Foundation
import UniformTypeIdentifiers

/// I tipi di file di un albero («Immagine JPEG», «Applicazione», …), con quanto occupano e il
/// colore nella mappa. Il tipo si ricava dall'estensione, una volta per estensione: durante la
/// scansione non si chiede nulla al sistema.
public final class Kinds {
    public struct Kind {
        public let name: String
        public let type: UTType?
        public var alloc: UInt64 = 0
        public var logical: UInt64 = 0
        public var count = 0
        public var color = Palette.other

        public func size(_ mode: SizeMode) -> UInt64 { mode == .allocated ? alloc : logical }
    }

    public private(set) var kinds: [Kind] = []
    /// per estensione: il tipo di un file, e quello di una cartella (-1 se non è un pacchetto)
    private var fileKind: [Int32] = []
    private var packageKind: [Int32] = []
    private var byName: [String: Int32] = [:]
    private var folderKind: Int32 = 0, symlinkKind: Int32 = 0, executableKind: Int32 = 0, documentKind: Int32 = 0
    /// i tipi delle voci dello spazio (libero, volumi di sistema, nascosto)
    private var spaceKinds: [Tree.Space: Int32] = [:]

    public init(extensions: [String]) {
        folderKind = add(UTType.folder)
        symlinkKind = add(UTType.symbolicLink)
        executableKind = add(UTType.unixExecutable)
        documentKind = add(UTType.data)
        for space in Tree.Space.allCases { spaceKinds[space] = add(name: space.name, type: nil) }
        fileKind = [Int32](repeating: documentKind, count: extensions.count)
        packageKind = [Int32](repeating: -1, count: extensions.count)
        for (id, ext) in extensions.enumerated() where id > 0 {
            if let t = UTType(filenameExtension: ext), t.localizedDescription != nil, !t.isDynamic {
                fileKind[id] = add(t)
            } else {
                fileKind[id] = add(name: L("File .%@", ext), type: nil)
            }
            if let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package), !t.isDynamic {
                packageKind[id] = add(t)
            }
        }
    }

    private func add(_ type: UTType) -> Int32 {
        add(name: type.localizedDescription ?? type.identifier, type: type)
    }

    private func add(name: String, type: UTType?) -> Int32 {
        if let k = byName[name] { return k }
        let k = Int32(kinds.count)
        kinds.append(Kind(name: name, type: type))
        byName[name] = k
        return k
    }

    public var folderKindIndex: Int { Int(folderKind) }

    /// è uno dei tipi dello spazio (libero, volumi di sistema, nascosto)?
    public func isSpace(_ k: Int) -> Bool { spaceKinds.values.contains(Int32(k)) }

    public func isPackage(_ e: Entry) -> Bool {
        e.isDirectory && packageKind[Int(e.ext)] >= 0
    }

    public func kind(of e: Entry) -> Int {
        if e.flags.contains(.special) { return Int(spaceKinds[Tree.Space(rawValue: e.ext) ?? .hidden]!) }
        if e.isDirectory {
            let p = packageKind[Int(e.ext)]
            return Int(p >= 0 ? p : folderKind)
        }
        if e.flags.contains(.symlink) { return Int(symlinkKind) }
        if e.ext == 0 && e.flags.contains(.executable) { return Int(executableKind) }
        return Int(fileKind[Int(e.ext)])
    }

    /// Conta quanto occupa ogni tipo sotto `folder` e dà i colori ai dodici tipi più grandi.
    /// I pacchetti chiusi contano come un oggetto solo del loro tipo.
    public func tally(_ folder: Folder, mode: SizeMode, openPackages: Bool, colored: Int = 12) {
        for i in kinds.indices {
            kinds[i].alloc = 0
            kinds[i].logical = 0
            kinds[i].count = 0
        }
        var stack = [folder]
        while let f = stack.popLast() {
            for e in f.entries {
                if e.sub >= 0 && (openPackages || !isPackage(e)) {
                    stack.append(f.subfolders[Int(e.sub)])
                    continue
                }
                if e.isDirectory && !isPackage(e) { continue }
                let k = kind(of: e)
                kinds[k].alloc &+= e.alloc
                kinds[k].logical &+= e.logical
                kinds[k].count += 1
            }
        }
        // i colori ai tipi veri; lo spazio libero chiaro, l'altro scuro
        let spaces = Set(spaceKinds.values.map(Int.init))
        let order = kinds.indices.filter { !spaces.contains($0) }.sorted { kinds[$0].size(mode) > kinds[$1].size(mode) }
        let palette = Palette.colors(colored)
        for (rank, k) in order.enumerated() {
            kinds[k].color = rank < palette.count && kinds[k].count > 0 ? palette[rank] : Palette.other
        }
        kinds[Int(spaceKinds[.free]!)].color = [0.95, 0.95, 0.95]
        kinds[Int(spaceKinds[.system]!)].color = [0.45, 0.47, 0.55]
        kinds[Int(spaceKinds[.hidden]!)].color = [0.25, 0.25, 0.25]
    }

    /// i tipi presenti, dal più grande
    public func ranked(_ mode: SizeMode) -> [Int] {
        kinds.indices.filter { kinds[$0].count > 0 }.sorted { kinds[$0].size(mode) > kinds[$1].size(mode) }
    }
}
