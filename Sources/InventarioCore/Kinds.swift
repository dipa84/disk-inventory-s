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
    private var freeKind: Int32 = 0, otherKind: Int32 = 0

    public init(extensions: [String]) {
        folderKind = add(UTType.folder)
        symlinkKind = add(UTType.symbolicLink)
        executableKind = add(UTType.unixExecutable)
        documentKind = add(UTType.data)
        freeKind = add(name: "Spazio libero", type: nil)
        otherKind = add(name: "Altro spazio", type: nil)
        fileKind = [Int32](repeating: documentKind, count: extensions.count)
        packageKind = [Int32](repeating: -1, count: extensions.count)
        for (id, ext) in extensions.enumerated() where id > 0 {
            if let t = UTType(filenameExtension: ext), t.localizedDescription != nil, !t.isDynamic {
                fileKind[id] = add(t)
            } else {
                fileKind[id] = add(name: "File .\(ext)", type: nil)
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

    public func isPackage(_ e: Entry) -> Bool {
        e.isDirectory && packageKind[Int(e.ext)] >= 0
    }

    public func kind(of e: Entry) -> Int {
        if e.flags.contains(.special) { return Int(e.ext == Tree.freeSpace ? freeKind : otherKind) }
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
    public func tally(_ folder: Folder, mode: SizeMode, openPackages: Bool) {
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
        let order = kinds.indices.filter { $0 != freeKind && $0 != otherKind }.sorted { kinds[$0].size(mode) > kinds[$1].size(mode) }
        for (rank, k) in order.enumerated() {
            kinds[k].color = rank < Palette.base.count && kinds[k].count > 0 ? Palette.base[rank] : Palette.other
        }
        kinds[Int(freeKind)].color = [0.95, 0.95, 0.95]
        kinds[Int(otherKind)].color = [0.3, 0.3, 0.3]
    }

    /// i tipi presenti, dal più grande
    public func ranked(_ mode: SizeMode) -> [Int] {
        kinds.indices.filter { kinds[$0].count > 0 }.sorted { kinds[$0].size(mode) > kinds[$1].size(mode) }
    }
}
