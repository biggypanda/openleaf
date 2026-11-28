import SwiftUI
import PencilKit
import PDFKit

// MARK: - Kâğıt deseni (önizleme ve sayfa altlığı aynı kodu kullanır)

enum PaperPattern {
    enum Align { case leading, center }
    typealias Stroke = (Path, UIColor, CGFloat) -> Void
    typealias Fill = (Path, UIColor) -> Void
    /// Şablon yazısı: (yazı, konum, punto, hizalama). Konum yazının dikey ortasıdır;
    /// yatayda hizalamaya göre sol kenarı ya da ortası.
    typealias Label = (String, CGPoint, CGFloat, Align) -> Void

    /// `s` = sayfa ölçeği (kanonik sayfa genişliği 768 pt)
    static func draw(_ style: PaperStyle, in r: CGRect, scale s: CGFloat,
                     stroke: Stroke, fill: Fill, text: Label = { _, _, _, _ in }) {
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
        default:
            drawTemplate(style, in: r, scale: s, stroke: stroke, fill: fill, text: text)
        }
    }
}

/// Parçaları solmadan hemen gösteren döşemeli katman
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// Yakınlaşınca PDF sayfasını vektör döşemelerle net çizen katmanın çizicisi (döşemeler arka planda çizilir)
private final class PDFTileDrawer: NSObject, CALayerDelegate {
    private let lock = NSLock()
    private var page: PDFPage?
    private var size: CGSize = .zero

    func set(_ page: PDFPage?, size: CGSize) {
        lock.lock(); self.page = page; self.size = size; lock.unlock()
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        lock.lock(); let page = self.page, size = self.size; lock.unlock()
        guard let page, size.width > 0 else { return }
        PDFRender.draw(page, in: CGRect(origin: .zero, size: size), context: ctx)
    }

    /// Kare dışı özellik değişimlerinde örtük animasyon olmasın
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// Tuvalin altında duran kâğıt yüzeyi. Yakınlaştırınca bulanıklaşmasın diye döşemeli katmanla
/// (her yakınlık düzeyinde yeniden) çizilir.
/// PDF sayfası ekran çözünürlüğünde bir kez bitmap'e çizilir ve komşu sayfalar önceden hazırlanır:
/// sayfa çevrilirken döşemeler parça parça gelip sayfa pikselli görünmesin, yavaş iPad'de takılmasın.
/// Yakınlaşınca bitmap'in üstünde vektör döşemeler net çizilir; döşeme gelmeden bitmap görünür.
final class PaperUIView: UIView {
    override class var layerClass: AnyClass { InstantTiledLayer.self }

    var style: PaperStyle = .cizgili { didSet { redraw() } }
    var pageScale: CGFloat = 1 { didSet { if pageScale != oldValue { redraw() } } }
    var isWhiteboard = false
    /// Doluysa desen yerine bu PDF sayfası çizilir
    var pdfPage: PDFPage? {
        didSet {
            if oldValue !== pdfPage {
                redraw()
                showPDFImage(waitIfMissing: true)
            }
        }
    }
    /// Tuvalin yakınlık oranı; 1'den büyükse PDF vektör döşemelerle de çizilir
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { updateDetail() } } }

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

    /// Ekran çözünürlüğünde hazır PDF sayfası
    private let imageLayer = CALayer()
    /// Yakınlaşınca bitmap'in üstünde net vektör döşemeler
    private let detailLayer = InstantTiledLayer()
    private let tileDrawer = PDFTileDrawer()

    /// Hazır sayfa bitmap'leri (açık sayfa ve komşuları)
    private struct Rendered {
        let page: PDFPage
        let pixels: CGSize
        let image: CGImage
    }
    private var cache: [Rendered] = []
    private static let cacheLimit = 3
    /// Arka plan çizimleri sırayla yapılır; aynı anda çok sayfa çizilip cihaz yorulmasın
    private static let renderQueue = DispatchQueue(label: "openleaf.paper.render", qos: .userInitiated)
    /// Arka planda çizilmekte olan sayfalar (aynı sayfa iki kez sıraya girmesin)
    private var pending: Set<ObjectIdentifier> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 3
            tiled.tileSize = CGSize(width: 512, height: 512)
        }
        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        imageLayer.isHidden = true
        layer.addSublayer(imageLayer)
        detailLayer.levelsOfDetail = 4
        detailLayer.levelsOfDetailBias = 3
        detailLayer.tileSize = CGSize(width: 512, height: 512)
        detailLayer.delegate = tileDrawer
        detailLayer.isHidden = true
        layer.addSublayer(detailLayer)
        layer.shadowColor = UIColor(hex: 0x28220F).cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: PaperUIView, _: UITraitCollection) in
            v.redraw()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (v: PaperUIView, _: UITraitCollection) in
            v.showPDFImage(waitIfMissing: false)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = isWhiteboard ? nil : UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
        layer.shadowOpacity = isWhiteboard ? 0 : 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        detailLayer.frame = bounds
        CATransaction.commit()
        if snapshotValue().size != bounds.size {
            redraw()
            // Boyut değişince (döndürme, bölünmüş ekran) eski bitmap esnetilmiş görünür, yenisi arka planda çizilir
            showPDFImage(waitIfMissing: false)
            updateDetail()
        }
    }

    private func snapshotValue() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    private func redraw() {
        let s = Snapshot(style: style, scale: pageScale, whiteboard: isWhiteboard, pdf: pdfPage,
                         traits: UITraitCollection(userInterfaceStyle: traitCollection.userInterfaceStyle),
                         size: bounds.size)
        lock.lock(); snap = s; lock.unlock()
        setNeedsDisplay()
    }

    // MARK: PDF bitmap'i

    private var pixelSize: CGSize {
        let scale = traitCollection.displayScale
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    private func cached(_ page: PDFPage, _ pixels: CGSize) -> CGImage? {
        cache.first { $0.page === page && $0.pixels == pixels }?.image
    }

    private func store(_ page: PDFPage, _ pixels: CGSize, _ image: CGImage) {
        cache.removeAll { $0.page === page }
        cache.append(Rendered(page: page, pixels: pixels, image: image))
        // Açık sayfayı hiç atma; en eski komşudan başla
        while cache.count > Self.cacheLimit,
              let i = cache.firstIndex(where: { $0.page !== pdfPage }) {
            cache.remove(at: i)
        }
    }

    private static func render(_ page: PDFPage, pixels: CGSize) -> CGImage? {
        PDFRender.image(page, size: pixels, scale: 1).cgImage
    }

    /// Açık PDF sayfasının bitmap'ini gösterir. `waitIfMissing` ise (sayfa değişti) hazır değilse hemen çizer:
    /// sayfa çevirme animasyonu yarım döşemeyle değil, net sayfayla başlasın.
    private func showPDFImage(waitIfMissing: Bool) {
        guard let page = pdfPage, bounds.width > 0, bounds.height > 0 else {
            imageLayer.contents = nil
            imageLayer.isHidden = true
            updateDetail()
            return
        }
        let pixels = pixelSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = cached(page, pixels) {
            imageLayer.contents = image
        } else if waitIfMissing, let image = Self.render(page, pixels: pixels) {
            store(page, pixels, image)
            imageLayer.contents = image
        } else {
            // Eski bitmap (başka sayfanınsa) yanlış sayfa göstermesin
            if waitIfMissing { imageLayer.contents = nil }
            renderInBackground(page, pixels: pixels)
        }
        imageLayer.isHidden = false
        CATransaction.commit()
        updateDetail()
        prefetchNeighbors(of: page, pixels: pixels)
    }

    private func renderInBackground(_ page: PDFPage, pixels: CGSize) {
        let id = ObjectIdentifier(page)
        guard !pending.contains(id) else { return }
        pending.insert(id)
        Self.renderQueue.async { [weak self] in
            let image = Self.render(page, pixels: pixels)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(id)
                guard let image else { return }
                // Bu arada boyut değiştiyse eski boyutta çizilmiş bitmap'i saklama
                guard pixels == self.pixelSize else {
                    if self.pdfPage === page { self.showPDFImage(waitIfMissing: false) }
                    return
                }
                self.store(page, pixels, image)
                if self.pdfPage === page {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageLayer.contents = image
                    CATransaction.commit()
                }
            }
        }
    }

    private func prefetchNeighbors(of page: PDFPage, pixels: CGSize) {
        guard let doc = page.document else { return }
        let i = doc.index(for: page)
        for j in [i + 1, i - 1] where j >= 0 && j < doc.pageCount {
            guard let next = doc.page(at: j), cached(next, pixels) == nil else { continue }
            renderInBackground(next, pixels: pixels)
        }
    }

    /// Yakınlaşınca vektör döşemeleri aç, sayfaya sığarken kapat (bitmap zaten net)
    private func updateDetail() {
        let on = pdfPage != nil && zoom > 1.01
        tileDrawer.set(on ? pdfPage : nil, size: bounds.size)
        if on {
            if detailLayer.isHidden { detailLayer.isHidden = false }
            detailLayer.setNeedsDisplay()
        } else if !detailLayer.isHidden {
            detailLayer.isHidden = true
            detailLayer.contents = nil
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let s = snapshotValue()
        let bounds = CGRect(origin: .zero, size: s.size)
        if s.pdf != nil {
            // Sayfanın kendisi bitmap ve döşeme katmanlarında; burada yalnız beyaz zemin
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(bounds)
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
        } text: { string, point, size, align in
            PaperText.draw(string, at: point, size: size, align: align,
                           color: Y.paperTextUI.resolvedColor(with: tc), in: ctx)
        }
    }
}

// MARK: - Tuval

/// Çizimler kanonik sayfa koordinatlarında saklanır (genişlik 768); ekranda sayfa genişliğine ölçeklenir.
final class OpenLeafCanvas: PKCanvasView {
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
        // Her yeni dokunuş buradan geçer: PencilKit'in bu dokunuşla çizip çizmeyeceğine şimdi karar ver
        updateDrawingGate(at: point)
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
        layoutTapes(m)
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

    /// Uzaktan (eşitlemeyle) gelen not, resim ve bantları açık sayfaya uygular (I4). Değişmeyen not görünümleri
    /// yerinde kalır; klavyeyle yazılmakta olan not dokunulmadan korunur (yazan kazanır) ve uzaktaki hâlden
    /// farklıysa listenin tamamı geri bildirilir, böylece sonraki kayıt uzaktan gelenleri silmez.
    func applyRemoteItems(notes: [StickyNote], images list: [PageImage], tapes newTapes: [Tape]) {
        if list != images {
            let selected = selectedImage
            setImages(list)
            if let selected, list.contains(where: { $0.id == selected }) { selectImage(selected) }
        } else if let nid = notebookID {
            // Liste aynı; dosyası sonradan gelen resim artık gösterilebilir
            for img in images { if let v = imageViews[img.id], v.image == nil { v.image = ImageStore.image(nid, img.file) } }
        }
        if newTapes != tapes {
            // Çekilmekte olan bant (taslak) iptal edilmez; bitince güncel listeye eklenir
            tapes = newTapes
            revealedTapes.formIntersection(newTapes.map(\.id))
            rebuildTapeViews()
        }
        guard notes != noteViews.map(\.note) else { return }
        let busy = noteViews.filter { $0.isFirstResponderInside }
        var result: [StickyNoteView] = []
        var used = Set<ObjectIdentifier>()
        var keptLocal = false
        for n in notes {
            if let v = busy.first(where: { $0.note.id == n.id }) {
                if v.note != n { keptLocal = true }
                result.append(v)
            } else if let v = noteViews.first(where: { $0.note == n && !used.contains(ObjectIdentifier($0)) }) {
                result.append(v)
            } else {
                result.append(makeNoteView(n))
            }
            used.insert(ObjectIdentifier(result[result.count - 1]))
        }
        // Uzakta silinmiş ama burada yazılmakta olan not kalır
        for v in busy where !used.contains(ObjectIdentifier(v)) {
            result.append(v)
            used.insert(ObjectIdentifier(v))
            keptLocal = true
        }
        for v in noteViews where !used.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
        noteViews = result
        layoutNotes()
        if keptLocal { notesChanged() }
    }

    // MARK: Bantlar

    var onTapesChange: (([Tape]) -> Void)?
    /// Bant aracı seçili: kalem (parmakla çizim açıksa parmak da) mürekkep yerine bant çeker
    var tapeMode = false {
        didSet {
            if oldValue, !tapeMode { cancelTapeDrag() }
            updateDrawingGate()
        }
    }
    /// Silgi seçili: bantın üstünde başlayan silgi dokunuşu mürekkebi değil bantı siler
    var erasesTapes = false {
        didSet {
            if oldValue, !erasesTapes { erasingTapes = false }
            updateDrawingGate()
        }
    }
    var tapeColor: TapeColor = .sari
    /// Yeni şerit bantların kalınlığı (kanonik)
    var tapeThickness: CGFloat = 30
    private var tapes: [Tape] = []
    private var tapeViews: [UUID: TapeView] = [:]
    /// Dokunulup açılmış bantlar (saklanmaz; sayfa her açılışta kapalı gelir)
    private var revealedTapes: Set<UUID> = []
    /// Sürüklenirken gösterilen taslak bant ve sürüklemenin başladığı nokta (kanonik)
    private var draftTape: TapeView?
    private var tapeDragStart: CGPoint?
    /// Süren silgi dokunuşu bir bantın üstünde başladı
    private var erasingTapes = false

    /// PencilKit'in çizim/silme hareketini açıp kapatır. Bant aracında hep kapalıdır; silgide dokunuş
    /// bir bantın üstüne iniyorsa o dokunuş için kapanır (bant silinir, altındaki yazı silinmez).
    /// Hareketi kapatmak tek güvenilir yol: `gestureRecognizerShouldBegin` çizim hareketi için çağrılmıyor,
    /// açık kalırsa bantın altındaki (görünmeyen) yazı fark edilmeden silinebilir.
    func updateDrawingGate(at point: CGPoint? = nil) {
        var allow = !tapeMode
        if allow, erasesTapes, let p = point, tape(at: p) != nil { allow = false }
        if drawingGestureRecognizer.isEnabled != allow { drawingGestureRecognizer.isEnabled = allow }
    }

    func setTapes(_ list: [Tape]) {
        cancelTapeDrag()
        erasingTapes = false
        revealedTapes = []
        tapes = list
        rebuildTapeViews()
    }

    private func rebuildTapeViews() {
        tapeViews.values.forEach { $0.removeFromSuperview() }
        tapeViews = [:]
        for t in tapes {
            let v = TapeView(color: t.color)
            v.revealed = revealedTapes.contains(t.id)
            v.onActivate = { [weak self] in self?.toggleTape(t.id) }
            addSubview(v)
            tapeViews[t.id] = v
        }
        layoutNotes()
    }

    /// Bantlar mürekkebin üstünde, yapışkan notların altında durur
    private func layoutTapes(_ m: CGAffineTransform) {
        for t in tapes {
            guard let v = tapeViews[t.id] else { continue }
            v.scale = m.a
            v.frame = t.frame.applying(m)
            bringSubviewToFront(v)
        }
        if let d = draftTape { bringSubviewToFront(d) }
    }

    /// Bant listesini değiştirir (ekleme/silme); geri alınabilir
    private func changeTapes(_ new: [Tape]) {
        let old = tapes
        undoManager?.registerUndo(withTarget: self) { $0.changeTapes(old) }
        tapes = new
        revealedTapes.formIntersection(new.map(\.id))
        rebuildTapeViews()
        onTapesChange?(tapes)
    }

    /// Ekran noktasının altındaki en üstteki bant (küçük bantlara dokunmak kolay olsun diye biraz payla)
    private func tape(at p: CGPoint) -> Tape? {
        let c = p.applying(viewMapping.inverted())
        return tapes.last { $0.frame.insetBy(dx: -4, dy: -4).contains(c) }
    }

    private func setRevealed(_ on: Bool, _ id: UUID) {
        guard let v = tapeViews[id], v.revealed != on else { return }
        UIView.transition(with: v, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            v.revealed = on
        }
    }

    /// Bantı açar (altı görünür) ya da yeniden kapatır
    func toggleTape(_ id: UUID) {
        let on = !revealedTapes.contains(id)
        if on { revealedTapes.insert(id) } else { revealedTapes.remove(id) }
        setRevealed(on, id)
    }

    func setAllTapesRevealed(_ on: Bool) {
        revealedTapes = on ? Set(tapes.map(\.id)) : []
        tapes.forEach { setRevealed(on, $0.id) }
    }

    private func cancelTapeDrag() {
        draftTape?.removeFromSuperview()
        draftTape = nil
        tapeDragStart = nil
    }

    /// Kalem/parmak dokunuşunu bant aracı ve silgi için izler (çizimle aynı dokunuş kurallarıyla gelir).
    /// Dokunuşu bant aracı kullandıysa true döner.
    func tapeTouch(_ state: UIGestureRecognizer.State, at p: CGPoint) -> Bool {
        if tapeMode { trackTapeDrag(state, at: p); return true }
        if erasesTapes { trackTapeErase(state, at: p) }
        return false
    }

    /// Bant aracı: sürükleme yeni bant çeker, dokunma alttaki bantı açıp kapatır
    private func trackTapeDrag(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        let toPage = viewMapping.inverted()
        func rect(to b: CGPoint) -> CGRect? {
            guard let a = tapeDragStart, hypot(b.x - a.x, b.y - a.y) >= Tape.minLength else { return nil }
            let r = Tape.rect(from: a, to: b, thickness: tapeThickness)
                .intersection(CGRect(origin: .zero, size: canonical))
            return r.isNull || min(r.width, r.height) < 6 ? nil : r
        }
        switch state {
        case .began:
            cancelTapeDrag()
            if !noteViews.contains(where: { $0.frame.contains(p) }) { tapeDragStart = p.applying(toPage) }
        case .changed:
            guard tapeDragStart != nil else { return }
            guard let r = rect(to: p.applying(toPage)) else { draftTape?.isHidden = true; return }
            let v: TapeView
            if let d = draftTape { v = d } else {
                v = TapeView(color: tapeColor)
                v.alpha = 0.8
                v.isAccessibilityElement = false
                addSubview(v)
                draftTape = v
            }
            v.isHidden = false
            v.scale = viewMapping.a
            v.frame = r.applying(viewMapping)
        case .ended:
            guard let a = tapeDragStart else { return }
            let b = p.applying(toPage)
            let r = rect(to: b)
            let moved = draftTape != nil || hypot(b.x - a.x, b.y - a.y) >= Tape.minLength
            cancelTapeDrag()
            if let r {
                var t = Tape(x: 0, y: 0, w: 0, h: 0, color: tapeColor)
                t.frame = r
                changeTapes(tapes + [t])
            } else if !moved, let t = tape(at: p) {
                toggleTape(t.id)
            }
        default:
            cancelTapeDrag()
        }
    }

    /// Silgi: bantın üstünde başlayan dokunuş, geçtiği bantları siler
    private func trackTapeErase(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        switch state {
        case .began:
            erasingTapes = tape(at: p) != nil && !noteViews.contains(where: { $0.frame.contains(p) })
        case .changed, .ended:
            if erasingTapes, let t = tape(at: p) { changeTapes(tapes.filter { $0.id != t.id }) }
            if state == .ended { erasingTapes = false }
        default:
            erasingTapes = false
        }
    }

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
            imageSelection.locked = img.isLocked
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
        imageSelection.onToggleLock = { [weak self] in self?.toggleSelectedImageLock() }
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

    /// Seçili resmi yerine kilitler ya da kilidini açar
    private func toggleSelectedImageLock() {
        guard let s = selectedImage, let i = images.firstIndex(where: { $0.id == s }) else { return }
        images[i].locked = images[i].isLocked ? nil : true
        layoutImages()
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
        // Parmak çizmiyorken (yalnızca Pencil) banta parmakla dokunmak onu açıp kapatır.
        // Parmakla çizim açıkken bunu bant aracı yapar (`tapeTouch`).
        if drawingPolicy == .pencilOnly, let t = tape(at: p) { toggleTape(t.id); return }
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
        // Bant çekerken sayfa kaymasın
        if g === panGestureRecognizer, tapeDragStart != nil { return false }
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
                // Yerleşim değişikliği kullanıcının çizimi değil: kayıt ve "değişti" tarihi tetiklenmesin
                isApplyingLayout = true
                drawing = drawing.transformed(using: old.inverted().concatenating(newMap))
                isApplyingLayout = false
                scheduleRenderRefresh()
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
            paper.zoom = z
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
        if !d.strokes.isEmpty { scheduleRenderRefresh() }
    }

    /// Düzen kaynaklı çizim atamasında kaydı bastırmak için (bkz. Coordinator)
    private(set) var isApplyingLayout = false
    private var renderRefresh: DispatchWorkItem?

    /// Açılış geçişi sürerken yapılan atamalarda PencilKit'in ilk çizimi yarım kalabiliyor
    /// (çizgilerin son kısımları görünmüyor). Yerleşim oturduktan sonra çizimi bir kez yeniden atayıp
    /// tam olarak yeniden çizdirir. Kullanıcı değişikliği sayılmaz.
    private func scheduleRenderRefresh() {
        renderRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, !self.drawing.strokes.isEmpty else { return }
            // Kullanıcı tam o an çiziyorsa çizgisini kesme; biraz sonra yeniden dene
            if self.drawingGestureRecognizer.state != .possible { self.scheduleRenderRefresh(); return }
            let current = self.drawing
            // Geri alma geçmişine adım eklenmesin
            self.undoManager?.disableUndoRegistration()
            self.isApplyingLayout = true
            self.drawing = PKDrawing()
            self.drawing = current
            self.isApplyingLayout = false
            self.undoManager?.enableUndoRegistration()
        }
        renderRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    var canonicalData: Data { drawing.transformed(using: mapping.inverted()).dataRepresentation() }
}

@Observable
final class CanvasController {
    weak var canvas: OpenLeafCanvas?
    var canUndo = false
    var canRedo = false

    func addNote() { canvas?.addNote() }
    func addImage(file: String, pixelSize: CGSize) { canvas?.addImage(file: file, pixelSize: pixelSize) }
    /// Sayfadaki tüm bantları açar ya da kapatır
    func revealTapes(_ on: Bool) { canvas?.setAllTapesRevealed(on) }

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
    /// Son parametre: tuvalin gördüğü uzak öğe sürümü (I4; kütüphane eski listeyle uzaktan gelenleri silmesin)
    var onNotesChange: ((UUID, [StickyNote], Int) -> Void)? = nil
    var notebookID: UUID? = nil
    var images: [PageImage] = []
    var onImagesChange: ((UUID, [PageImage], Int) -> Void)? = nil
    /// Apple Pencil Pro sıkıldı: kalem ucunun pencere koordinatı (kalem havada değilse nil)
    var onPencilSqueeze: ((CGPoint?) -> Void)? = nil
    var tapes: [Tape] = []
    var onTapesChange: ((UUID, [Tape], Int) -> Void)? = nil
    /// Bant aracı seçili mi; silgi seçili mi (silgi bantları da siler)
    var tapeMode = false
    var erasesTapes = false
    var tapeColor: TapeColor = .sari
    var tapeThickness: CGFloat = 30
    /// PencilKit cetveli açık mı
    var ruler = false
    /// Açık sayfaya uzaktan (eşitlemeyle) gelen mürekkebin sayacı; artınca tuval yeniden yüklenir
    var remoteVersion = 0
    /// Açık sayfaya uzaktan gelen not, resim ve bantların sayacı; artınca bunlar yeniden uygulanır (I4)
    var remoteItemsVersion = 0
    /// Sayfanın güncel mürekkebi (uzaktan gelen uygulandıktan sonra)
    var latestData: ((UUID) -> Data)? = nil
    /// Uzaktan mürekkep geldiği sırada çizilen çizgiler: tuvaldeki hâl çakışma kopyasına alınır
    var onRemoteConflict: ((UUID, Data) -> Void)? = nil
    /// Kalem ekrandayken sayfa değişti; kalem kalkınca eski sayfanın tuvaldeki mürekkebi buraya teslim edilir
    var onPageGoneSave: ((UUID, Data) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Araçla birlikte değişen ayarlar (kurulumda ve her güncellemede)
    private func applySettings(_ c: OpenLeafCanvas) {
        c.applyTool(tool)
        c.cursorDiameter = eraserCursor
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.tapeMode = tapeMode
        c.erasesTapes = erasesTapes
        c.tapeColor = tapeColor
        c.tapeThickness = tapeThickness
        // Araç ya da çizim kuralı atanınca PencilKit hareketini yeniden açmış olabilir
        c.updateDrawingGate()
        if c.isRulerActive != ruler { c.isRulerActive = ruler }
    }

    func makeUIView(context: Context) -> OpenLeafCanvas {
        let c = OpenLeafCanvas()
        c.style = paper
        c.paper.pdfPage = pdfPage
        c.isWhiteboard = isWhiteboard
        // PDF'ler beyaz kâğıttır: koyu temada mürekkep tersine dönüp kaybolmasın
        // (düz deftere eklenmiş PDF sayfaları da)
        if isPDF || pdfPage != nil { c.overrideUserInterfaceStyle = .light }
        c.canonical = canonical
        c.backgroundColor = .clear
        c.isOpaque = false
        c.alwaysBounceVertical = true
        c.showsVerticalScrollIndicator = true
        c.minimumZoomScale = 1
        c.maximumZoomScale = 4
        c.bouncesZoom = true
        applySettings(c)
        c.delegate = context.coordinator
        context.coordinator.pageID = pageID
        context.coordinator.remoteSeen = remoteVersion
        context.coordinator.itemsSeen = remoteItemsVersion
        context.coordinator.itemsAsked = remoteItemsVersion
        let pending = data
        let pendingNotes = notes
        let pendingImages = images
        let pendingTapes = tapes
        c.notebookID = notebookID
        c.onTapesChange = { [weak coord = context.coordinator] list in
            guard let coord, let pid = coord.pageID else { return }
            coord.parent.onTapesChange?(pid, list, coord.itemsSeen)
            // Bant ekleme/silme geri alınabilir: düğmelerin durumunu güncelle
            DispatchQueue.main.async { [weak coord] in coord?.parent.controller.refresh() }
        }
        c.onImagesChange = { [weak coord = context.coordinator] list in
            guard let coord, let pid = coord.pageID else { return }
            coord.parent.onImagesChange?(pid, list, coord.itemsSeen)
        }
        c.onNotesChange = { [weak coord = context.coordinator] list in
            guard let coord, let pid = coord.pageID else { return }
            coord.parent.onNotesChange?(pid, list, coord.itemsSeen)
            // Not mürekkebi geri alınabilir: düğmelerin durumunu güncelle
            DispatchQueue.main.async { [weak coord] in coord?.parent.controller.refresh() }
        }
        c.onLayoutChange = { [weak c, weak coord = context.coordinator] in
            guard let c, let coord, !coord.loaded else { return }
            coord.loaded = true
            coord.suppress = true
            // Kurulumla yükleme arasında uzaktan mürekkep geldiyse güncel hâl yüklensin
            let same = coord.parent.pageID == coord.pageID
            c.load(same ? coord.parent.data : pending)
            coord.remoteSeen = coord.parent.remoteVersion
            // Not, resim ve bantlar için de güncel hâl (kurulumla yükleme arasında uzaktan gelmiş olabilir)
            c.setImages(same ? coord.parent.images : pendingImages)
            c.setTapes(same ? coord.parent.tapes : pendingTapes)
            c.setNotes(same ? coord.parent.notes : pendingNotes)
            if same {
                coord.itemsSeen = coord.parent.remoteItemsVersion
                coord.itemsAsked = coord.itemsSeen
            }
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

    func updateUIView(_ c: OpenLeafCanvas, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if coord.loaded, coord.pageID != pageID {
            if coord.isDrawing {
                // Açık sayfa kalem ekrandayken değişti (başka iPad'de silindi): çizgi kendi sayfasında
                // bitsin, geçiş kalem kalkınca yapılır
                coord.deferPageChange()
            } else {
                // Önce eski sayfayı kaydet, sonra yeni sayfayı yükle
                c.endEditing(true)
                coord.flush(c)
                turnPage(c, coord)
            }
        } else if coord.loaded, coord.pageID == pageID, coord.remoteSeen != remoteVersion {
            // Açık sayfaya uzaktan mürekkep geldi; sayfa değişmeden yeniden yüklenir
            coord.remoteSeen = remoteVersion
            coord.remoteArrived(c)
        }
        if coord.loaded, coord.pageID == pageID, coord.itemsAsked != remoteItemsVersion {
            // Açık sayfaya uzaktan not, resim ya da bant geldi (I4): bir sonraki kayıt bunları eski listeyle ezmesin
            coord.itemsAsked = remoteItemsVersion
            coord.remoteItemsArrived(c)
        }
        applySettings(c)
        coord.oneFingerSwipes.forEach { $0.isEnabled = pencilOnly }
        controller.canvas = c
    }

    /// Yeni sayfayı yükler (kitap sayfası animasyonuyla). Eski sayfa çağırandan önce kaydedilmiş olmalı.
    func turnPage(_ c: OpenLeafCanvas, _ coord: Coordinator) {
        c.endEditing(true)
        coord.resetRemote(remoteVersion)
        coord.itemsSeen = remoteItemsVersion
        coord.itemsAsked = remoteItemsVersion
        let newData = data, newNotes = notes, newImages = images, newTapes = tapes, newPDF = pdfPage, pid = pageID
        let lightOnly = isPDF || newPDF != nil
        c.animatePageTurn(forward: turnForward) {
            coord.pageID = pid
            // Yeni sayfa sayfaya sığar halde açılsın
            c.setZoomScale(1, animated: false)
            c.paper.pdfPage = newPDF
            c.overrideUserInterfaceStyle = lightOnly ? .light : .unspecified
            coord.suppress = true
            c.load(newData)
            c.setImages(newImages)
            c.setTapes(newTapes)
            c.setNotes(newNotes)
            c.undoManager?.removeAllActions()
            coord.suppress = false
        }
        DispatchQueue.main.async { [weak controller] in controller?.refresh() }
        c.setContentOffset(CGPoint(x: -c.adjustedContentInset.left, y: -c.adjustedContentInset.top), animated: false)
    }

    static func dismantleUIView(_ c: OpenLeafCanvas, coordinator: Coordinator) {
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
        /// Kalem (ya da araç) ekranda mı
        private(set) var isDrawing = false
        /// Kalem ekrandayken sayfa değişti; geçiş kalem kalkınca yapılır
        var pageChangeDeferred = false
        /// Kalem inince tuvaldeki çizgi sayısı (gecikmeli geçişte çizim olup olmadığını anlamak için)
        private var strokesAtPenDown = 0
        /// Son kayıt ya da yüklemeden sonra kullanıcı çizimi değişti mi
        private var changedSinceSave = false
        /// Görülen son uzak mürekkep sayacı
        var remoteSeen = 0
        /// Tuvale uygulanmış son uzak not/resim/bant sayacı (kütüphaneye giden listeler bununla gider)
        var itemsSeen = 0
        /// Uygulanması istenmiş son sayaç (uygulama bir tur sonra yapılır)
        var itemsAsked = 0
        /// Uzaktan mürekkep geldi, tuval henüz yeniden yüklenmedi (çizim sürerken kalem kalkınca yüklenir)
        private var remotePending = false
        /// Uzaktan mürekkep geldikten sonra tuvalde çizim değişti: kaydedilmez, çakışma kopyasına gider
        private var strokeAfterRemote = false
        /// Tek parmakla sayfa çevirme (yalnızca parmak çizmiyorken açık)
        var oneFingerSwipes: [UISwipeGestureRecognizer] = []

        init(_ p: CanvasRepresentable) { parent = p }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Geri al adımı çizgi bitince kaydedilir; durumu bir tur sonra oku
            DispatchQueue.main.async { [weak self] in self?.parent.controller.refresh() }
            guard loaded, !suppress, let c = canvasView as? OpenLeafCanvas, !c.isApplyingLayout, let pid = pageID else { return }
            changedSinceSave = true
            if remotePending {
                // Uzaktan gelen mürekkebin üstüne yazılmasın; kalem kalkınca çakışma kopyası olur
                strokeAfterRemote = true
                return
            }
            // Sayfa geçişi bekliyor: eski sayfa silinmiş olabilir, kayıt geçişte teslim edilir
            if pageChangeDeferred { work?.cancel(); work = nil; return }
            work?.cancel()
            let item = DispatchWorkItem { [weak self, weak c] in
                guard let self, let c else { return }
                self.work = nil
                // Bu arada geçiş ertelendiyse silinmiş sayfaya (etkisiz) yazıp işareti silmesin
                guard !self.pageChangeDeferred else { return }
                self.changedSinceSave = false
                self.parent.onChange(pid, c.canonicalData)
            }
            work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }

        func flush(_ c: OpenLeafCanvas) {
            if pageChangeDeferred {
                // Kalem ekrandaysa geçişte teslim edilir; değilse (kapanış, arka plan) şimdi teslim et
                if !isDrawing { deliverDeferredInk(c) }
                return
            }
            if strokeAfterRemote, loaded, let pid = pageID {
                // Uzak mürekkep geldikten sonra çizilenler sayfaya değil çakışma kopyasına yazılır
                strokeAfterRemote = false
                parent.onRemoteConflict?(pid, c.canonicalData)
                return
            }
            guard work != nil, loaded, let pid = pageID else { return }
            work?.cancel(); work = nil
            changedSinceSave = false
            parent.onChange(pid, c.canonicalData)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = true
            strokesAtPenDown = canvasView.drawing.strokes.count
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = false
            guard remotePending || pageChangeDeferred, let c = canvasView as? OpenLeafCanvas else { return }
            // Bir tur sonra: biten çizginin `canvasViewDrawingDidChange`'i önce gelsin
            DispatchQueue.main.async { [weak self, weak c] in
                guard let self, let c else { return }
                if self.pageChangeDeferred { self.finishDeferredPageChange(c) } else { self.resolveRemote(c) }
            }
        }

        /// Kalem kalktı; ekrandayken kaybolan (ya da yer değiştiren) sayfadan yenisine geçilir.
        /// Tuvaldeki mürekkep, çizim olduysa ya da uzak mürekkep sonrası çizildiyse sayfa kimliğiyle teslim edilir:
        /// DocumentView sayfa duruyorsa kaydeder, silinmişse kurtarılmış yeni sayfa olarak saklar.
        private func finishDeferredPageChange(_ c: OpenLeafCanvas) {
            guard pageChangeDeferred, !isDrawing, loaded else { return }
            deliverDeferredInk(c)
            pageChangeDeferred = false
            remotePending = false
            if pageID != parent.pageID { parent.turnPage(c, self) }
        }

        /// Kalem ekrandayken sayfa değişti: bekleyen gecikmeli kayıt iptal edilir (silinmiş sayfaya etkisiz
        /// yazılıp kaydedildi sanılmasın); çizim geçişte `deliverDeferredInk` ile teslim edilir
        func deferPageChange() {
            pageChangeDeferred = true
            if work != nil {
                work?.cancel(); work = nil
                changedSinceSave = true
            }
        }

        /// Ertelenen geçişte tuvaldeki kaydedilmemiş mürekkebi sayfa kimliğiyle teslim eder
        private func deliverDeferredInk(_ c: OpenLeafCanvas) {
            // Bildirim sırasına bağlı kalmamak için çizgi sayısına da bakılır
            let dirty = changedSinceSave || strokeAfterRemote || work != nil
                || c.drawing.strokes.count != strokesAtPenDown
            work?.cancel(); work = nil
            if dirty, loaded, let pid = pageID {
                if strokeAfterRemote {
                    // Sayfa silinmişse DocumentView kurtarılmış sayfaya düşer
                    parent.onRemoteConflict?(pid, c.canonicalData)
                } else {
                    parent.onPageGoneSave?(pid, c.canonicalData)
                }
            }
            changedSinceSave = false
            strokeAfterRemote = false
            strokesAtPenDown = c.drawing.strokes.count
        }

        /// Açık sayfaya uzaktan mürekkep uygulandı. Çizim sürüyorsa kalem kalkınca, sürmüyorsa hemen yüklenir.
        func remoteArrived(_ c: OpenLeafCanvas) {
            remotePending = true
            if work != nil || isDrawing {
                // Eşitleme önce bekleyen kaydı yazar; yine de kalmışsa üstüne yazılmasın, kopyaya gitsin.
                // Kalem ekrandaysa çizgi her durumda kopyaya gider: kalem kalkınca bildirimlerin hangi
                // sırayla geldiğine bağlı kalmasın (çizgi sessizce kaybolmasın)
                work?.cancel(); work = nil
                strokeAfterRemote = true
            }
            guard !isDrawing else { return }
            // Görünüm güncellemesi sırasında kütüphane değiştirilmesin (çakışma kopyası) diye bir tur sonra
            DispatchQueue.main.async { [weak self, weak c] in
                if let self, let c { self.resolveRemote(c) }
            }
        }

        /// Açık sayfaya uzaktan not, resim ya da bant geldi. Görünüm güncellemesi bitince, o andaki güncel
        /// listelerle uygulanır (sayfa bu arada değiştiyse yeni sayfa zaten güncel listelerle yüklenir).
        func remoteItemsArrived(_ c: OpenLeafCanvas) {
            DispatchQueue.main.async { [weak self, weak c] in
                guard let self, let c, self.loaded, !self.pageChangeDeferred, self.pageID == self.parent.pageID else { return }
                self.suppress = true
                self.itemsSeen = self.parent.remoteItemsVersion
                c.applyRemoteItems(notes: self.parent.notes, images: self.parent.images, tapes: self.parent.tapes)
                self.suppress = false
            }
        }

        /// Sayfa değişti: önceki sayfanın bekleyen uzak yüklemesi yeni sayfaya taşınmasın
        func resetRemote(_ version: Int) {
            remoteSeen = version
            remotePending = false
            strokeAfterRemote = false
            changedSinceSave = false
            pageChangeDeferred = false
        }

        private func resolveRemote(_ c: OpenLeafCanvas) {
            guard remotePending, !isDrawing, loaded, let pid = pageID else { return }
            remotePending = false
            if strokeAfterRemote {
                strokeAfterRemote = false
                parent.onRemoteConflict?(pid, c.canonicalData)
            }
            changedSinceSave = false
            suppress = true
            c.load(parent.latestData?(pid) ?? parent.data)
            // Eski geri alma adımları yeni yüklenen mürekkebe uymaz
            c.undoManager?.removeAllActions()
            suppress = false
            DispatchQueue.main.async { [weak self] in self?.parent.controller.refresh() }
        }

        @objc func track(_ g: UILongPressGestureRecognizer) {
            guard let c = g.view as? OpenLeafCanvas else { return }
            if g.state == .began { c.endNoteEditingIfOutside(g.location(in: c)) }
            if c.tapeTouch(g.state, at: g.location(in: c)) { c.hideCursor(); return }
            switch g.state {
            case .began, .changed: c.showCursor(at: g.location(in: c))
            default: c.hideCursor()
            }
        }

        @objc func imageTap(_ g: UITapGestureRecognizer) {
            guard let c = g.view as? OpenLeafCanvas else { return }
            c.handleImageTap(at: g.location(in: c))
        }

        @objc func pageSwipe(_ g: UISwipeGestureRecognizer) {
            guard g.state == .ended else { return }
            parent.onPageSwipe?(g.direction == .left ? 1 : -1)
        }

        @objc func hover(_ g: UIHoverGestureRecognizer) {
            guard let c = g.view as? OpenLeafCanvas else { return }
            switch g.state {
            case .began, .changed: c.showCursor(at: g.location(in: c))
            default: c.hideCursor()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Yakınlaştırılmışken kaydırma sayfayı gezdirir, sayfa çevirmez.
        /// Cetvel açıkken iki parmak cetveli taşır/döndürür, sayfa çevirmez.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UISwipeGestureRecognizer, let c = g.view as? PKCanvasView {
                return c.zoomScale < 1.02 && !c.isRulerActive
            }
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
