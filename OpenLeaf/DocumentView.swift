import SwiftUI
import PencilKit
import PDFKit
import PhotosUI

enum ToolKind: String, CaseIterable {
    case pen, highlighter, tape, eraser, lasso
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .tape: "bandage"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
    var name: String {
        switch self {
        case .pen: String(localized: "Kalem")
        case .highlighter: String(localized: "Vurgulayıcı")
        case .tape: String(localized: "Bant")
        case .eraser: String(localized: "Silgi")
        case .lasso: String(localized: "Kement")
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .tape: "t"
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
        case .tukenmez: String(localized: "Tükenmez")
        case .dolma: String(localized: "Dolma")
        case .kursun: String(localized: "Kurşun")
        case .firca: String(localized: "Fırça")
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
    var name: String { self == .kismi ? String(localized: "Kısmi") : String(localized: "Bütün çizgi") }
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
    @Environment(\.scenePhase) private var scenePhase
    /// Belgeyi kapatıp kütüphaneye döner
    var onClose: () -> Void = {}
    private func dismiss() { onClose() }

    init(id: UUID, onClose: @escaping () -> Void = {}) {
        self.id = id
        self.onClose = onClose
        // Defter, en son kalınan sayfadan açılır
        _page = State(initialValue: LastOpened.page(id))
    }

    @State private var page = 0
    @State private var forward = true
    @State private var tool: ToolKind = .pen
    @State private var lastInkTool: ToolKind = .pen
    @AppStorage("kalem.renk.rgb") private var color: PenColor = .initial
    @AppStorage(PenPalette.favoritesKey) private var favoritesRaw = ""
    @AppStorage("kalem.tur") private var penType: PenType = .tukenmez
    @AppStorage("kalem.kalinlik.pt") private var penWidth: Double = 3
    @AppStorage("silgi.tur") private var eraserMode: EraserMode = .kismi
    @AppStorage("silgi.boyut") private var eraserSize: Double = 22
    private var eraser: EraserSettings { EraserSettings(mode: eraserMode, size: eraserSize) }
    private var eraserBinding: Binding<EraserSettings> {
        Binding(get: { EraserSettings(mode: eraserMode, size: eraserSize) },
                set: { eraserMode = $0.mode; eraserSize = $0.size })
    }
    @AppStorage("bant.renk") private var tapeColor: TapeColor = .sari
    @AppStorage("bant.kalinlik") private var tapeSize: TapeSize = .orta
    /// PencilKit cetveli (düz çizgi çekmek için); belge kapanınca kapanır
    @State private var ruler = false
    @State private var showToolMenu = false
    @State private var focus = false
    /// Tam ekrana girince birkaç saniye görünen "Tam ekrandan çık" düğmesi
    @State private var exitHint = false
    @State private var exitHintID = 0
    /// Varsayılan: parmak çizmez (sayfayı kaydırır ve tek parmakla sayfa çevirir), yalnızca Pencil çizer
    @AppStorage("kalem.sadecePencil") private var pencilOnly = true
    /// Araç çubuğu varsayılan olarak açık; üst çubuktaki düğmeyle gizlenip geri açılır ve tercih hatırlanır
    // @AppStorage değişikliği withAnimation'ı taşımadığı için görünürlük @State'te tutulur, tercih ayrıca kaydedilir
    @State private var toolbarHidden = UserDefaults.standard.bool(forKey: "aracCubugu.gizli")
    /// Gizle/göster düğmesinin ve araç çubuğu şeridinin konumu: çubuk düğmeden çıkıp düğmeye girer gibi görünsün
    @State private var toolbarButtonFrame: CGRect = .zero
    @State private var topBarFrame: CGRect = .zero
    @State private var controller = CanvasController()
    @State private var tapRipple = false
    @State private var confirmDelete = false
    @State private var showMore = false
    @State private var pdfDoc: PDFDocument?
    /// Kalem sıkılınca açılan hızlı menü ve açıldığı nokta (pencere koordinatı; nil ise ekran ortası)
    @State private var quickShown = false
    /// Sayfa genel görünümü açık mı; açıkken sıralama değişse de açık sayfa aynı kalsın diye kimliği tutulur
    @State private var showPages = false
    /// Resim ekleme: kamera ve fotoğraf arşivi
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var sharing: SharedFile?
    @State private var dropTargeted = false
    @State private var pasteboardHasImage = UIPasteboard.general.hasImages
    @State private var pinnedPage: UUID?
    /// "Sayfaya git" kutusu
    @State private var goToShown = false
    /// PDF'den sayfa ekleme
    @State private var showPDFPicker = false
    @State private var insertingPDF = false
    @State private var pdfError: String?
    @State private var goToText = ""
    @State private var quickPoint: CGPoint?

    /// Kalem kalınlığı aralığı (nokta); çubukla serbestçe ayarlanır
    static let penWidthRange: ClosedRange<Double> = 0.8...14

    var body: some View {
        if let nb = library.notebooks.first(where: { $0.id == id }) {
            if nb.pdfFile != nil && pdfDoc == nil {
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

    /// Açık sayfanın indeksi: sayfa kimliğiyle tutulur; eşitlemeyle sıra değişse de açık sayfa kaymaz
    private func openIndex(_ nb: Notebook) -> Int {
        if let pin = pinnedPage {
            if let i = nb.pages.firstIndex(where: { $0.id == pin }) { return i }
            // Açık sayfa silindi: bir önceki sayfaya düşülür
            return max(0, min(page - 1, nb.pages.count - 1))
        }
        return min(page, nb.pages.count - 1)
    }

    /// Açık sayfayı değiştirir; indeks ve kimlik birlikte güncellenir (kütüphanenin güncel hâlinden)
    private func setPage(_ target: Int) {
        guard let nb = library.notebooks.first(where: { $0.id == id }), !nb.pages.isEmpty else { return }
        let i = min(max(target, 0), nb.pages.count - 1)
        page = i
        pinnedPage = nb.pages[i].id
    }

    private func content(_ nb: Notebook) -> some View {
        let p = openIndex(nb)
        let pageID = nb.pages[p].id
        return ZStack(alignment: .bottom) {
            Y.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                if !focus {
                    topBar(nb, page: p)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("belge")) } action: { topBarFrame = $0 }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !focus && !toolbarHidden {
                    // Araç çubuğu üstte: yazarken avuç içi alttaki düğmelere değmesin
                    ToolbarCapsule(tool: $tool, color: $color, showToolMenu: $showToolMenu,
                                   penType: $penType, penWidth: $penWidth, eraser: eraserBinding,
                                   tapeColor: $tapeColor, tapeSize: $tapeSize, ruler: $ruler,
                                   revealTapes: controller.revealTapes,
                                   canUndo: controller.canUndo, canRedo: controller.canRedo,
                                   undo: controller.undo, redo: controller.redo,
                                   addNote: controller.addNote,
                                   takePhoto: { showCamera = true },
                                   pickPhoto: { showPhotos = true },
                                   pastePhoto: pasteImage,
                                   select: select)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Y.bg)
                        .overlay(alignment: .bottom) { Rectangle().fill(Y.line2).frame(height: 1) }
                        .zIndex(1)
                        .transition(focus ? .move(edge: .top).combined(with: .opacity)
                                    : .scale(scale: 0.03, anchor: toolbarAnchor).combined(with: .opacity))
                }
                ZStack {
                    canvas(nb, page: p)
                }
                // Dosyalar'dan, Safari'den ya da Fotoğraflar'dan sürüklenen resim sayfaya eklenir
                .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
                    dropImages(providers)
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Y.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .ignoresSafeArea(edges: .bottom)
            }
            .coordinateSpace(.named("belge"))

            if focus {
                focusHandle
            }

            if tapRipple {
                Text(tool.name)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(Color(hex: 0xF1ECDF))
                    .background(Color(hex: 0x2A2824).opacity(0.92), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 140)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .overlay {
            if showPages {
                PageOverview(notebook: nb, current: p, pdf: pdfDoc,
                             onOpen: { i in
                                 forward = i >= p
                                 setPage(i)
                                 withAnimation(Y.springSoft) { showPages = false }
                             },
                             onClose: {
                                 withAnimation(Y.springSoft) { showPages = false }
                             })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .sheet(item: $sharing) { file in ActivityView(items: [file.url]).ignoresSafeArea() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { insertImage($0) }.ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    insertImage(ui)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): insertPDF(url, after: p)
            case .failure(let error): pdfError = error.localizedDescription
            }
        }
        .alert("PDF eklenemedi", isPresented: Binding(get: { pdfError != nil }, set: { if !$0 { pdfError = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(pdfError ?? "")
        }
        .overlay {
            if insertingPDF {
                ProgressView("PDF ekleniyor…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Y.rM, style: .continuous))
                    .transition(.opacity)
            }
        }
        .onAppear {
            LastOpened.notebook = id
            // Eşitleme gelen değişiklikleri uygulamadan önce bekleyen çizgiyi kaydettirir
            // (zayıf tutulur: belge kapanınca kendiliğinden etkisiz kalır, başka belge açılınca onunki atanır)
            let editor = controller
            library.flushOpenEditors = { [weak editor] in editor?.flush() }
            // Kayıtlı sayfa artık yoksa (sayfalar silinmiş) son sayfaya düş; açık sayfa kimliğiyle tutulur
            setPage(page)
        }
        .onChange(of: page) { _, new in LastOpened.setPage(new, for: id) }
        .alert("Sayfaya git", isPresented: $goToShown) {
            TextField("Sayfa numarası", text: $goToText)
                .keyboardType(.numberPad)
            Button("Git") { goTo(goToText, nb) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("1 ile \(nb.pages.count) arasında bir sayfa numarası yaz.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            pasteboardHasImage = UIPasteboard.general.hasImages
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { pasteboardHasImage = UIPasteboard.general.hasImages }
            // Uygulama arka plana giderken bekleyen son çizgi diske yazılsın
            if phase != .active { controller.flush() }
        }
        .onChange(of: nb.pages.map(\.id)) { _, ids in
            // Sıralama/ekleme/silme (genel görünümde ya da eşitlemeyle) olunca açık sayfa kaymasın.
            // Kalem ekrandayken tuval geçişi kalem kalkınca yapar (Canvas); burada yalnızca indeks izlenir.
            guard !ids.isEmpty else { return }
            guard let pin = pinnedPage else { setPage(page); return }
            if let i = ids.firstIndex(of: pin) {
                if page != i { page = i }
            } else {
                // Açık sayfa silindi: bir önceki sayfaya düş
                let i = max(0, min(page - 1, ids.count - 1))
                page = i
                pinnedPage = ids[i]
            }
        }
        .overlay {
            if quickShown {
                GeometryReader { g in
                    let o = g.frame(in: .global).origin
                    let c = quickPoint.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
                        ?? CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                    QuickPalette(
                        center: c, tool: tool, color: color, colors: PenPalette.favorites(favoritesRaw),
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

            // Sayfa numarasına dokununca "Sayfaya git" açılır
            Button { askGoTo() } label: {
                VStack(spacing: 1) {
                    Text(nb.title).font(.system(.headline, design: .serif, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(Y.ink)
                    HStack(spacing: 3) {
                        Text(nb.kind == .whiteboard ? String(localized: "Whiteboard") : (nb.subtitle.isEmpty ? "" : nb.subtitle + " · ") + String(localized: "Sayfa \(p + 1) / \(nb.pages.count)"))
                            .contentTransition(.numericText())
                        if nb.isPaged && nb.pages.count > 1 {
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(.caption).foregroundStyle(Y.ink3).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(nb.isPaged && nb.pages.count > 1)
            .accessibilityHint(nb.isPaged && nb.pages.count > 1 ? Text("Sayfaya git") : Text(""))

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                if nb.isPaged {
                    iconButton("square.grid.2x2", "Tüm sayfalar") { openPages(nb, current: p) }
                    iconButton("chevron.up", "Önceki sayfa") { go(p - 1, nb) }.disabled(p == 0)
                    iconButton("chevron.down", "Sonraki sayfa") { go(p + 1, nb) }.disabled(p >= nb.pages.count - 1)
                    Menu {
                        Button("Boş sayfa", systemImage: "doc") { addPage(after: p) }
                        Button("PDF'den sayfa ekle…", systemImage: "doc.richtext") { showPDFPicker = true }
                    } label: {
                        Image(systemName: "doc.badge.plus").font(.system(size: 17)).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Y.ink2)
                    .accessibilityLabel("Sayfa ekle")
                    .help("Sayfa ekle")
                    let marked = nb.pages[p].isBookmarked
                    Button { library.toggleBookmark(id, nb.pages[p].id) } label: {
                        Image(systemName: marked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17)).frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(marked ? Y.accent : Y.ink2)
                    .accessibilityLabel(marked ? "Yer imini kaldır" : "Yer imi koy")
                    .help(marked ? "Yer imini kaldır" : "Yer imi koy")
                }
                shareMenu(nb, page: nb.pages[p])
                ThemeMenuButton()
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { toolbarHidden.toggle() }
                    UserDefaults.standard.set(toolbarHidden, forKey: "aracCubugu.gizli")
                } label: {
                    Image(systemName: toolbarHidden ? "rectangle" : "rectangle.topthird.inset.filled")
                        .font(.system(size: 17)).frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("belge")) } action: { toolbarButtonFrame = $0 }
                .buttonStyle(.plain)
                .foregroundStyle(toolbarHidden ? Y.ink2 : Y.accent)
                .accessibilityLabel(toolbarHidden ? "Araç çubuğunu göster" : "Araç çubuğunu gizle")
                .help(toolbarHidden ? "Araç çubuğunu göster" : "Araç çubuğunu gizle")
                iconButton("arrow.up.left.and.arrow.down.right", "Tam ekran") {
                    setFullScreen(true)
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

    /// Araç çubuğunun büyüyüp küçüldüğü nokta: gizle/göster düğmesinin ortası, şeride göre (şeridin üstünde kalır).
    /// Şerit animasyon sırasında ölçülmez; ölçülürse her kare başlangıç noktası değişip geçiş yeniden başlar.
    /// Şerit üst çubuğun hemen altında, onunla aynı genişlikte ve yaklaşık 72 pt yüksekliğinde.
    private var toolbarAnchor: UnitPoint {
        let b = toolbarButtonFrame, bar = topBarFrame
        let stripHeight: CGFloat = 72
        guard bar.width > 0, b != .zero else { return .topTrailing }
        return UnitPoint(x: (b.midX - bar.minX) / bar.width, y: (b.midY - bar.maxY) / stripHeight)
    }

    private func iconButton(_ icon: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Y.ink2)
        .accessibilityLabel(label)
        .help(label)
    }

    private func setFullScreen(_ on: Bool) {
        withAnimation(Y.springSoft) {
            focus = on
            exitHint = on
        }
        guard on else { return }
        // Çıkış yolu ilk anda görünsün, sonra sayfayı kapatmasın.
        // Hızlıca çıkıp yeniden girilirse eski zamanlayıcı yeni ipucunu kapatmasın diye sayaç tutulur.
        exitHintID += 1
        let id = exitHintID
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard id == exitHintID else { return }
            withAnimation(.easeOut(duration: 0.4)) { exitHint = false }
        }
    }

    private var focusHandle: some View {
        ZStack {
            // Sol kenardaki kalıcı çıkış tutamacı
            HStack {
                Button { setFullScreen(false) } label: {
                    Capsule().fill(Y.ink2.opacity(0.55)).frame(width: 6, height: 72)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .background(Y.surface.opacity(0.85), in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        .padding(.horizontal, 6).padding(.vertical, 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tam ekrandan çık")
                .help("Tam ekrandan çık")
                Spacer()
            }
            .frame(maxHeight: .infinity)

            if exitHint {
                VStack {
                    Button { setFullScreen(false) } label: {
                        Label("Tam ekrandan çık", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .foregroundStyle(Color(hex: 0xF1ECDF))
                            .background(Color(hex: 0x2A2824).opacity(0.92), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: Eylemler

    private var pkTool: PKTool {
        switch tool {
        case .pen, .tape:
            // Bantı tuval kendisi çeker, PencilKit çizimi o sırada kapalıdır. Araç yine de kalem kalır:
            // silgi olsaydı ve bir dokunuş kaçsaydı bantın altındaki yazı görünmeden silinirdi.
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

    private func canvas(_ nb: Notebook, page p: Int) -> CanvasRepresentable {
        let pageID = nb.pages[p].id
        let pdf: PDFPage? = nb.pages[p].pdfPage.flatMap { pdfDoc?.page(at: $0) }
        let cursor: CGFloat? = tool == .eraser && eraser.mode == .kismi ? eraser.width : nil
        let swipe: ((Int) -> Void)? = nb.isPaged ? { step in go(p + step, nb) } : nil
        let notebookID = id
        return CanvasRepresentable(
            pageID: pageID,
            data: library.drawing(notebookID, pageID),
            notes: nb.pages[p].stickyNotes,
            turnForward: forward,
            pdfPage: pdf,
            paper: nb.paper,
            canonical: nb.canonicalSize,
            isWhiteboard: nb.kind == .whiteboard,
            isPDF: nb.kind == .pdf,
            tool: pkTool,
            eraserCursor: cursor,
            pencilOnly: pencilOnly,
            controller: controller,
            onChange: { pid, data in
                // Sayfa kimliğiyle yaz: araya sayfa eklenip silinse de doğru dosyaya gider
                library.saveDrawing(notebookID, pid, data)
            },
            onPencilTap: pencilDoubleTap,
            onPageSwipe: swipe,
            onNotesChange: { pid, list, seen in library.setNotes(notebookID, pid, list, seenRemote: seen) },
            notebookID: notebookID,
            images: nb.pages[p].pageImages,
            onImagesChange: { pid, list, seen in library.setImages(notebookID, pid, list, seenRemote: seen) },
            onPencilSqueeze: { point in squeezed(at: point) },
            tapes: nb.pages[p].pageTapes,
            onTapesChange: { pid, list, seen in library.setTapes(notebookID, pid, list, seenRemote: seen) },
            tapeMode: tool == .tape,
            erasesTapes: tool == .eraser,
            tapeColor: tapeColor,
            tapeThickness: tapeSize.thickness,
            ruler: ruler,
            remoteVersion: library.remoteInkVersion[pageID] ?? 0,
            remoteItemsVersion: library.remoteItemsVersion[pageID] ?? 0,
            latestData: { pid in library.drawing(notebookID, pid) },
            onRemoteConflict: { pid, data in
                // Uzak mürekkep sayfada kalır; bu iPad'de o sırada çizilenler yanındaki kopyaya.
                // Sayfa bu arada silindiyse kopyanın kaynağı yok: kurtarılmış yeni sayfaya yazılır
                let exists = library.notebooks.first { $0.id == notebookID }?.pages.contains { $0.id == pid } ?? false
                if exists {
                    _ = library.insertConflictCopy(of: pid, ink: data)
                } else {
                    savePageGone(notebookID, pid, data)
                }
            },
            onPageGoneSave: { pid, data in savePageGone(notebookID, pid, data) }
        )
    }

    /// Kalem ekrandayken açık sayfa değişti (başka iPad'de silindi). Sayfa duruyorsa normal kayıt; silinmişse
    /// tuvaldeki mürekkep yeni bir sayfaya yazılır ve "Kurtarıldı" + yer imiyle işaretlenir (çizgi kaybolmasın).
    /// Silinen sayfaya kopya bağlanamadığı için `insertConflictCopy` değil, mevcut `insertPage` + `markRescued`.
    private func savePageGone(_ notebookID: UUID, _ pid: UUID, _ data: Data) {
        guard let nb = library.notebooks.first(where: { $0.id == notebookID }) else { return }
        if nb.pages.contains(where: { $0.id == pid }) {
            library.saveDrawing(notebookID, pid, data)
            return
        }
        guard !((try? PKDrawing(data: data))?.strokes.isEmpty ?? true) else { return }
        // Silinen sayfanın yerine: düşülen (önceki) sayfanın arkasına
        let at = min(openIndex(nb) + 1, nb.pages.count)
        library.insertPage(notebookID, at: at)
        guard let fresh = library.notebooks.first(where: { $0.id == notebookID }), at < fresh.pages.count else { return }
        let newID = fresh.pages[at].id
        library.saveDrawing(notebookID, newID, data)
        library.markRescued(page: newID)
    }

    private func squeezed(at point: CGPoint?) {
        if quickShown {
            withAnimation(Y.quick) { quickShown = false }
        } else {
            quickPoint = point
            showToolMenu = false
            quickShown = true
        }
    }

    /// Resmi küçültüp defter klasörüne kaydeder ve açık sayfanın ortasına koyar
    private func insertImage(_ ui: UIImage) {
        guard let prepared = ImageStore.prepare(ui) else { return }
        let file = library.saveImageFile(id, data: prepared.data)
        if let img = UIImage(data: prepared.data) { ImageStore.remember(id, file, img) }
        controller.addImage(file: file, pixelSize: prepared.size)
    }

    // MARK: Paylaş ve yazdır

    private func shareMenu(_ nb: Notebook, page: Page) -> some View {
        Menu {
            Section(nb.isPaged ? String(localized: "Bu sayfa") : "") {
                Button { share { PDFExporter.renderImage(nb, page: page, library: library) } } label: {
                    Label("Resim olarak paylaş", systemImage: "photo")
                }
                if nb.isPaged {
                    Button { share { PDFExporter.render(nb, library: library, only: page) } } label: {
                        Label("PDF olarak paylaş", systemImage: "doc")
                    }
                }
                Button { printPDF(nb) { PDFExporter.render(nb, library: library, only: page) } } label: {
                    Label(nb.isPaged ? "Bu sayfayı yazdır" : "Yazdır", systemImage: "printer")
                }
            }
            if nb.isPaged {
                Section("Tüm defter") {
                    Button { share { PDFExporter.render(nb, library: library) } } label: {
                        Label("Defteri PDF olarak paylaş", systemImage: "doc.richtext")
                    }
                    Button { printPDF(nb) { PDFExporter.render(nb, library: library) } } label: {
                        Label("Defteri yazdır", systemImage: "printer.fill")
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 17)).frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Y.ink2)
        .accessibilityLabel("Paylaş ve yazdır")
    }

    /// Son çizgiyi kaydeder, dosyayı üretir, menü kapandıktan sonra paylaşım sayfasını açar
    private func share(_ make: @escaping () -> URL) {
        controller.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sharing = SharedFile(url: make()) }
    }

    private func printPDF(_ nb: Notebook, _ make: @escaping () -> URL) {
        controller.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PDFExporter.print(make(), title: nb.title) }
    }

    // MARK: Yapıştır ve sürükle-bırak

    private func pasteImage() {
        guard let img = UIPasteboard.general.image else { return }
        insertImage(img)
    }

    private func dropImages(_ providers: [NSItemProvider]) -> Bool {
        let items = providers.filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !items.isEmpty else { return false }
        for provider in items {
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let img = object as? UIImage else { return }
                DispatchQueue.main.async { insertImage(img) }
            }
        }
        return true
    }

    private func openPages(_ nb: Notebook, current p: Int) {
        controller.flush()
        withAnimation(Y.springSoft) { showPages = true }
    }

    private func go(_ target: Int, _ nb: Notebook) {
        guard target >= 0, target < nb.pages.count else { return }
        forward = target > page
        turn(to: target)
    }

    /// Seçilen PDF'in sayfalarını açık sayfanın arkasına ekler ve ilk eklenen sayfaya gider
    private func insertPDF(_ url: URL, after p: Int) {
        controller.flush()
        withAnimation(Y.quick) { insertingPDF = true }
        Task {
            defer { withAnimation(Y.quick) { insertingPDF = false } }
            do {
                let count = try await library.insertPDF(id, from: url, at: p + 1)
                guard count > 0, let nb = library.notebooks.first(where: { $0.id == id }) else { return }
                // Defterin PDF'i değişti: yeni sayfaları görmek için yeniden aç
                pdfDoc = library.pdfURL(nb).flatMap { PDFDocument(url: $0) }
                forward = true
                turn(to: p + 1)
            } catch {
                pdfError = error.localizedDescription
            }
        }
    }

    private func askGoTo() {
        goToText = ""
        goToShown = true
    }

    /// Yazılan numaraya gider; aralık dışıysa ilk ya da son sayfaya
    private func goTo(_ text: String, _ nb: Notebook) {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        go(min(max(n, 1), nb.pages.count) - 1, nb)
    }

    private func addPage(after p: Int) {
        library.insertPage(id, at: p + 1)
        forward = true
        turn(to: p + 1)
    }

    /// Sayfa değiştir; kitap sayfası animasyonunu tuval yapar (yönü `forward`)
    private func turn(to target: Int) {
        setPage(target)
    }

    private func deletePage(_ p: Int) {
        guard let nb = library.notebooks.first(where: { $0.id == id }), p < nb.pages.count else { return }
        forward = false
        withAnimation(Y.quick) {
            library.deletePage(id, nb.pages[p].id)
            setPage(max(0, p - 1))
        }
    }

    // ⌘ kısayolları (harici klavye)
    private func shortcuts(_ nb: Notebook) -> some View {
        Group {
            ForEach(ToolKind.allCases, id: \.self) { t in
                Button(t.name) { select(t) }.keyboardShortcut(t.key, modifiers: [])
            }
            Button("Yeni sayfa") { addPage(after: min(page, nb.pages.count - 1)) }.keyboardShortcut("n")
            if nb.isPaged && nb.pages.count > 1 {
                Button("Sayfaya git") { askGoTo() }.keyboardShortcut("g")
            }
            Button("Tam ekran") { setFullScreen(!focus) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Geri al") { controller.undo() }.keyboardShortcut("z")
            Button("Yinele") { controller.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            // ⌘V: panoda resim varsa sayfaya yapıştırır (yazı yapıştırmayı engellememek için yalnızca resimde)
            if pasteboardHasImage {
                Button("Resmi yapıştır") { pasteImage() }.keyboardShortcut("v")
            }
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
    @Binding var tapeColor: TapeColor
    @Binding var tapeSize: TapeSize
    @Binding var ruler: Bool
    var revealTapes: (Bool) -> Void
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
    var addNote: () -> Void
    var takePhoto: () -> Void
    var pickPhoto: () -> Void
    var pastePhoto: () -> Void
    var select: (ToolKind) -> Void

    @AppStorage(PenPalette.favoritesKey) private var favoritesRaw = ""
    /// Kalem menüsünde renk paneli açık mı; `editSlot` doluysa o sık kullanılan renk değiştiriliyor
    @State private var colorPanel = false
    @State private var editSlot: Int?

    var body: some View {
        // Dar ekranda (iPad mini dikey, Split View) "Diğer renkler" düğmesi çubuktan çıkar; kalem menüsünde durur
        ViewThatFits(in: .horizontal) {
            bar(moreColors: true)
            bar(moreColors: false)
        }
    }

    private func bar(moreColors: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach([ToolKind.pen, .highlighter, .tape, .eraser], id: \.self) { toolButton($0) }

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

            // Resim ekle: kamera ya da fotoğraf arşivi
            Menu {
                Button(action: takePhoto) { Label("Fotoğraf çek", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button(action: pickPhoto) { Label("Fotoğraflardan seç", systemImage: "photo.on.rectangle") }
                Button(action: pastePhoto) { Label("Kopyalanan resmi yapıştır", systemImage: "doc.on.clipboard") }
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(Y.ink2)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Resim ekle")

            toolButton(.lasso)

            // Cetvel: açıkken çizgiler cetvelin kenarına yapışır; iki parmakla taşınır ve döndürülür
            Button { ruler.toggle() } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(ruler ? Y.accent : Y.ink2)
                    .background(Circle().fill(ruler ? Y.accentSoft : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cetvel")
            .accessibilityAddTraits(ruler ? .isSelected : [])

            sep

            colorButtons(more: moreColors)

            sep

            undoRedo
        }
        .font(.system(size: 17))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glass(Capsule())
        .animation(Y.quick, value: tool)
        .animation(Y.quick, value: color)
        .animation(Y.quick, value: ruler)
    }

    /// Kalem menüsünü renk panelinde açar
    private func openColorPanel(slot: Int? = nil) {
        if tool != .pen { select(.pen) }
        editSlot = slot
        colorPanel = true
        showToolMenu = true
    }

    private func toolButton(_ t: ToolKind) -> some View {
                Button {
                    // Araç düğmesinden açılan menü her zaman ana sayfasıyla açılır
                    colorPanel = false
                    editSlot = nil
                    select(t)
                } label: {
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
                         arrowEdge: .top) {
                    ToolMenu(tool: t, penType: $penType, penWidth: $penWidth, color: $color,
                             colorPanel: $colorPanel, editSlot: $editSlot, eraser: $eraser,
                             tapeColor: $tapeColor, tapeSize: $tapeSize, revealTapes: revealTapes)
                        .presentationCompactAdaptation(.popover)
                }
    }

    private func colorButtons(more: Bool) -> some View {
        let favorites = PenPalette.favorites(favoritesRaw)
        let custom = !favorites.contains(color)
        return Group {
            ForEach(Array(favorites.enumerated()), id: \.offset) { i, c in
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { openColorPanel(slot: i) } label: { Label("Bu rengi değiştir…", systemImage: "eyedropper") }
                    Button { favoritesRaw = "" } label: { Label("Varsayılan renklere dön", systemImage: "arrow.counterclockwise") }
                }
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }
            // Diğer renkler: seçili renk sık kullanılanlarda değilse onu gösterir
            if more {
                Button { openColorPanel() } label: {
                    ZStack {
                        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .frame(width: 24, height: 24)
                        if custom {
                            Circle().fill(color.swatch).frame(width: 15, height: 15)
                                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                        }
                    }
                    .padding(4)
                    .overlay(Circle().strokeBorder(custom && tool == .pen ? Y.accent : .clear, lineWidth: 2))
                    .frame(width: 38, height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Diğer renkler")
                .accessibilityValue(custom ? color.name : "")
            }
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

/// Aktif araç menüsü: kalem türü, kalınlık, renk; silgi türü; bant ayarları
struct ToolMenu: View {
    var tool: ToolKind
    @Binding var penType: PenType
    @Binding var penWidth: Double
    @Binding var color: PenColor
    @Binding var colorPanel: Bool
    @Binding var editSlot: Int?
    @Binding var eraser: EraserSettings
    @Binding var tapeColor: TapeColor
    @Binding var tapeSize: TapeSize
    var revealTapes: (Bool) -> Void

    @AppStorage(PenPalette.favoritesKey) private var favoritesRaw = ""
    @AppStorage(PenPalette.recentsKey) private var recentsRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tool == .pen, colorPanel {
                ColorPanel(color: $color, slot: editSlot) {
                    withAnimation(Y.quick) { colorPanel = false; editSlot = nil }
                }
            } else if tool == .pen {
                Picker("Kalem türü", selection: $penType) {
                    ForEach(PenType.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("KALINLIK").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                        Spacer()
                        Text(penWidth.formatted(.number.precision(.fractionLength(1))))
                            .font(.caption.monospacedDigit()).foregroundStyle(Y.ink2)
                    }
                    HStack(spacing: 12) {
                        Circle().fill(color.swatch).frame(width: 4, height: 4).frame(width: 14)
                        Slider(value: $penWidth, in: DocumentView.penWidthRange)
                            .tint(Y.accent)
                            .accessibilityLabel("Kalem kalınlığı")
                            .accessibilityValue(penWidth.formatted(.number.precision(.fractionLength(1))))
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

                penColors
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
            } else if tool == .tape {
                Picker("Bant kalınlığı", selection: $tapeSize) {
                    ForEach(TapeSize.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("RENKLER").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                    HStack(spacing: 10) {
                        ForEach(TapeColor.allCases) { c in
                            Button { tapeColor = c } label: {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(uiColor: c.ui))
                                    .frame(width: 52, height: 26)
                                    .padding(4)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(c == tapeColor ? Y.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                            .accessibilityAddTraits(c == tapeColor ? .isSelected : [])
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button { revealTapes(false) } label: {
                        Label("Hepsini kapat", systemImage: "eye.slash").frame(maxWidth: .infinity)
                    }
                    Button { revealTapes(true) } label: {
                        Label("Hepsini aç", systemImage: "eye").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(Y.accent)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                Text("Kendini sınamak için yazının üstüne sürükleyerek bant çek. Banta dokununca altı görünür, yeniden dokununca kapanır. Silmek için silgiyle banta dokun.")
                    .font(.footnote).foregroundStyle(Y.ink2)
                    .fixedSize(horizontal: false, vertical: true)
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

extension ToolMenu {
    @ViewBuilder
    var penColors: some View {
        let favorites = PenPalette.favorites(favoritesRaw)
        let recents = PenPalette.decode(recentsRaw).filter { !favorites.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text("SIK KULLANILANLAR").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
            HStack(spacing: 10) {
                ForEach(Array(favorites.enumerated()), id: \.offset) { i, c in
                    swatchButton(c, size: 30)
                        .contextMenu {
                            Button { editSlot = i; withAnimation(Y.quick) { colorPanel = true } } label: {
                                Label("Bu rengi değiştir…", systemImage: "eyedropper")
                            }
                            Button { favoritesRaw = "" } label: {
                                Label("Varsayılan renklere dön", systemImage: "arrow.counterclockwise")
                            }
                        }
                }
            }
            Text("Bir renge basılı tutarak yerine başka bir renk koyabilirsin.")
                .font(.caption).foregroundStyle(Y.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SON KULLANILANLAR").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                HStack(spacing: 6) {
                    ForEach(recents, id: \.self) { c in swatchButton(c, size: 26) }
                }
            }
        }
        Button { editSlot = nil; withAnimation(Y.quick) { colorPanel = true } } label: {
            HStack(spacing: 8) {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 18, height: 18)
                Text("Diğer renkler…")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Y.accent)
        .font(.subheadline)
    }

    private func swatchButton(_ c: PenColor, size: CGFloat) -> some View {
        Button { color = c } label: {
            Circle().fill(c.swatch).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Y.line.opacity(0.6)))
                .padding(3)
                .overlay(Circle().strokeBorder(c == color ? Y.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.name)
        .accessibilityAddTraits(c == color ? .isSelected : [])
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
                Label(favorite ? String(localized: "Favorilerden çıkar") : String(localized: "Favorilere ekle"), systemImage: favorite ? "star.slash" : "star")
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
