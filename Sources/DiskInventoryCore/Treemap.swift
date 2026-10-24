// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
// Based on Disk Inventory X (TMVItem.m, TMVCushionRenderer.m, FileTypeColors.m),
// Copyright (C) 2003-2022 Tjark Derlien, GPL-3.0-or-later.
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A tile of the map: an entry of a folder (file or folder) and where it is, in pixels.
public struct Cell {
    public unowned(unsafe) let folder: Folder
    /// the entry in `folder.entries`; -1 for the starting folder (the map's root)
    public let entry: Int32
    public var x0: Int32, y0: Int32, x1: Int32, y1: Int32
    /// the children in `Treemap.cells`, one after the other
    public var firstChild: Int32 = -1
    public var childCount: Int32 = 0

    public var width: Int { Int(x1 - x0) }
    public var height: Int { Int(y1 - y0) }
    public func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
}

/// Disk Inventory X's treemap (van Wijk and van de Wetering's cushions, with the rows of
/// SequoiaView/WinDirStat) ported from TMVItem.m and TMVCushionRenderer.m.
///
/// The layout is in whole pixels; a tile smaller than `minSide` pixels is not divided further.
/// Drawing is done in horizontal bands, one per core: each pixel belongs to a single leaf, so
/// the bands never touch.
/// How the cushions look (from the settings).
public struct CushionStyle: Sendable {
    /// the relief of the first level (the original: 0.5); 0 is flat
    public var height = 0.5
    /// the light that reaches even where the cushion is not lit (the original: 0.15)
    public var ambient = 0.15
    /// a dark line between files
    public var edges = false

    public init(height: Double = 0.5, ambient: Double = 0.15, edges: Bool = false) {
        self.height = height
        self.ambient = ambient
        self.edges = edges
    }

    /// How flat the map is, from 0 (the original's relief or more) to 1 (no relief at all).
    /// Without relief the cushions no longer show where folders end, so the flatter the map,
    /// the more its folder and file borders are drawn.
    var flatness: Double { max(0, min(1, 1 - height / 0.4)) }

    /// The original's brightness puts every cushion's top close to white (its sheen). A flat
    /// tile is all top, so the sheen fades out with the relief and flat colors stay full.
    var brightnessScale: Double {
        let len = (1.0 + 1.0 + 100.0).squareRoot()
        let flatTop = (1 - ambient) * 10 / len + ambient
        let f = min(1, height / 0.5)
        return 2.5 / Palette.baseBrightness * f + 1 / flatTop * (1 - f)
    }
}

public final class Treemap {
    public private(set) var cells: [Cell] = []
    public let width: Int, height: Int
    /// the leaves to draw: tile index and cushion surface
    private var leaves: [(cell: Int32, surface: SIMD4<Double>)] = []
    /// the folders divided into tiles, for their borders
    private var folders: [Int32] = []

    /// - Parameters:
    ///   - isLeaf: whether an entry is drawn whole (files, closed packages, empty folders)
    ///   - minSide: the smallest side, in pixels, for a tile to be divided (1 point on screen)
    public let style: CushionStyle

    public init(folder: Folder, entry: Int32, width: Int, height: Int, mode: SizeMode, minSide: Int,
                style: CushionStyle = CushionStyle(), isLeaf: (Folder, Int) -> Bool) {
        self.style = style
        self.width = width
        self.height = height
        cells.reserveCapacity(1024)
        cells.append(Cell(folder: folder, entry: entry, x0: 0, y0: 0, x1: Int32(width), y1: Int32(height)))
        guard width > 0, height > 0 else { return }
        layout(0, surface: .zero, height: style.height, mode: mode, minSide: max(1, minSide), isLeaf: isLeaf)
    }

    /// the folder whose contents the tile shows, if it is a folder
    private func contents(of c: Cell) -> Folder? {
        c.entry < 0 ? c.folder : c.folder.subfolder(at: Int(c.entry))
    }

    private static let cushionScale = 0.9
    private static let minProportion = 0.4

    private func layout(_ index: Int, surface: SIMD4<Double>, height h: Double, mode: SizeMode, minSide: Int,
                        isLeaf: (Folder, Int) -> Bool) {
        let c = cells[index]
        let leaf = c.entry >= 0 && isLeaf(c.folder, Int(c.entry))
        guard !leaf, let f = contents(of: c), !f.entries.isEmpty, c.width >= minSide, c.height >= minSide else {
            leaves.append((Int32(index), surface))
            return
        }
        let first = cells.count
        let n = f.entries.count
        if index > 0 { folders.append(Int32(index)) }
        cells[index].firstChild = Int32(first)
        cells[index].childCount = Int32(n)
        for i in 0 ..< n {
            cells.append(Cell(folder: f, entry: Int32(i), x0: c.x0, y0: c.y0, x1: c.x0, y1: c.y0))
        }
        place(parent: c, total: f.size(mode), first: first, entries: f.entries, mode: mode)
        let childHeight = h * Self.cushionScale
        for i in 0 ..< n {
            let k = first + i
            let r = cells[k]
            if r.x1 <= r.x0 || r.y1 <= r.y0 { continue }
            layout(k, surface: Self.ridge(surface, r, childHeight), height: childHeight, mode: mode, minSide: minSide,
                   isLeaf: isLeaf)
        }
    }

    /// TMVItem layoutChilds: the children (already sorted by size) in rows, each row filled until
    /// the tiles get too narrow.
    private func place(parent c: Cell, total: UInt64, first: Int, entries: [Entry], mode: SizeMode) {
        let n = entries.count
        var rows: [(height: Double, count: Int)] = []
        var widths = [Double](repeating: 0, count: n)
        var horizontal = true
        if total == 0 {
            rows.append((1, n))
            for i in 0 ..< n { widths[i] = 1 / Double(n) }
        } else {
            horizontal = c.width >= c.height
            var rowWidth = 1.0
            if horizontal {
                if c.height > 0 { rowWidth = Double(c.width) / Double(c.height) }
            } else if c.width > 0 {
                rowWidth = Double(c.height) / Double(c.width)
            }
            let mySize = Double(total)
            var start = 0
            while start < n {
                var sizeUsed = 0.0, rowHeight = 0.0
                var i = start
                while i < n {
                    let childSize = Double(entries[i].size(mode))
                    if childSize == 0 { break }
                    sizeUsed += childSize
                    let virtualRowHeight = sizeUsed / mySize
                    let childWidth = childSize / mySize * rowWidth / virtualRowHeight
                    if childWidth / virtualRowHeight < Self.minProportion && i > start { break }
                    rowHeight = virtualRowHeight
                    i += 1
                }
                // empty children go at the end of the last row
                if i == start { i += 1 }
                while i < n && entries[i].size(mode) == 0 { i += 1 }
                let used = i - start
                let rowSize = mySize * rowHeight
                for k in 0 ..< used {
                    widths[start + k] = rowSize > 0 ? Double(entries[start + k].size(mode)) / rowSize : 0
                }
                rows.append((rowHeight, used))
                start = i
            }
        }

        let parentWidth = Double(horizontal ? c.width : c.height)
        let parentHeight = Double(horizontal ? c.height : c.width)
        let parentBottom = horizontal ? Int(c.y1) : Int(c.x1)
        let parentRight = horizontal ? Int(c.x1) : Int(c.y1)
        let parentLeft = horizontal ? Int(c.x0) : Int(c.y0)
        var top = horizontal ? Int(c.y0) : Int(c.x0)
        var child = 0
        for (r, row) in rows.enumerated() {
            var bottom = top + Int((row.height * parentHeight).rounded())
            if bottom > parentBottom || r == rows.count - 1 { bottom = parentBottom }
            var left = parentLeft
            for col in 0 ..< row.count {
                var right = left + Int((widths[child] * parentWidth).rounded())
                if right > parentRight || col == row.count - 1 { right = parentRight }
                let k = first + child
                if horizontal {
                    cells[k].x0 = Int32(left); cells[k].x1 = Int32(right)
                    cells[k].y0 = Int32(top); cells[k].y1 = Int32(bottom)
                } else {
                    cells[k].x0 = Int32(top); cells[k].x1 = Int32(bottom)
                    cells[k].y0 = Int32(left); cells[k].y1 = Int32(right)
                }
                left = right
                child += 1
            }
            top = bottom
        }
    }

    /// TMVCushionRenderer addRidgeByHeightFactor
    private static func ridge(_ s: SIMD4<Double>, _ r: Cell, _ h: Double) -> SIMD4<Double> {
        var s = s
        let h4 = 4 * h
        let wf = h4 / Double(r.width)
        s[2] += wf * Double(r.x1 + r.x0)
        s[0] -= wf
        let hf = h4 / Double(r.height)
        s[3] += hf * Double(r.y1 + r.y0)
        s[1] -= hf
        return s
    }

    // MARK: drawing

    /// Draws into `pixels` (RGBA, `width * height`, row by row from the top).
    /// `color` gives a leaf's color, already normalized (see `Palette.normalize`).
    public func render(into pixels: UnsafeMutablePointer<UInt32>, color: (Cell) -> SIMD3<Double>) {
        let colors = leaves.map { color(cells[Int($0.cell)]) }
        let bands = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
        let rowsPerBand = (height + bands - 1) / bands
        leaves.withUnsafeBufferPointer { leaves in
            cells.withUnsafeBufferPointer { cells in
                DispatchQueue.concurrentPerform(iterations: bands) { b in
                    let y0 = b * rowsPerBand, y1 = min(height, y0 + rowsPerBand)
                    guard y0 < y1 else { return }
                    for (i, leaf) in leaves.enumerated() {
                        let c = cells[Int(leaf.cell)]
                        let top = max(Int(c.y0), y0), bottom = min(Int(c.y1), y1)
                        if top >= bottom { continue }
                        Self.shade(pixels, width, c, top, bottom, leaf.surface, colors[i], style)
                    }
                    // folder borders: each folder darkens its top row and left column, so nested
                    // folders sharing an edge add up and the larger boundaries come out darker
                    let flat = style.flatness
                    guard flat > 0 else { return }
                    let keep = 1 - 0.38 * flat
                    for k in folders {
                        let c = cells[Int(k)]
                        guard c.width >= 3, c.height >= 3 else { continue }
                        if Int(c.y0) >= y0 && Int(c.y0) < y1 {
                            Self.darken(pixels + Int(c.y0) * width, Int(c.x0), Int(c.x1), keep)
                        }
                        let top = max(Int(c.y0), y0), bottom = min(Int(c.y1), y1)
                        if top < bottom {
                            for y in top ..< bottom { Self.darken(pixels + y * width, Int(c.x0), Int(c.x0) + 1, keep) }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func darken(_ row: UnsafeMutablePointer<UInt32>, _ from: Int, _ to: Int, _ keep: Double) {
        let k = UInt32(keep * 256)
        for x in from ..< to {
            let p = row[x]
            let r = (p & 0xFF) * k >> 8, g = (p >> 8 & 0xFF) * k >> 8, b = (p >> 16 & 0xFF) * k >> 8
            row[x] = r | g << 8 | b << 16 | 0xFF00_0000
        }
    }

    /// TMVCushionRenderer renderCushionInBitmapGeneric, for the rows from `top` to `bottom`
    private static func shade(_ pixels: UnsafeMutablePointer<UInt32>, _ width: Int, _ c: Cell, _ top: Int, _ bottom: Int,
                              _ s: SIMD4<Double>, _ color: SIMD3<Double>, _ style: CushionStyle) {
        let ia = style.ambient
        // the edge: the first row and column of each file, if it is at least 3 pixels wide; drawn
        // when asked, and more and more as the map gets flat
        let edge = style.edges ? 0.45 : 1 - 0.3 * style.flatness
        let edgeX = edge < 1 && c.width >= 3 ? Int(c.x0) : -1
        let edgeY = edge < 1 && c.height >= 3 ? Int(c.y0) : -1
        let isl = 1 - ia
        let len = (1.0 + 1.0 + 100.0).squareRoot()
        let lx = -1 / len, ly = -1 / len, lz = 10 / len
        let scale = style.brightnessScale
        for iy in top ..< bottom {
            let ny = -(2 * s[1] * (Double(iy) + 0.5) + s[3])
            let row = pixels + iy * width
            for ix in Int(c.x0) ..< Int(c.x1) {
                let nx = -(2 * s[0] * (Double(ix) + 0.5) + s[2])
                let cosa = (nx * lx + ny * ly + lz) / (nx * nx + ny * ny + 1).squareRoot()
                var b = isl * cosa
                b = b < 0 ? ia : b + ia
                b *= scale
                if ix == edgeX || iy == edgeY { b *= edge }
                let rgb = Palette.clamp(color * b)
                row[ix] = UInt32(rgb.x * 255) | UInt32(rgb.y * 255) << 8 | UInt32(rgb.z * 255) << 16 | 0xFF00_0000
            }
        }
    }

    // MARK: lookup

    /// the path of tiles (from the root) containing the pixel
    public func path(at x: Int, _ y: Int) -> [Int] {
        guard !cells.isEmpty, cells[0].contains(x, y) else { return [] }
        var path = [0]
        var k = 0
        outer: while cells[k].childCount > 0 {
            let first = Int(cells[k].firstChild)
            for j in first ..< first + Int(cells[k].childCount) where cells[j].contains(x, y) {
                path.append(j)
                k = j
                continue outer
            }
            break
        }
        return path
    }

    /// the tile of an entry, if it is big enough to be in the map
    public func cell(folder: Folder, entry: Int) -> Int? {
        // the chain of folders from the entry up to the map's folder
        var chain: [(Folder, Int)] = [(folder, entry)]
        var f = folder
        while f !== contents(of: cells[0]) {
            guard let p = f.parent else { return nil }
            chain.append((p, Int(f.index)))
            f = p
        }
        var k = 0
        for (folder, entry) in chain.reversed() {
            guard cells[k].childCount > 0 else { return nil }
            let j = Int(cells[k].firstChild) + entry
            guard j < Int(cells[k].firstChild + cells[k].childCount), cells[j].folder === folder else { return nil }
            k = j
        }
        return k
    }
}

/// The file kind colors (FileTypeColors.m) and their normalization (TMVCushionRenderer).
public enum Palette {
    /// all map colors have the same “brightness”: components summing to 1.8
    public static let baseBrightness = 1.8

    public static let base: [SIMD3<Double>] = [
        [0, 0, 1], [1, 0, 0], [0, 1, 0], [0, 1, 1], [1, 0, 1], [1, 1, 0],
        [0.58, 0.58, 1], [1, 0.58, 0.58], [0.58, 1, 0.58], [0.58, 1, 1], [1, 0.58, 1], [1, 1, 0.58],
    ].map { normalize($0) }

    /// How the kinds' colors look.
    public enum Tone: String, CaseIterable, Sendable {
        /// Disk Inventory X's: all colors at the same brightness
        case original
        /// deeper and more saturated
        case vivid
        /// soft, close to white
        case pastel
    }

    /// `n` colors: the original twelve, then further hues halfway between them, in a tone
    public static func colors(_ n: Int, tone: Tone = .original) -> [SIMD3<Double>] {
        let raw: [SIMD3<Double>] = [
            [0, 0, 1], [1, 0, 0], [0, 1, 0], [0, 1, 1], [1, 0, 1], [1, 1, 0],
            [0.58, 0.58, 1], [1, 0.58, 0.58], [0.58, 1, 0.58], [0.58, 1, 1], [1, 0.58, 1], [1, 1, 0.58],
        ]
        var result = Array(raw.prefix(n))
        var i = 0
        while result.count < n {
            // in-between hues, at two saturations
            let hue = (Double(i % 12) + 0.5) / 12
            let sat = i < 12 ? 1.0 : 0.5
            result.append(hsv(hue, sat))
            i += 1
        }
        return result.map { c in
            switch tone {
            case .original: normalize(c)
            case .vivid: normalize(c, brightness: 1.4)
            case .pastel: normalize(c * 0.5 + SIMD3(repeating: 0.5), brightness: 2.2)
            }
        }
    }

    private static func hsv(_ h: Double, _ s: Double) -> SIMD3<Double> {
        let k = { (n: Double) -> Double in
            let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
            return 1 - s * max(0, min(k, 4 - k, 1))
        }
        return [k(5), k(3), k(1)]
    }

    /// the color of the kinds beyond the colored ones
    public static let other = normalize([0.5, 0.5, 0.5])

    public static func normalize(_ c: SIMD3<Double>, brightness: Double = baseBrightness) -> SIMD3<Double> {
        let sum = c.x + c.y + c.z
        return clamp(sum != 0 ? c * (brightness / sum) : c)
    }

    /// spreads to the other two components what one has above 1
    @inline(__always)
    static func clamp(_ c: SIMD3<Double>) -> SIMD3<Double> {
        var (r, g, b) = (c.x, c.y, c.z)
        if r > 1 { distribute(&r, &g, &b) } else if g > 1 { distribute(&g, &r, &b) } else if b > 1 { distribute(&b, &r, &g) }
        return [min(r, 1), min(g, 1), min(b, 1)]
    }

    @inline(__always)
    private static func distribute(_ first: inout Double, _ second: inout Double, _ third: inout Double) {
        let h = (first - 1) / 2
        first = 1
        second += h
        third += h
        if second > 1 {
            third += second - 1
            second = 1
        } else if third > 1 {
            second += third - 1
            third = 1
        }
    }
}
