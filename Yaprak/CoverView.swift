import SwiftUI

/// Malzemeli defter kapağı (3:4). Sol kenarda sırt bandı, ortada krem etiket.
struct CoverView: View {
    var style: CoverStyle
    var title: String
    var subtitle: String = ""
    var compact = false

    var body: some View {
        let (top, bottom) = style.colors
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4,
                                           bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom)
            if style.linen { LinenTexture(light: style.isLight) }
            if style == .deri {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(compact ? 5 : 9)
                    .padding(.leading, compact ? 6 : 12)
            }
            // Sırt bandı
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: compact ? 8 : 14)
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
                Spacer()
            }
            if !compact || !title.isEmpty {
                label
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .aspectRatio(3 / 4, contentMode: .fit)
        .shadow(color: Color(hex: 0x28220F).opacity(0.10), radius: 3, y: 2)
        .shadow(color: Color(hex: 0x28220F).opacity(0.10), radius: 12, y: 8)
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: compact ? 9 : 15, weight: .semibold, design: .serif))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !subtitle.isEmpty && !compact {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .italic()
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color(hex: 0x2A2824))
        .padding(.horizontal, compact ? 4 : 10)
        .padding(.vertical, compact ? 3 : 8)
        .frame(maxWidth: compact ? 50 : 120)
        .background(Color(hex: 0xF4EEDF), in: RoundedRectangle(cornerRadius: compact ? 2 : 4, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        .padding(.leading, compact ? 6 : 12)
        .offset(y: compact ? -8 : -24)
    }
}

/// İnce keten dokusu
struct LinenTexture: View {
    var light: Bool
    var body: some View {
        Canvas { ctx, size in
            let c: Color = light ? .black.opacity(0.05) : .white.opacity(0.06)
            var p = Path()
            var y: CGFloat = 0
            while y < size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)); y += 2.5 }
            var x: CGFloat = 0
            while x < size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)); x += 2.5 }
            ctx.stroke(p, with: .color(c), lineWidth: 0.6)
        }
    }
}

/// Whiteboard küçük resmi
struct WhiteboardThumb: View {
    var title: String
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Y.surface)
            .overlay {
                Canvas { ctx, size in
                    var dots = Path()
                    stride(from: 10.0, to: size.width, by: 12).forEach { x in
                        stride(from: 10.0, to: size.height, by: 12).forEach { y in
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
                        }
                    }
                    ctx.fill(dots, with: .color(Y.ink3.opacity(0.35)))
                    let w = size.width, h = size.height
                    ctx.fill(Path(roundedRect: CGRect(x: w * 0.12, y: h * 0.18, width: w * 0.32, height: h * 0.18), cornerRadius: 4),
                             with: .color(Y.hl.opacity(0.85)))
                    ctx.fill(Path(roundedRect: CGRect(x: w * 0.55, y: h * 0.42, width: w * 0.32, height: h * 0.18), cornerRadius: 4),
                             with: .color(Color(hex: 0xBFD8CC)))
                    var arrow = Path()
                    arrow.move(to: .init(x: w * 0.44, y: h * 0.30))
                    arrow.addQuadCurve(to: .init(x: w * 0.6, y: h * 0.42), control: .init(x: w * 0.58, y: h * 0.28))
                    ctx.stroke(arrow, with: .color(Y.accent), style: .init(lineWidth: 1.6, lineCap: .round))
                    ctx.stroke(Path(roundedRect: CGRect(x: w * 0.18, y: h * 0.62, width: w * 0.4, height: h * 0.16), cornerRadius: 10),
                               with: .color(Y.ink2), lineWidth: 1.2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Y.line, lineWidth: 1))
            .aspectRatio(3 / 4, contentMode: .fit)
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }
}

/// Uygulama logosu: uygulama ikonuyla aynı çizim (120 birimlik ızgara).
struct LogoMark: View {
    var size: CGFloat = 34
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 120
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let bg = Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: sz.width * 0.225, style: .continuous)
            ctx.fill(bg, with: .linearGradient(Gradient(colors: [Color(hex: 0x3A6B5C), Color(hex: 0x1B3A32)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: sz.height)))
            var page = Path()
            page.move(to: pt(34, 28)); page.addLine(to: pt(70, 28)); page.addLine(to: pt(90, 48))
            page.addLine(to: pt(90, 92)); page.addQuadCurve(to: pt(86, 96), control: pt(90, 96))
            page.addLine(to: pt(34, 96)); page.addQuadCurve(to: pt(30, 92), control: pt(30, 96))
            page.addLine(to: pt(30, 32)); page.addQuadCurve(to: pt(34, 28), control: pt(30, 28))
            ctx.fill(page, with: .color(Color(hex: 0xF6F1E4)))
            var fold = Path()
            fold.move(to: pt(70, 28)); fold.addLine(to: pt(70, 44))
            fold.addQuadCurve(to: pt(74, 48), control: pt(70, 48)); fold.addLine(to: pt(90, 48)); fold.closeSubpath()
            ctx.fill(fold, with: .color(.black.opacity(0.14)))
            var wave = Path()
            wave.move(to: pt(40, 62))
            wave.addCurve(to: pt(62, 61), control1: pt(48, 53), control2: pt(54, 70))
            wave.addCurve(to: pt(80, 53), control1: pt(70, 52), control2: pt(74, 57))
            ctx.stroke(wave, with: .color(Color(hex: 0x24483F)), style: .init(lineWidth: 3.6 * k, lineCap: .round))
            var line = Path()
            line.move(to: pt(40, 76)); line.addLine(to: pt(70, 76))
            ctx.stroke(line, with: .color(Color(hex: 0x24483F).opacity(0.5)), style: .init(lineWidth: 3 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
