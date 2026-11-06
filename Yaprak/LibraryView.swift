import SwiftUI
import UniformTypeIdentifiers

struct OpenDoc: Identifiable, Hashable { let id: UUID }

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var section: SidebarSection? = .belgeler
    @State private var search = ""
    @State private var openDoc: OpenDoc?
    @State private var showNew = false
    @State private var showImporter = false
    @State private var importError: String?
    @AppStorage("siralama") private var sort: SortOrder = .modified
    @State private var columns = NavigationSplitViewVisibility.all
    @Namespace private var zoom

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
        .fullScreenCover(item: $openDoc) { doc in
            DocumentView(id: doc.id)
                .navigationTransition(.zoom(sourceID: doc.id, in: zoom))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do { openDoc = OpenDoc(id: try library.importPDF(from: url)) }
                catch { importError = error.localizedDescription }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        // Başka uygulamadan "Yaprak'ta aç" / Paylaş > Yaprak ile gelen PDF
        .onOpenURL { url in openIncoming(url) }
        .alert("PDF içe aktarılamadı", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showNew) {
            NewNotebookSheet { nb in
                let id = library.create(nb)
                showNew = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openDoc = OpenDoc(id: id) }
            }
        }
    }

    // MARK: Kenar çubuğu

    private var sidebar: some View {
        List(selection: $section) {
            HStack(spacing: 10) {
                LogoMark(size: 30)
                Text("Yaprak").font(.system(size: 24, weight: .semibold, design: .serif))
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .selectionDisabled()

            Section {
                ForEach(SidebarSection.allCases) { s in
                    NavigationLink(value: s) {
                        HStack {
                            Label(s.title, systemImage: s.icon)
                            Spacer()
                            if let n = library.count(s), n > 0 {
                                Text("\(n)").font(.subheadline).foregroundStyle(Y.ink3).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Y.surface2)
        .navigationSplitViewColumnWidth(272)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Image(systemName: "ipad").font(.system(size: 16)).foregroundStyle(Y.ink3)
                    .frame(width: 34, height: 34)
                    .background(Y.surface3, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bu iPad'de kayıtlı").font(.subheadline.weight(.semibold))
                    Text("\(library.items(for: .belgeler).count) belge").font(.caption).foregroundStyle(Y.ink3)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Ana alan

    @ViewBuilder
    private var detail: some View {
        let s = section ?? .belgeler
        let items = library.items(for: s, sort: sort).filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.subtitle.localizedStandardContains(search)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if s == .belgeler && search.isEmpty && !items.isEmpty {
                    Text(sort == .modified ? "SON DÜZENLENENLER" : "ADA GÖRE").font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                        .padding(.top, 4)
                }
                if items.isEmpty {
                    empty(s)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28, alignment: .top)],
                              alignment: .leading, spacing: 30) {
                        ForEach(items) { nb in
                            DocCard(nb: nb)
                                .matchedTransitionSource(id: nb.id, in: zoom)
                                .onTapGesture { if !nb.trashed { openDoc = OpenDoc(id: nb.id) } }
                                .contextMenu { menu(for: nb) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Y.bg)
        .navigationTitle(s.title)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Notlarda ara")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sıralama", selection: $sort) {
                        Label("Son düzenlenen", systemImage: "clock").tag(SortOrder.modified)
                        Label("Ada göre", systemImage: "textformat").tag(SortOrder.title)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sıralama")
                Menu {
                    Button("Defter", systemImage: "book.closed") { showNew = true }
                    Button("Hızlı not", systemImage: "bolt") { quick(kind: .defter) }
                    Button("Whiteboard", systemImage: "rectangle.on.rectangle.angled") { quick(kind: .whiteboard) }
                    Divider()
                    Button("Klasör", systemImage: "folder.badge.plus") {}.disabled(true)
                    Button("Belge tara", systemImage: "doc.viewfinder") {}.disabled(true)
                    Button("PDF içe aktar", systemImage: "square.and.arrow.down") { showImporter = true }
                } label: {
                    Label("Yeni", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
    }

    @ViewBuilder
    private func empty(_ s: SidebarSection) -> some View {
        let (icon, title, text): (String, String, String) = switch s {
        case .favoriler: ("star", "Favori yok", "Bir belgeye basılı tutup Favorilere ekleyin.")
        case .paylasilanlar: ("person.2", "Paylaşılan belge yok", "Sizinle paylaşılan belgeler burada görünür.")
        case .magaza: ("square.grid.2x2", "Galeri yakında", "Ücretsiz şablon, kapak ve çıkartma paketleri burada olacak.")
        case .cop: ("trash", "Çöp boş", "Silinen belgeler 30 gün burada kalır.")
        case .belgeler: ("doc.on.doc", search.isEmpty ? "Henüz belge yok" : "Sonuç yok",
                         search.isEmpty ? "Yeni düğmesiyle ilk defterinizi oluşturun." : "“\(search)” için eşleşme bulunamadı.")
        }
        ContentUnavailableView(title, systemImage: icon, description: Text(text))
            .frame(maxWidth: .infinity, minHeight: 420)
    }

    @ViewBuilder
    private func menu(for nb: Notebook) -> some View {
        if nb.trashed {
            Button("Geri yükle", systemImage: "arrow.uturn.backward") { library.update(nb.id) { $0.trashed = false } }
            Button("Kalıcı olarak sil", systemImage: "trash", role: .destructive) { library.deleteForever(nb.id) }
        } else {
            Button(nb.favorite ? "Favorilerden çıkar" : "Favorilere ekle", systemImage: nb.favorite ? "star.slash" : "star") {
                library.update(nb.id) { $0.favorite.toggle() }
            }
            Button("Çoğalt", systemImage: "plus.square.on.square") { library.duplicate(nb) }
            ShareLink(item: NotebookPDF(notebook: nb),
                      preview: SharePreview("\(nb.title).pdf", image: Image(systemName: "doc.richtext"))) {
                Label("PDF olarak paylaş", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Çöpe taşı", systemImage: "trash", role: .destructive) {
                withAnimation(Y.spring) { library.update(nb.id) { $0.trashed = true } }
            }
        }
    }

    private func openIncoming(_ url: URL) {
        guard url.isFileURL else { return }
        defer {
            // Sistem dosyayı Inbox klasörüne kopyalar; içe aktardıktan sonra o kopyayı sil
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let id = try library.importPDF(from: url)
            section = .belgeler
            if openDoc != nil {
                // Açık bir belge varsa önce kapat, sonra yenisini aç
                openDoc = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openDoc = OpenDoc(id: id) }
            } else {
                openDoc = OpenDoc(id: id)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func quick(kind: DocKind) {
        let nb = kind == .whiteboard
            ? Notebook(title: "Adsız Whiteboard", kind: .whiteboard, cover: .kagit, paper: .bos)
            : Notebook(title: "Hızlı not", subtitle: Date().formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "tr_TR"))),
                       cover: .tas, paper: .cizgili)
        openDoc = OpenDoc(id: library.create(nb))
    }
}

struct DocCard: View {
    var nb: Notebook
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if nb.kind == .whiteboard { WhiteboardThumb(title: nb.title) }
                else if nb.kind == .pdf, let file = nb.pdfFile { PDFThumb(file: file) }
                else { CoverView(style: nb.cover, title: nb.title, subtitle: nb.subtitle) }
            }
            .overlay(alignment: .topTrailing) {
                if nb.favorite {
                    Image(systemName: "star.fill").font(.caption2)
                        .foregroundStyle(Y.hl)
                        .padding(6)
                        .background(.black.opacity(0.25), in: Circle())
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(nb.title).font(.subheadline.weight(.semibold)).foregroundStyle(Y.ink).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(Y.ink3).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nb.title), \(meta)")
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String {
        nb.kind == .whiteboard ? "Whiteboard · \(nb.modified.yaprakRelative)"
            : nb.kind == .pdf ? "PDF · \(nb.pages.count) sayfa · \(nb.modified.yaprakRelative)"
            : "\(nb.pages.count) sayfa · \(nb.modified.yaprakRelative)"
    }
}
