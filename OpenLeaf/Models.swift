import SwiftUI
import Observation

enum CoverStyle: String, Codable, CaseIterable, Identifiable {
    case ketenYesil, keten, ketenLacivert, deri, kraft, tas, kagit, bordo
    // Yılbaşı kapakları
    case ekose, karTanesi, camOrmani, kraftYildiz, altinPuantiye, sekerKamisi
    var id: String { rawValue }

    static let festive: [CoverStyle] = [.ekose, .karTanesi, .camOrmani, .kraftYildiz, .altinPuantiye, .sekerKamisi]
    static var classic: [CoverStyle] { allCases.filter { !festive.contains($0) } }
    var isFestive: Bool { Self.festive.contains(self) }

    var name: String {
        switch self {
        case .ketenYesil: String(localized: "Keten yeşil")
        case .keten: String(localized: "Keten")
        case .ketenLacivert: String(localized: "Keten lacivert")
        case .deri: String(localized: "Deri")
        case .kraft: String(localized: "Kraft")
        case .tas: String(localized: "Taş")
        case .kagit: String(localized: "Kâğıt")
        case .bordo: String(localized: "Bordo")
        case .ekose: String(localized: "Ekose")
        case .karTanesi: String(localized: "Kar tanesi")
        case .camOrmani: String(localized: "Çam ormanı")
        case .kraftYildiz: String(localized: "Kraft yıldız")
        case .altinPuantiye: String(localized: "Altın puantiye")
        case .sekerKamisi: String(localized: "Şeker kamışı")
        }
    }

    /// Üst ve alt gradyan renkleri
    var colors: (UInt32, UInt32) {
        switch self {
        case .ketenYesil: (0x2F5A4E, 0x203F37)
        case .keten: (0xD9CFBA, 0xC7BBA2)
        case .ketenLacivert: (0x34466B, 0x243250)
        case .deri: (0x6B4630, 0x4A2F20)
        case .kraft: (0xC49A6C, 0xAD8357)
        case .tas: (0x8F918A, 0x75776F)
        case .kagit: (0xF7F3EA, 0xEAE4D6)
        case .bordo: (0x7A2E3A, 0x5A1F2A)
        case .ekose: (0xA3262E, 0x8A1F27)
        case .karTanesi: (0x26385F, 0x1C2A4A)
        case .camOrmani: (0x1F4535, 0x16342A)
        case .kraftYildiz: (0xC49A6C, 0xAD8357)
        case .altinPuantiye: (0x8E2430, 0x761C27)
        case .sekerKamisi: (0xF7F3EA, 0xEDE6D6)
        }
    }

    var isLight: Bool { [.keten, .kraft, .kagit, .kraftYildiz, .sekerKamisi].contains(self) }
    var linen: Bool { [.ketenYesil, .keten, .ketenLacivert].contains(self) }
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case cizgili, kareli, noktali, bos
    case cornell, milimetrik, nota, haftalik, dersProgrami, konuTakip, denemeAnalizi
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cizgili: String(localized: "Çizgili")
        case .kareli: String(localized: "Kareli")
        case .noktali: String(localized: "Noktalı")
        case .bos: String(localized: "Boş")
        case .cornell: String(localized: "Cornell")
        case .milimetrik: String(localized: "Milimetrik")
        case .nota: String(localized: "Nota")
        case .haftalik: String(localized: "Haftalık plan")
        case .dersProgrami: String(localized: "Ders programı")
        case .konuTakip: String(localized: "Konu takip")
        case .denemeAnalizi: String(localized: "Deneme analizi")
        }
    }

    /// Sayfanın tamamına yerleşen düzen (tablo, bölmeler); küçük önizlemesi sayfanın gerçek minyatürü olarak çizilir.
    /// Diğerleri tekrarlayan desendir, önizlemede yakından gösterilir.
    var isLayout: Bool {
        switch self {
        case .cornell, .haftalik, .dersProgrami, .konuTakip, .denemeAnalizi: true
        default: false
        }
    }
}

enum DocKind: String, Codable { case defter, whiteboard, pdf }

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a4, a5, mektup
    var id: String { rawValue }
    var name: String {
        switch self {
        case .a4: String(localized: "A4")
        case .a5: String(localized: "A5")
        case .mektup: String(localized: "Mektup")
        }
    }
    /// Kanonik sayfa boyutu (genişlik 768 pt). A5 daha dar sayfa: aynı oran, satırlar daha iri görünür.
    var canonical: CGSize {
        switch self {
        case .a4: CGSize(width: 768, height: 1086)
        case .a5: CGSize(width: 768 * 0.82, height: 1086 * 0.82)
        case .mektup: CGSize(width: 768, height: 994)
        }
    }
}

/// Her sayfanın kalıcı kimliği var; mürekkebi defter klasöründe `<id>.drawing` dosyasında durur.
struct Page: Identifiable, Codable, Equatable {
    var id = UUID()
    /// İçe aktarılmış PDF'teki sayfa numarası (0'dan); boş sayfada nil
    var pdfPage: Int?
    /// Sayfadaki yapışkan notlar (eski kayıtlarda alan yok)
    var notes: [StickyNote]?
    /// Sayfaya eklenmiş resimler (eski kayıtlarda alan yok)
    var images: [PageImage]?
    /// Sayfadaki bantlar (eski kayıtlarda alan yok)
    var tapes: [Tape]?
    /// Yer imi konmuş sayfa (eski kayıtlarda alan yok)
    var bookmarked: Bool?

    var isBookmarked: Bool { bookmarked == true }
    var stickyNotes: [StickyNote] { notes ?? [] }
    var pageImages: [PageImage] { images ?? [] }
    var pageTapes: [Tape] { tapes ?? [] }

    init(id: UUID = UUID(), pdfPage: Int? = nil, notes: [StickyNote]? = nil, images: [PageImage]? = nil, tapes: [Tape]? = nil) {
        self.id = id
        self.pdfPage = pdfPage
        self.notes = notes
        self.images = images
        self.tapes = tapes
    }

    enum CodingKeys: String, CodingKey { case id, pdfPage, notes, images, tapes, bookmarked }

    /// Bilinmeyen bir not, resim ya da bant (ör. daha yeni sürümün kaydı) yalnızca o öğeyi atlatır; sayfa kaybolmaz.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pdfPage = try? c.decodeIfPresent(Int.self, forKey: .pdfPage)
        notes = (try? c.decodeIfPresent(LossyList<StickyNote>.self, forKey: .notes))?.items
        images = (try? c.decodeIfPresent(LossyList<PageImage>.self, forKey: .images))?.items
        tapes = (try? c.decodeIfPresent(LossyList<Tape>.self, forKey: .tapes))?.items
        bookmarked = try? c.decodeIfPresent(Bool.self, forKey: .bookmarked)
    }
}

/// Öğeleri tek tek çözer; çözülemeyeni atlar ve sayar. Tek bozuk/bilinmeyen kayıt bütün listeyi düşürmesin diye.
struct LossyList<Element: Decodable>: Decodable {
    var items: [Element] = []
    var skipped = 0

    /// Her şeyi kabul eden boş tür: başarısız öğeyi atlayıp konteyneri ilerletir
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let item = try? c.decode(Element.self) {
                items.append(item)
            } else {
                // Konteyner ilerlesin diye öğeyi boş bir türle tüket
                _ = try? c.decode(Skip.self)
                skipped += 1
            }
        }
    }
}

struct Notebook: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String = ""
    var kind: DocKind = .defter
    var cover: CoverStyle
    var paper: PaperStyle
    var size: PaperSize = .mektup
    var pages: [Page] = [Page()]
    var favorite = false
    var trashed = false
    var created = Date()
    var modified = Date()
    /// PDF belgelerinde: uygulama klasöründeki PDF dosyasının adı ve ilk sayfanın yükseklik/genişlik oranı
    var pdfFile: String?
    var pdfAspect: Double?
    /// Bulunduğu klasör (yoksa klasörsüz)
    var folder: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, kind, cover, paper, size, pages, favorite, trashed, created, modified, pdfFile, pdfAspect, folder
    }

    /// Kanonik sayfa boyutu (genişlik 768 pt)
    var canonicalSize: CGSize {
        switch kind {
        case .whiteboard: return CGSize(width: 2400, height: 1800)
        case .pdf: return CGSize(width: 768, height: 768 * (pdfAspect ?? 1.294))
        case .defter: return size.canonical
        }
    }

    var isPaged: Bool { kind != .whiteboard }
}

extension Notebook {
    /// Eski kayıt biçimini de okur (sayfalar düz Data dizisiyken, kâğıt boyutu yokken).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        // Bilinmeyen kapak, kâğıt ya da boyut (daha yeni sürümden) defteri düşürmesin; varsayılana dönsün
        kind = (try? c.decodeIfPresent(DocKind.self, forKey: .kind)) ?? .defter
        cover = (try? c.decode(CoverStyle.self, forKey: .cover)) ?? .ketenYesil
        paper = (try? c.decode(PaperStyle.self, forKey: .paper)) ?? .cizgili
        size = (try? c.decodeIfPresent(PaperSize.self, forKey: .size)) ?? .mektup
        if let p = try? c.decode(LossyList<Page>.self, forKey: .pages), !(p.items.isEmpty && p.skipped > 0) {
            pages = p.items
        } else {
            // Çok eski biçim: sayfalar düz veri dizisiydi (çizimler taşıma sırasında ayrıca okunur)
            pages = try c.decode([Data].self, forKey: .pages).map { _ in Page() }
        }
        if pages.isEmpty { pages = [Page()] }
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        pdfFile = try c.decodeIfPresent(String.self, forKey: .pdfFile)
        pdfAspect = try c.decodeIfPresent(Double.self, forKey: .pdfAspect)
        folder = try c.decodeIfPresent(UUID.self, forKey: .folder)
    }

}

enum SortOrder: String, Hashable { case modified, title }

/// Kullanıcının oluşturduğu klasör (defterler ders/dönem bazında gruplansın)
struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
}

/// Kenar çubuğunda seçili öğe: sabit bölüm ya da klasör
enum SidebarItem: Hashable {
    case section(SidebarSection)
    case folder(UUID)
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case belgeler, favoriler, paylasilanlar, magaza, cop
    /// Kenar çubuğunda gösterilenler (paylaşım ve galeri henüz yok)
    static let visible: [SidebarSection] = [.belgeler, .favoriler, .cop]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .belgeler: String(localized: "Belgeler")
        case .favoriler: String(localized: "Favoriler")
        case .paylasilanlar: String(localized: "Paylaşılanlar")
        case .magaza: String(localized: "Galeri")
        case .cop: String(localized: "Çöp")
        }
    }
    var icon: String {
        switch self {
        case .belgeler: "doc.on.doc"
        case .favoriler: "star"
        case .paylasilanlar: "person.2"
        case .magaza: "square.grid.2x2"
        case .cop: "trash"
        }
    }
}

@MainActor
@Observable
final class Library {
    var notebooks: [Notebook] = []
    var folders: [Folder] = []
    /// Küçük resim yenilenince artar; görünümler bunu izleyip resmi yeniden yükler
    var thumbVersion: [UUID: Int] = [:]

    @ObservationIgnored let store: NotebookStore
    @ObservationIgnored private var drawingCache = DrawingCache()
    @ObservationIgnored var textCache: [UUID: String] = [:]
    @ObservationIgnored private var thumbWork: [UUID: DispatchWorkItem] = [:]
    /// Kütüphanede kalıcı bir değişiklik olunca çağrılır (otomatik yedek bunu dinler)
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: NotebookStore = NotebookStore()) {
        self.store = store
        folders = store.loadFolders()
        if let list = store.loadIndex() {
            notebooks = list
        } else if let migrated = LegacyMigration.migrate(into: store) {
            notebooks = migrated
            save()
            notebooks.forEach { scheduleThumbnail($0.id, delay: 0.5) }
        } else {
            notebooks = []
            save()
        }
    }

    // MARK: Liste

    func items(for section: SidebarSection, sort: SortOrder = .modified) -> [Notebook] {
        let list: [Notebook]
        switch section {
        case .belgeler: list = notebooks.filter { !$0.trashed }
        case .favoriler: list = notebooks.filter { $0.favorite && !$0.trashed }
        case .cop: list = notebooks.filter { $0.trashed }
        case .paylasilanlar, .magaza: list = []
        }
        switch sort {
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .title: return list.sorted { $0.title.compare($1.title, locale: .autoupdatingCurrent) == .orderedAscending }
        }
    }

    func count(_ section: SidebarSection) -> Int? {
        switch section {
        case .belgeler, .favoriler, .cop: items(for: section).count
        default: nil
        }
    }

    func index(of id: UUID) -> Int? { notebooks.firstIndex { $0.id == id } }

    /// Başlık, alt başlık ve (PDF'lerde) belge metninde arar.
    func matches(_ nb: Notebook, _ query: String) -> Bool {
        if query.isEmpty { return true }
        if nb.title.localizedStandardContains(query) || nb.subtitle.localizedStandardContains(query) { return true }
        return nb.kind == .pdf && searchText(nb.id).localizedStandardContains(query)
    }

    func searchText(_ id: UUID) -> String {
        if let t = textCache[id] { return t }
        var t = store.readText(id)
        // Eski sürümden taşınan PDF'lerde metin dosyası yok: bir kez çıkarıp sakla
        if t.isEmpty, let nb = notebooks.first(where: { $0.id == id }), let url = pdfURL(nb) {
            t = PDFRender.text(of: url)
            if !t.isEmpty, let data = t.data(using: .utf8) { store.writeFile(data, to: store.textURL(id)) }
        }
        textCache[id] = t
        return t
    }

    // MARK: Klasörler

    func items(inFolder id: UUID, sort: SortOrder = .modified) -> [Notebook] {
        let list = notebooks.filter { $0.folder == id && !$0.trashed }
        switch sort {
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .title: return list.sorted { $0.title.compare($1.title, locale: .autoupdatingCurrent) == .orderedAscending }
        }
    }

    @discardableResult
    func createFolder(_ name: String) -> UUID {
        let f = Folder(name: Self.cleanName(name))
        folders.append(f)
        saveFolders()
        return f.id
    }

    /// Defterin adını değiştirir; boş ad girilirse eski ad kalır
    func renameNotebook(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { nb in
            guard nb.title != clean else { return }
            nb.title = clean
            nb.modified = Date()
        }
    }

    func renameFolder(_ id: UUID, _ name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = Self.cleanName(name)
        saveFolders()
    }

    /// Klasörü siler; içindeki defterler silinmez, klasörsüz kalır
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in notebooks.indices where notebooks[i].folder == id { notebooks[i].folder = nil }
        save()
        saveFolders()
    }

    func move(_ notebook: UUID, toFolder folder: UUID?) {
        update(notebook) { $0.folder = folder }
    }

    func saveFolders() {
        store.writeFolders(folders)
        onChange?()
    }

    private static func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Yeni klasör") : t
    }

    // MARK: Defter işlemleri

    @discardableResult
    func create(_ nb: Notebook) -> UUID {
        store.createDir(nb.id)
        notebooks.append(nb)
        save()
        return nb.id
    }

    func update(_ id: UUID, _ change: (inout Notebook) -> Void) {
        guard let i = index(of: id) else { return }
        change(&notebooks[i])
        save()
    }

    func deleteForever(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        drawingCache.removeAll(prefix: id.uuidString)
        textCache[id] = nil
        store.deleteDir(id)
        // Yedekten de silinsin: yedek yalnızca bu listedeki defterleri siler
        DeletedNotebooks.add(id)
        save()
    }

    /// Defteri tüm sayfaları, PDF'i ve metniyle çoğaltır.
    func duplicate(_ nb: Notebook) {
        var copy = nb
        copy.id = UUID()
        copy.title += String(localized: " (kopya)")
        copy.favorite = false
        copy.created = Date()
        copy.modified = Date()
        store.copyDir(nb.id, to: copy.id)
        notebooks.append(copy)
        save()
        bumpThumb(copy.id)
    }

    // MARK: Sayfalar

    private func key(_ id: UUID, _ page: UUID) -> String { id.uuidString + "/" + page.uuidString }

    func drawing(_ id: UUID, _ page: UUID) -> Data {
        let k = key(id, page)
        if let d = drawingCache.get(k) { return d }
        let d = store.readDrawing(id, page)
        drawingCache.fill(k, d)
        return d
    }

    /// Sayfanın mürekkebi bu oturumda her değiştiğinde artar; küçük resimler bunu anahtar yapar
    /// (mürekkep verisinin tamamını her seferinde özetlemek büyük sayfalarda pahalıydı).
    func drawingVersion(_ id: UUID, _ page: UUID) -> Int { drawingCache.version(key(id, page)) }

    /// Yalnızca o sayfanın dosyasını yazar; kütüphane dizini sadece tarih için güncellenir.
    func saveDrawing(_ id: UUID, _ page: UUID, _ data: Data) {
        // Silinmiş bir sayfanın gecikmeli kaydı dosyayı geri yaratmasın
        guard let nb = notebooks.first(where: { $0.id == id }), nb.pages.contains(where: { $0.id == page }) else { return }
        drawingCache.set(key(id, page), data)
        store.writeDrawing(id, page, data)
        update(id) { $0.modified = Date() }
        scheduleThumbnail(id)
    }

    func setNotes(_ id: UUID, _ page: UUID, _ notes: [StickyNote]) {
        update(id) { nb in
            if let i = nb.pages.firstIndex(where: { $0.id == page }) { nb.pages[i].notes = notes.isEmpty ? nil : notes }
            nb.modified = Date()
        }
        scheduleThumbnail(id)
    }

    /// Sayfanın yer imini açar/kapatır (içerik değişmediği için düzenlenme tarihi değişmez)
    func toggleBookmark(_ id: UUID, _ page: UUID) {
        update(id) { nb in
            if let i = nb.pages.firstIndex(where: { $0.id == page }) {
                nb.pages[i].bookmarked = nb.pages[i].isBookmarked ? nil : true
            }
        }
    }

    func insertPage(_ id: UUID, at index: Int) {
        update(id) { nb in
            nb.pages.insert(Page(), at: min(max(index, 0), nb.pages.count))
            nb.modified = Date()
        }
    }

    /// Sayfayı yeni sırasına taşır (`to`, taşınan sayfanın yeni indeksi)
    func movePage(_ id: UUID, from: Int, to: Int) {
        update(id) { nb in
            guard nb.pages.indices.contains(from) else { return }
            let p = nb.pages.remove(at: from)
            nb.pages.insert(p, at: min(max(to, 0), nb.pages.count))
            nb.modified = Date()
        }
        scheduleThumbnail(id)
    }

    /// Sayfanın kopyasını hemen arkasına ekler (mürekkep, notlar, bantlar, resimler ve PDF sayfası dahil)
    @discardableResult
    func duplicatePage(_ id: UUID, at index: Int) -> Int? {
        guard let nb = notebooks.first(where: { $0.id == id }), nb.pages.indices.contains(index) else { return nil }
        let src = nb.pages[index]
        var copy = Page()
        copy.pdfPage = src.pdfPage
        copy.notes = src.notes?.map { n in var c = n; c.id = UUID(); return c }
        copy.tapes = src.tapes?.map { t in var c = t; c.id = UUID(); return c }
        // Resim dosyası iki sayfa arasında paylaşılır; temizlik hiçbir sayfanın kullanmadığı dosyayı siler
        copy.images = src.images?.map { m in var c = m; c.id = UUID(); return c }
        let data = drawing(id, src.id)
        if !data.isEmpty {
            drawingCache.set(key(id, copy.id), data)
            store.writeDrawing(id, copy.id, data)
        }
        update(id) { nb in
            nb.pages.insert(copy, at: index + 1)
            nb.modified = Date()
        }
        return index + 1
    }

    func deletePage(_ id: UUID, _ page: UUID) {
        update(id) { nb in
            nb.pages.removeAll { $0.id == page }
            if nb.pages.isEmpty { nb.pages = [Page()] }
            nb.modified = Date()
        }
        drawingCache.set(key(id, page), nil)
        store.deleteDrawing(id, page)
        cleanupImages(id)
        scheduleThumbnail(id)
    }

    // MARK: Küçük resim

    func thumbnailURL(_ id: UUID) -> URL { store.thumbURL(id) }

    private func bumpThumb(_ id: UUID) { thumbVersion[id, default: 0] += 1 }

    /// Son değişiklikten kısa süre sonra ilk sayfanın mürekkepli küçük resmini üretir.
    func scheduleThumbnail(_ id: UUID, delay: TimeInterval = 1.2) {
        thumbWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.renderThumbnail(id) } }
        thumbWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Kapak resmini arka planda çizer; yazarken ana iş parçacığı takılmasın
    private func renderThumbnail(_ id: UUID) {
        guard let nb = notebooks.first(where: { $0.id == id }), let first = nb.pages.first else { return }
        let data = drawing(id, first.id)
        let pdfURL = nb.pdfFile != nil ? store.pdfURL(id) : nil
        let store = self.store
        Self.thumbQueue.async { [weak self] in
            guard let png = PageRenderer.thumbnail(nb, page: first, drawing: data, pdfURL: pdfURL)?.pngData() else { return }
            store.writeFile(png, to: store.thumbURL(id))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.bumpThumb(id) } }
        }
    }

    /// Kapak resimleri sırayla çizilsin (aynı dosyaya iki çizim yarışmasın)
    private nonisolated static let thumbQueue = DispatchQueue(label: "openleaf.kapak", qos: .utility)

    // MARK: Kayıt

    func save() {
        store.writeIndex(notebooks)
        onChange?()
    }

    /// Uygulama arka plana geçerken bekleyen tüm yazmaları bitirir.
    func flush() {
        // Hemen çalıştır, sonra iptal et ki zamanlanmış kopyası ikinci kez çalışmasın
        thumbWork.values.forEach { $0.perform(); $0.cancel() }
        thumbWork.removeAll()
        // Kapak çizimi bitsin ki dosyası da aşağıdaki kayıtla birlikte diske yazılsın
        Self.thumbQueue.sync {}
        store.flush()
    }
}

extension Date {
    var relativeText: String {
        let f = RelativeDateTimeFormatter()
        f.locale = .autoupdatingCurrent
        f.unitsStyle = .full
        if Calendar.current.isDateInToday(self) { return String(localized: "Bugün") }
        if Calendar.current.isDateInYesterday(self) { return String(localized: "Dün") }
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// Sayfa mürekkeplerinin bellekteki kopyası. Toplam boyut sınırı aşılınca en uzun süredir kullanılmayan
/// sayfa çıkarılır; dosyası diskte durduğu için gerekince yeniden okunur. Büyük PDF defterlerinde gezindikçe
/// belleğin sınırsız büyüyüp uygulamanın kapanmasını önler.
struct DrawingCache {
    private var items: [String: Data] = [:]
    /// En uzun süredir kullanılmayan başta
    private var order: [String] = []
    private var bytes = 0
    private var versions: [String: Int] = [:]
    let limit: Int

    init(limit: Int = 48 * 1024 * 1024) { self.limit = limit }

    mutating func get(_ key: String) -> Data? {
        guard let d = items[key] else { return nil }
        touch(key)
        return d
    }

    /// Diskten okunan veriyi koyar (sayfa değişmediği için sürüm artmaz)
    mutating func fill(_ key: String, _ data: Data) { put(key, data) }

    /// Sayfanın yeni mürekkebi (nil: sayfa silindi); sürümü artırır
    mutating func set(_ key: String, _ data: Data?) {
        versions[key, default: 0] += 1
        if let data { put(key, data) } else { remove(key) }
    }

    func version(_ key: String) -> Int { versions[key] ?? 0 }

    mutating func removeAll(prefix: String) {
        for key in items.keys where key.hasPrefix(prefix) { remove(key) }
        for key in versions.keys where key.hasPrefix(prefix) { versions[key, default: 0] += 1 }
    }

    private mutating func put(_ key: String, _ data: Data) {
        remove(key)
        items[key] = data
        order.append(key)
        bytes += data.count
        // En son eklenen her zaman kalır (açık sayfa)
        while bytes > limit, order.count > 1 { remove(order[0]) }
    }

    private mutating func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    private mutating func remove(_ key: String) {
        guard let d = items.removeValue(forKey: key) else { return }
        bytes -= d.count
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
    }
}
