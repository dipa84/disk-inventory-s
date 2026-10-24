import Foundation

/// Cartelle lette altrove (dal programma d'aiuto con i permessi da amministratore) e passate
/// all'app in un file: un formato binario semplice, cartella per cartella in profondità.
///
///     file     = n:u32, n × (percorso, cartella)
///     percorso = lunghezza:u32, byte UTF-8
///     cartella = stato:u8 (1 non leggibile, 2 altro volume), voci:u32, voci × voce
///     voce     = flags:u16, alloc:u64, logical:u64, nome (lunghezza:u16, byte),
///                e subito dopo la sua cartella, se è una cartella letta
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

    /// Le cartelle, per percorso, già sommate e ordinate; nil se il file è rovinato.
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
            // la cartella arriva subito dopo la sua voce, tranne per quelle che la scansione non
            // apre mai (altri volumi, saltate, firmlink): sono le uniche con `sub` < 0
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
