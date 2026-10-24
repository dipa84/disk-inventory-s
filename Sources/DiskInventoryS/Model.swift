// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DiskInventoryCore

/// Something that can be selected: an entry of a folder, or (entry -1) the starting folder,
/// which has no entry above it.
struct Item: Equatable {
    unowned(unsafe) let folder: Folder
    let entry: Int

    static func == (a: Item, b: Item) -> Bool { a.folder === b.folder && a.entry == b.entry }

    /// the entry representing a folder
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

    /// the folder this entry is, if it is a folder that was read
    var contents: Folder? { entry < 0 ? folder : folder.subfolder(at: entry) }

    var parent: Item? {
        if entry < 0 { return nil }
        return Item(folder)
    }

    func size(_ mode: SizeMode) -> UInt64 {
        entry < 0 ? folder.size(mode) : folder.entries[entry].size(mode)
    }

    /// is it still in the tree? (positions change after Trash and Refresh)
    var isValid: Bool { entry < 0 || entry < folder.entries.count }
}

/// Everything a window knows about a scan.
final class Document {
    let tree: Tree
    let kinds: Kinds
    var openPackages = Prefs.openPackages
    /// the volume's space, when the starting folder is a whole volume
    let space: VolumeSpace?
    /// how much the scan counted: the rest of the used space was not seen
    private let counted: UInt64
    /// the folders that could not be read (system permissions or privacy)
    let unreadFolders: [Folder]
    var isVolume: Bool { space != nil }
    /// the kind selected in the kinds list: the map highlights it
    var highlightedKind: Int?

    init(tree: Tree, space: VolumeSpace?) {
        self.tree = tree
        self.space = space
        tree.setSpecialSpace([])
        counted = tree.root.alloc
        var unread: [Folder] = []
        var stack = [tree.root]
        while let f = stack.popLast() {
            if f.unreadable { unread.append(f) }
            stack.append(contentsOf: f.subfolders)
        }
        unreadFolders = unread
        kinds = Kinds(extensions: tree.extensions.names)
        updateSpecialSpace()
        tally()
    }

    /// Redoes the space entries (after the settings change). They stay as measured at scan time:
    /// the Trash frees no space until it is emptied.
    func updateSpecialSpace() {
        guard let space, Prefs.showSpace else {
            tree.setSpecialSpace([])
            return
        }
        tree.setSpecialSpace(space.spaces(counted: counted, includePurgeable: Prefs.purgeableIsFree, unread: !unreadFolders.isEmpty))
    }

    func isSpecial(_ item: Item) -> Bool { item.entryValue?.flags.contains(.special) == true }

    /// what a special entry means (for the status bar and tooltips)
    static func note(_ e: Entry) -> String? {
        if e.flags.contains(.special) {
            switch Tree.Space(rawValue: e.ext) {
            case .free?: return L("the space still available")
            case .system?: return L("virtual memory, Preboot, Recovery, macOS updates")
            case .filesystem?: return L("the file system’s indexes and tables")
            default: return L("the space of the folders that couldn’t be read")
            }
        }
        if e.flags.contains(.unreadable) { return L("unreadable: needs Full Disk Access") }
        if e.flags.contains(.mountPoint) { return L("another volume: not counted here") }
        if e.flags.contains(.firmlinked) { return L("the same folder seen from / (firmlink): counted there") }
        if e.flags.contains(.skipped) { return L("skipped (Settings › Scan)") }
        if e.flags.contains(.hardlinkSeen) { return L("another name of a file already counted elsewhere") }
        if e.flags.contains(.cloneSeen) { return L("a clone: only its own data counts") }
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

    /// in the map: is it divided into tiles or drawn whole?
    func isLeaf(_ e: Entry) -> Bool {
        !e.isDirectory || (!openPackages && kinds.isPackage(e))
    }

    /// can one go into it (zoom, children in the list)? Packages only if we open them.
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
