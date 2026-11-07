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

    // MARK: Sayfa sınırı

    /// Mürekkep sayfanın dışında başlamasın: dokunuş kâğıdın dışındaysa tuval o dokunuşu almaz
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isWhiteboard { return super.point(inside: point, with: event) }
        return paper.frame.contains(point) && super.point(inside: point, with: event)
    }

    /// Sayfanın içinde başlayıp dışına taşan çizginin taşan kısmı görünmesin
    private let pageMask = CAShapeLayer()

    private func updatePageMask() {
        guard !isWhiteboard else { layer.mask = nil; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageMask.frame = CGRect(x: 0, y: 0,
                                width: max(contentSize.width, bounds.maxX, bounds.width),
                                height: max(contentSize.height, bounds.maxY))
        pageMask.path = UIBezierPath(roundedRect: paper.frame, cornerRadius: 6).cgPath
        layer.mask = pageMask
        CATransaction.commit()
    }

    // MARK: Yapışkan notlar

    var onNotesChange: (([StickyNote]) -> Void)?
    private var noteViews: [StickyNoteView] = []

    func setNotes(_ notes: [StickyNote]) {
        noteViews.forEach { $0.removeFromSuperview() }
        noteViews = notes.map(makeNoteView)
        layoutNotes()
    }

    private func makeNoteView(_ note: StickyNote) -> StickyNoteView {
        let v = StickyNoteView(note: note)
        v.onChange = { [weak self] _ in self?.notesChanged() }
        v.onMoveEnded = { [weak self] v in self?.finishMove(v) }
        v.setTool(tool)
        v.ink.undoProvider = { [weak self] in self?.undoManager }
        v.onDelete = { [weak self] v in
            guard let self else { return }
            UIView.animate(withDuration: 0.18, animations: {
                v.alpha = 0
                v.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            }, completion: { _ in v.removeFromSuperview() })
            self.noteViews.removeAll { $0 === v }
            self.notesChanged()
        }
        addSubview(v)
        return v
    }

    private func layoutNotes() {
        let s = mapping.a
        for v in noteViews {
            v.scale = s
            v.frame = v.note.frame.applying(mapping)
            bringSubviewToFront(v)
        }
        bringSubviewToFront(cursor)
    }

    /// Sürüklenen notun yeni yerini kanonik koordinata çevirir ve sayfanın içinde tutar
    private func finishMove(_ v: StickyNoteView) {
        var f = v.frame.applying(mapping.inverted())
        f.size.width = min(max(f.width, StickyNote.minSize.width), canonical.width)
        f.size.height = min(max(f.height, StickyNote.minSize.height), canonical.height)
        f.origin.x = min(max(f.minX, 0), canonical.width - f.width)
        f.origin.y = min(max(f.minY, 0), canonical.height - f.height)
        v.note.frame = f
        UIView.animate(withDuration: 0.2) { v.frame = f.applying(self.mapping) }
        notesChanged()
    }

    private func notesChanged() { onNotesChange?(noteViews.map(\.note)) }

    /// Seçili aracı hem sayfaya hem notların kalem katmanına uygular
    func applyTool(_ t: PKTool) {
        tool = t
        noteViews.forEach { $0.setTool(t) }
    }

    /// Notun üstünde çizim başlamasın; basılı tutma ve sürükleme nota gitsin
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === drawingGestureRecognizer {
            let p = g.location(in: self)
            if noteViews.contains(where: { $0.frame.contains(p) }) { return false }
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// Notun dışında bir yere dokunulunca not yazmayı bitir (klavyeyi kapat)
    func endNoteEditingIfOutside(_ point: CGPoint) {
        guard noteViews.contains(where: { $0.isFirstResponderInside }) else { return }
        if !noteViews.contains(where: { $0.frame.contains(point) }) { endEditing(true) }
    }

    /// Görünen alanın ortasına yeni bir not koyar ve yazmaya başlatır
    func addNote(color: StickyColor = .sari) {
        let visible = bounds.intersection(paper.frame)
        let center = CGPoint(x: visible.midX, y: visible.midY).applying(mapping.inverted())
        var note = StickyNote(x: 0, y: 0, color: color)
        note.x = min(max(center.x - note.w / 2, 0), canonical.width - note.w)
        note.y = min(max(center.y - note.h / 2, 0), canonical.height - note.h)
        let v = makeNoteView(note)
        noteViews.append(v)
        layoutNotes()
        v.alpha = 0
        v.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).rotated(by: -0.04)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4) {
            v.alpha = 1
            v.transform = .identity
        }
        notesChanged()
        v.beginEditing()
    }

    // MARK: Sayfa çevirme animasyonu

    /// Animasyon sürerken tutulan sayfa çevirici (bitince bırakılır)
    private var curl: PageCurl?

    /// Sayfayı kitap gibi köşesinden kıvırarak çevirir (Kitaplar uygulamasındaki efekt).
    /// İleri: eski sayfa kalkıp sola kıvrılır, altından yeni sayfa çıkar.
    /// Geri: önceki sayfa soldan kıvrılarak eski sayfanın üstüne iner.
    /// Tuvalin kendisi hareket etmez; animasyon sayfanın görüntüleri üzerinde yapılır.
    func animatePageTurn(forward: Bool, swapContent: @escaping () -> Void) {
        curl?.finish()
        let rect = paper.frame.intersection(bounds)
        guard let host = superview, !rect.isEmpty,
              let oldSnap = resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero)
        else { swapContent(); return }
        let frameInHost = convert(rect, to: host)

        if UIAccessibility.isReduceMotionEnabled {
            oldSnap.frame = frameInHost
            host.addSubview(oldSnap)
            swapContent()
            UIView.animate(withDuration: 0.25, animations: { oldSnap.alpha = 0 }, completion: { _ in oldSnap.removeFromSuperview() })
            return
        }

        let c = PageCurl(frame: frameInHost, oldPage: oldSnap, in: host)
        curl = c
        swapContent()
        c.onDone = { [weak self, weak c] in if self?.curl === c { self?.curl = nil } }

        if forward {
            // Altta canlı tuval görünsün diye yeni sayfa saydam
            c.turn(to: nil, forward: true)
        } else {
            // Geri dönerken yeni sayfa üstten iner; PencilKit'in çizmesi için bir an bekleyip görüntüsünü al
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, weak c] in
                guard let self, let c, !c.isFinished else { return }
                let r = self.paper.frame.intersection(self.bounds)
                c.turn(to: self.resizableSnapshotView(from: r, afterScreenUpdates: true, withCapInsets: .zero), forward: false)
            }
        }
    }

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
            layoutNotes()
            onLayoutChange?()
        }
        updatePageMask()
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

    func addNote() { canvas?.addNote() }

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
    var notes: [StickyNote] = []
    /// Sayfa değişirken animasyon yönü: +1 ileri, -1 geri
    var turnForward = true
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
    var onNotesChange: ((UUID, [StickyNote]) -> Void)? = nil
    /// Apple Pencil Pro sıkıldı: kalem ucunun pencere koordinatı (kalem havada değilse nil)
    var onPencilSqueeze: ((CGPoint?) -> Void)? = nil

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
        c.applyTool(tool)
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = context.coordinator
        context.coordinator.pageID = pageID
        let pending = data
        let pendingNotes = notes
        c.onNotesChange = { [weak coord = context.coordinator] list in
            guard let coord, let pid = coord.pageID else { return }
            coord.parent.onNotesChange?(pid, list)
            // Not mürekkebi geri alınabilir: düğmelerin durumunu güncelle
            DispatchQueue.main.async { [weak coord] in coord?.parent.controller.refresh() }
        }
        c.onLayoutChange = { [weak c, weak coord = context.coordinator] in
            guard let c, let coord, !coord.loaded else { return }
            coord.loaded = true
            coord.suppress = true
            c.load(pending)
            c.setNotes(pendingNotes)
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
            // Parmak çizmiyorken (yalnızca Pencil) tek parmakla da sayfa çevrilir
            let one = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pageSwipe(_:)))
            one.direction = direction
            one.numberOfTouchesRequired = 1
            one.delegate = context.coordinator
            one.isEnabled = pencilOnly
            c.addGestureRecognizer(one)
            context.coordinator.oneFingerSwipes.append(one)
        }
        controller.canvas = c
        return c
    }

    func updateUIView(_ c: YaprakCanvas, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if coord.loaded, coord.pageID != pageID {
            // Önce eski sayfayı kaydet, sonra yeni sayfayı yükle (kitap sayfası animasyonuyla)
            c.endEditing(true)
            coord.flush(c)
            let newData = data, newNotes = notes, newPDF = pdfPage, pid = pageID
            c.animatePageTurn(forward: turnForward) {
                coord.pageID = pid
                c.paper.pdfPage = newPDF
                coord.suppress = true
                c.load(newData)
                c.setNotes(newNotes)
                c.undoManager?.removeAllActions()
                coord.suppress = false
            }
            DispatchQueue.main.async { [weak controller] in controller?.refresh() }
            c.setContentOffset(CGPoint(x: -c.adjustedContentInset.left, y: -c.adjustedContentInset.top), animated: false)
        }
        c.applyTool(tool)
        c.cursorDiameter = eraserCursor
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        coord.oneFingerSwipes.forEach { $0.isEnabled = pencilOnly }
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
        /// Tek parmakla sayfa çevirme (yalnızca parmak çizmiyorken açık)
        var oneFingerSwipes: [UISwipeGestureRecognizer] = []

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
            if g.state == .began { c.endNoteEditingIfOutside(g.location(in: c)) }
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
            if g is UISwipeGestureRecognizer {
                // Sayfa çevirme parmakla; yapışkan notu sürüklerken/yazarken sayfa değişmesin
                guard touch.type == .direct else { return false }
                var v = touch.view
                while let x = v {
                    if x is StickyNoteView { return false }
                    v = x.superview
                }
                return true
            }
            guard let c = g.view as? PKCanvasView else { return true }
            return !(c.drawingPolicy == .pencilOnly && touch.type == .direct)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            parent.onPencilTap()
        }

        /// Apple Pencil Pro sıkma: kullanıcının sistem ayarına uyar
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            switch UIPencilInteraction.preferredSqueezeAction {
            case .ignore:
                return
            case .switchEraser, .switchPrevious:
                parent.onPencilTap()
            default:
                let view = interaction.view
                let p = squeeze.hoverPose.flatMap { pose in view.map { $0.convert(pose.location, to: nil) } }
                parent.onPencilSqueeze?(p)
            }
        }
    }
}

// MARK: - Sayfa kıvırma

/// UIPageViewController'ın gerçek sayfa kıvırma efektini sayfa görüntüleri üzerinde bir kez oynatır.
@MainActor
final class PageCurl {
    private let pvc: UIPageViewController
    private(set) var isFinished = false
    var onDone: (() -> Void)?

    init(frame: CGRect, oldPage: UIView, in host: UIView) {
        pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                   options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)])
        pvc.isDoubleSided = false
        pvc.view.frame = frame
        pvc.view.backgroundColor = .clear
        pvc.view.isUserInteractionEnabled = false
        pvc.view.clipsToBounds = false
        pvc.setViewControllers([Self.page(oldPage, size: frame.size)], direction: .forward, animated: false)
        host.addSubview(pvc.view)
        // Herhangi bir sebeple tamamlanma gelmezse takılı kalmasın
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish() }
    }

    /// `newPage` nil ise yeni sayfa saydam olur (altındaki canlı tuval görünür).
    func turn(to newPage: UIView?, forward: Bool) {
        guard !isFinished else { return }
        let next = Self.page(newPage, size: pvc.view.bounds.size)
        pvc.setViewControllers([next], direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            self?.finish()
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        pvc.view.removeFromSuperview()
        onDone?()
    }

    private static func page(_ content: UIView?, size: CGSize) -> UIViewController {
        let vc = UIViewController()
        vc.view.frame = CGRect(origin: .zero, size: size)
        vc.view.backgroundColor = .clear
        if let content {
            content.frame = vc.view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            vc.view.addSubview(content)
        }
        return vc
    }
}
