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
    /// Silgi çapı (ekran noktası); kaydırma çubuğuyla serbestçe ayarlanır
    var size: Double = 22
    /// Boyutu ayarlanabilen kısmi silgi. Düz `.bitmap` genişlik kabul etmiyor (geçerli aralığı 0…0),
    /// verilen değer en küçük boyuta düşüyordu.
    static let eraserType = PKEraserTool.EraserType.fixedWidthBitmap
    /// Kaydırma çubuğu aralığı: PencilKit'in izin verdiği aralık (yaklaşık 16…80)
    static let range: ClosedRange<Double> = {
        let v = eraserType.validWidthRange
        let lo = Double(v.lowerBound.rounded(.up)), hi = Double(v.upperBound.rounded(.down))
        return lo < hi ? lo...hi : 16...80
    }()
    var width: CGFloat {
        CGFloat(min(max(size, Self.range.lowerBound), Self.range.upperBound))
    }
}

struct DocumentView: View {
    let id: UUID
    @Environment(Library.self) private var library
    /// Belgeyi kapatıp kütüphaneye döner
    var onClose: () -> Void = {}
    private func dismiss() { onClose() }

    @State private var page = 0
    @State private var forward = true
    @State private var tool: ToolKind = .pen
    @State private var lastInkTool: ToolKind = .pen
    @AppStorage("kalem.renk") private var color: PenColor = .ink
    @AppStorage("kalem.tur") private var penType: PenType = .tukenmez
    @AppStorage("kalem.kalinlik.pt") private var penWidth: Double = 3
    @AppStorage("silgi.tur") private var eraserMode: EraserMode = .kismi
    @AppStorage("silgi.boyut") private var eraserSize: Double = 22
    private var eraser: EraserSettings { EraserSettings(mode: eraserMode, size: eraserSize) }
    private var eraserBinding: Binding<EraserSettings> {
        Binding(get: { EraserSettings(mode: eraserMode, size: eraserSize) },
                set: { eraserMode = $0.mode; eraserSize = $0.size })
    }
    @State private var showToolMenu = false
    @State private var focus = false
    /// Varsayılan: parmak çizmez (sayfayı kaydırır ve tek parmakla sayfa çevirir), yalnızca Pencil çizer
    @AppStorage("kalem.sadecePencil") private var pencilOnly = true
    @State private var controller = CanvasController()
    @State private var tapRipple = false
    @State private var confirmDelete = false
    @State private var showMore = false
    @State private var pdfDoc: PDFDocument?
    /// Kalem sıkılınca açılan hızlı menü ve açıldığı nokta (pencere koordinatı; nil ise ekran ortası)
    @State private var quickShown = false
    @State private var quickPoint: CGPoint?

    /// Kalem kalınlığı aralığı (nokta); çubukla serbestçe ayarlanır
    static let penWidthRange: ClosedRange<Double> = 0.8...14

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
                        notes: nb.pages[p].stickyNotes,
                        turnForward: forward,
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
                        onPencilTap: pencilDoubleTap,
                        onPageSwipe: nb.isPaged ? { step in go(p + step, nb) } : nil,
                        onNotesChange: { pid, list in library.setNotes(id, pid, list) },
                        onPencilSqueeze: { point in
                            if quickShown {
                                withAnimation(Y.quick) { quickShown = false }
                            } else {
                                quickPoint = point
                                showToolMenu = false
                                quickShown = true
                            }
                        }
                    )
                }
                .clipped()
                .ignoresSafeArea(edges: .bottom)
            }

            if !focus {
                ToolbarCapsule(tool: $tool, color: $color, showToolMenu: $showToolMenu,
                               penType: $penType, penWidth: $penWidth, eraser: eraserBinding,
                               canUndo: controller.canUndo, canRedo: controller.canRedo,
                               undo: controller.undo, redo: controller.redo,
                               addNote: controller.addNote,
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
        .overlay {
            if quickShown {
                GeometryReader { g in
                    let o = g.frame(in: .global).origin
                    let c = quickPoint.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
                        ?? CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                    QuickPalette(
                        center: c, tool: tool, color: color,
                        canUndo: controller.canUndo, canRedo: controller.canRedo,
                        onTool: { t in
                            withAnimation(Y.quick) { tool = t }
                            if t != .eraser { lastInkTool = t }
                        },
                        onColor: { c in
                            color = c
                            withAnimation(Y.quick) { tool = .pen }
                            lastInkTool = .pen
                        },
                        onNote: controller.addNote,
                        onUndo: controller.undo,
                        onRedo: controller.redo,
                        onClose: { withAnimation(Y.quick) { quickShown = false } }
                    )
                }
                .ignoresSafeArea()
                .transition(.opacity)
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
            return PKInkingTool(penType.ink, color: color.ui, width: CGFloat(penWidth) * penType.widthScale)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(hex: 0xF3D77A).withAlphaComponent(0.9), width: 22)
        case .eraser:
            return eraser.mode == .kismi ? PKEraserTool(EraserSettings.eraserType, width: eraser.width) : PKEraserTool(.vector)
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

    /// Sayfa değiştir; kitap sayfası animasyonunu tuval yapar (yönü `forward`)
    private func turn(to target: Int) {
        page = target
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
    @Binding var penWidth: Double
    @Binding var eraser: EraserSettings
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
    var addNote: () -> Void
    var select: (ToolKind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([ToolKind.pen, .highlighter, .eraser], id: \.self) { toolButton($0) }

            // Silginin sağında: yapışkan not ekle
            Button(action: addNote) {
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(Y.ink2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Yapışkan not ekle")

            toolButton(.lasso)

            sep

            colorButtons

            sep

            undoRedo
        }
        .font(.system(size: 17))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glass(Capsule())
        .animation(Y.quick, value: tool)
        .animation(Y.quick, value: color)
    }

    private func toolButton(_ t: ToolKind) -> some View {
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
                    ToolMenu(tool: t, penType: $penType, penWidth: $penWidth, color: $color, eraser: $eraser)
                        .presentationCompactAdaptation(.popover)
                }
    }

    private var colorButtons: some View {
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
    }

    @ViewBuilder
    private var undoRedo: some View {
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

    private var sep: some View {
        Rectangle().fill(Y.line).frame(width: 1, height: 26).padding(.horizontal, 6)
    }
}

/// Aktif araç menüsü: kalem türü, kalınlık, renk
struct ToolMenu: View {
    var tool: ToolKind
    @Binding var penType: PenType
    @Binding var penWidth: Double
    @Binding var color: PenColor
    @Binding var eraser: EraserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tool == .pen {
                Picker("Kalem türü", selection: $penType) {
                    ForEach(PenType.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("KALINLIK").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                        Spacer()
                        Text(String(format: "%.1f", penWidth).replacingOccurrences(of: ".", with: ","))
                            .font(.caption.monospacedDigit()).foregroundStyle(Y.ink2)
                    }
                    HStack(spacing: 12) {
                        Circle().fill(color.swatch).frame(width: 4, height: 4).frame(width: 14)
                        Slider(value: $penWidth, in: DocumentView.penWidthRange)
                            .tint(Y.accent)
                            .accessibilityLabel("Kalem kalınlığı")
                            .accessibilityValue(String(format: "%.1f", penWidth))
                        Circle().fill(color.swatch).frame(width: 14, height: 14)
                    }
                    // Seçilen kalınlıkta canlı çizgi önizlemesi
                    Canvas { ctx, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 18, y: size.height / 2 + 6))
                        path.addCurve(to: CGPoint(x: size.width - 18, y: size.height / 2 - 6),
                                      control1: CGPoint(x: size.width * 0.35, y: -6),
                                      control2: CGPoint(x: size.width * 0.65, y: size.height + 6))
                        ctx.stroke(path, with: .color(color.swatch),
                                   style: StrokeStyle(lineWidth: penWidth * penType.widthScale * 0.9, lineCap: .round))
                    }
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Y.surface3.opacity(0.6)))
                    .animation(.easeOut(duration: 0.12), value: penWidth)
                    .accessibilityHidden(true)
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("BOYUT").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                            Spacer()
                            Text("\(Int(eraser.width.rounded())) pt")
                                .font(.caption.monospacedDigit()).foregroundStyle(Y.ink2)
                        }
                        HStack(spacing: 12) {
                            Circle().strokeBorder(Y.ink3, lineWidth: 1.5).frame(width: 8, height: 8)
                            Slider(value: $eraser.size, in: EraserSettings.range)
                                .tint(Y.accent)
                                .accessibilityLabel("Silgi boyutu")
                                .accessibilityValue("\(Int(eraser.width.rounded())) nokta")
                            Circle().strokeBorder(Y.ink3, lineWidth: 1.5).frame(width: 22, height: 22)
                        }
                        // Silginin gerçek boyutta önizlemesi
                        Circle()
                            .fill(Y.surface)
                            .overlay(Circle().strokeBorder(Y.ink2, lineWidth: 1.5))
                            .frame(width: eraser.width, height: eraser.width)
                            .frame(maxWidth: .infinity, minHeight: 92)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Y.surface3.opacity(0.6)))
                            .animation(.easeOut(duration: 0.12), value: eraser.size)
                            .accessibilityHidden(true)
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
