import AppKit
import InventarioCore
import SwiftUI

setlinebuf(stdout)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: [DocumentController] = []
    private var start: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSApp.mainMenu = makeMenu()
        // da terminale: Inventario <cartella>; le opzioni (-AppleLanguages "(ja)") col loro valore no
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            if a.hasPrefix("-") {
                if !args.isEmpty { args.removeFirst() }
            } else {
                open(path: (a as NSString).expandingTildeInPath)
            }
        }
        // INVENTARIO_IMPOSTAZIONI=file.png INVENTARIO_SCHEDA=n: un'immagine delle impostazioni (per le prove)
        if let photo = ProcessInfo.processInfo.environment["INVENTARIO_IMPOSTAZIONI"] {
            PreferencesWindow.show(tab: Int(ProcessInfo.processInfo.environment["INVENTARIO_SCHEDA"] ?? "") ?? 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PreferencesWindow.photograph(to: photo)
                NSApp.terminate(nil)
            }
            return
        }
        if documents.isEmpty {
            switch Prefs.atLaunch {
            case .disks: showStart(nil)
            case .lastFolder:
                if let last = Prefs.lastFolder, FileManager.default.fileExists(atPath: last) { open(path: last) } else { showStart(nil) }
            case .nothing: break
            }
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { open(path: u.path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStart(nil) }
        return true
    }

    func open(path: String, replacing old: DocumentController? = nil) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        let doc = DocumentController(path: path)
        documents.append(doc)
        if let old, let w = old.window {
            doc.window?.setFrame(w.frame, display: false)
            old.close()
        } else if let key = documents.dropLast().last?.window {
            doc.window?.setFrame(key.frame.offsetBy(dx: 24, dy: -24), display: false)
        } else {
            doc.window?.center()
        }
        doc.showWindow(nil)
        start?.close()
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
    }

    func closed(_ doc: DocumentController) {
        documents.removeAll { $0 === doc }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Leggi")
        panel.message = L("Scegli la cartella o il disco da esaminare")
        if panel.runModal() == .OK, let url = panel.url { open(path: url.path) }
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindow.show()
    }

    @objc func showStart(_ sender: Any?) {
        if let start {
            start.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Disk Inventory S"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: StartView(open: { [weak self] in self?.open(path: $0) },
                                                          choose: { [weak self] in self?.openFolder(nil) }))
        w.center()
        w.makeKeyAndOrderFront(nil)
        start = w
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))

        menu("Disk Inventory S", [
            item(L("Informazioni su %@", "Disk Inventory S"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(L("Impostazioni…"), #selector(showPreferences(_:)), ","),
            .separator(),
            item(L("Nascondi %@", "Disk Inventory S"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Nascondi altre"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Mostra tutte"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Esci da %@", "Disk Inventory S"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu(L("Archivio"), [
            item(L("Leggi una cartella…"), #selector(openFolder(_:)), "o"),
            item(L("Dischi"), #selector(showStart(_:)), "o", [.command, .shift]),
            .separator(),
            item(L("Chiudi"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu(L("Modifica"), [
            item(L("Copia il percorso"), #selector(DocumentController.copyPath(_:)), "c", [.command, .option]),
        ])
        menu(L("Scelta"), [
            item(L("Apri"), #selector(DocumentController.openSelection(_:)), down, [.command, .option]),
            item(L("Mostra nel Finder"), #selector(DocumentController.revealInFinder(_:)), "r"),
            item(L("Anteprima"), #selector(DocumentController.quickLook(_:)), "y"),
            .separator(),
            item(L("Scegli la cartella che la contiene"), #selector(DocumentController.selectParent(_:)), up),
            item(L("Scegli la voce più grande dentro"), #selector(DocumentController.selectChild(_:)), down),
            .separator(),
            item(L("Aggiorna"), #selector(DocumentController.refresh(_:)), "r", [.command, .shift]),
            item(L("Aggiorna tutto"), #selector(DocumentController.refreshAll(_:))),
            .separator(),
            item(L("Sposta nel Cestino"), #selector(DocumentController.moveToTrash(_:)), backspace),
        ])
        menu(L("Vista"), [
            item(L("Entra nella scelta"), #selector(DocumentController.zoomIn(_:))),
            item(L("Esci dalla cartella"), #selector(DocumentController.zoomOut(_:)), "["),
            item(L("Torna dentro"), #selector(DocumentController.zoomForward(_:)), "]"),
            item(L("Tutta la cartella"), #selector(DocumentController.zoomToTop(_:)), "[", [.command, .shift]),
            .separator(),
            item(L("Dimensione logica (invece che su disco)"), #selector(DocumentController.toggleSizeMode(_:))),
            item(L("Apri i pacchetti"), #selector(DocumentController.togglePackages(_:))),
            item(L("Spazio libero, volumi di sistema e spazio nascosto"), #selector(DocumentController.toggleSpecialSpace(_:))),
            .separator(),
            item(L("Schermo intero"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = NSMenu(title: L("Finestra"))
        window.addItem(item(L("Contrai"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L("Ridimensiona"), #selector(NSWindow.performZoom(_:))))
        let top = NSMenuItem(title: L("Finestra"), action: nil, keyEquivalent: "")
        top.submenu = window
        main.addItem(top)
        NSApp.windowsMenu = window
        return main
    }
}

// MARK: la finestra iniziale: i dischi

struct Volume: Identifiable {
    let id: URL
    let name: String
    let total: Int64
    let available: Int64
    let icon: NSImage
    let isInternal: Bool
}

struct StartView: View {
    let open: (String) -> Void
    let choose: () -> Void
    @State private var volumes: [Volume] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L("Che cosa occupa il disco?"))
                .font(.title2.weight(.semibold))
            List(volumes) { v in
                Button { open(v.id.path) } label: {
                    HStack(spacing: 12) {
                        Image(nsImage: v.icon).resizable().frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.name).font(.headline)
                            ProgressView(value: Double(v.total - v.available), total: Double(max(v.total, 1)))
                            Text(verbatim: L("%@ usati di %@ · %@ liberi", Format.size(UInt64(max(0, v.total - v.available))), Format.size(UInt64(max(0, v.total))), Format.size(UInt64(max(0, v.available)))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            HStack {
                Text(verbatim: L("Si può anche trascinare una cartella sull'icona di %@.", "Disk Inventory S"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Leggi una cartella…"), action: choose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear(perform: load)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in load() }
    }

    private func load() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return Volume(id: u, name: v.volumeLocalizedName ?? u.lastPathComponent, total: Int64(v.volumeTotalCapacity ?? 0),
                          available: available, icon: NSWorkspace.shared.icon(forFile: u.path), isInternal: v.volumeIsInternal ?? false)
        }
    }
}
