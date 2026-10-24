import AppKit
import InventarioCore
import SwiftUI

/// La finestra delle impostazioni (⌘,): Generale, Mappa, Scansione, Spazio.
final class PreferencesWindow {
    private static var window: NSWindow?

    static func show(tab: Int = 0) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        PreferencesView.firstTab = tab
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("Impostazioni")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PreferencesView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func photograph(to path: String) {
        guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

struct PreferencesView: View {
    static var firstTab = 0
    @State private var tab = PreferencesView.firstTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label(L("Generale"), systemImage: "gearshape") }.tag(0)
            MapPane().tabItem { Label(L("Mappa"), systemImage: "square.grid.3x3.square") }.tag(1)
            ScanPane().tabItem { Label(L("Scansione"), systemImage: "magnifyingglass") }.tag(2)
            SpacePane().tabItem { Label(L("Spazio"), systemImage: "internaldrive") }.tag(3)
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// avvisa le finestre aperte
private func notify() {
    NotificationCenter.default.post(name: Prefs.changed, object: nil)
}

/// una nota grigia sotto un'impostazione
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @AppStorage(Prefs.Key.logicalSize) private var logical = false
    @AppStorage(Prefs.Key.binaryUnits) private var binary = false
    @AppStorage(Prefs.Key.confirmTrash) private var confirmTrash = true
    @AppStorage(Prefs.Key.atLaunch) private var atLaunch = Prefs.Launch.disks.rawValue
    @State private var language = Language.current
    @State private var languageChanged = false

    var body: some View {
        Form {
            Picker(L("Dimensione"), selection: $logical) {
                Text(L("Su disco (quello che si libera cancellando)")).tag(false)
                Text(L("Logica (la lunghezza del contenuto)")).tag(true)
            }
            .pickerStyle(.radioGroup)
            Note(L("Per le finestre nuove; in una finestra aperta si cambia dal menu Vista."))
            Picker(L("Unità"), selection: $binary) {
                Text(L("Decimali: 1 GB = 1000 MB, come il Finder")).tag(false)
                Text(L("Binarie: 1 GiB = 1024 MiB")).tag(true)
            }
            .pickerStyle(.radioGroup)
            Toggle(L("Chiedi conferma prima di spostare nel Cestino"), isOn: $confirmTrash)
            Picker(L("All'avvio"), selection: $atLaunch) {
                Text(L("La finestra dei dischi")).tag(Prefs.Launch.disks.rawValue)
                Text(L("L'ultima cartella letta")).tag(Prefs.Launch.lastFolder.rawValue)
                Text(L("Niente")).tag(Prefs.Launch.nothing.rawValue)
            }
            Picker(L("Lingua"), selection: $language) {
                ForEach(Language.all, id: \.self) { Text($0.name).tag($0) }
            }
            .onChange(of: language) { _, l in
                l.apply()
                languageChanged = true
            }
            if languageChanged {
                HStack {
                    Note(L("La lingua cambia al prossimo avvio."))
                    Button(L("Riavvia ora"), action: relaunch)
                }
            }
        }
        .onChange(of: binary) { _, _ in notify() }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // aspetta che questa copia sia uscita, poi la riapre
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Le lingue dell'interfaccia. «Come il sistema» toglie la scelta dell'app.
struct Language: Hashable {
    let code: String?
    let name: String

    static let all: [Language] = [
        Language(code: nil, name: L("Come il sistema")),
        Language(code: "it", name: "Italiano"),
        Language(code: "en", name: "English"),
        Language(code: "es", name: "Español"),
        Language(code: "fr", name: "Français"),
        Language(code: "de", name: "Deutsch"),
        Language(code: "zh-Hans", name: "简体中文"),
        Language(code: "ja", name: "日本語"),
    ]

    static var current: Language {
        let chosen = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return all.first { $0.code != nil && $0.code == chosen?.first } ?? all[0]
    }

    func apply() {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

private struct MapPane: View {
    @AppStorage(Prefs.Key.cushionHeight) private var height = 0.5
    @AppStorage(Prefs.Key.ambientLight) private var ambient = 0.15
    @AppStorage(Prefs.Key.hoverFrame) private var hover = true
    @AppStorage(Prefs.Key.coloredKinds) private var colored = 12
    @AppStorage(Prefs.Key.edges) private var edges = false

    var body: some View {
        Form {
            Slider(value: $height, in: 0 ... 1.5) {
                Text(L("Rilievo dei cuscini"))
            } minimumValueLabel: {
                Text(L("piatti")).font(.caption)
            } maximumValueLabel: {
                Text(L("alti")).font(.caption)
            }
            Slider(value: $ambient, in: 0 ... 0.6) {
                Text(L("Luce nelle ombre"))
            } minimumValueLabel: {
                Text(L("scure")).font(.caption)
            } maximumValueLabel: {
                Text(L("chiare")).font(.caption)
            }
            Toggle(L("Una riga scura fra un file e l'altro"), isOn: $edges)
            Toggle(L("Un bordo sul file sotto il puntatore"), isOn: $hover)
            Picker(L("Tipi colorati"), selection: $colored) {
                Text(L("I 12 più grandi (come l'originale)")).tag(12)
                Text(L("I 24 più grandi")).tag(24)
            }
            Note(L("Gli altri tipi sono grigi."))
            HStack {
                Spacer()
                Button(L("Come l'originale")) {
                    height = 0.5
                    ambient = 0.15
                    edges = false
                    hover = true
                    colored = 12
                }
            }
        }
        .onChange(of: height) { _, _ in notify() }
        .onChange(of: ambient) { _, _ in notify() }
        .onChange(of: edges) { _, _ in notify() }
        .onChange(of: hover) { _, _ in notify() }
        .onChange(of: colored) { _, _ in notify() }
    }
}

private struct ScanPane: View {
    @AppStorage(Prefs.Key.countSharedOnce) private var sharedOnce = true
    @AppStorage(Prefs.Key.crossVolumes) private var crossVolumes = false
    @AppStorage(Prefs.Key.skipNames) private var skipNames = ""
    @AppStorage(Prefs.Key.openPackages) private var openPackages = false

    var body: some View {
        Form {
            Toggle(L("Conta una volta sola i cloni di APFS e i collegamenti fissi"), isOn: $sharedOnce)
            Note(L("Come du. Il Finder e Disk Inventory X li contano ogni volta, e un disco può sembrare più pieno di quanto sia."))
            Toggle(L("Entra negli altri volumi (dischi esterni) dentro la cartella"), isOn: $crossVolumes)
            Toggle(L("Apri i pacchetti (applicazioni, librerie di Foto…)"), isOn: $openPackages)
            TextField(L("Cartelle da saltare"), text: $skipNames, prompt: Text(verbatim: "node_modules, .git"))
            Note(L("Nomi separati da virgole. Restano nella mappa come cartelle vuote."))
            Note(L("Queste scelte valgono dalla prossima lettura."))
        }
    }
}

private struct SpacePane: View {
    @AppStorage(Prefs.Key.showSpace) private var show = true
    @AppStorage(Prefs.Key.purgeableIsFree) private var purgeable = false

    var body: some View {
        Form {
            Toggle(L("Quando leggo un disco intero, mostra anche lo spazio che non è nei file"), isOn: $show)
            VStack(alignment: .leading, spacing: 6) {
                legend(Tree.Space.free, L("lo spazio ancora disponibile."))
                legend(Tree.Space.system, L("gli altri volumi dello stesso disco: memoria virtuale, Preboot, Recovery, aggiornamenti di macOS."))
                legend(Tree.Space.hidden, L("occupato ma non leggibile come file: cartelle protette (con l'Accesso completo al disco diventa più piccolo), istantanee di Time Machine, dati del file system."))
            }
            .padding(.leading, 20)
            Toggle(L("Conta come libero anche lo spazio eliminabile, come il Finder"), isOn: $purgeable)
            Note(L("Lo spazio eliminabile (cache, copie locali di iCloud) il sistema lo libera da sé quando serve."))
        }
        .onChange(of: show) { _, _ in notify() }
        .onChange(of: purgeable) { _, _ in notify() }
    }

    private func legend(_ space: Tree.Space, _ text: String) -> some View {
        (Text(space.name).bold() + Text(verbatim: ": ") + Text(text))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
