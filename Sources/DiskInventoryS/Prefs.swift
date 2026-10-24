// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import DiskInventoryCore

/// The settings, in UserDefaults. Whoever changes them posts `Prefs.changed`: open windows
/// redraw (map, units) or apply it at the next scan (scan options).
enum Prefs {
    static let changed = Notification.Name("SettingsChanged")

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
            Key.spotlight: true,
            Key.colorTone: Palette.Tone.original.rawValue,
            Key.coloredKinds: 12,
            Key.edges: false,
            Key.countSharedOnce: true,
            Key.crossVolumes: false,
            Key.skipNames: "",
            Key.openPackages: false,
            Key.showSpace: true,
            Key.purgeableIsFree: false,
        ])
    }

    enum Key {
        static let logicalSize = "logicalSize"
        static let binaryUnits = "binaryUnits"
        static let confirmTrash = "confirmTrash"
        static let atLaunch = "atLaunch"
        static let lastFolder = "lastFolder"
        static let cushionHeight = "cushionHeight"
        static let ambientLight = "ambientLight"
        static let hoverFrame = "hoverFrame"
        static let spotlight = "spotlight"
        static let colorTone = "colorTone"
        static let coloredKinds = "coloredKinds"
        static let edges = "edges"
        static let countSharedOnce = "countSharedOnce"
        static let crossVolumes = "crossVolumes"
        static let skipNames = "skipNames"
        static let openPackages = "openPackages"
        static let showSpace = "showSpace"
        static let purgeableIsFree = "purgeableIsFree"
    }

    enum Launch: String { case disks, lastFolder, nothing }

    // general
    static var logicalSize: Bool { d.bool(forKey: Key.logicalSize) }
    static var binaryUnits: Bool { d.bool(forKey: Key.binaryUnits) }
    static var confirmTrash: Bool { d.bool(forKey: Key.confirmTrash) }
    static var atLaunch: Launch { Launch(rawValue: d.string(forKey: Key.atLaunch) ?? "") ?? .disks }
    static var lastFolder: String? {
        get { d.string(forKey: Key.lastFolder) }
        set { d.set(newValue, forKey: Key.lastFolder) }
    }

    // map
    static var cushionHeight: Double { d.double(forKey: Key.cushionHeight) }
    static var ambientLight: Double { d.double(forKey: Key.ambientLight) }
    static var hoverFrame: Bool { d.bool(forKey: Key.hoverFrame) }
    static var spotlight: Bool { d.bool(forKey: Key.spotlight) }
    static var colorTone: Palette.Tone { Palette.Tone(rawValue: d.string(forKey: Key.colorTone) ?? "") ?? .original }
    static var coloredKinds: Int { d.integer(forKey: Key.coloredKinds) }
    static var edges: Bool { d.bool(forKey: Key.edges) }

    // scan
    static var scanOptions: ScanOptions {
        let names = d.string(forKey: Key.skipNames) ?? ""
        let skip = Set(names.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return ScanOptions(countSharedOnce: d.bool(forKey: Key.countSharedOnce), crossVolumes: d.bool(forKey: Key.crossVolumes), skipNames: skip)
    }
    static var openPackages: Bool { d.bool(forKey: Key.openPackages) }

    // space
    static var showSpace: Bool { d.bool(forKey: Key.showSpace) }
    static var purgeableIsFree: Bool { d.bool(forKey: Key.purgeableIsFree) }
}
