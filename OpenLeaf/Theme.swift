import SwiftUI
import UIKit

// OpenLeaf tasarım tokenları (b-kagit/parts/base.css ile aynı değerler).

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: da) : UIColor(hex: light, alpha: la) }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(uiColor: UIColor(hex: hex, alpha: alpha)) }
}

enum Y {
    // Yüzeyler
    static let bg = Color(uiColor: .dyn(0xEFEBE2, 0x141411))
    static let surface = Color(uiColor: .dyn(0xFBF9F4, 0x1D1C18))
    static let surface2 = Color(uiColor: .dyn(0xF4F0E7, 0x25241F))
    static let surface3 = Color(uiColor: .dyn(0xE9E4D8, 0x2E2C26))
    static let paperUI = UIColor.dyn(0xFFFEFA, 0x26241F)
    static let paperLineUI = UIColor.dyn(0xD9E0DC, 0x37403B)
    static let paperMarginUI = UIColor.dyn(0xE3C9C2, 0x5A3A3A)

    // Metin
    static let ink = Color(uiColor: .dyn(0x1F2421, 0xEDE8DB))
    static let ink2 = Color(uiColor: .dyn(0x5A5F58, 0xB1AC9F))
    static let ink3 = Color(uiColor: .dyn(0x8E9189, 0x7F7B70))
    static let line = Color(uiColor: .dyn(0x1F2421, 0xEDE8DB, 0.12, 0.14))
    static let line2 = Color(uiColor: .dyn(0x1F2421, 0xEDE8DB, 0.06, 0.07))

    // Aksan
    static let accent = Color(uiColor: .dyn(0x24483F, 0x8CC1AC))
    static let accent2 = Color(uiColor: .dyn(0x35655A, 0xA5D3C0))
    static let accentInk = Color(uiColor: .dyn(0xF5F2E8, 0x0F1D18))
    static let accentSoft = Color(uiColor: .dyn(0x24483F, 0x8CC1AC, 0.10, 0.14))
    static let hl = Color(uiColor: .dyn(0xF3D77A, 0xC9A93C))
    static let danger = Color(uiColor: .dyn(0x9B3B3B, 0xD98080))
    static let ok = Color(uiColor: .dyn(0x3F7A57, 0x7CC49A))

    // Köşe yarıçapları
    static let rS: CGFloat = 10, rM: CGFloat = 14, rL: CGFloat = 20, rXL: CGFloat = 28

    // Hareket
    static let spring = Animation.spring(duration: 0.38, bounce: 0.25)
    static let springSoft = Animation.spring(duration: 0.56, bounce: 0.15)
    static let quick = Animation.easeOut(duration: 0.22)

    // Tipografi: başlıklar serif (New York; tasarımdaki Newsreader'ın sistem karşılığı)
    static func serif(_ style: Font.TextStyle, _ weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif).weight(weight)
    }
    static let eyebrow = Font.system(size: 11.5, weight: .semibold)
}

/// Kalem renkleri (açık tema değerleri; PencilKit koyu temada kendisi uyarlar).
enum PenColor: Int, CaseIterable, Codable {
    case ink, indigo, green, wine, ochre

    var ui: UIColor {
        switch self {
        case .ink: UIColor(hex: 0x1E2321)
        case .indigo: UIColor(hex: 0x2E4A7A)
        case .green: UIColor(hex: 0x2F6B4F)
        case .wine: UIColor(hex: 0x7A2E42)
        case .ochre: UIColor(hex: 0xB98A2E)
        }
    }

    /// Arayüzde gösterilen renk (koyu temada açık eşdeğeri)
    var swatch: Color {
        switch self {
        case .ink: Color(uiColor: .dyn(0x1E2321, 0xEDE8DB))
        case .indigo: Color(uiColor: .dyn(0x2E4A7A, 0x8FAEE0))
        case .green: Color(uiColor: .dyn(0x2F6B4F, 0x8CC9A5))
        case .wine: Color(uiColor: .dyn(0x7A2E42, 0xE0899F))
        case .ochre: Color(uiColor: .dyn(0xB98A2E, 0xE3BB5A))
        }
    }

    var name: String {
        switch self {
        case .ink: "Mürekkep"
        case .indigo: "Çivit"
        case .green: "Yeşil"
        case .wine: "Şarap"
        case .ochre: "Hardal"
        }
    }
}

/// Yüzen yüzeyler için cam: iOS 26+ Liquid Glass, öncesinde sistem malzemesi.
struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Y.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
    }
}

extension View {
    func glass<S: Shape>(_ shape: S) -> some View { modifier(GlassBackground(shape: shape)) }
}
