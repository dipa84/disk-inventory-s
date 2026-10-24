import AppKit
import InventarioCore

/// La mappa: ogni file un riquadro grande quanto il posto che occupa, le cartelle a cuscino.
///
/// Clic sceglie il file; doppio clic entra nella cartella sotto il puntatore (uno zoom di un
/// livello). Le frecce passano al riquadro vicino dello stesso livello, ⇧ e le frecce a quello
/// del livello sopra; ⌘↑ ⌘↓ cambiano livello (dal menu Vista).
final class TreemapView: NSView {
    weak var controller: DocumentController?
    private var map: Treemap?
    private var image: CGImage?
    private var hovered: Int?
    /// misure dei tempi nel terminale (INVENTARIO_MISURA=1)
    private let measure = ProcessInfo.processInfo.environment["INVENTARIO_MISURA"] != nil

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// da rifare: la disposizione (dimensioni, zoom, albero cambiati)
    func reload() {
        map = nil
        image = nil
        hovered = nil
        needsDisplay = true
    }

    /// da ridisegnare: solo i colori (tipo in evidenza)
    func recolor() {
        image = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reload()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reload()
    }

    private func build() {
        guard let c = controller, let doc = c.model else { return }
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        var start = ContinuousClock.now
        if map == nil {
            map = Treemap(folder: c.zoom, entry: -1, width: w, height: h, mode: doc.mode, minSide: Int(scale.rounded())) { f, i in
                doc.isLeaf(f.entries[i])
            }
        }
        guard let map else { return }
        let layoutTime = ContinuousClock.now - start
        start = ContinuousClock.now
        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        let kinds = doc.kinds
        let highlight = doc.highlightedKind
        map.render(into: pixels) { cell in
            guard cell.entry >= 0 else { return Palette.other }
            let e = cell.folder.entries[Int(cell.entry)]
            if e.isDirectory && !kinds.isPackage(e) { return Palette.other * 0.6 }
            if e.flags.contains(.special) { return kinds.kinds[kinds.kind(of: e)].color }
            let k = kinds.kind(of: e)
            let color = kinds.kinds[k].color
            if let highlight, highlight != k { return Palette.other * 0.35 }
            return color
        }
        let renderTime = ContinuousClock.now - start
        let data = Data(bytesNoCopy: pixels, count: w * h * 4, deallocator: .custom { p, _ in p.deallocate() })
        let provider = CGDataProvider(data: data as CFData)!
        image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        if measure {
            print("mappa \(w)x\(h): disposizione \(layoutTime), disegno \(renderTime), \(map.cells.count) riquadri")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        if image == nil { build() }
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // l'immagine ha la prima riga in alto: in una vista capovolta va raddrizzata
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)
        ctx.restoreGState()

        if let h = hovered, let r = rect(of: h) {
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
        if let sel = controller?.selection, let k = cellIndex(of: sel), let r = rect(of: k) {
            // bianco dentro e nero fuori: si vede su ogni colore
            NSColor.black.setStroke()
            let outer = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            outer.lineWidth = 3
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            inner.lineWidth = 1.5
            inner.stroke()
        }
    }

    // MARK: riquadri e voci

    private func rect(of cell: Int) -> NSRect? {
        guard let map, cell < map.cells.count else { return nil }
        let c = map.cells[cell]
        let s = scale
        let r = NSRect(x: CGFloat(c.x0) / s, y: CGFloat(c.y0) / s, width: CGFloat(c.width) / s, height: CGFloat(c.height) / s)
        return r.width >= 1 && r.height >= 1 ? r : nil
    }

    private func item(of cell: Int) -> Item? {
        guard let map else { return nil }
        let c = map.cells[cell]
        return c.entry < 0 ? Item(c.folder) : Item(folder: c.folder, entry: Int(c.entry))
    }

    private func cellIndex(of item: Item) -> Int? {
        guard let map, let c = controller else { return nil }
        if item.contents === c.zoom { return 0 }
        if item.isRoot { return nil }
        return map.cell(folder: item.folder, entry: item.entry)
    }

    private func path(at point: NSPoint) -> [Int] {
        if map == nil { build() }
        guard let map else { return [] }
        return map.path(at: Int(point.x * scale), Int(point.y * scale))
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let path = path(at: p)
        guard let last = path.last, let c = controller else { return }
        if event.clickCount == 2 {
            // un livello più giù: la cartella sotto il puntatore dentro quella mostrata
            if path.count > 1, let item = item(of: path[1]), let folder = item.contents, c.model?.isContainer(item) == true {
                c.zoom(into: folder)
            }
            return
        }
        c.select(item(of: last), from: .map)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let last = path(at: p).last, let item = item(of: last), item != controller?.selection {
            controller?.select(item, from: .map)
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = path(at: p).last
        guard h != hovered else { return }
        hovered = h
        needsDisplay = true
        controller?.hover(h.flatMap { item(of: $0) })
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        controller?.hover(nil)
    }

    // MARK: tastiera

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        switch event.specialKey {
        case .leftArrow?, .rightArrow?, .upArrow?, .downArrow?:
            if mods.isSubset(of: [.shift]) {
                move(event.specialKey!, up: mods.contains(.shift))
            } else {
                super.keyDown(with: event)
            }
        case .carriageReturn?, .enter?:
            controller?.zoomIn(nil)
        default:
            if event.charactersIgnoringModifiers == " " && mods.isEmpty {
                controller?.quickLook(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Passa al riquadro accanto: quello che sta appena oltre il lato, allo stesso livello
    /// (con ⇧ al livello della cartella sopra: il passo grande).
    private func move(_ key: NSEvent.SpecialKey, up: Bool) {
        guard let map, let c = controller else { return }
        guard let sel = c.selection, let k = cellIndex(of: sel) else {
            // niente di scelto: il riquadro più grande
            if map.cells.count > 1 { c.select(item(of: Int(map.cells[0].firstChild)), from: .map) }
            return
        }
        let cell = map.cells[k]
        let mid = map.path(at: Int(cell.x0 + cell.x1) / 2, Int(cell.y0 + cell.y1) / 2)
        guard let depth = mid.firstIndex(of: k) else { return }
        let level = up ? max(1, depth - 1) : depth
        let from = map.cells[mid[min(level, mid.count - 1)]]
        let x: Int, y: Int
        switch key {
        case .leftArrow: (x, y) = (Int(from.x0) - 1, Int(cell.y0 + cell.y1) / 2)
        case .rightArrow: (x, y) = (Int(from.x1), Int(cell.y0 + cell.y1) / 2)
        case .upArrow: (x, y) = (Int(cell.x0 + cell.x1) / 2, Int(from.y0) - 1)
        default: (x, y) = (Int(cell.x0 + cell.x1) / 2, Int(from.y1))
        }
        let target = map.path(at: x, y)
        guard !target.isEmpty else { NSSound.beep(); return }
        c.select(item(of: target[min(level, target.count - 1)]), from: .map)
    }
}
