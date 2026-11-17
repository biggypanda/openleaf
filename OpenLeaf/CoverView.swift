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
            if style.isFestive { FestivePattern(style: style) }
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

    /// Uzun tek kelimeler (ör. "Vertragsrecht") ortadan bölünmesin diye
    /// en geniş kelime etikete sığacak kadar yazıyı küçültür.
    private var titleSize: CGFloat {
        let base: CGFloat = compact ? 9 : 15
        let room: CGFloat = compact ? 38 : 90
        guard let desc = UIFont.systemFont(ofSize: base, weight: .semibold).fontDescriptor.withDesign(.serif) else { return base }
        let font = UIFont(descriptor: desc, size: base)
        let widest = title.split(whereSeparator: \.isWhitespace)
            .map { String($0).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        guard widest > room else { return base }
        return max(base * 0.6, (base * room / widest).rounded(.down))
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .serif))
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
        // Açık desenli kapakta etiket zeminle karışmasın
        .overlay {
            if style == .sekerKamisi {
                RoundedRectangle(cornerRadius: compact ? 2 : 4, style: .continuous)
                    .strokeBorder(Color(hex: 0x2A2824).opacity(0.18), lineWidth: 0.75)
            }
        }
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

/// Yılbaşı kapak desenleri. Ölçüler 150 birim genişliğe göre; kapak boyutu ne olursa olsun desen aynı görünür.
struct FestivePattern: View {
    var style: CoverStyle

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 150
            switch style {
            case .ekose: tartan(ctx, size, u)
            case .karTanesi: snow(ctx, size, u)
            case .camOrmani: pines(ctx, size, u)
            case .kraftYildiz: kraftStars(ctx, size, u)
            case .altinPuantiye: dots(ctx, size, u)
            case .sekerKamisi: candyCane(ctx, size, u)
            default: break
            }
        }
        .allowsHitTesting(false)
    }

    private func tiles(_ size: CGSize, _ step: CGFloat, _ body: (CGFloat, CGFloat) -> Void) {
        var y: CGFloat = 0
        while y < size.height { var x: CGFloat = 0; while x < size.width { body(x, y); x += step }; y += step }
    }

    private func fill(_ ctx: GraphicsContext, _ path: Path, _ hex: UInt32, _ opacity: Double = 1) {
        ctx.fill(path, with: .color(Color(hex: hex).opacity(opacity)))
    }

    private func tartan(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        let t = 40 * u
        var greenH = Path(), greenV = Path(), gold = Path(), dark = Path()
        var v: CGFloat = 0
        while v < max(size.width, size.height) {
            greenH.addRect(CGRect(x: 0, y: v + 14 * u, width: size.width, height: 12 * u))
            greenV.addRect(CGRect(x: v + 14 * u, y: 0, width: 12 * u, height: size.height))
            gold.addRect(CGRect(x: 0, y: v + 19 * u, width: size.width, height: 2 * u))
            gold.addRect(CGRect(x: v + 19 * u, y: 0, width: 2 * u, height: size.height))
            dark.addRect(CGRect(x: 0, y: v + 4 * u, width: size.width, height: 1.5 * u))
            dark.addRect(CGRect(x: v + 4 * u, y: 0, width: 1.5 * u, height: size.height))
            v += t
        }
        // Yatay ve dikey bantlar üst üste binince koyulaşsın diye ayrı ayrı boyanır
        fill(ctx, greenH, 0x1F3B2C, 0.4)
        fill(ctx, greenV, 0x1F3B2C, 0.4)
        fill(ctx, gold, 0xE8C66A, 0.7)
        fill(ctx, dark, 0x000000, 0.22)
    }

    private func flake(at c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<3 {
            let a = CGFloat(i) * .pi / 3 + .pi / 2
            let d = CGPoint(x: cos(a) * r, y: sin(a) * r)
            p.move(to: CGPoint(x: c.x - d.x, y: c.y - d.y)); p.addLine(to: CGPoint(x: c.x + d.x, y: c.y + d.y))
        }
        // Uçlardaki küçük V'ler
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 + .pi / 2
            let tip = CGPoint(x: c.x + cos(a) * r * 0.62, y: c.y + sin(a) * r * 0.62)
            for s in [-1.0, 1.0] {
                let b = a + CGFloat(s) * 0.7
                p.move(to: tip); p.addLine(to: CGPoint(x: tip.x + cos(b) * r * 0.32, y: tip.y + sin(b) * r * 0.32))
            }
        }
        return p
    }

    private func snow(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        var big = Path(), small = Path(), dots = Path()
        tiles(size, 54 * u) { x, y in
            big.addPath(flake(at: CGPoint(x: x + 14 * u, y: y + 14 * u), r: 7 * u))
            small.addPath(flake(at: CGPoint(x: x + 41 * u, y: y + 40 * u), r: 4.5 * u))
            dots.addEllipse(in: CGRect(x: x + 39 * u, y: y + 11 * u, width: 2.4 * u, height: 2.4 * u))
            dots.addEllipse(in: CGRect(x: x + 9 * u, y: y + 43 * u, width: 2 * u, height: 2 * u))
        }
        let style = StrokeStyle(lineWidth: 1.2 * u, lineCap: .round)
        ctx.stroke(big, with: .color(.white.opacity(0.85)), style: style)
        ctx.stroke(small, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 0.9 * u, lineCap: .round))
        fill(ctx, dots, 0xFFFFFF, 0.55)
    }

    private func tree(at c: CGPoint, _ u: CGFloat, scale k: CGFloat = 1) -> (Path, Path) {
        let s = u * k
        var leaves = Path()
        leaves.addLines([CGPoint(x: c.x, y: c.y - 11 * s), CGPoint(x: c.x + 7 * s, y: c.y + 1 * s), CGPoint(x: c.x - 7 * s, y: c.y + 1 * s)])
        leaves.closeSubpath()
        leaves.addLines([CGPoint(x: c.x, y: c.y - 5 * s), CGPoint(x: c.x + 9 * s, y: c.y + 8 * s), CGPoint(x: c.x - 9 * s, y: c.y + 8 * s)])
        leaves.closeSubpath()
        let trunk = Path(CGRect(x: c.x - 1.5 * s, y: c.y + 8 * s, width: 3 * s, height: 3 * s))
        return (leaves, trunk)
    }

    private func pines(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        var front = Path(), back = Path(), trunks = Path(), berries = Path()
        tiles(size, 46 * u) { x, y in
            let a = tree(at: CGPoint(x: x + 12 * u, y: y + 14 * u), u)
            let b = tree(at: CGPoint(x: x + 35 * u, y: y + 37 * u), u, scale: 0.85)
            front.addPath(a.0); back.addPath(b.0); trunks.addPath(a.1); trunks.addPath(b.1)
            berries.addEllipse(in: CGRect(x: x + 32.4 * u, y: y + 8.4 * u, width: 3.2 * u, height: 3.2 * u))
            berries.addEllipse(in: CGRect(x: x + 9.4 * u, y: y + 36.4 * u, width: 3.2 * u, height: 3.2 * u))
        }
        fill(ctx, back, 0x2F6B4F, 0.6)
        fill(ctx, front, 0x2F6B4F, 0.95)
        fill(ctx, trunks, 0x6B4630, 0.8)
        fill(ctx, berries, 0xC9423C)
    }

    private func star(at c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 - .pi / 2
            let rr = i.isMultiple(of: 2) ? r : r * 0.42
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private func kraftStars(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        let w = size.width, h = size.height
        // Kapağın üst ve alt kenarına gerilmiş ip, üstünde yıldızlar
        var twine = Path()
        twine.move(to: CGPoint(x: 0, y: h * 0.15)); twine.addQuadCurve(to: CGPoint(x: w, y: h * 0.13), control: CGPoint(x: w * 0.5, y: h * 0.27))
        twine.move(to: CGPoint(x: 0, y: h * 0.85)); twine.addQuadCurve(to: CGPoint(x: w, y: h * 0.88), control: CGPoint(x: w * 0.5, y: h * 0.73))
        ctx.stroke(twine, with: .color(Color(hex: 0xF4EEDF).opacity(0.9)), lineWidth: 1.4 * u)
        var stars = Path()
        for (x, y, r) in [(0.27, 0.20, 8.0), (0.53, 0.225, 5.5), (0.81, 0.17, 8.0),
                          (0.28, 0.81, 5.5), (0.57, 0.785, 8.0), (0.84, 0.85, 5.5)] {
            stars.addPath(star(at: CGPoint(x: w * x, y: h * y), r: r * u))
        }
        fill(ctx, stars, 0xC99A2E)
    }

    private func dots(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        var p = Path()
        tiles(size, 22 * u) { x, y in
            p.addEllipse(in: CGRect(x: x + 2.8 * u, y: y + 2.8 * u, width: 4.4 * u, height: 4.4 * u))
            p.addEllipse(in: CGRect(x: x + 13.8 * u, y: y + 13.8 * u, width: 4.4 * u, height: 4.4 * u))
        }
        fill(ctx, p, 0xD9B35A)
    }

    private func candyCane(_ ctx: GraphicsContext, _ size: CGSize, _ u: CGFloat) {
        var c = ctx
        c.translateBy(x: size.width / 2, y: size.height / 2)
        c.rotate(by: .degrees(-35))
        let reach = hypot(size.width, size.height)
        var red = Path(), green = Path()
        var x = -reach
        while x < reach {
            red.addRect(CGRect(x: x, y: -reach, width: 10 * u, height: reach * 2))
            green.addRect(CGRect(x: x + 14 * u, y: -reach, width: 3 * u, height: reach * 2))
            x += 28 * u
        }
        fill(c, red, 0xB8323A)
        fill(c, green, 0x2F6B4F, 0.8)
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
