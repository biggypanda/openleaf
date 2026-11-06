import SwiftUI
import PencilKit
import PDFKit

// MARK: - Kâğıt deseni (önizleme ve sayfa altlığı aynı kodu kullanır)

enum PaperPattern {
    /// `s` = sayfa ölçeği (kanonik sayfa genişliği 768 pt)
    static func draw(_ style: PaperStyle, in r: CGRect, scale s: CGFloat,
                     stroke: (Path, UIColor, CGFloat) -> Void,
                     fill: (Path, UIColor) -> Void) {
        switch style {
        case .cizgili:
            var p = Path()
            var y = r.minY + 110 * s
            while y < r.maxY - 24 * s {
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y)); y += 34 * s
            }
            stroke(p, Y.paperLineUI, max(0.5, 1 * s))
            var m = Path()
            m.move(to: CGPoint(x: r.minX + 84 * s, y: r.minY)); m.addLine(to: CGPoint(x: r.minX + 84 * s, y: r.maxY))
            stroke(m, Y.paperMarginUI, max(0.6, 1.2 * s))
        case .kareli:
            var p = Path()
            let step = 28 * s
            var x = r.minX + step
            while x < r.maxX { p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY)); x += step }
            var y = r.minY + step
            while y < r.maxY { p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y)); y += step }
            stroke(p, Y.paperLineUI, max(0.5, 0.8 * s))
        case .noktali:
            var p = Path()
            let step = 28 * s, d = max(1.2, 2.4 * s)
            var y = r.minY + step
            while y < r.maxY {
                var x = r.minX + step
                while x < r.maxX { p.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)); x += step }
                y += step
            }
            fill(p, Y.paperLineUI.withAlphaComponent(1))
        case .bos:
            break
        }
    }
}

/// Tuvalin altında duran kâğıt yüzeyi
final class PaperUIView: UIView {
    var style: PaperStyle = .cizgili { didSet { setNeedsDisplay() } }
    var pageScale: CGFloat = 1 { didSet { setNeedsDisplay() } }
    var isWhiteboard = false
    /// Doluysa desen yerine bu PDF sayfası çizilir
    var pdfPage: PDFPage? {
        didSet { if oldValue !== pdfPage { rendered = nil; setNeedsDisplay() } }
    }
    private var rendered: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor(hex: 0x28220F).cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: PaperUIView, _: UITraitCollection) in
            v.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = isWhiteboard ? nil : UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
        layer.shadowOpacity = isWhiteboard ? 0 : 0.12
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let pdfPage {
            if rendered?.size != bounds.size {
                rendered = PDFRender.image(pdfPage, size: bounds.size, scale: max(2, traitCollection.displayScale))
            }
            rendered?.draw(in: bounds)
            return
        }
        let tc = traitCollection
        let page = UIBezierPath(roundedRect: bounds, cornerRadius: isWhiteboard ? 0 : 6)
        ctx.addPath(page.cgPath)
        ctx.setFillColor(Y.paperUI.resolvedColor(with: tc).cgColor)
        ctx.fillPath()
        PaperPattern.draw(style, in: bounds, scale: pageScale) { path, color, width in
            ctx.addPath(path.cgPath)
            ctx.setStrokeColor(color.resolvedColor(with: tc).cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        } fill: { path, color in
            ctx.addPath(path.cgPath)
            ctx.setFillColor(color.resolvedColor(with: tc).cgColor)
            ctx.fillPath()
        }
    }
}

// MARK: - Tuval

/// Çizimler kanonik sayfa koordinatlarında saklanır (genişlik 768); ekranda sayfa genişliğine ölçeklenir.
final class YaprakCanvas: PKCanvasView {
    let paper = PaperUIView()
    var canonical = CGSize(width: 768, height: 994)
    var style: PaperStyle = .cizgili
    var isWhiteboard = false
    var bottomRoom: CGFloat = 140
    private(set) var mapping = CGAffineTransform.identity
    var onLayoutChange: (() -> Void)?

    /// Tuvalin kendi geri alma yöneticisi: PencilKit adımları, araç çubuğu düğmeleri ve ⌘Z
    /// aynı yere bakar (pencerenin genel yöneticisine güvenmek düğmeleri boşa çıkarıyordu).
    private let ownUndo = UndoManager()
    override var undoManager: UndoManager? { ownUndo }

    // MARK: Silgi imleci

    /// Kısmi silgi seçiliyken dairenin çapı (ekran noktası); nil ise imleç gösterilmez
    var cursorDiameter: CGFloat? {
        didSet { if cursorDiameter == nil { hideCursor() } else if !cursor.isHidden { showCursor(at: cursor.center) } }
    }

    private let cursor: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.isHidden = true
        v.layer.borderWidth = 1.5
        v.layer.zPosition = 1000
        return v
    }()

    func showCursor(at point: CGPoint) {
        guard let d = cursorDiameter else { hideCursor(); return }
        if cursor.superview == nil { addSubview(cursor) }
        bringSubviewToFront(cursor)
        cursor.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        cursor.layer.cornerRadius = d / 2
        cursor.layer.borderColor = UIColor.dyn(0x5A5F58, 0xB1AC9F).resolvedColor(with: traitCollection).cgColor
        cursor.backgroundColor = UIColor.dyn(0xFFFFFF, 0x26241F, 0.45, 0.45).resolvedColor(with: traitCollection)
        cursor.center = point
        cursor.isHidden = false
    }

    func hideCursor() { cursor.isHidden = true }

    func pageRect(forWidth w: CGFloat) -> CGRect {
        if isWhiteboard { return CGRect(origin: .zero, size: canonical) }
        let pw = min(w - 48, 880)
        let s = pw / canonical.width
        return CGRect(x: (w - pw) / 2, y: 20, width: pw, height: canonical.height * s)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        if paper.superview == nil {
            insertSubview(paper, at: 0)
            paper.layer.zPosition = -1
        }
        if subviews.first !== paper { sendSubviewToBack(paper) }
        let r = pageRect(forWidth: bounds.width)
        let s = r.width / canonical.width
        let newMap = CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: r.minX, y: r.minY))
        if newMap != mapping {
            // Döndürme / yeniden boyutlandırmada çizimi yeni yerleşime taşı
            let old = mapping
            mapping = newMap
            if !drawing.strokes.isEmpty {
                drawing = drawing.transformed(using: old.inverted().concatenating(newMap))
            }
            paper.isWhiteboard = isWhiteboard
            paper.style = style
            paper.pageScale = s
            paper.frame = r
            contentSize = CGSize(width: max(bounds.width, r.maxX), height: r.maxY + bottomRoom)
            onLayoutChange?()
        }
    }

    func load(_ data: Data) {
        let d = (try? PKDrawing(data: data)) ?? PKDrawing()
        drawing = d.transformed(using: mapping)
    }

    var canonicalData: Data { drawing.transformed(using: mapping.inverted()).dataRepresentation() }
}

@Observable
final class CanvasController {
    weak var canvas: YaprakCanvas?
    var canUndo = false
    var canRedo = false

    func undo() {
        guard let u = canvas?.undoManager, u.canUndo else { return }
        u.undo()
        refresh()
    }

    func redo() {
        guard let u = canvas?.undoManager, u.canRedo else { return }
        u.redo()
        refresh()
    }

    /// Düğmelerin etkin/pasif durumunu günceller
    func refresh() {
        let u = canvas?.undoManager
        if canUndo != (u?.canUndo ?? false) { canUndo = u?.canUndo ?? false }
        if canRedo != (u?.canRedo ?? false) { canRedo = u?.canRedo ?? false }
    }
}

/// Tek bir tuval; sayfa değişince içerik değiştirilir (eski sayfanın tuvali dokunmaları çalmasın diye).
struct CanvasRepresentable: UIViewRepresentable {
    var pageID: UUID
    var data: Data
    var pdfPage: PDFPage?
    var paper: PaperStyle
    var canonical: CGSize
    var isWhiteboard: Bool
    var isPDF = false
    var tool: PKTool
    var eraserCursor: CGFloat? = nil
    var pencilOnly: Bool
    var controller: CanvasController
    var onChange: (UUID, Data) -> Void
    var onPencilTap: () -> Void
    /// İki parmakla yatay kaydırma: +1 sonraki sayfa (sola kaydırma), -1 önceki sayfa (sağa kaydırma)
    var onPageSwipe: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> YaprakCanvas {
        let c = YaprakCanvas()
        c.style = paper
        c.paper.pdfPage = pdfPage
        c.isWhiteboard = isWhiteboard
        // PDF'ler beyaz kâğıttır: koyu temada mürekkep tersine dönüp kaybolmasın
        if isPDF { c.overrideUserInterfaceStyle = .light }
        c.canonical = canonical
        c.backgroundColor = .clear
        c.isOpaque = false
        c.alwaysBounceVertical = true
        c.showsVerticalScrollIndicator = true
        c.minimumZoomScale = 1
        c.maximumZoomScale = 1
        c.tool = tool
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = context.coordinator
        context.coordinator.pageID = pageID
        let pending = data
        c.onLayoutChange = { [weak c, weak coord = context.coordinator] in
            guard let c, let coord, !coord.loaded else { return }
            coord.loaded = true
            coord.suppress = true
            c.load(pending)
            coord.suppress = false
        }
        let pencil = UIPencilInteraction(delegate: context.coordinator)
        c.addInteraction(pencil)

        // Silgi imleci: dokunurken ve Pencil ekrana yaklaşınca kalemin ucunu takip eder.
        // Dokunuşları yutmaz, PencilKit'in çizimiyle aynı anda çalışır.
        let track = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.track(_:)))
        track.minimumPressDuration = 0
        track.allowableMovement = .greatestFiniteMagnitude
        track.cancelsTouchesInView = false
        track.delaysTouchesBegan = false
        track.delaysTouchesEnded = false
        track.delegate = context.coordinator
        c.addGestureRecognizer(track)
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hover(_:)))
        hover.delegate = context.coordinator
        c.addGestureRecognizer(hover)
        c.cursorDiameter = eraserCursor

        // İki parmakla sola/sağa kaydırınca sayfa değişir. Tek parmak ve kalem çizmeye,
        // iki parmakla dikey kaydırma sayfayı kaydırmaya devam eder.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pageSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.delegate = context.coordinator
            c.addGestureRecognizer(swipe)
        }
        controller.canvas = c
        return c
    }

    func updateUIView(_ c: YaprakCanvas, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if coord.loaded, coord.pageID != pageID {
            // Önce eski sayfayı kaydet, sonra yeni sayfayı yükle
            coord.flush(c)
            coord.pageID = pageID
            c.paper.pdfPage = pdfPage
            coord.suppress = true
            c.load(data)
            c.undoManager?.removeAllActions()
            coord.suppress = false
            DispatchQueue.main.async { [weak controller] in controller?.refresh() }
            c.setContentOffset(CGPoint(x: -c.adjustedContentInset.left, y: -c.adjustedContentInset.top), animated: false)
        }
        c.tool = tool
        c.cursorDiameter = eraserCursor
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        controller.canvas = c
    }

    static func dismantleUIView(_ c: YaprakCanvas, coordinator: Coordinator) {
        coordinator.flush(c)
        // Kapanan sayfanın geri alma adımları yeni sayfada çalışmasın
        c.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: CanvasRepresentable
        var loaded = false
        var suppress = false
        var pageID: UUID?
        private var work: DispatchWorkItem?

        init(_ p: CanvasRepresentable) { parent = p }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Geri al adımı çizgi bitince kaydedilir; durumu bir tur sonra oku
            DispatchQueue.main.async { [weak self] in self?.parent.controller.refresh() }
            guard loaded, !suppress, let c = canvasView as? YaprakCanvas, let pid = pageID else { return }
            work?.cancel()
            let item = DispatchWorkItem { [weak self, weak c] in
                guard let self, let c else { return }
                self.work = nil
                self.parent.onChange(pid, c.canonicalData)
            }
            work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }

        func flush(_ c: YaprakCanvas) {
            guard work != nil, loaded, let pid = pageID else { return }
            work?.cancel(); work = nil
            parent.onChange(pid, c.canonicalData)
        }

        @objc func track(_ g: UILongPressGestureRecognizer) {
            guard let c = g.view as? YaprakCanvas else { return }
            switch g.state {
            case .began, .changed: c.showCursor(at: g.location(in: c))
            default: c.hideCursor()
            }
        }

        @objc func pageSwipe(_ g: UISwipeGestureRecognizer) {
            guard g.state == .ended else { return }
            parent.onPageSwipe?(g.direction == .left ? 1 : -1)
        }

        @objc func hover(_ g: UIHoverGestureRecognizer) {
            guard let c = g.view as? YaprakCanvas else { return }
            switch g.state {
            case .began, .changed: c.showCursor(at: g.location(in: c))
            default: c.hideCursor()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// "Yalnızca Pencil ile çiz" açıkken parmakla kaydırırken imleç çıkmasın
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g is UISwipeGestureRecognizer { return touch.type == .direct }
            guard let c = g.view as? PKCanvasView else { return true }
            return !(c.drawingPolicy == .pencilOnly && touch.type == .direct)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            parent.onPencilTap()
        }
    }
}
