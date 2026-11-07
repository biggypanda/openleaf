import SwiftUI

/// Apple Pencil Pro sıkılınca kalemin ucunda açılan dairesel hızlı menü.
/// İç halka: araçlar, not ekleme, geri al/yinele. Dış halka: renkler. Ortaya dokununca kapanır.
struct QuickPalette: View {
    /// Menünün merkezi (bu görünümün koordinatlarında)
    var center: CGPoint
    var tool: ToolKind
    var color: PenColor
    var canUndo: Bool
    var canRedo: Bool
    var onTool: (ToolKind) -> Void
    var onColor: (PenColor) -> Void
    var onNote: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onClose: () -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let innerR: CGFloat = 66
    private let outerR: CGFloat = 108
    private let diskR: CGFloat = 132
    private let button: CGFloat = 44

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let label: String
        var active = false
        var enabled = true
        var closes = true
        let action: () -> Void
    }

    private var items: [Item] {
        [
            Item(id: "pen", icon: ToolKind.pen.icon, label: ToolKind.pen.name, active: tool == .pen) { onTool(.pen) },
            Item(id: "hl", icon: ToolKind.highlighter.icon, label: ToolKind.highlighter.name, active: tool == .highlighter) { onTool(.highlighter) },
            Item(id: "er", icon: ToolKind.eraser.icon, label: ToolKind.eraser.name, active: tool == .eraser) { onTool(.eraser) },
            Item(id: "la", icon: ToolKind.lasso.icon, label: ToolKind.lasso.name, active: tool == .lasso) { onTool(.lasso) },
            Item(id: "note", icon: "note.text.badge.plus", label: "Yapışkan not ekle", action: onNote),
            // Geri al/yinele menüyü kapatmaz: art arda basılabilsin
            Item(id: "redo", icon: "arrow.uturn.forward", label: "Yinele", enabled: canRedo, closes: false, action: onRedo),
            Item(id: "undo", icon: "arrow.uturn.backward", label: "Geri al", enabled: canUndo, closes: false, action: onUndo),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let c = clamped(center, in: geo.size)
            ZStack {
                // Dışarıya dokununca kapanır
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)

                Circle()
                    .fill(Y.surface.opacity(0.9))
                    .frame(width: diskR * 2, height: diskR * 2)
                    .glass(Circle())
                    .overlay(Circle().strokeBorder(Y.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                    .scaleEffect(shown ? 1 : 0.35)
                    .opacity(shown ? 1 : 0)
                    .position(c)
                    .allowsHitTesting(false)

                // İç halka: araçlar
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let a = angle(i, of: items.count, start: -90)
                    toolButton(item)
                        .position(point(c, a, shown ? innerR : innerR * 0.25))
                        .opacity(shown ? 1 : 0)
                        .animation(anim(i), value: shown)
                }

                // Dış halka: renkler
                ForEach(Array(PenColor.allCases.enumerated()), id: \.element) { i, pc in
                    let a = angle(i, of: PenColor.allCases.count, start: -90 + 36)
                    colorButton(pc)
                        .position(point(c, a, shown ? outerR : outerR * 0.3))
                        .opacity(shown ? 1 : 0)
                        .animation(anim(i + items.count), value: shown)
                }

                // Orta: seçili araç; dokununca kapanır
                Button(action: onClose) {
                    ZStack {
                        Circle().fill(Y.surface)
                        Image(systemName: tool.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tool == .pen ? color.swatch : Y.accent)
                    }
                    .frame(width: 46, height: 46)
                    .overlay(Circle().strokeBorder(Y.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hızlı menüyü kapat")
                .scaleEffect(shown ? 1 : 0.5)
                .opacity(shown ? 1 : 0)
                .position(c)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.3), value: shown)
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hızlı menü")
    }

    // MARK: Parçalar

    private func toolButton(_ item: Item) -> some View {
        Button {
            item.action()
            if item.closes { onClose() }
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .regular))
                .frame(width: button, height: button)
                .foregroundStyle(item.active ? Y.accent : (item.enabled ? Y.ink : Y.ink3.opacity(0.45)))
                .background(Circle().fill(item.active ? Y.accentSoft : Y.surface.opacity(0.7)))
                .overlay(Circle().strokeBorder(item.active ? Y.accent.opacity(0.5) : Y.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(QuickPress())
        .disabled(!item.enabled)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(item.active ? .isSelected : [])
    }

    private func colorButton(_ pc: PenColor) -> some View {
        let selected = pc == color && tool == .pen
        return Button {
            onColor(pc)
            onClose()
        } label: {
            Circle().fill(pc.swatch)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                .padding(4)
                .overlay(Circle().strokeBorder(selected ? Y.accent : .clear, lineWidth: 2.5))
                .frame(width: button, height: button)
                .contentShape(Circle())
        }
        .buttonStyle(QuickPress())
        .accessibilityLabel(pc.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Geometri

    private func angle(_ i: Int, of n: Int, start: Double) -> Double {
        (start + 360 / Double(n) * Double(i)) * .pi / 180
    }

    private func point(_ c: CGPoint, _ a: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }

    /// Menü ekranın dışına taşmasın
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let m = diskR + 8
        return CGPoint(x: min(max(p.x, m), max(m, size.width - m)),
                       y: min(max(p.y, m), max(m, size.height - m)))
    }

    private func anim(_ i: Int) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15)
            : .spring(duration: 0.32, bounce: 0.35).delay(Double(i) * 0.012)
    }
}

/// Basınca hafifçe küçülen düğme
private struct QuickPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
