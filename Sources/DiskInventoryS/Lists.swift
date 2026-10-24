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
import UniformTypeIdentifiers

/// The first column takes whatever the others leave of the visible width.
private func fitFirstColumn(_ table: NSTableView, _ first: NSTableColumn, _ scroll: NSScrollView) {
    let others = table.tableColumns.filter { $0 !== first && !$0.isHidden }.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
    let available = scroll.contentSize.width - others - table.intercellSpacing.width - 24
    first.width = max(first.minWidth, available)
}

// MARK: the folder list

final class OutlineItem: NSObject {
    let item: Item
    init(_ item: Item) { self.item = item }
}

/// Folders sorted by size, like the Finder but with the size of everything.
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var controller: DocumentController?
    let scrollView = NSScrollView()
    private let view = KeyOutlineView()
    /// each folder's rows, made the first time it is opened
    private var children: [ObjectIdentifier: [OutlineItem]] = [:]
    private var root: OutlineItem?
    private var revealing = false
    private var icons: [Int: NSImage] = [:]
    private var packageIcons: [String: NSImage] = [:]

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("name"))
        name.title = L("Name")
        name.width = 220
        let size = NSTableColumn(identifier: .init("size"))
        size.title = L("Size")
        size.width = 84
        let share = NSTableColumn(identifier: .init("share"))
        share.title = "%"
        share.width = 56
        let kind = NSTableColumn(identifier: .init("kind"))
        kind.title = L("Kind")
        kind.width = 110
        // numbers keep their width; when the window narrows, names make room
        // the number columns keep their width (they are not saved: old saved widths were too
        // wide); the names get the rest
        for c in [size, share] { c.minWidth = c.width; c.maxWidth = c.width; c.resizingMask = [] }
        kind.minWidth = 80
        kind.maxWidth = 200
        for c in [name, size, share, kind] { view.addTableColumn(c) }
        view.outlineTableColumn = name
        view.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        view.dataSource = self
        view.delegate = self
        view.style = .inset
        view.usesAlternatingRowBackgroundColors = false
        view.allowsMultipleSelection = false
        view.autosaveName = "DiskInventoryS.folders"
        view.autosaveTableColumns = false
        // NSOutlineView would widen the names column on each expansion, pushing the others out
        view.autoresizesOutlineColumn = false
        view.target = self
        view.doubleAction = #selector(doubleClicked)
        view.owner = self
        scrollView.documentView = view
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.fitNameColumn()
        }
    }

    fileprivate var menuController: DocumentController? { controller }

    func reload() {
        children.removeAll()
        root = controller?.model.map { OutlineItem(Item($0.tree.root)) }
        view.reloadData()
        fitNameColumn()
        if let root { view.expandItem(root) }
    }

    /// Saved column widths may add up to more than the list shows: the names take what is left.
    /// When the list is narrow the Kind column goes first, then %: names matter more.
    func fitNameColumn() {
        guard let name = view.outlineTableColumn else { return }
        let width = scrollView.contentSize.width
        view.tableColumn(withIdentifier: .init("kind"))?.isHidden = width < 440
        view.tableColumn(withIdentifier: .init("share"))?.isHidden = width < 330
        fitFirstColumn(view, name, scrollView)
    }

    private func rows(of folder: Folder) -> [OutlineItem] {
        let key = ObjectIdentifier(folder)
        if let r = children[key], r.count == folder.entries.count { return r }
        let r = folder.entries.indices.map { OutlineItem(Item(folder: folder, entry: $0)) }
        children[key] = r
        return r
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let doc = controller?.model else { return 0 }
        guard let o = item as? OutlineItem else { return root == nil ? 0 : 1 }
        guard doc.isContainer(o.item), let f = o.item.contents else { return 0 }
        return f.entries.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let o = item as? OutlineItem, let f = o.item.contents else { return root! }
        return rows(of: f)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let doc = controller?.model, let o = item as? OutlineItem else { return false }
        return doc.isContainer(o.item) && (o.item.contents?.entries.isEmpty == false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let doc = controller?.model, let o = item as? OutlineItem, let column = tableColumn, o.item.isValid else { return nil }
        let id = column.identifier
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let it = o.item
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = doc.name(it)
            cell.imageView?.image = icon(it, doc)
            let e = it.entryValue
            let dim = e.map { !$0.flags.isDisjoint(with: [.hardlinkSeen, .cloneSeen, .mountPoint, .skipped, .special, .firmlinked]) } == true
            cell.textField?.textColor = e?.flags.contains(.unreadable) == true ? .systemRed : dim ? .secondaryLabelColor : .labelColor
            cell.toolTip = tip(e)
        case "size":
            cell.textField?.stringValue = Format.size(it.size(doc.mode))
        case "share":
            let whole = it.isRoot ? it.size(doc.mode) : it.folder.size(doc.mode)
            cell.textField?.stringValue = Format.percent(it.size(doc.mode), of: whole)
        default:
            cell.textField?.stringValue = doc.kindName(it)
        }
        return cell
    }

    private func tip(_ e: Entry?) -> String? {
        guard let e else { return nil }
        return Document.note(e)
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
        }
        if id.rawValue == "size" || id.rawValue == "share" {
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        if id.rawValue == "kind" { text.textColor = .secondaryLabelColor }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(_ it: Item, _ doc: Document) -> NSImage {
        if let e = it.entryValue, e.flags.contains(.special) {
            let symbol = switch Tree.Space(rawValue: e.ext) {
            case .free?: "circle.dashed"
            case .system?: "gearshape.2"
            default: "eye.slash"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
        if let e = it.entryValue, doc.kinds.isPackage(e) {
            // packages (apps) each have their own icon
            let path = doc.path(it)
            if let i = packageIcons[path] { return i }
            let i = NSWorkspace.shared.icon(forFile: path)
            packageIcons[path] = i
            return i
        }
        let k = it.entryValue.map { doc.kinds.kind(of: $0) } ?? doc.kinds.folderKindIndex
        if let i = icons[k] { return i }
        let i = doc.kinds.kinds[k].type.map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data)
        icons[k] = i
        return i
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !revealing, let o = view.item(atRow: view.selectedRow) as? OutlineItem else { return }
        controller?.select(o.item, from: .outline)
    }

    @objc private func doubleClicked() {
        guard let o = view.item(atRow: view.clickedRow) as? OutlineItem, let doc = controller?.model else { return }
        if doc.isContainer(o.item), let f = o.item.contents {
            controller?.zoom(into: f)
        }
    }

    /// opens the folders down to the entry and selects it
    func reveal(_ item: Item?) {
        guard let item, item.isValid, let root else {
            view.deselectAll(nil)
            return
        }
        var chain: [Item] = []
        var c: Item? = item
        while let i = c { chain.append(i); c = i.parent }
        revealing = true
        defer { revealing = false }
        var row: OutlineItem = root
        for it in chain.reversed().dropFirst() {
            guard let f = row.item.contents else { break }
            view.expandItem(row)
            let rs = rows(of: f)
            guard it.entry < rs.count else { break }
            row = rs[it.entry]
        }
        let r = view.row(forItem: row)
        if r >= 0 {
            view.selectRowIndexes([r], byExtendingSelection: false)
            view.scrollRowToVisible(r)
        }
    }

    func selectClickedRow() {
        let r = view.clickedRow
        if r >= 0, let o = view.item(atRow: r) as? OutlineItem {
            view.selectRowIndexes([r], byExtendingSelection: false)
            controller?.select(o.item, from: .outline)
        }
    }
}

/// space opens Quick Look, right click the selection's menu
final class KeyOutlineView: NSOutlineView {
    weak var owner: OutlineController?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.charactersIgnoringModifiers == " " && mods.isEmpty {
            owner?.menuController?.quickLook(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.selectClickedRow()
        return owner?.menuController?.contextMenu()
    }
}

// MARK: the file kinds

/// File kinds, largest first, with their color in the map. Selecting one highlights it in the
/// map; selecting it again (or the empty area) removes the highlight.
final class KindsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var controller: DocumentController?
    let scrollView = NSScrollView()
    private let table = NSTableView()
    private var ranked: [Int] = []

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("kind"))
        name.title = L("Kind")
        name.width = 200
        let size = NSTableColumn(identifier: .init("size"))
        size.title = L("Size")
        size.width = 80
        let count = NSTableColumn(identifier: .init("files"))
        count.title = L("Files")
        count.width = 72
        for c in [name, size, count] { table.addTableColumn(c) }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.allowsEmptySelection = true
        table.autosaveName = "DiskInventoryS.kinds"
        table.autosaveTableColumns = false
        for c in [size, count] { c.minWidth = c.width; c.maxWidth = c.width; c.resizingMask = [] }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            guard let self, let name = self.table.tableColumns.first else { return }
            // narrow: the file count goes, the kind's name stays
            self.table.tableColumn(withIdentifier: .init("files"))?.isHidden = self.scrollView.contentSize.width < 320
            fitFirstColumn(self.table, name, self.scrollView)
        }
    }

    func reload() {
        guard let doc = controller?.model else { return }
        ranked = doc.kinds.ranked(doc.mode)
        table.reloadData()
        if let k = doc.highlightedKind, let r = ranked.firstIndex(of: k) {
            table.selectRowIndexes([r], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ranked.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let doc = controller?.model, let id = tableColumn?.identifier else { return nil }
        let k = doc.kinds.kinds[ranked[row]]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        switch id.rawValue {
        case "kind":
            cell.textField?.stringValue = k.name
            cell.imageView?.image = swatch(k.color)
        case "size":
            cell.textField?.stringValue = Format.size(k.size(doc.mode))
        default:
            cell.textField?.stringValue = doc.kinds.isSpace(ranked[row]) ? "" : Format.count(k.count)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "kind" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14),
                image.heightAnchor.constraint(equalToConstant: 14),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// a small cushion square in the kind's color, as in the map
    private func swatch(_ c: SIMD3<Double>) -> NSImage {
        let color = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let g = NSGradient(starting: color.highlight(withLevel: 0.5) ?? color, ending: color.shadow(withLevel: 0.4) ?? color)
            g?.draw(in: NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3), relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
            return true
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        controller?.kindSelected(r >= 0 && r < ranked.count ? ranked[r] : nil)
    }
}
