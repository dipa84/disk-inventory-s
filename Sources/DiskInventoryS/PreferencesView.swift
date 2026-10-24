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
import SwiftUI

/// The settings window (⌘,): General, Map, Scan, Space.
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
        w.title = L("Settings")
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
            GeneralPane().tabItem { Label(L("General"), systemImage: "gearshape") }.tag(0)
            MapPane().tabItem { Label(L("Map"), systemImage: "square.grid.3x3.square") }.tag(1)
            ScanPane().tabItem { Label(L("Scan"), systemImage: "magnifyingglass") }.tag(2)
            SpacePane().tabItem { Label(L("Space"), systemImage: "internaldrive") }.tag(3)
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// tells the open windows
private func notify() {
    NotificationCenter.default.post(name: Prefs.changed, object: nil)
}

/// a gray note under a setting
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
            Picker(L("Size"), selection: $logical) {
                Text(L("On disk (what deleting frees)")).tag(false)
                Text(L("Logical (the length of the content)")).tag(true)
            }
            .pickerStyle(.radioGroup)
            Note(L("For new windows; in an open window, change it from the View menu."))
            Picker(L("Units"), selection: $binary) {
                Text(L("Decimal: 1 GB = 1000 MB, like the Finder")).tag(false)
                Text(L("Binary: 1 GiB = 1024 MiB")).tag(true)
            }
            .pickerStyle(.radioGroup)
            Toggle(L("Ask before moving to the Trash"), isOn: $confirmTrash)
            Picker(L("At launch"), selection: $atLaunch) {
                Text(L("The disks window")).tag(Prefs.Launch.disks.rawValue)
                Text(L("The last folder read")).tag(Prefs.Launch.lastFolder.rawValue)
                Text(L("Nothing")).tag(Prefs.Launch.nothing.rawValue)
            }
            Picker(L("Language"), selection: $language) {
                ForEach(Language.all, id: \.self) { Text($0.name).tag($0) }
            }
            .onChange(of: language) { _, l in
                l.apply()
                languageChanged = true
            }
            if languageChanged {
                HStack {
                    Note(L("The language changes at the next launch."))
                    Button(L("Relaunch Now"), action: relaunch)
                }
            }
        }
        .onChange(of: binary) { _, _ in notify() }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // waits for this copy to quit, then opens it again
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The interface languages. “Same as the system” removes the app's own choice.
struct Language: Hashable {
    let code: String?
    let name: String

    static let all: [Language] = [
        Language(code: nil, name: L("Same as the system")),
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
    @AppStorage(Prefs.Key.spotlight) private var spotlight = true
    @AppStorage(Prefs.Key.colorTone) private var tone = Palette.Tone.original.rawValue
    @AppStorage(Prefs.Key.coloredKinds) private var colored = 12
    @AppStorage(Prefs.Key.edges) private var edges = false

    var body: some View {
        Form {
            Slider(value: $height, in: 0 ... 1.5) {
                Text(L("Cushion relief"))
            } minimumValueLabel: {
                Text(L("flat")).font(.caption)
            } maximumValueLabel: {
                Text(L("high")).font(.caption)
            }
            Slider(value: $ambient, in: 0 ... 0.6) {
                Text(L("Light in the shadows"))
            } minimumValueLabel: {
                Text(L("dark")).font(.caption)
            } maximumValueLabel: {
                Text(L("light")).font(.caption)
            }
            Picker(L("Colors"), selection: $tone) {
                Text(L("Like the original")).tag(Palette.Tone.original.rawValue)
                Text(L("Vivid")).tag(Palette.Tone.vivid.rawValue)
                Text(L("Soft pastel")).tag(Palette.Tone.pastel.rawValue)
            }
            Toggle(L("A dark line between files"), isOn: $edges)
            Toggle(L("A frame on the file under the pointer"), isOn: $hover)
            Toggle(L("Spotlight on the folder under the pointer (hold ⌘ for the one above)"), isOn: $spotlight)
            Picker(L("Colored kinds"), selection: $colored) {
                Text(L("The 12 largest (like the original)")).tag(12)
                Text(L("The 24 largest")).tag(24)
            }
            Note(L("The other kinds are gray."))
            HStack {
                Spacer()
                Button(L("Like the Original")) {
                    height = 0.5
                    ambient = 0.15
                    edges = false
                    hover = true
                    spotlight = true
                    tone = Palette.Tone.original.rawValue
                    colored = 12
                }
            }
        }
        .onChange(of: height) { _, _ in notify() }
        .onChange(of: ambient) { _, _ in notify() }
        .onChange(of: edges) { _, _ in notify() }
        .onChange(of: hover) { _, _ in notify() }
        .onChange(of: spotlight) { _, _ in notify() }
        .onChange(of: tone) { _, _ in notify() }
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
            Toggle(L("Count APFS clones and hard links only once"), isOn: $sharedOnce)
            Note(L("Like du. The Finder and Disk Inventory X count them every time, and a disk can look fuller than it is."))
            Toggle(L("Go into other volumes (external disks) inside the folder"), isOn: $crossVolumes)
            Toggle(L("Open packages (apps, Photos libraries…)"), isOn: $openPackages)
            TextField(L("Folders to skip"), text: $skipNames, prompt: Text(verbatim: "node_modules, .git"))
            Note(L("Names separated by commas. They stay in the map as empty folders."))
            Note(L("These choices apply from the next scan."))
        }
    }
}

private struct SpacePane: View {
    @AppStorage(Prefs.Key.showSpace) private var show = true
    @AppStorage(Prefs.Key.purgeableIsFree) private var purgeable = false

    var body: some View {
        Form {
            Toggle(L("When reading a whole disk, also show the space that isn’t in files"), isOn: $show)
            VStack(alignment: .leading, spacing: 6) {
                legend(Tree.Space.free, L("the space still available."))
                legend(Tree.Space.system, L("the disk’s other volumes: virtual memory, Preboot, Recovery, macOS updates."))
                legend(Tree.Space.unread, L("the folders that couldn’t be read: system ones are read with the button at the bottom of the window (it asks for the password), private ones with Full Disk Access."))
                legend(Tree.Space.filesystem, L("once everything has been read, what remains: the file system’s indexes and tables."))
            }
            .padding(.leading, 20)
            Toggle(L("Count purgeable space as free too, like the Finder"), isOn: $purgeable)
            Note(L("The system frees purgeable space (caches, local iCloud copies) by itself when needed."))
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
