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

/// Parçaları solmadan hemen gösteren döşemeli katman
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// Tuvalin altında duran kâğıt yüzeyi. Yakınlaştırınca bulanıklaşmasın diye döşemeli katmanla
/// (her yakınlık düzeyinde yeniden) çizilir; PDF sayfası da vektör olarak çizilir.
final class PaperUIView: UIView {
    override class var layerClass: AnyClass { InstantTiledLayer.self }

    var style: PaperStyle = .cizgili { didSet { redraw() } }
    var pageScale: CGFloat = 1 { didSet { if pageScale != oldValue { redraw() } } }
    var isWhiteboard = false
    /// Doluysa desen yerine bu PDF sayfası çizilir
    var pdfPage: PDFPage? {
        didSet { if oldValue !== pdfPage { redraw() } }
    }

    /// Döşemeler arka planda çizilir; orada kullanılan değerlerin ana iş parçacığındaki kopyası
    private struct Snapshot {
        var style: PaperStyle
        var scale: CGFloat
        var whiteboard: Bool
        var pdf: PDFPage?
        var traits: UITraitCollection
        var size: CGSize
    }
    private let lock = NSLock()
    private var snap = Snapshot(style: .cizgili, scale: 1, whiteboard: false, pdf: nil,
                                traits: UITraitCollection(userInterfaceStyle: .light), size: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 3
            tiled.tileSize = CGSize(width: 512, height: 512)
        }
        layer.shadowColor = UIColor(hex: 0x28220F).cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: PaperUIView, _: UITraitCollection) in
            v.redraw()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = isWhiteboard ? nil : UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
        layer.shadowOpacity = isWhiteboard ? 0 : 0.12
        if snapshotValue().size != bounds.size { redraw() }
    }

    private func snapshotValue() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    private func redraw() {
        let s = Snapshot(style: style, scale: pageScale, whiteboard: isWhiteboard, pdf: pdfPage,
                         traits: UITraitCollection(userInterfaceStyle: traitCollection.userInterfaceStyle),
                         size: bounds.size)
        lock.lock(); snap = s; lock.unlock()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let s = snapshotValue()
        let bounds = CGRect(origin: .zero, size: s.size)
        if let pdf = s.pdf {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(bounds)
            PDFRender.draw(pdf, in: bounds, context: ctx)
            return
        }
        let tc = s.traits
        let page = UIBezierPath(roundedRect: bounds, cornerRadius: s.whiteboard ? 0 : 6)
        ctx.addPath(page.cgPath)
        ctx.setFillColor(Y.paperUI.resolvedColor(with: tc).cgColor)
        ctx.fillPath()
        PaperPattern.draw(s.style, in: bounds, scale: s.scale) { path, color, width in
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
    /// Son yerleşimin yapıldığı yakınlık
    private var laidOutZoom: CGFloat = 0
    /// Kanonik → ekran (yakınlaştırma dahil); notlar bununla konumlanır
    var viewMapping: CGAffineTransform { mapping.concatenating(CGAffineTransform(scaleX: zoomScale, y: zoomScale)) }
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
        let m = viewMapping
        for v in noteViews {
            v.scale = m.a
            v.frame = v.note.frame.applying(m)
            bringSubviewToFront(v)
        }
        layoutImages()
        bringSubviewToFront(cursor)
    }

    /// Sürüklenen notun yeni yerini kanonik koordinata çevirir ve sayfanın içinde tutar
    private func finishMove(_ v: StickyNoteView) {
        let m = viewMapping
        var f = v.frame.applying(m.inverted())
        f.size.width = min(max(f.width, StickyNote.minSize.width), canonical.width)
        f.size.height = min(max(f.height, StickyNote.minSize.height), canonical.height)
        f.origin.x = min(max(f.minX, 0), canonical.width - f.width)
        f.origin.y = min(max(f.minY, 0), canonical.height - f.height)
        v.note.frame = f
        UIView.animate(withDuration: 0.2) { v.frame = f.applying(m) }
        notesChanged()
    }

    private func notesChanged() { onNotesChange?(noteViews.map(\.note)) }

    // MARK: Resimler

    var notebookID: UUID?
    var onImagesChange: (([PageImage]) -> Void)?
    private var images: [PageImage] = []
    private var imageViews: [UUID: UIImageView] = [:]
    private let imageSelection = ImageSelectionView()
    private(set) var selectedImage: UUID?

    func setImages(_ list: [PageImage]) {
        selectImage(nil)
        imageViews.values.forEach { $0.removeFromSuperview() }
        imageViews = [:]
        images = list
        list.forEach(addImageView)
        layoutImages()
    }

    private func addImageView(_ img: PageImage) {
        let v = UIImageView()
        v.contentMode = .scaleToFill
        v.isUserInteractionEnabled = false
        v.accessibilityIgnoresInvertColors = true
        // Kâğıdın içinde durur: hep mürekkebin altında kalır, üstüne kalemle yazılabilir
        if let nid = notebookID { v.image = ImageStore.image(nid, img.file) }
        paper.addSubview(v)
        imageViews[img.id] = v
    }

    /// Kanonik → kâğıdın kendi koordinatı (kâğıt yakınlaştırmayı kendi dönüşümüyle yapar)
    private var paperMapping: CGAffineTransform { CGAffineTransform(scaleX: mapping.a, y: mapping.a) }

    private func layoutImages() {
        let m = viewMapping
        for img in images { imageViews[img.id]?.frame = img.frame.applying(paperMapping) }
        if let s = selectedImage, let img = images.first(where: { $0.id == s }) {
            let p = ImageSelectionView.pad
            imageSelection.frame = img.frame.applying(m).insetBy(dx: -p, dy: -p)
            imageSelection.isHidden = false
            bringSubviewToFront(imageSelection)
        } else {
            imageSelection.isHidden = true
        }
    }

    private func setupSelection() {
        guard imageSelection.superview == nil else { return }
        imageSelection.isHidden = true
        imageSelection.onMove = { [weak self] r in
            guard let self, let s = self.selectedImage else { return }
            self.imageViews[s]?.frame = self.paper.convert(r, from: self)
            let p = ImageSelectionView.pad
            self.imageSelection.frame = r.insetBy(dx: -p, dy: -p)
        }
        imageSelection.onMoveEnded = { [weak self] in self?.finishImageMove() }
        imageSelection.onDelete = { [weak self] in self?.deleteSelectedImage() }
        addSubview(imageSelection)
    }

    /// Taşınan/boyutlanan resmi kanonik koordinata çevirir ve sayfanın içinde tutar
    private func finishImageMove() {
        guard let s = selectedImage, let i = images.firstIndex(where: { $0.id == s }), let v = imageViews[s] else { return }
        var f = convert(v.frame, from: paper).applying(viewMapping.inverted())
        let ratio = f.height / max(f.width, 1)
        f.size.width = min(max(f.width, PageImage.minWidth), canonical.width)
        f.size.height = f.width * ratio
        if f.height > canonical.height { f.size.height = canonical.height; f.size.width = f.height / ratio }
        f.origin.x = min(max(f.minX, 0), canonical.width - f.width)
        f.origin.y = min(max(f.minY, 0), canonical.height - f.height)
        images[i].frame = f
        UIView.animate(withDuration: 0.18) { self.layoutImages() }
        onImagesChange?(images)
    }

    private func deleteSelectedImage() {
        guard let s = selectedImage else { return }
        let v = imageViews.removeValue(forKey: s)
        images.removeAll { $0.id == s }
        selectImage(nil)
        UIView.animate(withDuration: 0.18, animations: { v?.alpha = 0 }, completion: { _ in v?.removeFromSuperview() })
        onImagesChange?(images)
    }

    func selectImage(_ id: UUID?) {
        setupSelection()
        selectedImage = id
        layoutImages()
    }

    /// Parmakla dokunma: altındaki en üstteki resmi seç, boş yere dokununca seçimi kaldır
    func handleImageTap(at p: CGPoint) {
        if noteViews.contains(where: { $0.frame.contains(p) }) { return }
        if !imageSelection.isHidden, imageSelection.frame.contains(p) { return }
        let m = viewMapping
        let hit = images.last { $0.frame.applying(m).contains(p) }
        selectImage(hit?.id)
    }

    /// Görünen alanın ortasına yeni resim koyar ve seçer
    func addImage(file: String, pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let visible = bounds.intersection(paper.frame)
        let c = CGPoint(x: visible.midX, y: visible.midY).applying(viewMapping.inverted())
        var w = canonical.width * 0.6
        var h = w * pixelSize.height / pixelSize.width
        if h > canonical.height * 0.7 { h = canonical.height * 0.7; w = h * pixelSize.width / pixelSize.height }
        let x = min(max(c.x - w / 2, 0), canonical.width - w)
        let y = min(max(c.y - h / 2, 0), canonical.height - h)
        let img = PageImage(file: file, x: x, y: y, w: w, h: h)
        images.append(img)
        addImageView(img)
        imageViews[img.id]?.alpha = 0
        selectImage(img.id)
        UIView.animate(withDuration: 0.25) { self.imageViews[img.id]?.alpha = 1 }
        onImagesChange?(images)
    }

    /// Seçili aracı hem sayfaya hem notların kalem katmanına uygular
    func applyTool(_ t: PKTool) {
        tool = t
        noteViews.forEach { $0.setTool(t) }
    }

    /// Notun üstünde çizim başlamasın; basılı tutma ve sürükleme nota gitsin
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Seçili resmi taşırken/boyutlandırırken sayfa kaymasın
        if g === panGestureRecognizer, !imageSelection.isHidden,
           imageSelection.frame.insetBy(dx: -12, dy: -12).contains(g.location(in: self)) {
            return false
        }
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
        let center = CGPoint(x: visible.midX, y: visible.midY).applying(viewMapping.inverted())
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
        let z = zoomScale
        let mapChanged = newMap != mapping
        if mapChanged {
            // Döndürme / yeniden boyutlandırmada çizimi yeni yerleşime taşı
            let old = mapping
            mapping = newMap
            if !drawing.strokes.isEmpty {
                drawing = drawing.transformed(using: old.inverted().concatenating(newMap))
            }
            paper.isWhiteboard = isWhiteboard
            paper.style = style
            paper.pageScale = s
        }
        if mapChanged || z != laidOutZoom {
            laidOutZoom = z
            // Kâğıt yakınlığa göre büyür (döşemeli katman her düzeyde net çizer); çizim koordinatları değişmez
            paper.transform = .identity
            paper.frame = CGRect(origin: .zero, size: r.size)
            paper.transform = CGAffineTransform(scaleX: z, y: z)
            paper.center = CGPoint(x: r.midX * z, y: r.midY * z)
            contentSize = CGSize(width: max(bounds.width, r.maxX) * z, height: (r.maxY + bottomRoom) * z)
            layoutNotes()
        }
        if mapChanged { onLayoutChange?() }
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
    func addImage(file: String, pixelSize: CGSize) { canvas?.addImage(file: file, pixelSize: pixelSize) }

    /// Bekleyen (gecikmeli) çizim kaydını hemen yazar
    var flushHandler: (() -> Void)?
    func flush() { flushHandler?() }

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
    var notebookID: UUID? = nil
    var images: [PageImage] = []
    var onImagesChange: ((UUID, [PageImage]) -> Void)? = nil
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
        c.maximumZoomScale = 4
        c.bouncesZoom = true
        c.applyTool(tool)
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = context.coordinator
        context.coordinator.pageID = pageID
        let pending = data
        let pendingNotes = notes
        let pendingImages = images
        c.notebookID = notebookID
        c.onImagesChange = { [weak coord = context.coordinator] list in
            guard let coord, let pid = coord.pageID else { return }
            coord.parent.onImagesChange?(pid, list)
        }
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
            c.setImages(pendingImages)
            c.setNotes(pendingNotes)
            coord.suppress = false
        }
        // Parmakla resme dokununca seç (taşı/boyutlandır/sil); boş yere dokununca bırak
        let imageTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.imageTap(_:)))
        imageTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        imageTap.cancelsTouchesInView = false
        imageTap.delegate = context.coordinator
        c.addGestureRecognizer(imageTap)

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
        controller.flushHandler = { [weak c, weak coord = context.coordinator] in
            if let c, let coord { coord.flush(c) }
        }
        return c
    }

    func updateUIView(_ c: YaprakCanvas, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if coord.loaded, coord.pageID != pageID {
            // Önce eski sayfayı kaydet, sonra yeni sayfayı yükle (kitap sayfası animasyonuyla)
            c.endEditing(true)
            coord.flush(c)
            let newData = data, newNotes = notes, newImages = images, newPDF = pdfPage, pid = pageID
            c.animatePageTurn(forward: turnForward) {
                coord.pageID = pid
                // Yeni sayfa sayfaya sığar halde açılsın
                c.setZoomScale(1, animated: false)
                c.paper.pdfPage = newPDF
                coord.suppress = true
                c.load(newData)
                c.setImages(newImages)
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

        @objc func imageTap(_ g: UITapGestureRecognizer) {
            guard let c = g.view as? YaprakCanvas else { return }
            c.handleImageTap(at: g.location(in: c))
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

        /// Yakınlaştırılmışken kaydırma sayfayı gezdirir, sayfa çevirmez
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UISwipeGestureRecognizer, let c = g.view as? UIScrollView { return c.zoomScale < 1.02 }
            return true
        }

        /// "Yalnızca Pencil ile çiz" açıkken parmakla kaydırırken imleç çıkmasın
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g is UISwipeGestureRecognizer {
                // Sayfa çevirme parmakla; yapışkan notu sürüklerken/yazarken sayfa değişmesin
                guard touch.type == .direct else { return false }
                var v = touch.view
                while let x = v {
                    if x is StickyNoteView || x is ImageSelectionView { return false }
                    v = x.superview
                }
                return true
            }
            if g is UITapGestureRecognizer { return touch.type == .direct }
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
