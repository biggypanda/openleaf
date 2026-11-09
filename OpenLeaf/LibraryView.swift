import SwiftUI
import UniformTypeIdentifiers

struct OpenDoc: Identifiable, Hashable { let id: UUID }

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var selection: SidebarItem? = .section(.belgeler)
    /// Klasör adı penceresi: yeni klasör, yeniden adlandır ya da defteri yeni klasöre taşı
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""
    @State private var deletingFolder: Folder?

    enum FolderPrompt: Identifiable {
        case create
        case rename(Folder)
        case createAndMove(UUID)
        var id: String {
            switch self {
            case .create: "create"
            case .rename(let f): "rename-\(f.id)"
            case .createAndMove(let n): "move-\(n)"
            }
        }
    }

    /// Seçili klasör (bölüm seçiliyse nil)
    private var currentFolder: UUID? {
        if case .folder(let id) = selection { return id }
        return nil
    }
    @State private var search = ""
    @State private var openDoc: OpenDoc?
    @State private var showNew = false
    @State private var showImporter = false
    @State private var importError: String?
    /// Yedekleme: dışa aktarılacak dosya, geri yükleme seçici ve sonuç mesajı
    @State private var backupDoc: BackupDocument?
    @State private var showBackupExport = false
    @State private var showRestore = false
    @State private var backupMessage: (title: String, text: String)?
    @State private var showAbout = false
    @AppStorage("siralama") private var sort: SortOrder = .modified
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                NavigationStack {
                    detail
                }
            }

            // Belge kütüphanenin üstünde açılır. Sistem geçişleri (yakınlaştırma, tam ekran) iki parmak
            // hareketlerini "kapat" sayıp yazarken belgeyi kapatabiliyordu; burada çıkış yalnızca düğmeyle.
            if let doc = openDoc {
                DocumentView(id: doc.id, onClose: { openDoc = nil })
                    .id(doc.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)))
                    .zIndex(1)
            }
        }
        .animation(Y.springSoft, value: openDoc)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do {
                    let id = try library.importPDF(from: url)
                    if let f = currentFolder { library.move(id, toFolder: f) }
                    openDoc = OpenDoc(id: id)
                }
                catch { importError = error.localizedDescription }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        // Başka uygulamadan "OpenLeaf'te aç" / Paylaş > OpenLeaf ile gelen PDF
        .onOpenURL { url in openIncoming(url) }
        .alert("PDF içe aktarılamadı", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(folderPromptTitle, isPresented: Binding(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })) {
            TextField("Klasör adı", text: $folderName)
            Button(folderPromptAction) { commitFolderName() }
            Button("Vazgeç", role: .cancel) { folderPrompt = nil }
        }
        .confirmationDialog("“\(deletingFolder?.name ?? "")” klasörü silinsin mi?",
                            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                            titleVisibility: .visible) {
            Button("Klasörü sil", role: .destructive) {
                if let f = deletingFolder {
                    if currentFolder == f.id { selection = .section(.belgeler) }
                    library.deleteFolder(f.id)
                }
                deletingFolder = nil
            }
            Button("Vazgeç", role: .cancel) { deletingFolder = nil }
        } message: {
            Text("İçindeki defterler silinmez, Belgeler'de kalır.")
        }
        .sheet(isPresented: $showNew) {
            NewNotebookSheet { nb in
                var nb = nb
                nb.folder = currentFolder
                let id = library.create(nb)
                showNew = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openDoc = OpenDoc(id: id) }
            }
        }
    }

    private var folderPromptTitle: String {
        if case .rename = folderPrompt { return String(localized: "Klasörü yeniden adlandır") }
        return String(localized: "Yeni klasör")
    }
    private var folderPromptAction: String {
        switch folderPrompt {
        case .rename: String(localized: "Kaydet")
        case .createAndMove: String(localized: "Oluştur ve taşı")
        default: String(localized: "Oluştur")
        }
    }

    private func askFolderName(_ p: FolderPrompt) {
        if case .rename(let f) = p { folderName = f.name } else { folderName = "" }
        folderPrompt = p
    }

    private func commitFolderName() {
        guard let p = folderPrompt else { return }
        switch p {
        case .create:
            let id = library.createFolder(folderName)
            selection = .folder(id)
        case .rename(let f):
            library.renameFolder(f.id, folderName)
        case .createAndMove(let nb):
            let id = library.createFolder(folderName)
            library.move(nb, toFolder: id)
        }
        folderPrompt = nil
    }

    // MARK: Kenar çubuğu

    private var sidebar: some View {
        List(selection: $selection) {
            HStack(spacing: 10) {
                LogoMark(size: 30)
                Text("OpenLeaf").font(.system(size: 24, weight: .semibold, design: .serif))
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .selectionDisabled()

            Section {
                ForEach(SidebarSection.allCases) { s in
                    NavigationLink(value: SidebarItem.section(s)) {
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

            Section("Klasörler") {
                ForEach(library.folders) { f in
                    NavigationLink(value: SidebarItem.folder(f.id)) {
                        HStack {
                            Label(f.name, systemImage: "folder")
                            Spacer()
                            let n = library.items(inFolder: f.id).count
                            if n > 0 {
                                Text("\(n)").font(.subheadline).foregroundStyle(Y.ink3).monospacedDigit()
                            }
                        }
                    }
                    .contextMenu {
                        Button("Yeniden adlandır", systemImage: "pencil") { askFolderName(.rename(f)) }
                        Button("Klasörü sil", systemImage: "trash", role: .destructive) { deletingFolder = f }
                    }
                }
                Button { askFolderName(.create) } label: {
                    Label("Yeni klasör", systemImage: "folder.badge.plus").foregroundStyle(Y.accent)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
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
                    Text("Bu iPad'de kayıtlı").font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(library.items(for: .belgeler).count) belge").font(.caption).foregroundStyle(Y.ink3)
                }
                Spacer()
                Menu {
                    Button { exportBackup() } label: {
                        Label("Yedeği Dosyalar'a kaydet", systemImage: "square.and.arrow.down")
                    }
                    Button { showRestore = true } label: {
                        Label("Yedekten geri yükle", systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                    Button { showAbout = true } label: {
                        Label("OpenLeaf hakkında", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 17))
                        .foregroundStyle(Y.accent)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Yedekleme")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .fileExporter(isPresented: $showBackupExport, document: backupDoc, contentType: .data,
                          defaultFilename: BackupDocument.defaultName()) { result in
                if case .success = result {
                    backupMessage = (String(localized: "Yedek kaydedildi"), String(localized: "Tüm defterlerin tek dosyada. Uygulamayı silsen bile bu dosyadan geri yükleyebilirsin."))
                }
                backupDoc = nil
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.data, .item]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let r = try library.restoreBackup(from: url)
                    backupMessage = (String(localized: "Geri yükleme tamam"),
                                     r.added == 0 ? String(localized: "Yedekteki defterlerin hepsi zaten bu iPad'de var.")
                                     : String(localized: "\(r.added) defter geri yüklendi.") + (r.skipped > 0 ? " " + String(localized: "\(r.skipped) defter zaten vardı, dokunulmadı.") : ""))
                } catch {
                    backupMessage = (String(localized: "Geri yüklenemedi"), error.localizedDescription)
                }
            }
            .alert("OpenLeaf \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", isPresented: $showAbout) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text("Öğrenciler için ücretsiz ve açık kaynak not uygulaması.\n\nCopyright © 2026 biggypanda\nGNU GPL sürüm 3 ile lisanslanmıştır. Bu program HİÇBİR GARANTİ olmaksızın dağıtılır. Kaynak kodu ve lisansın tam metni projenin deposundadır.")
            }
            .alert(backupMessage?.title ?? "", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(backupMessage?.text ?? "")
            }
        }
    }

    private func exportBackup() {
        do {
            backupDoc = BackupDocument(data: try library.makeBackup())
            showBackupExport = true
        } catch {
            backupMessage = (String(localized: "Yedek oluşturulamadı"), error.localizedDescription)
        }
    }

    // MARK: Ana alan

    @ViewBuilder
    private var detail: some View {
        let folder = currentFolder.flatMap { id in library.folders.first { $0.id == id } }
        let s: SidebarSection = if case .section(let sec) = selection { sec } else { .belgeler }
        let base = folder.map { library.items(inFolder: $0.id, sort: sort) } ?? library.items(for: s, sort: sort)
        let items = base.filter { library.matches($0, search) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if folder == nil && s == .belgeler && search.isEmpty && !items.isEmpty {
                    Text(sort == .modified ? String(localized: "SON DÜZENLENENLER") : String(localized: "ADA GÖRE")).font(Y.eyebrow).tracking(0.8).foregroundStyle(Y.ink3)
                        .padding(.top, 4)
                }
                if items.isEmpty {
                    if folder != nil {
                        ContentUnavailableView(search.isEmpty ? String(localized: "Klasör boş") : String(localized: "Sonuç yok"), systemImage: "folder",
                                               description: Text(search.isEmpty ? String(localized: "Bir belgeye basılı tutup “Klasöre taşı”yı seçin ya da Yeni ile burada oluşturun.") : String(localized: "“\(search)” için eşleşme bulunamadı.")))
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else {
                        empty(s)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28, alignment: .top)],
                              alignment: .leading, spacing: 30) {
                        ForEach(items) { nb in
                            DocCard(nb: nb)
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
        .navigationTitle(folder?.name ?? s.title)
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
                    Button("Klasör", systemImage: "folder.badge.plus") { askFolderName(.create) }
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
        case .favoriler: ("star", String(localized: "Favori yok"), String(localized: "Bir belgeye basılı tutup Favorilere ekleyin."))
        case .paylasilanlar: ("person.2", String(localized: "Paylaşılan belge yok"), String(localized: "Sizinle paylaşılan belgeler burada görünür."))
        case .magaza: ("square.grid.2x2", String(localized: "Galeri yakında"), String(localized: "Ücretsiz şablon, kapak ve çıkartma paketleri burada olacak."))
        case .cop: ("trash", String(localized: "Çöp boş"), String(localized: "Silinen belgeler 30 gün burada kalır."))
        case .belgeler: ("doc.on.doc", search.isEmpty ? String(localized: "Henüz belge yok") : String(localized: "Sonuç yok"),
                         search.isEmpty ? String(localized: "Yeni düğmesiyle ilk defterinizi oluşturun.") : String(localized: "“\(search)” için eşleşme bulunamadı."))
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
            Button(nb.favorite ? String(localized: "Favorilerden çıkar") : String(localized: "Favorilere ekle"), systemImage: nb.favorite ? "star.slash" : "star") {
                library.update(nb.id) { $0.favorite.toggle() }
            }
            Button("Çoğalt", systemImage: "plus.square.on.square") { library.duplicate(nb) }
            Menu("Klasöre taşı", systemImage: "folder") {
                ForEach(library.folders) { f in
                    Button(f.name, systemImage: nb.folder == f.id ? "checkmark" : "folder") {
                        withAnimation(Y.spring) { library.move(nb.id, toFolder: f.id) }
                    }
                }
                if nb.folder != nil {
                    Button("Klasörden çıkar", systemImage: "folder.badge.minus") {
                        withAnimation(Y.spring) { library.move(nb.id, toFolder: nil) }
                    }
                }
                Divider()
                Button("Yeni klasör…", systemImage: "folder.badge.plus") { askFolderName(.createAndMove(nb.id)) }
            }
            ShareLink(item: NotebookPDF(notebook: nb, library: library),
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
            selection = .section(.belgeler)
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
            ? Notebook(title: String(localized: "Adsız Whiteboard"), kind: .whiteboard, cover: .kagit, paper: .bos)
            : Notebook(title: String(localized: "Hızlı not"), subtitle: Date().formatted(.dateTime.day().month(.wide)),
                       cover: .tas, paper: .cizgili)
        var placed = nb
        placed.folder = currentFolder
        openDoc = OpenDoc(id: library.create(placed))
    }
}

struct DocCard: View {
    var nb: Notebook
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if nb.kind == .whiteboard || nb.kind == .pdf { NotebookThumb(nb: nb) }
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
        nb.kind == .whiteboard ? String(localized: "Whiteboard") + " · \(nb.modified.relativeText)"
            : nb.kind == .pdf ? "PDF · " + String(localized: "\(nb.pages.count) sayfa") + " · \(nb.modified.relativeText)"
            : String(localized: "\(nb.pages.count) sayfa") + " · \(nb.modified.relativeText)"
    }
}
