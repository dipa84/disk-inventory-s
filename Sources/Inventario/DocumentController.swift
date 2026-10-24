import AppKit
import InventarioCore
import Quartz
import SwiftUI

/// Una finestra: la scansione di una cartella, poi l'elenco delle cartelle, i tipi e la mappa.
final class DocumentController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let rootPath: String
    private(set) var model: Document?
    /// la cartella che la mappa mostra
    private(set) var zoom: Folder!
    /// le cartelle da cui si è usciti con ⌘[, per tornarci con ⌘]
    private var forward: [Folder] = []
    private(set) var selection: Item?

    enum Source { case map, outline, kinds, other }

    private let treemap = TreemapView(frame: .zero)
    private let outline = OutlineController()
    private let kindsTable = KindsController()
    private let status = NSTextField(labelWithString: "")
    private let notice = NSButton(title: "", target: nil, action: nil)
    private var split: NSSplitView!
    private var progress: ScanProgress?
    private var scanner: DiskScanner?
    private var pathControl: NSPathControl?
    private var zoomButtons: NSSegmentedControl?

    init(path: String) {
        rootPath = path
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        window.subtitle = path
        window.representedURL = URL(fileURLWithPath: path)
        window.setFrameAutosaveName("Inventario")
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Inventario")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
        startScan()
    }

    /// le preferenze della mappa, delle unità e dello spazio valgono subito
    @objc private func prefsChanged() {
        guard model != nil else { return }
        if let sel = selection, model!.isSpecial(sel) { selection = nil }
        changed()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: scansione

    private func startScan() {
        let scanner = DiskScanner(mode: Prefs.logicalSize ? .logical : .allocated, options: Prefs.scanOptions)
        self.scanner = scanner
        let progress = ScanProgress(scanner: scanner, path: rootPath)
        self.progress = progress
        let host = NSHostingView(rootView: ScanProgressView(progress: progress) { [weak self] in self?.cancelScan() })
        window?.contentView = host
        let path = rootPath
        let start = ContinuousClock.now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = scanner.scan(path)
            let elapsed = ContinuousClock.now - start
            // lo spazio del volume: diskutil, qualche decimo di secondo, anche questo qui
            let space = tree == nil ? nil : VolumeSpace.measure(path)
            DispatchQueue.main.async {
                progress.stop()
                guard let self else { return }
                self.scanner = nil
                if let tree {
                    if ProcessInfo.processInfo.environment["INVENTARIO_MISURA"] != nil {
                        print("scansione di \(path): \(elapsed), \(tree.root.fileCount) file")
                    }
                    Prefs.lastFolder = path
                    self.show(Document(tree: tree, space: space), unreadable: scanner.unreadable.load(ordering: .relaxed), elapsed: elapsed)
                } else {
                    self.close()
                }
            }
        }
    }

    private func cancelScan() {
        scanner?.cancel()
    }

    private func show(_ doc: Document, unreadable: Int, elapsed: Duration) {
        model = doc
        zoom = doc.tree.root
        buildViews()
        outline.reload()
        kindsTable.reload()
        treemap.reload()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        readIn = String(format: "%.1f s", seconds)
        updateNotice()
        setDefaultStatus()
        updateStatus()
        updateToolbar()
        window?.makeFirstResponder(treemap)
        if let photo = ProcessInfo.processInfo.environment["INVENTARIO_FOTO"] {
            let wait = Double(ProcessInfo.processInfo.environment["INVENTARIO_ATTESA"] ?? "") ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.photograph(to: photo) }
        }
    }

    /// INVENTARIO_FOTO=file.png: un'immagine della finestra dopo la scansione, poi esce (per le prove)
    private func photograph(to path: String) {
        if let action = ProcessInfo.processInfo.environment["INVENTARIO_AZIONE"] {
            for a in action.split(separator: ",") { perform(Selector(String(a) + ":"), with: nil) }
            // le azioni che lavorano in sottofondo (leggere le cartelle di sistema) hanno tempo di finire
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.snapshot(to: path) }
            return
        }
        snapshot(to: path)
    }

    private func snapshot(to path: String) {
        window?.displayIfNeeded()
        guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }

    private var defaultStatus = ""
    /// quanto ha messo la scansione
    private var readIn: String?

    private func setDefaultStatus() {
        guard let doc = model else { return }
        let n = doc.tree.root.fileCount
        var s = L(one: "%@ file, %@", other: "%@ file, %@ (molti)", n, Format.count(n), Format.size(doc.tree.root.size(doc.mode)))
        if let readIn { s += " — " + L("letti in %@", readIn) }
        defaultStatus = s
    }

    private func buildViews() {
        guard let window else { return }
        outline.controller = self
        kindsTable.controller = self
        treemap.controller = self

        let left = NSSplitView()
        left.isVertical = false
        left.dividerStyle = .thin
        left.addArrangedSubview(outline.scrollView)
        left.addArrangedSubview(kindsTable.scrollView)
        left.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)

        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(treemap)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

        status.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notice.bezelStyle = .inline
        notice.controlSize = .small
        notice.target = self
        notice.action = #selector(noticeClicked)
        notice.isHidden = true
        let bar = NSStackView(views: [status, notice])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        let content = NSView()
        for v in [split!, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
        ])
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        treemap.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        outline.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        kindsTable.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        window.contentView = content
        // le proporzioni dell'ultima volta (NSSplitView le salverebbe da sé, ma con i vincoli sbaglia)
        content.layoutSubtreeIfNeeded()
        let d = UserDefaults.standard
        let width = d.object(forKey: "larghezzaElenco") as? Double ?? 420
        let share = d.object(forKey: "quotaCartelle") as? Double ?? 0.62
        split.setPosition(width, ofDividerAt: 0)
        left.setPosition(left.bounds.height * share, ofDividerAt: 0)
        leftSplit = left
        NotificationCenter.default.addObserver(self, selector: #selector(splitMoved), name: NSSplitView.didResizeSubviewsNotification, object: split)
        NotificationCenter.default.addObserver(self, selector: #selector(splitMoved), name: NSSplitView.didResizeSubviewsNotification, object: left)
    }

    private weak var leftSplit: NSSplitView?

    @objc private func splitMoved(_ n: Notification) {
        // solo quando le muove chi usa la finestra, non quando la finestra cambia misura
        guard n.userInfo?["NSSplitViewDividerIndex"] != nil, let left = leftSplit, left.bounds.height > 0 else { return }
        UserDefaults.standard.set(Double(left.frame.width), forKey: "larghezzaElenco")
        UserDefaults.standard.set(Double(outline.scrollView.frame.height / left.bounds.height), forKey: "quotaCartelle")
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: le cartelle che non si lasciano leggere

    /// già provato a leggerle con la password: quelle che restano sono private (privacy)
    private var readAsAdmin = false
    private var readingAsAdmin = false

    /// Il pulsante in fondo: prima legge le cartelle di sistema con la password, poi (per quelle
    /// che restano, protette dalla privacy) apre l'Accesso completo al disco.
    private func updateNotice() {
        guard let doc = model else { return }
        let n = doc.unreadFolders.count
        notice.isHidden = n == 0
        if readingAsAdmin {
            notice.title = L("Leggo le cartelle di sistema…")
            notice.isEnabled = false
            return
        }
        notice.isEnabled = true
        if !readAsAdmin {
            notice.title = L(one: "%@ cartella non letta — Leggi…", other: "%@ cartelle non lette — Leggi…", n, Format.count(n))
            notice.toolTip = L("Sono cartelle di sistema che un'app non può leggere. Disk Inventory S le legge con la password da amministratore, senza cambiare niente.")
        } else {
            notice.title = L(one: "%@ cartella privata non letta…", other: "%@ cartelle private non lette…", n, Format.count(n))
            notice.toolTip = L("Per leggere tutto, Disk Inventory S ha bisogno dell'Accesso completo al disco (Impostazioni di Sistema › Privacy e sicurezza).")
        }
    }

    /// per le prove (INVENTARIO_AZIONE=leggiCartelleDiSistema)
    @objc func leggiCartelleDiSistema(_ sender: Any?) { readSystemFolders() }

    @objc private func noticeClicked() {
        if readAsAdmin { openPrivacySettings() } else { readSystemFolders() }
    }

    /// Fa leggere le cartelle non lette al programma d'aiuto (inventario-cli esporta), con i
    /// permessi da amministratore: macOS chiede la password. Poi le mette nell'albero.
    private func readSystemFolders() {
        guard let doc = model, !doc.unreadFolders.isEmpty, !readingAsAdmin,
              let helper = Bundle.main.path(forAuxiliaryExecutable: "inventario-cli") else { return }
        let tree = doc.tree
        let folders = doc.unreadFolders
        let paths = folders.map { tree.path(of: $0) }
        let dir = FileManager.default.temporaryDirectory
        let list = dir.appendingPathComponent("disk-inventory-s-\(getpid())-elenco.txt")
        let out = dir.appendingPathComponent("disk-inventory-s-\(getpid())-cartelle.bin")
        try? FileManager.default.removeItem(at: out)
        guard (try? (paths.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)) != nil else { return }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = [helper, "esporta", list.path, out.path].map(quoted).joined(separator: " ")
        func literal(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let prompt = L("Disk Inventory S vuole leggere le cartelle di sistema che un'app non può aprire. Le legge soltanto, senza cambiare niente.")
        let script = "do shell script \(literal(shell)) with administrator privileges with prompt \(literal(prompt))"
        // per le prove: il programma d'aiuto senza password (legge solo quello che legge l'utente)
        let withoutPassword = ProcessInfo.processInfo.environment["INVENTARIO_SENZA_PASSWORD"] != nil
        readingAsAdmin = true
        updateNotice()
        let mode = doc.mode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: withoutPassword ? "/bin/sh" : "/usr/bin/osascript")
            p.arguments = withoutPassword ? ["-c", shell] : ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            let data = ok ? try? Data(contentsOf: out) : nil
            let read = data.flatMap { FolderExport.read($0, registry: tree.extensions, mode: mode) }
            try? FileManager.default.removeItem(at: list)
            try? FileManager.default.removeItem(at: out)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingAsAdmin = false
                // annullato (niente password): si può riprovare
                guard let read else {
                    self.updateNotice()
                    return
                }
                self.readAsAdmin = true
                for (folder, path) in zip(folders, paths) {
                    if let fresh = read[path] { tree.replace(folder: folder, with: fresh) }
                }
                let updated = Document(tree: tree, space: doc.space)
                updated.openPackages = doc.openPackages
                self.model = updated
                self.selection = nil
                self.changed()
                self.updateNotice()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        scanner?.cancel()
        progress?.stop()
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }

    // MARK: scelta

    func select(_ item: Item?, from source: Source) {
        guard item != selection else { return }
        selection = item
        treemap.needsDisplay = true
        if source != .outline { outline.reveal(item) }
        updateStatus()
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private var hoveredItem: Item?

    func hover(_ item: Item?) {
        hoveredItem = item
        updateStatus()
    }

    private func updateStatus() {
        guard let doc = model else { return }
        guard let item = hoveredItem ?? selection, item.isValid else {
            status.stringValue = defaultStatus
            return
        }
        var parts = [doc.path(item), Format.size(item.size(doc.mode)), doc.kindName(item)]
        if let f = item.contents { parts.append(L(one: "%@ file", other: "%@ file (molti)", f.fileCount, Format.count(f.fileCount))) }
        if let e = item.entryValue, let note = Document.note(e) { parts.append(note) }
        let p = Format.percent(item.size(doc.mode), of: zoom.size(doc.mode))
        if !p.isEmpty { parts.append(p) }
        status.stringValue = parts.joined(separator: "  ·  ")
    }

    func kindSelected(_ kind: Int?) {
        model?.highlightedKind = kind
        treemap.recolor()
    }

    // MARK: zoom

    func zoom(into folder: Folder, keepForward: Bool = false) {
        guard folder !== zoom else { return }
        if !keepForward { forward.removeAll() }
        zoom = folder
        treemap.reload()
        updateToolbar()
        updateStatus()
    }

    /// ↩ e ⌘]: entra nella cartella scelta, o in quella che contiene il file scelto
    @objc func zoomIn(_ sender: Any?) {
        guard let doc = model else { return }
        if let sel = selection {
            if let f = sel.contents, doc.isContainer(sel), f !== zoom {
                zoom(into: f)
            } else if !sel.isRoot, sel.folder !== zoom, sel.folder.isDescendant(of: zoom) {
                zoom(into: sel.folder)
            }
        } else if let f = forward.popLast() {
            zoom(into: f, keepForward: true)
        }
    }

    /// ⌘[: esce di un livello
    @objc func zoomOut(_ sender: Any?) {
        guard let p = zoom.parent else { return }
        forward.append(zoom)
        zoom(into: p, keepForward: true)
    }

    /// ⌘]: torna dove si era prima di ⌘[
    @objc func zoomForward(_ sender: Any?) {
        guard let f = forward.popLast() else { return }
        zoom(into: f, keepForward: true)
    }

    /// ⇧⌘[: tutta la cartella di partenza
    @objc func zoomToTop(_ sender: Any?) {
        guard let root = model?.tree.root, zoom !== root else { return }
        var f: Folder? = zoom
        var trail: [Folder] = []
        while let c = f, c !== root { trail.append(c); f = c.parent }
        forward = trail
        zoom(into: root, keepForward: true)
    }

    /// ⌘↑: sceglie la cartella che contiene la scelta
    @objc func selectParent(_ sender: Any?) {
        guard let sel = selection, let p = sel.parent else { return }
        select(p, from: .other)
    }

    /// ⌘↓: sceglie la voce più grande dentro la scelta
    @objc func selectChild(_ sender: Any?) {
        guard let doc = model, let sel = selection ?? Optional(Item(zoom)), doc.isContainer(sel), let f = sel.contents,
              !f.entries.isEmpty else { return }
        select(Item(folder: f, entry: 0), from: .other)
    }

    private func zoomTo(component url: URL) {
        var f: Folder? = zoom
        while let c = f {
            if URL(fileURLWithPath: model!.tree.path(of: c)).standardizedFileURL == url.standardizedFileURL {
                if c !== zoom { forward.removeAll(); zoom(into: c) }
                return
            }
            f = c.parent
        }
    }

    // MARK: azioni sulla scelta

    private var selectedPath: String? {
        guard let doc = model, let sel = selection, sel.isValid, !doc.isSpecial(sel) else { return nil }
        return doc.path(sel)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let p = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc func openSelection(_ sender: Any?) {
        guard let p = selectedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc func copyPath(_ sender: Any?) {
        guard let p = selectedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p, forType: .string)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let doc = model, let sel = selection, sel.isValid, !sel.isRoot, !doc.isSpecial(sel), let window else { return }
        guard Prefs.confirmTrash else {
            trash(sel)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Spostare «%@» nel Cestino?", doc.name(sel))
        var info = Format.size(sel.size(doc.mode))
        if let f = sel.contents { info += ", " + L(one: "%@ file", other: "%@ file (molti)", f.fileCount, Format.count(f.fileCount)) }
        alert.informativeText = info + "\n" + doc.path(sel)
        alert.addButton(withTitle: L("Sposta nel Cestino"))
        alert.addButton(withTitle: L("Annulla"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Non chiedere più")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: Prefs.Key.confirmTrash) }
            self.trash(sel)
        }
    }

    private func trash(_ item: Item) {
        guard let doc = model else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: doc.path(item)), resultingItemURL: nil)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
            return
        }
        NSSound(named: "Poof")?.play()
        let parent = Item(item.folder)
        // se la mappa mostrava la cartella tolta, torna a quella che la conteneva
        if let f = item.contents, zoom.isDescendant(of: f) { zoom = item.folder }
        forward.removeAll()
        doc.tree.remove(folder: item.folder, entry: item.entry)
        selection = nil
        changed()
        select(parent, from: .other)
    }

    /// ⇧⌘R: rilegge dal disco la cartella scelta (o quella del file scelto)
    @objc func refresh(_ sender: Any?) {
        guard let doc = model, let sel = selection else { return }
        let folder = (doc.isContainer(sel) ? sel.contents : nil) ?? sel.folder
        reread(folder)
    }

    @objc func refreshAll(_ sender: Any?) {
        guard let root = model?.tree.root else { return }
        reread(root)
    }

    private func reread(_ folder: Folder) {
        guard let doc = model, scanner == nil else { return }
        if folder.parent == nil {
            // tutto da capo, in una finestra nuova al posto di questa
            (NSApp.delegate as? AppDelegate)?.open(path: rootPath, replacing: self)
            return
        }
        let scanner = DiskScanner(registry: doc.tree.extensions, mode: doc.mode, options: Prefs.scanOptions)
        self.scanner = scanner
        status.stringValue = L("Rileggo %@…", doc.tree.path(of: folder))
        let tree = doc.tree
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = scanner.rescan(folder, in: tree)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanner = nil
                guard let fresh else { self.updateStatus(); return }
                // la mappa e la scelta non possono restare nella cartella vecchia
                let wasInside = self.zoom.isDescendant(of: folder)
                tree.replace(folder: folder, with: fresh)
                if wasInside { self.zoom = fresh }
                self.forward.removeAll()
                // la lettura nuova può avere estensioni nuove
                let fresh2 = Document(tree: tree, space: doc.space)
                fresh2.openPackages = doc.openPackages
                self.model = fresh2
                fresh2.tally()
                self.selection = nil
                self.changed()
                self.select(Item(fresh), from: .other)
            }
        }
    }

    /// l'albero è cambiato: tutto da rifare
    private func changed() {
        model?.updateSpecialSpace()
        model?.tally()
        outline.reload()
        kindsTable.reload()
        treemap.reload()
        setDefaultStatus()
        updateToolbar()
        updateStatus()
    }

    // MARK: vista

    @objc func toggleSizeMode(_ sender: Any?) {
        guard let doc = model else { return }
        doc.tree.setSizeMode(doc.mode == .allocated ? .logical : .allocated)
        let sel = selection
        changed()
        selection = nil
        select(sel, from: .other)
    }

    @objc func togglePackages(_ sender: Any?) {
        guard let doc = model else { return }
        doc.openPackages.toggle()
        // dentro un pacchetto che ora è chiuso non si può restare
        if !doc.openPackages {
            var f: Folder? = zoom
            while let c = f, let p = c.parent {
                if doc.kinds.isPackage(p.entries[Int(c.index)]) { zoom = p }
                f = p
            }
        }
        changed()
    }

    /// vale per tutte le finestre: è la stessa preferenza
    @objc func toggleSpecialSpace(_ sender: Any?) {
        UserDefaults.standard.set(!Prefs.showSpace, forKey: Prefs.Key.showSpace)
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let doc = model else { return false }
        let hasSelection = selection.map { $0.isValid && !doc.isSpecial($0) } == true
        switch menuItem.action {
        case #selector(toggleSizeMode(_:)):
            menuItem.state = doc.mode == .logical ? .on : .off
            return true
        case #selector(togglePackages(_:)):
            menuItem.state = doc.openPackages ? .on : .off
            return true
        case #selector(toggleSpecialSpace(_:)):
            menuItem.state = Prefs.showSpace && doc.isVolume ? .on : .off
            return doc.isVolume
        case #selector(zoomOut(_:)), #selector(zoomToTop(_:)):
            return zoom.parent != nil
        case #selector(zoomForward(_:)):
            return !forward.isEmpty
        case #selector(zoomIn(_:)), #selector(selectChild(_:)):
            return true
        case #selector(selectParent(_:)):
            return selection?.parent != nil
        case #selector(refresh(_:)) where selection.map(doc.isSpecial) == true:
            return false
        case #selector(moveToTrash(_:)):
            return hasSelection && selection?.isRoot == false
        case #selector(refresh(_:)), #selector(refreshAll(_:)):
            return scanner == nil
        default:
            return hasSelection
        }
    }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: L("Apri"), action: #selector(openSelection(_:)), keyEquivalent: "")
        m.addItem(withTitle: L("Mostra nel Finder"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
        m.addItem(withTitle: L("Anteprima"), action: #selector(quickLook(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L("Entra"), action: #selector(zoomIn(_:)), keyEquivalent: "")
        m.addItem(withTitle: L("Aggiorna"), action: #selector(refresh(_:)), keyEquivalent: "")
        m.addItem(withTitle: L("Copia il percorso"), action: #selector(copyPath(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L("Sposta nel Cestino"), action: #selector(moveToTrash(_:)), keyEquivalent: "")
        for i in m.items { i.target = self }
        return m
    }

    // MARK: barra degli strumenti

    private static let zoomItem = NSToolbarItem.Identifier("zoom")
    private static let pathItem = NSToolbarItem.Identifier("percorso")
    private static let finderItem = NSToolbarItem.Identifier("finder")
    private static let trashItem = NSToolbarItem.Identifier("cestino")
    private static let refreshItem = NSToolbarItem.Identifier("aggiorna")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.zoomItem, Self.pathItem, .flexibleSpace, Self.refreshItem, Self.finderItem, Self.trashItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.zoomItem:
            let seg = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Esci"))!,
                                                  NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Entra"))!],
                                         trackingMode: .momentary, target: self, action: #selector(zoomSegment(_:)))
            seg.segmentStyle = .separated
            zoomButtons = seg
            item.view = seg
            item.label = L("Esci / Entra")
            item.toolTip = L("Esci dalla cartella (⌘[) / Entra nella scelta (↩)")
        case Self.pathItem:
            let pc = NSPathControl()
            pc.pathStyle = .standard
            pc.controlSize = .small
            pc.target = self
            pc.action = #selector(pathClicked(_:))
            pc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pc.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            pc.widthAnchor.constraint(lessThanOrEqualToConstant: 700).isActive = true
            pathControl = pc
            item.view = pc
            item.label = L("Cartella mostrata")
        case Self.finderItem:
            configure(item, L("Mostra nel Finder"), "finder", #selector(revealInFinder(_:)), L("Mostra nel Finder (⌘R)"))
        case Self.trashItem:
            configure(item, L("Cestino"), "trash", #selector(moveToTrash(_:)), L("Sposta nel Cestino (⌘⌫)"))
        case Self.refreshItem:
            configure(item, L("Aggiorna"), "arrow.clockwise", #selector(refresh(_:)), L("Rileggi dal disco la cartella scelta (⇧⌘R)"))
        default:
            return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ symbol: String, _ action: Selector, _ tip: String) {
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        item.toolTip = tip
        item.isBordered = true
    }

    @objc private func zoomSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { zoomOut(nil) } else { zoomIn(nil) }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        zoomTo(component: url)
    }

    private func updateToolbar() {
        guard let doc = model else { return }
        pathControl?.url = URL(fileURLWithPath: doc.tree.path(of: zoom))
        zoomButtons?.setEnabled(zoom.parent != nil, forSegment: 0)
    }

    // MARK: Anteprima (Quick Look)

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

extension DocumentController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedPath == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        URL(fileURLWithPath: selectedPath ?? "/") as NSURL
    }
}

extension Folder {
    func isDescendant(of other: Folder) -> Bool {
        var f: Folder? = self
        while let c = f {
            if c === other { return true }
            f = c.parent
        }
        return false
    }
}

// MARK: avanzamento della scansione

final class ScanProgress: ObservableObject {
    @Published var files = 0
    @Published var folders = 0
    @Published var bytes: UInt64 = 0
    @Published var seconds = 0.0
    @Published var cancelling = false
    let path: String
    private var timer: Timer?

    init(scanner: DiskScanner, path: String) {
        self.path = path
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak scanner] _ in
            guard let self, let scanner else { return }
            files = scanner.files.load(ordering: .relaxed)
            folders = scanner.folders.load(ordering: .relaxed)
            bytes = scanner.bytes.load(ordering: .relaxed)
            seconds = Date().timeIntervalSince(start)
            cancelling = scanner.isCancelled
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct ScanProgressView: View {
    @ObservedObject var progress: ScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(verbatim: L("Leggo %@", progress.path))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: L("%@ file in %@ cartelle · %@", Format.count(progress.files), Format.count(progress.folders), Format.size(progress.bytes)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(verbatim: String(format: "%.1f s", progress.seconds))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Button(progress.cancelling ? L("Annullo…") : L("Annulla"), action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(progress.cancelling)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
