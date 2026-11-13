import SwiftUI

/// İlk açılışta uygulamayı tanıtan beş sayfa. Son sayfa otomatik yedeği sorar;
/// böylece yeni kullanıcıya ayrıca bir uyarı çıkmaz.
struct OnboardingView: View {
    @Environment(AutoBackup.self) private var backup
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        var title: String
        var text: String
    }

    private var pages: [Page] {
        [
            Page(title: String(localized: "OpenLeaf'e hoş geldin"),
                 text: String(localized: "Ders notlarını tutman için yapıldı. Tamamen ücretsiz; reklam çıkmaz, üyelik istemez.")),
            Page(title: String(localized: "Kâğıda yazar gibi"),
                 text: String(localized: "Apple Pencil ile yazarsın, parmağınla sayfayı kaydırıp çevirirsin; elin değdi diye sayfa karalanmaz. Silmek için kalemin yanına iki kez dokunman yeter.")),
            Page(title: String(localized: "Bantla kapat, kendini dene"),
                 text: String(localized: "Ezberlemen gereken yerin üstünü bantla kapat. Aklına gelmezse banta dokun, cevap altından çıksın.")),
            Page(title: String(localized: "Boş sayfayla uğraşma"),
                 text: String(localized: "Cornell, haftalık plan, ders programı, deneme analizi gibi şablonlar hazır. Hocanın attığı PDF'i de açıp doğrudan üstüne yazabilirsin.")),
            Page(title: String(localized: "Notların başına bir şey gelmesin"),
                 text: String(localized: "Otomatik yedeği açarsan defterlerin kendi iCloud'una ya da seçtiğin bir klasöre yedeklenir; iPad bozulsa bile notların durur. Notlarını senden başka kimse göremez, biz de.")),
        ]
    }

    private var isLast: Bool { page == pages.count - 1 }
    /// Son sayfada yedeği açmayı sor: iCloud varsa ve yedek zaten açık değilse
    private var asksBackup: Bool { isLast && backup.iCloudAvailable && !backup.enabled }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Atla") { withAnimation(Y.quick) { page = pages.count - 1 } }
                    .font(.body)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
            }
            .frame(height: 44)
            .padding(.horizontal, 28)
            .padding(.top, 10)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    pageView(i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Y.accent : Y.surface3)
                        .frame(width: i == page ? 20 : 7, height: 7)
                }
            }
            .animation(Y.quick, value: page)
            .padding(.vertical, 18)
            .accessibilityElement()
            .accessibilityLabel(Text("Sayfa \(page + 1) / \(pages.count)"))

            VStack(spacing: 6) {
                Button(action: primary) {
                    Text(isLast ? (asksBackup ? String(localized: "Yedeği aç") : String(localized: "Başla")) : String(localized: "Devam"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Y.accent, in: Capsule())
                        .foregroundStyle(Y.accentInk)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button("Şimdi değil") {
                    backup.markAsked()
                    dismiss()
                }
                .font(.body)
                .frame(height: 40)
                .opacity(asksBackup ? 1 : 0)
                .disabled(!asksBackup)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
        }
        .tint(Y.accent)
        .background(Y.surface)
    }

    private func primary() {
        guard isLast else {
            withAnimation(Y.quick) { page += 1 }
            return
        }
        if asksBackup { backup.setEnabled(true) }
        dismiss()
    }

    private func pageView(_ i: Int) -> some View {
        VStack(spacing: 0) {
            illustration(i)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 170, maxHeight: 290)
                .background(Y.surface2, in: RoundedRectangle(cornerRadius: Y.rL, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Y.rL, style: .continuous))
                .accessibilityHidden(true)
            Text(pages[i].title)
                .font(Y.serif(.title, .semibold))
                .foregroundStyle(Y.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            Text(pages[i].text)
                .font(.body)
                .foregroundStyle(Y.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 6)
    }

    // MARK: Resimler (uygulamanın kendi kapak, kâğıt ve bant çizimleriyle)

    @ViewBuilder
    private func illustration(_ i: Int) -> some View {
        switch i {
        case 0: covers
        case 1: writing
        case 2: tapes
        case 3: templates
        default: backupArt
        }
    }

    private var covers: some View {
        ZStack {
            CoverView(style: .deri, title: "", compact: true)
                .frame(width: 112)
                .rotationEffect(.degrees(-9))
                .offset(x: -84, y: 10)
            CoverView(style: .kraft, title: "", compact: true)
                .frame(width: 112)
                .rotationEffect(.degrees(8))
                .offset(x: 84, y: 10)
            CoverView(style: .ketenYesil, title: String(localized: "Biyoloji"), subtitle: String(localized: "Hücre"))
                .frame(width: 136)
        }
        .padding(.vertical, 24)
    }

    private var writing: some View {
        VStack(spacing: 16) {
            Canvas { ctx, size in
                paper(ctx, size, lines: [38, 70, 102, 134])
                // Fosforlu kalem
                ctx.fill(Path(roundedRect: CGRect(x: 61, y: 46, width: 70, height: 23), cornerRadius: 3),
                         with: .color(Y.hl.opacity(0.65)))
                // El yazısı
                var ink = Path()
                scribble(&ink, x: 20, y: 33, words: [[11, 9, 12, 10, 9], [10, 12, 9], [12, 9, 11, 10]])
                scribble(&ink, x: 20, y: 65, words: [[9, 12, 10], [11, 9, 12, 10, 9, 11], [10, 12]])
                scribble(&ink, x: 20, y: 97, words: [[12, 10, 9, 11], [9, 11, 12], [10, 9]])
                ctx.stroke(ink, with: .color(Y.ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 280, height: 150)

            HStack(spacing: 16) {
                Image(systemName: "pencil.tip")
                    .foregroundStyle(Y.accent)
                    .frame(width: 34, height: 34)
                    .background(Y.accentSoft, in: Circle())
                Image(systemName: "highlighter")
                Image(systemName: "bandage")
                Image(systemName: "eraser")
                Rectangle().fill(Y.line).frame(width: 1, height: 22)
                ForEach([Color(hex: 0x1F2421), Color(hex: 0x3A5BA0), Color(hex: 0x2F7A5C), Color(hex: 0xC29124)], id: \.self) { c in
                    Circle().fill(c).frame(width: 18, height: 18)
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(Y.ink2)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Y.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Y.line))
        }
        .padding(.vertical, 20)
    }

    private var tapes: some View {
        Canvas { ctx, size in
            paper(ctx, size, lines: [46, 88, 130])
            let words = [String(localized: "Mitokondri:"), String(localized: "Ribozom:"), String(localized: "Fotosentez:")]
            for (i, word) in words.enumerated() {
                ctx.draw(note(word), at: CGPoint(x: 16, y: 42 + CGFloat(i) * 42), anchor: .bottomLeading)
            }
            // Açılmış bandın altındaki cevap
            ctx.draw(note(String(localized: "protein üretir")), at: CGPoint(x: 142, y: 84), anchor: .bottomLeading)
            ctx.withCGContext { cg in
                TapeArt.draw(CGRect(x: 136, y: 20, width: 150, height: 26), color: .sari, look: .covered, scale: 1, in: cg)
                TapeArt.draw(CGRect(x: 136, y: 62, width: 128, height: 26), color: .pembe, look: .revealed, scale: 1, in: cg)
                TapeArt.draw(CGRect(x: 136, y: 104, width: 140, height: 26), color: .yesil, look: .covered, scale: 1, in: cg)
            }
            // Dokunma işareti
            let tap = CGPoint(x: 278, y: 75)
            ctx.stroke(Path(ellipseIn: CGRect(x: tap.x - 13, y: tap.y - 13, width: 26, height: 26)),
                       with: .color(Y.accent), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: tap.x - 5, y: tap.y - 5, width: 10, height: 10)), with: .color(Y.accent))
        }
        .frame(width: 304, height: 150)
        .padding(.vertical, 20)
    }

    private var templates: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                ForEach([PaperStyle.cornell, .kareli, .haftalik, .dersProgrami]) { style in
                    VStack(spacing: 7) {
                        PaperSwatch(style: style)
                            .frame(width: 70, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Y.line))
                        Text(style.name)
                            .font(.caption)
                            .foregroundStyle(Y.ink2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: 86)
                }
            }
            Label("PDF içe aktar", systemImage: "arrow.down.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Y.accentInk)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Y.accent, in: Capsule())
        }
        .padding(.vertical, 20)
    }

    private var backupArt: some View {
        VStack(spacing: 22) {
            HStack(spacing: 18) {
                Image(systemName: "ipad")
                    .font(.system(size: 62, weight: .light))
                    .foregroundStyle(Y.ink2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Y.accent)
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 62, weight: .light))
                    .foregroundStyle(Y.accent)
            }
            HStack(spacing: 7) {
                ForEach(["iCloud", "Google Drive", "Dropbox", "OneDrive"], id: \.self) { name in
                    Text(verbatim: name)
                        .font(.footnote)
                        .foregroundStyle(Y.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Y.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Y.line))
                }
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: Çizim yardımcıları

    /// Kâğıt: zemin, kenar ve satır çizgileri
    private func paper(_ ctx: GraphicsContext, _ size: CGSize, lines: [CGFloat]) {
        let sheet = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
        ctx.fill(sheet, with: .color(Color(uiColor: Y.paperUI)))
        for y in lines {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(Color(uiColor: Y.paperLineUI)), lineWidth: 1)
        }
        ctx.stroke(sheet, with: .color(Y.line), lineWidth: 1)
    }

    /// El yazısına benzeyen dalgalı çizgi: her sayı bir harfin genişliği, her dizi bir kelime
    private func scribble(_ path: inout Path, x: CGFloat, y: CGFloat, words: [[CGFloat]]) {
        var x = x
        for word in words {
            path.move(to: CGPoint(x: x, y: y))
            for (i, w) in word.enumerated() {
                // Uzun ve kısa harfler sırayla: her biri yukarı çıkıp satıra geri iner
                let up: CGFloat = i.isMultiple(of: 3) ? 34 : 20
                path.addCurve(to: CGPoint(x: x + w, y: y),
                              control1: CGPoint(x: x + w * 0.1, y: y - up),
                              control2: CGPoint(x: x + w * 0.9, y: y - up * 0.55))
                x += w
            }
            x += 14
        }
    }

    private func note(_ text: String) -> Text {
        Text(verbatim: text)
            .font(.system(size: 16, design: .serif))
            .italic()
            .foregroundStyle(Y.ink)
    }
}
