import SwiftUI

struct NewNotebookSheet: View {
    var onCreate: (Notebook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cover: CoverStyle = .ketenYesil
    @State private var paper: PaperStyle = .cizgili
    @State private var size: PaperSize = .a4

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 32) {
                // Önizleme
                VStack(spacing: 14) {
                    CoverView(style: cover, title: title.isEmpty ? String(localized: "Adsız defter") : title)
                        .frame(width: 180)
                        .animation(Y.spring, value: cover)
                    Text("\(cover.name) · \(paper.name) · \(size.name)").font(.footnote).foregroundStyle(Y.ink3)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 22) {
                    TextField("Defter adı", text: $title)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(Y.surface, in: RoundedRectangle(cornerRadius: Y.rM, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Y.rM, style: .continuous).strokeBorder(Y.line))

                    group("KAPAK") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 12), count: 4), spacing: 12) {
                            ForEach(CoverStyle.allCases) { c in
                                CoverView(style: c, title: "", compact: true)
                                    .frame(width: 58)
                                    .overlay {
                                        if c == cover {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(Y.accent, lineWidth: 2.5).padding(-5)
                                        }
                                    }
                                    .onTapGesture { cover = c }
                                    .accessibilityLabel(c.name)
                                    .accessibilityAddTraits(c == cover ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                    }

                    group("ŞABLON") {
                        HStack(spacing: 12) {
                            ForEach(PaperStyle.allCases) { p in
                                VStack(spacing: 6) {
                                    PaperSwatch(style: p)
                                        .frame(width: 64, height: 84)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(p == paper ? Y.accent : Y.line, lineWidth: p == paper ? 2.5 : 1)
                                        }
                                    Text(p.name).font(.caption).foregroundStyle(p == paper ? Y.accent : Y.ink2)
                                }
                                .onTapGesture { paper = p }
                            }
                        }
                    }

                    group("KÂĞIT BOYUTU") {
                        Picker("Kâğıt boyutu", selection: $size) {
                            ForEach(PaperSize.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 260)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Y.surface2)
            .navigationTitle("Yeni defter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Oluştur") {
                        onCreate(Notebook(title: title.isEmpty ? String(localized: "Adsız defter") : title, cover: cover, paper: paper, size: size))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationSizing(.form)
    }

    private func group<C: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
            content()
        }
    }
}

/// Şablon küçük resmi
struct PaperSwatch: View {
    var style: PaperStyle
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(uiColor: Y.paperUI)))
            PaperPattern.draw(style, in: CGRect(origin: .zero, size: size), scale: 0.35) { path, color, width in
                ctx.stroke(path, with: .color(Color(uiColor: color)), lineWidth: width)
            } fill: { path, color in
                ctx.fill(path, with: .color(Color(uiColor: color)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}
