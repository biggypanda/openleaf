import SwiftUI
import PencilKit
import PDFKit

enum ToolKind: String, CaseIterable {
    case pen, highlighter, eraser, lasso
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
    var name: String {
        switch self {
        case .pen: "Kalem"
        case .highlighter: "Vurgulayıcı"
        case .eraser: "Silgi"
        case .lasso: "Kement"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .eraser: "e"
        case .lasso: "l"
        }
    }
}

enum PenType: String, CaseIterable, Identifiable {
    case tukenmez, dolma, kursun, firca
    var id: String { rawValue }
    var name: String {
        switch self {
        case .tukenmez: "Tükenmez"
        case .dolma: "Dolma"
        case .kursun: "Kurşun"
        case .firca: "Fırça"
        }
    }
    var ink: PKInk.InkType {
        switch self {
        case .tukenmez: .pen
        case .dolma: .fountainPen
        case .kursun: .pencil
        case .firca: .watercolor
        }
    }
    /// Aynı "0,4" seçimi her kalemde benzer kalınlıkta görünsün: kurşun ve fırça doğal olarak daha ince çizer
    var widthScale: CGFloat {
        switch self {
        case .tukenmez, .dolma: 1
        case .kursun: 2.4
        case .firca: 2
        }
    }
}

/// Silgi: kısmi (gerçek silgi gibi, dairenin değdiği yer) ya da bütün çizgi.
enum EraserMode: String, CaseIterable, Identifiable {
    case kismi, butun
    var id: String { rawValue }
    var name: String { self == .kismi ? "Kısmi" : "Bütün çizgi" }
}

struct EraserSettings: Equatable {
    var mode: EraserMode = .kismi
    var sizeIndex = 1
    static let sizes: [CGFloat] = [10, 22, 40]
    static let labels = ["Küçük", "Orta", "Büyük"]
    var width: CGFloat { Self.sizes[sizeIndex] }
}

struct DocumentView: View {
    let id: UUID
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var forward = true
    @State private var tool: ToolKind = .pen
    @State private var lastInkTool: ToolKind = .pen
    @AppStorage("kalem.renk") private var color: PenColor = .ink
    @AppStorage("kalem.tur") private var penType: PenType = .tukenmez
    @AppStorage("kalem.kalinlik") private var widthIndex = 1
    @State private var eraser = EraserSettings()
    @State private var showToolMenu = false
    @State private var focus = false
    @State private var pencilOnly = false
    @State private var controller = CanvasController()
    @State private var tapRipple = false
    @State private var confirmDelete = false
    @State private var flip: CGFloat = 0
    @State private var showMore = false
    @State private var pdfDoc: PDFDocument?

    static let widths: [CGFloat] = [1.6, 3, 5, 8]
    static let widthLabels = ["0,2", "0,4", "0,7", "1,0"]

    var body: some View {
        if let nb = library.notebooks.first(where: { $0.id == id }) {
            if nb.kind == .pdf && pdfDoc == nil {
                // PDF açılmadan tuvali kurma; yoksa ilk sayfa boş görünür
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Y.bg)
                    .task { pdfDoc = library.pdfURL(nb).flatMap { PDFDocument(url: $0) } ?? PDFDocument() }
            } else {
                content(nb)
            }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func content(_ nb: Notebook) -> some View {
        let p = min(page, nb.pages.count - 1)
        let pageID = nb.pages[p].id
        return ZStack(alignment: .bottom) {
            Y.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                if !focus {
                    topBar(nb, page: p)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ZStack {
                    CanvasRepresentable(
                        pageID: pageID,
                        data: library.drawing(id, pageID),
                        pdfPage: nb.pages[p].pdfPage.flatMap { pdfDoc?.page(at: $0) },
                        paper: nb.paper,
                        canonical: nb.canonicalSize,
                        isWhiteboard: nb.kind == .whiteboard,
                        isPDF: nb.kind == .pdf,
                        tool: pkTool,
                        eraserCursor: tool == .eraser && eraser.mode == .kismi ? eraser.width : nil,
                        pencilOnly: pencilOnly,
                        controller: controller,
                        onChange: { pid, data in
                            // Sayfa kimliğiyle yaz: araya sayfa eklenip silinse de doğru dosyaya gider
                            library.saveDrawing(id, pid, data)
                        },
                        onPencilTap: pencilDoubleTap
                    )
                    // Sayfa çevirme: içerik değişirken kısa bir kayma ve solma
                    .offset(x: flip)
                    .opacity(1 - min(abs(flip) / 40, 1))
                }
                .clipped()
                .ignoresSafeArea(edges: .bottom)
            }

            if !focus {
                ToolbarCapsule(tool: $tool, color: $color, showToolMenu: $showToolMenu,
                               penType: $penType, widthIndex: $widthIndex, eraser: $eraser,
                               canUndo: controller.canUndo, canRedo: controller.canRedo,
                               undo: controller.undo, redo: controller.redo,
                               select: select)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if focus {
                focusHandle
            }

            if tapRipple {
                Text(tool == .eraser ? "Silgi" : "Kalem")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(Color(hex: 0xF1ECDF))
                    .background(Color(hex: 0x2A2824).opacity(0.92), in: Capsule())
                    .padding(.bottom, 100)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .confirmationDialog("Sayfa \(p + 1) silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Sayfayı sil", role: .destructive) { deletePage(p) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu sayfadaki notlar kalıcı olarak silinir.")
        }
        .statusBarHidden(focus)
        .persistentSystemOverlays(focus ? .hidden : .automatic)
        .background(shortcuts(nb))
    }

    // MARK: Üst çubuk

    private func topBar(_ nb: Notebook, page p: Int) -> some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                    Text("Kütüphane")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Y.accent)
            .padding(.horizontal, 10).frame(height: 40)

            Spacer(minLength: 12)

            VStack(spacing: 1) {
                Text(nb.title).font(.system(size: 17, weight: .semibold, design: .serif)).lineLimit(1)
                Text(nb.kind == .whiteboard ? "Whiteboard" : "\(nb.subtitle.isEmpty ? "" : nb.subtitle + " · ")Sayfa \(p + 1) / \(nb.pages.count)")
                    .font(.caption).foregroundStyle(Y.ink3).monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                if nb.isPaged {
                    iconButton("chevron.up", "Önceki sayfa") { go(p - 1, nb) }.disabled(p == 0)
                    iconButton("chevron.down", "Sonraki sayfa") { go(p + 1, nb) }.disabled(p >= nb.pages.count - 1)
                    iconButton("doc.badge.plus", "Sayfa ekle") { addPage(after: p) }
                }
                ShareLink(item: NotebookPDF(notebook: nb, library: library),
                          preview: SharePreview("\(nb.title).pdf", image: Image(systemName: "doc.richtext"))) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17)).frame(width: 40, height: 40)
                }
                .foregroundStyle(Y.ink2)
                .accessibilityLabel("PDF olarak paylaş")
                iconButton("arrow.up.left.and.arrow.down.right", "Odak modu") {
                    withAnimation(Y.springSoft) { focus = true }
                }
                Button { showMore = true } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Y.ink2)
                .accessibilityLabel("Diğer seçenekler")
                .popover(isPresented: $showMore, arrowEdge: .top) {
                    MoreMenu(pencilOnly: $pencilOnly,
                             favorite: nb.favorite,
                             canDeletePage: nb.isPaged && nb.pages.count > 1,
                             toggleFavorite: { library.update(id) { $0.favorite.toggle() } },
                             deletePage: {
                                 showMore = false
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { confirmDelete = true }
                             })
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Y.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Y.line2).frame(height: 1) }
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Y.ink2)
        .accessibilityLabel(label)
    }

    private var focusHandle: some View {
        HStack {
            Button {
                withAnimation(Y.springSoft) { focus = false }
            } label: {
                Capsule().fill(Y.ink3.opacity(0.5)).frame(width: 5, height: 64)
                    .padding(.horizontal, 10).padding(.vertical, 20)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Odak modundan çık")
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Eylemler

    private var pkTool: PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(penType.ink, color: color.ui, width: Self.widths[widthIndex] * penType.widthScale)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(hex: 0xF3D77A).withAlphaComponent(0.9), width: 22)
        case .eraser:
            return eraser.mode == .kismi ? PKEraserTool(.bitmap, width: eraser.width) : PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }

    private func select(_ t: ToolKind) {
        if t == tool, t != .lasso {
            showToolMenu.toggle()
        } else {
            withAnimation(Y.quick) { tool = t }
            showToolMenu = false
        }
        if t != .eraser { lastInkTool = t }
    }

    private func pencilDoubleTap() {
        withAnimation(Y.spring) {
            tool = tool == .eraser ? lastInkTool : .eraser
            tapRipple = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Y.quick) { tapRipple = false } }
    }

    private func go(_ target: Int, _ nb: Notebook) {
        guard target >= 0, target < nb.pages.count else { return }
        forward = target > page
        turn(to: target)
    }

    private func addPage(after p: Int) {
        library.insertPage(id, at: p + 1)
        forward = true
        turn(to: p + 1)
    }

    /// Sayfa çevirme: eski sayfa kayarak solar, yeni sayfa karşı yandan gelir.
    private func turn(to target: Int) {
        let d: CGFloat = forward ? -40 : 40
        withAnimation(.easeIn(duration: 0.14)) { flip = d } completion: {
            page = target
            flip = -d
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)) { flip = 0 }
        }
    }

    private func deletePage(_ p: Int) {
        guard let nb = library.notebooks.first(where: { $0.id == id }), p < nb.pages.count else { return }
        forward = false
        withAnimation(Y.quick) {
            library.deletePage(id, nb.pages[p].id)
            page = max(0, p - 1)
        }
    }

    // ⌘ kısayolları (harici klavye)
    private func shortcuts(_ nb: Notebook) -> some View {
        Group {
            ForEach(ToolKind.allCases, id: \.self) { t in
                Button(t.name) { select(t) }.keyboardShortcut(t.key, modifiers: [])
            }
            Button("Yeni sayfa") { addPage(after: min(page, nb.pages.count - 1)) }.keyboardShortcut("n")
            Button("Odak modu") { withAnimation(Y.springSoft) { focus.toggle() } }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Geri al") { controller.undo() }.keyboardShortcut("z")
            Button("Yinele") { controller.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Kütüphane") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Cam araç çubuğu

struct ToolbarCapsule: View {
    @Binding var tool: ToolKind
    @Binding var color: PenColor
    @Binding var showToolMenu: Bool
    @Binding var penType: PenType
    @Binding var widthIndex: Int
    @Binding var eraser: EraserSettings
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
    var select: (ToolKind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ToolKind.allCases, id: \.self) { t in
                Button { select(t) } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(tool == t ? Y.accent : Y.ink2)
                        .background(Circle().fill(tool == t ? Y.accentSoft : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityAddTraits(tool == t ? .isSelected : [])
                .popover(isPresented: Binding(get: { showToolMenu && tool == t }, set: { if !$0 { showToolMenu = false } }),
                         arrowEdge: .bottom) {
                    ToolMenu(tool: t, penType: $penType, widthIndex: $widthIndex, color: $color, eraser: $eraser)
                        .presentationCompactAdaptation(.popover)
                }
            }

            sep

            ForEach(PenColor.allCases, id: \.self) { c in
                Button {
                    color = c
                    if tool != .pen { select(.pen) }
                } label: {
                    Circle().fill(c.swatch)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .padding(4)
                        .overlay(Circle().strokeBorder(color == c && tool == .pen ? Y.accent : .clear, lineWidth: 2))
                        .frame(width: 38, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }

            sep

            Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 42, height: 46).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(canUndo ? Y.ink2 : Y.ink3.opacity(0.45))
                .disabled(!canUndo)
                .accessibilityLabel("Geri al")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 42, height: 46).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(canRedo ? Y.ink2 : Y.ink3.opacity(0.45))
                .disabled(!canRedo)
                .accessibilityLabel("Yinele")
        }
        .font(.system(size: 17))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glass(Capsule())
        .animation(Y.quick, value: tool)
        .animation(Y.quick, value: color)
    }

    private var sep: some View {
        Rectangle().fill(Y.line).frame(width: 1, height: 26).padding(.horizontal, 6)
    }
}

/// Aktif araç menüsü: kalem türü, kalınlık, renk
struct ToolMenu: View {
    var tool: ToolKind
    @Binding var penType: PenType
    @Binding var widthIndex: Int
    @Binding var color: PenColor
    @Binding var eraser: EraserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tool == .pen {
                Picker("Kalem türü", selection: $penType) {
                    ForEach(PenType.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("KALINLIK").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                    HStack(spacing: 10) {
                        ForEach(DocumentView.widths.indices, id: \.self) { i in
                            Button { widthIndex = i } label: {
                                VStack(spacing: 4) {
                                    Circle().fill(color.swatch)
                                        .frame(width: 4 + DocumentView.widths[i] * 2, height: 4 + DocumentView.widths[i] * 2)
                                        .frame(width: 44, height: 44)
                                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(i == widthIndex ? Y.accentSoft : Y.surface3.opacity(0.6)))
                                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(i == widthIndex ? Y.accent : .clear, lineWidth: 2))
                                    Text(DocumentView.widthLabels[i]).font(.caption2).foregroundStyle(Y.ink3)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(DocumentView.widthLabels[i]) milimetre")
                            .accessibilityAddTraits(i == widthIndex ? .isSelected : [])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("RENKLER").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                    HStack(spacing: 10) {
                        ForEach(PenColor.allCases, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(c.swatch).frame(width: 30, height: 30)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(c == color ? Y.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                        }
                    }
                }
            } else if tool == .eraser {
                Picker("Silgi türü", selection: $eraser.mode) {
                    ForEach(EraserMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                if eraser.mode == .kismi {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BOYUT").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                        HStack(spacing: 10) {
                            ForEach(EraserSettings.sizes.indices, id: \.self) { i in
                                Button { eraser.sizeIndex = i } label: {
                                    VStack(spacing: 4) {
                                        Circle()
                                            .strokeBorder(Y.ink2, lineWidth: 1.5)
                                            .frame(width: EraserSettings.sizes[i] * 0.9, height: EraserSettings.sizes[i] * 0.9)
                                            .frame(width: 56, height: 50)
                                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(i == eraser.sizeIndex ? Y.accentSoft : Y.surface3.opacity(0.6)))
                                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(i == eraser.sizeIndex ? Y.accent : .clear, lineWidth: 2))
                                        Text(EraserSettings.labels[i]).font(.caption2).foregroundStyle(Y.ink3)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(EraserSettings.labels[i]) silgi")
                                .accessibilityAddTraits(i == eraser.sizeIndex ? .isSelected : [])
                            }
                        }
                    }
                    Text("Sadece dairenin değdiği yer silinir.")
                        .font(.footnote).foregroundStyle(Y.ink2)
                } else {
                    Text("Dokunulan çizginin tamamı silinir.")
                        .font(.footnote).foregroundStyle(Y.ink2)
                }
            } else {
                Label("Vurgulayıcı", systemImage: "highlighter").font(.headline)
                Text("Sarı fosforlu kalem; metnin altında kalır gibi yarı saydam çizer.")
                    .font(.footnote).foregroundStyle(Y.ink2)
            }
        }
        .padding(18)
        .frame(width: 350)
    }
}

/// Belge üst çubuğundaki "Diğer" paneli
struct MoreMenu: View {
    @Binding var pencilOnly: Bool
    var favorite: Bool
    var canDeletePage: Bool
    var toggleFavorite: () -> Void
    var deletePage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $pencilOnly) {
                Label("Yalnızca Pencil ile çiz", systemImage: "applepencil")
            }
            .tint(Y.accent)
            .padding(.vertical, 10)
            Divider()
            Button(action: toggleFavorite) {
                Label(favorite ? "Favorilerden çıkar" : "Favorilere ekle", systemImage: favorite ? "star.slash" : "star")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if canDeletePage {
                Divider()
                Button(role: .destructive, action: deletePage) {
                    Label("Bu sayfayı sil", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Y.danger)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(width: 300)
    }
}
