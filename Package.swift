// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inventario",
    platforms: [.macOS(.v15)],
    targets: [
        // la scansione, l'albero, i tipi di file e la mappa: niente interfaccia
        .target(name: "InventarioCore"),
        // la finestra (AppKit)
        .executableTarget(name: "Inventario", dependencies: ["InventarioCore"]),
        // misure da terminale: scansione e disegno con i tempi
        .executableTarget(name: "inventario-cli", dependencies: ["InventarioCore"]),
        // le prove: senza Xcode il framework Testing non gira, quindi un eseguibile
        .executableTarget(name: "inventario-prove", dependencies: ["InventarioCore"]),
    ],
    swiftLanguageModes: [.v5]
)
