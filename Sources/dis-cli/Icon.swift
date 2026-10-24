// Disk Inventory S — what is taking up the disk, as a cushion treemap.
// Copyright (C) 2026 Riccardo Di Paola
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see the
// GNU General Public License in COPYING for details.
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// The app icon, drawn in code: a few treemap tiles with soft cushion light, inside the macOS
/// icon shape (a superellipse on the 1024 grid, 824 points wide), with a glass sheen on top.
enum IconStyle: String, CaseIterable {
    /// tiles on a deep blue ground
    case glass
    /// tiles on a light ground
    case light
    /// like glass, with the spotlight on one folder: the others dimmed, a white frame
    case spotlight
}

func drawIcon(size px: Int, style: IconStyle) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // work on the 1024 grid, y down
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high

    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    // the shadow under the icon
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(gray: 0.1, alpha: 1)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // the ground
    let ground: [CGColor] = style == .light
        ? [rgb(0.97, 0.98, 1.0), rgb(0.86, 0.89, 0.95)]
        : [rgb(0.16, 0.20, 0.36), rgb(0.05, 0.07, 0.15)]
    linear(ctx, ground, from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))

    // the tiles: a treemap of one disk, largest first, on a 664 area inset in the shape
    let tiles: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: 0, width: 384, height: 404), rgb(0.33, 0.52, 1.00)),   // blue
        (CGRect(x: 0, y: 404, width: 384, height: 260), rgb(1.00, 0.42, 0.42)),  // coral
        (CGRect(x: 384, y: 0, width: 280, height: 246), rgb(0.27, 0.84, 0.60)),  // green
        (CGRect(x: 384, y: 246, width: 150, height: 206), rgb(1.00, 0.76, 0.27)), // amber
        (CGRect(x: 534, y: 246, width: 130, height: 206), rgb(0.65, 0.53, 0.98)), // violet
        (CGRect(x: 384, y: 452, width: 168, height: 212), rgb(0.20, 0.74, 0.97)), // sky
        (CGRect(x: 552, y: 452, width: 112, height: 116), rgb(0.96, 0.45, 0.71)), // pink
        (CGRect(x: 552, y: 568, width: 112, height: 96), rgb(0.98, 0.60, 0.25)),  // orange
    ]
    let origin = CGPoint(x: 180, y: 180)
    let gap: CGFloat = 14, radius: CGFloat = 30
    let lit = 0 // the tile under the spotlight
    for (i, (r0, color)) in tiles.enumerated() {
        var r = r0.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: gap / 2, dy: gap / 2)
        r = r.integral
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        // a soft shadow under each tile gives the depth of the cushions
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14,
                      color: CGColor(gray: 0, alpha: style == .light ? 0.18 : 0.45))
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // the cushion: light from the top left, as in Disk Inventory X, but soft
        let c = color.components!
        let light = rgb(min(1, c[0] * 0.55 + 0.45), min(1, c[1] * 0.55 + 0.45), min(1, c[2] * 0.55 + 0.45))
        let dark = rgb(c[0] * 0.62, c[1] * 0.62, c[2] * 0.62)
        let center = CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.34)
        let reach = max(r.width, r.height) * 0.95
        let g = CGGradient(colorsSpace: space, colors: [light, color, dark] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: reach,
                               options: [.drawsAfterEndLocation])
        // a thin light edge on top, like glass
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(3)
        ctx.strokePath()
        if style == .spotlight && i != lit {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fill(r)
        }
        ctx.restoreGState()
        if style == .spotlight && i == lit {
            let frame = CGPath(roundedRect: r.insetBy(dx: -5, dy: -5), cornerWidth: radius + 5, cornerHeight: radius + 5, transform: nil)
            ctx.addPath(frame)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(9)
            ctx.strokePath()
        }
    }

    // the glass sheen over the upper half
    ctx.saveGState()
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: 100, y: 100))
    sheen.addLine(to: CGPoint(x: 924, y: 100))
    sheen.addLine(to: CGPoint(x: 924, y: 420))
    sheen.addQuadCurve(to: CGPoint(x: 100, y: 520), control: CGPoint(x: 520, y: 600))
    sheen.closeSubpath()
    ctx.addPath(sheen)
    ctx.clip()
    linear(ctx, [CGColor(gray: 1, alpha: style == .light ? 0.35 : 0.16), CGColor(gray: 1, alpha: 0)],
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    ctx.restoreGState()

    // a bright rim at the top fading to nothing at the bottom
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [CGColor(gray: 1, alpha: style == .light ? 0.9 : 0.45), CGColor(gray: 1, alpha: 0.05)],
           from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    ctx.restoreGState()

    return ctx.makeImage()!
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r, g, b, 1])!
}

private func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3)!, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// The macOS icon shape: a superellipse (exponent 5), smoother than a rounded rectangle.
private func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, a = Double(r.width) / 2, b = Double(r.height) / 2
    let cx = Double(r.midX), cy = Double(r.midY)
    let steps = 720
    for i in 0 ... steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}
