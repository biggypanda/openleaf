import SwiftUI
import UIKit
import PencilKit

// MARK: - Model

enum StickyColor: String, Codable, CaseIterable {
    case sari, yesil, pembe, mavi

    var ui: UIColor {
        switch self {
        case .sari: UIColor(hex: 0xF6E39A)
        case .yesil: UIColor(hex: 0xCFE6D2)
        case .pembe: UIColor(hex: 0xF2C9CF)
        case .mavi: UIColor(hex: 0xCFDDF0)
        }
    }

    var name: String {
        switch self {
        case .sari: String(localized: "Sarı")
        case .yesil: String(localized: "Yeşil")
        case .pembe: String(localized: "Pembe")
        case .mavi: String(localized: "Mavi")
        }
    }
}

/// Sayfaya yapıştırılan not. Konum ve boyut kanonik sayfa koordinatlarında (sayfa genişliği 768).
struct StickyNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var w: Double = 210
    var h: Double = 170
    var text: String = ""
    var color: StickyColor = .sari
    /// Notun üstüne kalemle yazılan mürekkep (PencilKit verisi, not gövdesinin sol üstüne göre kanonik koordinatlarda)
    var ink: Data? = nil

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    static let textColor = UIColor(hex: 0x2A2824)
    static let fontSize: CGFloat = 16
    static let handleHeight: CGFloat = 22
    /// Köşeden boyutlandırırken en küçük boyut (kanonik)
    static let minSize = CGSize(width: 140, height: 110)
}

/// Notun mürekkep katmanı; geri alma adımları sayfanın geri alma yöneticisine yazılır
/// (araç çubuğundaki geri al düğmesi not mürekkebini de geri alsın diye).
final class NoteInkView: PKCanvasView {
    var undoProvider: (() -> UndoManager?)?
    override var undoManager: UndoManager? { undoProvider?() ?? super.undoManager }
}

// MARK: - Not görünümü (tuvalin içinde, sayfayla birlikte kayar)

final class StickyNoteView: UIView, UITextViewDelegate, UIContextMenuInteractionDelegate, PKCanvasViewDelegate {
    var note: StickyNote
    var onChange: ((StickyNoteView) -> Void)?
    var onMoveEnded: ((StickyNoteView) -> Void)?
    var onDelete: ((StickyNoteView) -> Void)?

    /// Kanonik → ekran ölçeği (yazı boyutu ve tutamaç yüksekliği için)
    var scale: CGFloat = 1 { didSet { if scale != oldValue { applyScale() } } }

    private let handle = UIView()
    private let grip = UIView()
    private let textView = UITextView()
    private let menuButton = UIButton(type: .system)
    private var dragStart: CGPoint = .zero
    /// Kalemle yazılan katman (yazının üstünde; parmakla dokununca klavyeyle yazma açılır)
    let ink = NoteInkView()
    private var loadingInk = false
    private var inkNeedsLoad = true
    /// Sol üst köşedeki boyutlandırma tutamacı
    private let resizeKnob = UIImageView()
    private var resizeStart: CGRect = .zero

    init(note: StickyNote) {
        self.note = note
        super.init(frame: .zero)
        layer.cornerRadius = 4
        layer.shadowColor = UIColor(hex: 0x28220F).cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 3)

        handle.backgroundColor = UIColor.black.withAlphaComponent(0.06)
        grip.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        grip.layer.cornerRadius = 1.5
        handle.addSubview(grip)
        addSubview(handle)

        textView.backgroundColor = .clear
        textView.textColor = StickyNote.textColor
        textView.tintColor = UIColor(hex: 0x24483F)
        textView.text = note.text
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        textView.overrideUserInterfaceStyle = .light
        addSubview(textView)

        // Kalem katmanı: yalnızca Apple Pencil çizer, parmak dokunuşu yazı düzenlemeyi açar
        ink.backgroundColor = .clear
        ink.isOpaque = false
        ink.drawingPolicy = .pencilOnly
        ink.isScrollEnabled = false
        ink.showsVerticalScrollIndicator = false
        ink.showsHorizontalScrollIndicator = false
        ink.contentInsetAdjustmentBehavior = .never
        ink.overrideUserInterfaceStyle = .light
        ink.delegate = self
        ink.accessibilityLabel = String(localized: "Not üstüne kalemle yazma alanı")
        addSubview(ink)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapToType(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        ink.addGestureRecognizer(tap)

        // Sol üst köşeden sürükleyerek büyütme/küçültme
        resizeKnob.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        resizeKnob.tintColor = UIColor.black.withAlphaComponent(0.45)
        resizeKnob.contentMode = .center
        resizeKnob.isUserInteractionEnabled = true
        resizeKnob.accessibilityLabel = String(localized: "Notu boyutlandır")
        resizeKnob.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        addSubview(resizeKnob)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        handle.addGestureRecognizer(pan)
        // Notun her yerine basılı tutunca menü açılsın
        addInteraction(UIContextMenuInteraction(delegate: self))

        // Üst şeritte görünür menü butonu (dokununca renk ve sil seçenekleri)
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)), for: .normal)
        menuButton.tintColor = UIColor.black.withAlphaComponent(0.45)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = String(localized: "Not seçenekleri")
        handle.addSubview(menuButton)
        isAccessibilityElement = false
        textView.accessibilityLabel = String(localized: "Yapışkan not")
        applyColor()
        applyScale()
    }

    /// Araç çubuğunda seçili kalem/silgi notun üstünde de kullanılır
    func setTool(_ tool: PKTool) { ink.tool = tool }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hh = StickyNote.handleHeight * scale
        handle.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hh)
        grip.frame = CGRect(x: bounds.midX - 14, y: hh / 2 - 1.5, width: 28, height: 3)
        menuButton.frame = CGRect(x: bounds.width - max(hh, 30) - 2, y: 0, width: max(hh, 30), height: hh)
        textView.frame = CGRect(x: 0, y: hh, width: bounds.width, height: max(0, bounds.height - hh))
        ink.frame = textView.frame
        // PencilKit yalnızca içerik alanının içini çizer; alan sıfır kalırsa mürekkep görünmez
        if ink.contentSize != ink.bounds.size { ink.contentSize = ink.bounds.size }
        // Mürekkep, katmanın boyutu belli olduktan sonra yüklenir (boyutsuzken verilen çizim ekrana çıkmıyor)
        if inkNeedsLoad, !ink.bounds.isEmpty { loadInk() }
        let k = max(hh, 30)
        resizeKnob.frame = CGRect(x: 0, y: 0, width: k, height: max(hh, 26))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
    }

    func beginEditing() { textView.becomeFirstResponder() }
    var isFirstResponderInside: Bool { textView.isFirstResponder }

    private func applyColor() { backgroundColor = note.color.ui; refreshMenu() }

    private func applyScale() {
        textView.font = .systemFont(ofSize: StickyNote.fontSize * scale)
        inkNeedsLoad = true
        setNeedsLayout()
    }

    /// Kayıtlı mürekkebi ekran ölçeğine çevirip katmana koyar
    private func loadInk() {
        guard !ink.bounds.isEmpty else { inkNeedsLoad = true; return }
        inkNeedsLoad = false
        let d = note.ink.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        loadingInk = true
        ink.drawing = d.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
        loadingInk = false
        // Boyut/yakınlık değişirken verilen çizim ekrana çıkmayabiliyor; bir tur sonra yeniden çizdir
        redrawInk()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loadingInk, scale > 0 else { return }
        let d = ink.drawing.transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        note.ink = d.strokes.isEmpty ? nil : d.dataRepresentation()
        onChange?(self)
        if !usingTool { redrawInk() }
    }

    /// Kalem/silgi o an değiyor mu (canlı çizim kendini zaten ekrana çizer)
    private var usingTool = false
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { usingTool = true }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { usingTool = false }

    /// Notun içindeki tuval, geri al/yinele gibi koddan gelen değişiklikleri ekrana yansıtmıyor;
    /// çizimi bir an boşaltıp geri vererek yeniden çizdir.
    private func redrawInk() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.usingTool else { return }
            let d = self.ink.drawing
            self.loadingInk = true
            self.ink.drawing = PKDrawing()
            self.ink.drawing = d
            self.loadingInk = false
        }
    }

    // Parmakla dokununca dokunulan yerden yazmaya başla
    @objc private func tapToType(_ g: UITapGestureRecognizer) {
        textView.becomeFirstResponder()
        let p = g.location(in: textView)
        if let pos = textView.closestPosition(to: p) {
            textView.selectedTextRange = textView.textRange(from: pos, to: pos)
        }
    }

    // Yazarken metin üstte (seçim ve imleç için), bitince kalem katmanı yeniden üstte
    func textViewDidBeginEditing(_ textView: UITextView) {
        bringSubviewToFront(textView)
        bringSubviewToFront(resizeKnob)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        bringSubviewToFront(ink)
        bringSubviewToFront(resizeKnob)
    }

    // Sol üst köşeden boyutlandırma: sağ alt köşe sabit kalır
    @objc private func resize(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            resizeStart = frame
            sv.bringSubviewToFront(self)
        case .changed:
            let t = g.translation(in: sv)
            let minW = StickyNote.minSize.width * scale, minH = StickyNote.minSize.height * scale
            let x = min(resizeStart.minX + t.x, resizeStart.maxX - minW)
            let y = min(resizeStart.minY + t.y, resizeStart.maxY - minH)
            frame = CGRect(x: x, y: y, width: resizeStart.maxX - x, height: resizeStart.maxY - y)
        default:
            onMoveEnded?(self)
        }
    }

    // Yazı
    func textViewDidChange(_ textView: UITextView) {
        note.text = textView.text
        onChange?(self)
    }

    // Sürükleme (üstteki tutamaçtan)
    @objc private func drag(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            dragStart = center
            superview?.bringSubviewToFront(self)
            UIView.animate(withDuration: 0.15) { self.transform = CGAffineTransform(scaleX: 1.03, y: 1.03) }
        case .changed:
            let t = g.translation(in: sv)
            center = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y)
        default:
            UIView.animate(withDuration: 0.2) { self.transform = .identity }
            onMoveEnded?(self)
        }
    }

    // Renk ve silme menüsü (uzun basma ve ••• butonu aynı menüyü kullanır)
    private func makeMenu() -> UIMenu {
        let colors = StickyColor.allCases.map { c in
            UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(c.ui, renderingMode: .alwaysOriginal),
                     state: c == note.color ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.note.color = c
                self.applyColor()
                self.onChange?(self)
            }
        }
        let renk = UIMenu(title: String(localized: "Renk"), image: UIImage(systemName: "paintpalette"), children: colors)
        let sil = UIAction(title: String(localized: "Notu sil"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            self.endEditing(true)
            self.onDelete?(self)
        }
        return UIMenu(children: [renk, sil])
    }

    private func refreshMenu() { menuButton.menu = makeMenu() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // Yazarken metin seçimine karışmasın
        if textView.isFirstResponder, textView.frame.contains(location) { return nil }
        // Kalemle yazarken menü açılmasın
        switch ink.drawingGestureRecognizer.state {
        case .began, .changed: return nil
        default: break
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.makeMenu() }
    }
}

// MARK: - Dışa aktarma ve küçük resim için çizim

enum StickyRenderer {
    /// Notları kanonik koordinatlarda mevcut grafik bağlamına çizer (UIGraphicsPushContext yapılmış olmalı).
    static func draw(_ notes: [StickyNote], in cg: CGContext) {
        for n in notes {
            let r = n.frame
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.15).cgColor)
            n.color.ui.setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 4).fill()
            cg.restoreGState()
            UIColor.black.withAlphaComponent(0.06).setFill()
            UIBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: StickyNote.handleHeight),
                         byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: StickyNote.fontSize),
                .foregroundColor: StickyNote.textColor,
            ]
            let textRect = CGRect(x: r.minX + 11, y: r.minY + StickyNote.handleHeight + 6,
                                  width: r.width - 22, height: r.height - StickyNote.handleHeight - 12)
            (n.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: attrs, context: nil)
            if let data = n.ink, let d = try? PKDrawing(data: data), !d.strokes.isEmpty {
                let body = CGRect(x: r.minX, y: r.minY + StickyNote.handleHeight,
                                  width: r.width, height: r.height - StickyNote.handleHeight)
                d.image(from: CGRect(origin: .zero, size: body.size), scale: 2).draw(in: body)
            }
        }
    }
}
