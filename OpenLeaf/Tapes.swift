import SwiftUI
import UIKit

// MARK: - Model

enum TapeColor: String, Codable, CaseIterable, Identifiable {
    case sari, yesil, pembe, mavi
    var id: String { rawValue }

    /// Yapışkan notlardan daha doygun: altındaki yazıyı tamamen örtmesi gerekiyor
    var ui: UIColor {
        switch self {
        case .sari: UIColor(hex: 0xEBCB6A)
        case .yesil: UIColor(hex: 0x9CCBA8)
        case .pembe: UIColor(hex: 0xE8A5B0)
        case .mavi: UIColor(hex: 0x9DB8E0)
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

enum TapeSize: String, CaseIterable, Identifiable {
    case ince, orta, kalin
    var id: String { rawValue }
    var name: String {
        switch self {
        case .ince: String(localized: "İnce")
        case .orta: String(localized: "Orta")
        case .kalin: String(localized: "Kalın")
        }
    }
    /// Şerit kalınlığı (kanonik; çizgili kâğıtta satır aralığı 34)
    var thickness: CGFloat {
        switch self {
        case .ince: 20
        case .orta: 30
        case .kalin: 44
        }
    }
}

/// Yazının üstünü örten bant. Konum ve boyut kanonik sayfa koordinatlarında.
/// Açık/kapalı durumu saklanmaz: sayfa her açıldığında bantlar kapalı gelir.
struct Tape: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var color: TapeColor = .sari

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    /// Bundan kısa sürüklemeler bant sayılmaz (dokunma kabul edilir)
    static let minLength: CGFloat = 14

    /// Sürüklemeden bant dikdörtgeni: düze yakın sürükleme sabit kalınlıkta şerit,
    /// çapraz sürükleme (ör. bir şeklin üstünü kapatmak için) köşeden köşeye kutu olur.
    static func rect(from a: CGPoint, to b: CGPoint, thickness t: CGFloat) -> CGRect {
        let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
        if min(dx, dy) > t * 1.2 {
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: dx, height: dy)
        }
        if dx >= dy {
            return CGRect(x: min(a.x, b.x), y: a.y - t / 2, width: dx, height: t)
        }
        return CGRect(x: a.x - t / 2, y: min(a.y, b.y), width: t, height: dy)
    }
}

extension Library {
    func setTapes(_ id: UUID, _ page: UUID, _ tapes: [Tape]) {
        update(id) { nb in
            if let i = nb.pages.firstIndex(where: { $0.id == page }) { nb.pages[i].tapes = tapes.isEmpty ? nil : tapes }
            nb.modified = Date()
        }
        scheduleThumbnail(id)
    }
}

// MARK: - Çizim (ekran, küçük resim ve dışa aktarma aynı kodu kullanır)

enum TapeArt {
    enum Look {
        /// Altını tamamen örter
        case covered
        /// Dokunulup açılmış: yeri belli, altı okunuyor
        case revealed
        /// PDF dışa aktarma: yarı saydam, not kaybolmasın
        case export
    }

    /// `s` = kanonik → hedef ölçeği (köşe ve çizgi kalınlıkları için)
    static func draw(_ rect: CGRect, color: TapeColor, look: Look, scale s: CGFloat, in cg: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 3 * s).cgPath
        let base = color.ui
        cg.saveGState()
        defer { cg.restoreGState() }

        if look == .revealed {
            cg.addPath(path)
            cg.setFillColor(base.withAlphaComponent(0.16).cgColor)
            cg.fillPath()
            cg.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.75 * s, dy: 0.75 * s), cornerRadius: 3 * s).cgPath)
            cg.setStrokeColor(base.withAlphaComponent(0.95).cgColor)
            cg.setLineWidth(1.5 * s)
            cg.setLineDash(phase: 0, lengths: [5 * s, 4 * s])
            cg.strokePath()
            return
        }

        cg.addPath(path)
        cg.setFillColor(base.withAlphaComponent(look == .export ? 0.38 : 1).cgColor)
        cg.fillPath()

        // Bant dokusu: açık renkli çapraz şeritler
        cg.addPath(path)
        cg.clip()
        cg.setStrokeColor(UIColor.white.withAlphaComponent(look == .export ? 0.14 : 0.24).cgColor)
        cg.setLineWidth(4 * s)
        let step = 13 * s
        var x = rect.minX - rect.height
        while x < rect.maxX {
            cg.move(to: CGPoint(x: x, y: rect.maxY))
            cg.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        cg.strokePath()
        cg.resetClip()

        cg.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5 * s, dy: 0.5 * s), cornerRadius: 3 * s).cgPath)
        cg.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
        cg.setLineWidth(1 * s)
        cg.strokePath()
    }

    /// Bantları kanonik koordinatlarda çizer
    static func draw(_ tapes: [Tape], look: Look, in cg: CGContext) {
        for t in tapes { draw(t.frame, color: t.color, look: look, scale: 1, in: cg) }
    }
}

// MARK: - Bant görünümü (tuvalin içinde, mürekkebin üstünde)

/// Dokunuşları almaz: bantla ilgili tüm hareketleri tuval yönetir, altına kalemle yazılabilir.
final class TapeView: UIView {
    var color: TapeColor { didSet { if color != oldValue { setNeedsDisplay() } } }
    var revealed = false { didSet { if revealed != oldValue { setNeedsDisplay(); updateAccessibility() } } }
    /// Kanonik → ekran ölçeği
    var scale: CGFloat = 1 { didSet { if scale != oldValue { setNeedsDisplay() } } }
    /// VoiceOver ile etkinleştirilince (çift dokunma) bantı açıp kapatır
    var onActivate: (() -> Void)?

    init(color: TapeColor) {
        self.color = color
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateAccessibility() {
        accessibilityLabel = String(localized: "Bant")
        accessibilityValue = revealed ? String(localized: "Açık") : String(localized: "Kapalı")
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        TapeArt.draw(bounds, color: color, look: revealed ? .revealed : .covered, scale: scale, in: cg)
    }
}
