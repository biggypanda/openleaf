import SwiftUI
import UIKit

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
        case .sari: "Sarı"
        case .yesil: "Yeşil"
        case .pembe: "Pembe"
        case .mavi: "Mavi"
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

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    static let textColor = UIColor(hex: 0x2A2824)
    static let fontSize: CGFloat = 16
    static let handleHeight: CGFloat = 22
}

// MARK: - Not görünümü (tuvalin içinde, sayfayla birlikte kayar)

final class StickyNoteView: UIView, UITextViewDelegate, UIContextMenuInteractionDelegate {
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        handle.addGestureRecognizer(pan)
        // Notun her yerine basılı tutunca menü açılsın
        addInteraction(UIContextMenuInteraction(delegate: self))

        // Üst şeritte görünür menü butonu (dokununca renk ve sil seçenekleri)
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)), for: .normal)
        menuButton.tintColor = UIColor.black.withAlphaComponent(0.45)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Not seçenekleri"
        handle.addSubview(menuButton)
        isAccessibilityElement = false
        textView.accessibilityLabel = "Yapışkan not"
        applyColor()
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hh = StickyNote.handleHeight * scale
        handle.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hh)
        grip.frame = CGRect(x: bounds.midX - 14, y: hh / 2 - 1.5, width: 28, height: 3)
        menuButton.frame = CGRect(x: bounds.width - max(hh, 30) - 2, y: 0, width: max(hh, 30), height: hh)
        textView.frame = CGRect(x: 0, y: hh, width: bounds.width, height: max(0, bounds.height - hh))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
    }

    func beginEditing() { textView.becomeFirstResponder() }
    var isFirstResponderInside: Bool { textView.isFirstResponder }

    private func applyColor() { backgroundColor = note.color.ui; refreshMenu() }

    private func applyScale() {
        textView.font = .systemFont(ofSize: StickyNote.fontSize * scale)
        setNeedsLayout()
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
        let renk = UIMenu(title: "Renk", image: UIImage(systemName: "paintpalette"), children: colors)
        let sil = UIAction(title: "Notu sil", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
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
        }
    }
}
