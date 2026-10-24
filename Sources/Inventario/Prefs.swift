import Foundation
import InventarioCore

/// Le preferenze, in UserDefaults. Chi le cambia manda `Prefs.changed`: le finestre aperte si
/// ridisegnano (la mappa, le unità) o lo applicano alla prossima lettura (la scansione).
enum Prefs {
    static let changed = Notification.Name("PreferenzeCambiate")

    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            Key.logicalSize: false,
            Key.binaryUnits: false,
            Key.confirmTrash: true,
            Key.atLaunch: Launch.disks.rawValue,
            Key.cushionHeight: 0.5,
            Key.ambientLight: 0.15,
            Key.hoverFrame: true,
            Key.coloredKinds: 12,
            Key.edges: false,
            Key.countSharedOnce: true,
            Key.crossVolumes: false,
            Key.skipNames: "",
            Key.openPackages: false,
            Key.showSpace: true,
            Key.purgeableIsFree: true,
        ])
    }

    enum Key {
        static let logicalSize = "dimensioneLogica"
        static let binaryUnits = "unitaBinarie"
        static let confirmTrash = "confermaCestino"
        static let atLaunch = "allAvvio"
        static let lastFolder = "ultimaCartella"
        static let cushionHeight = "altezzaCuscini"
        static let ambientLight = "luceAmbiente"
        static let hoverFrame = "bordoSottoPuntatore"
        static let coloredKinds = "tipiColorati"
        static let edges = "bordiFraFile"
        static let countSharedOnce = "condivisiUnaVolta"
        static let crossVolumes = "attraversaVolumi"
        static let skipNames = "cartelleDaSaltare"
        static let openPackages = "pacchettiAperti"
        static let showSpace = "mostraSpazio"
        static let purgeableIsFree = "eliminabileLibero"
    }

    enum Launch: String { case disks, lastFolder, nothing }

    // generale
    static var logicalSize: Bool { d.bool(forKey: Key.logicalSize) }
    static var binaryUnits: Bool { d.bool(forKey: Key.binaryUnits) }
    static var confirmTrash: Bool { d.bool(forKey: Key.confirmTrash) }
    static var atLaunch: Launch { Launch(rawValue: d.string(forKey: Key.atLaunch) ?? "") ?? .disks }
    static var lastFolder: String? {
        get { d.string(forKey: Key.lastFolder) }
        set { d.set(newValue, forKey: Key.lastFolder) }
    }

    // mappa
    static var cushionHeight: Double { d.double(forKey: Key.cushionHeight) }
    static var ambientLight: Double { d.double(forKey: Key.ambientLight) }
    static var hoverFrame: Bool { d.bool(forKey: Key.hoverFrame) }
    static var coloredKinds: Int { d.integer(forKey: Key.coloredKinds) }
    static var edges: Bool { d.bool(forKey: Key.edges) }

    // scansione
    static var scanOptions: ScanOptions {
        let names = d.string(forKey: Key.skipNames) ?? ""
        let skip = Set(names.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return ScanOptions(countSharedOnce: d.bool(forKey: Key.countSharedOnce), crossVolumes: d.bool(forKey: Key.crossVolumes), skipNames: skip)
    }
    static var openPackages: Bool { d.bool(forKey: Key.openPackages) }

    // spazio
    static var showSpace: Bool { d.bool(forKey: Key.showSpace) }
    static var purgeableIsFree: Bool { d.bool(forKey: Key.purgeableIsFree) }
}
