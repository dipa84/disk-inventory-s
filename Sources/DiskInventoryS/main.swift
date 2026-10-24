import AppKit
import DiskInventoryCore
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
        // from the terminal: DiskInventoryS <folder>; options (-AppleLanguages "(ja)") and their values are not folders
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            if a.hasPrefix("-") {
                if !args.isEmpty { args.removeFirst() }
            } else {
                open(path: (a as NSString).expandingTildeInPath)
            }
        }
        // DIS_SETTINGS_PHOTO=file.png DIS_SETTINGS_TAB=n: an image of the settings (for testing)
        if let photo = ProcessInfo.processInfo.environment["DIS_SETTINGS_PHOTO"] {
            PreferencesWindow.show(tab: Int(ProcessInfo.processInfo.environment["DIS_SETTINGS_TAB"] ?? "") ?? 0)
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
        panel.prompt = L("Read")
        panel.message = L("Choose the folder or disk to examine")
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
            item(L("About %@", "Disk Inventory S"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(L("Settings…"), #selector(showPreferences(_:)), ","),
            .separator(),
            item(L("Hide %@", "Disk Inventory S"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Quit %@", "Disk Inventory S"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu(L("File"), [
            item(L("Read a Folder…"), #selector(openFolder(_:)), "o"),
            item(L("Disks"), #selector(showStart(_:)), "o", [.command, .shift]),
            .separator(),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu(L("Edit"), [
            item(L("Copy Path"), #selector(DocumentController.copyPath(_:)), "c", [.command, .option]),
        ])
        menu(L("Item"), [
            item(L("Open"), #selector(DocumentController.openSelection(_:)), down, [.command, .option]),
            item(L("Show in Finder"), #selector(DocumentController.revealInFinder(_:)), "r"),
            item(L("Quick Look"), #selector(DocumentController.quickLook(_:)), "y"),
            .separator(),
            item(L("Select Enclosing Folder"), #selector(DocumentController.selectParent(_:)), up),
            item(L("Select Largest Item Inside"), #selector(DocumentController.selectChild(_:)), down),
            .separator(),
            item(L("Refresh"), #selector(DocumentController.refresh(_:)), "r", [.command, .shift]),
            item(L("Refresh All"), #selector(DocumentController.refreshAll(_:))),
            .separator(),
            item(L("Move to Trash"), #selector(DocumentController.moveToTrash(_:)), backspace),
        ])
        menu(L("View"), [
            item(L("Go Into Selection"), #selector(DocumentController.zoomIn(_:))),
            item(L("Go Out of Folder"), #selector(DocumentController.zoomOut(_:)), "["),
            item(L("Go Back In"), #selector(DocumentController.zoomForward(_:)), "]"),
            item(L("Whole Folder"), #selector(DocumentController.zoomToTop(_:)), "[", [.command, .shift]),
            .separator(),
            item(L("Logical Size (Instead of On Disk)"), #selector(DocumentController.toggleSizeMode(_:))),
            item(L("Open Packages"), #selector(DocumentController.togglePackages(_:))),
            item(L("Free Space, System Volumes and Hidden Space"), #selector(DocumentController.toggleSpecialSpace(_:))),
            .separator(),
            item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = NSMenu(title: L("Window"))
        window.addItem(item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L("Zoom"), #selector(NSWindow.performZoom(_:))))
        let top = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        top.submenu = window
        main.addItem(top)
        NSApp.windowsMenu = window
        return main
    }
}

// MARK: the start window: the disks

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
            Text(verbatim: L("What’s taking up the disk?"))
                .font(.title2.weight(.semibold))
            List(volumes) { v in
                Button { open(v.id.path) } label: {
                    HStack(spacing: 12) {
                        Image(nsImage: v.icon).resizable().frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.name).font(.headline)
                            ProgressView(value: Double(v.total - v.available), total: Double(max(v.total, 1)))
                            Text(verbatim: L("%@ used of %@ · %@ free", Format.size(UInt64(max(0, v.total - v.available))), Format.size(UInt64(max(0, v.total))), Format.size(UInt64(max(0, v.available)))))
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
                Text(verbatim: L("You can also drag a folder onto the %@ icon.", "Disk Inventory S"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Read a Folder…"), action: choose)
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
