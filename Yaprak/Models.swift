import SwiftUI
import Observation

enum CoverStyle: String, Codable, CaseIterable, Identifiable {
    case ketenYesil, keten, ketenLacivert, deri, kraft, tas, kagit, bordo
    var id: String { rawValue }

    var name: String {
        switch self {
        case .ketenYesil: "Keten yeşil"
        case .keten: "Keten"
        case .ketenLacivert: "Keten lacivert"
        case .deri: "Deri"
        case .kraft: "Kraft"
        case .tas: "Taş"
        case .kagit: "Kâğıt"
        case .bordo: "Bordo"
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
        }
    }

    var isLight: Bool { [.keten, .kraft, .kagit].contains(self) }
    var linen: Bool { [.ketenYesil, .keten, .ketenLacivert].contains(self) }
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case cizgili, kareli, noktali, bos
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cizgili: "Çizgili"
        case .kareli: "Kareli"
        case .noktali: "Noktalı"
        case .bos: "Boş"
        }
    }
}

enum DocKind: String, Codable { case defter, whiteboard, pdf }

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a4, a5, mektup
    var id: String { rawValue }
    var name: String {
        switch self {
        case .a4: "A4"
        case .a5: "A5"
        case .mektup: "Mektup"
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

    var stickyNotes: [StickyNote] { notes ?? [] }
    var pageImages: [PageImage] { images ?? [] }
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

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, kind, cover, paper, size, pages, favorite, trashed, created, modified, pdfFile, pdfAspect
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
        kind = try c.decodeIfPresent(DocKind.self, forKey: .kind) ?? .defter
        cover = try c.decode(CoverStyle.self, forKey: .cover)
        paper = try c.decode(PaperStyle.self, forKey: .paper)
        size = try c.decodeIfPresent(PaperSize.self, forKey: .size) ?? .mektup
        if let p = try? c.decode([Page].self, forKey: .pages) {
            pages = p
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
    }

    static func pages(_ n: Int) -> [Page] { (0..<n).map { _ in Page() } }
}

enum SortOrder: String, Hashable { case modified, title }

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case belgeler, favoriler, paylasilanlar, magaza, cop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .belgeler: "Belgeler"
        case .favoriler: "Favoriler"
        case .paylasilanlar: "Paylaşılanlar"
        case .magaza: "Galeri"
        case .cop: "Çöp"
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
    /// Küçük resim yenilenince artar; görünümler bunu izleyip resmi yeniden yükler
    var thumbVersion: [UUID: Int] = [:]

    @ObservationIgnored let store: NotebookStore
    @ObservationIgnored private var drawingCache: [String: Data] = [:]
    @ObservationIgnored private var textCache: [UUID: String] = [:]
    @ObservationIgnored private var thumbWork: [UUID: DispatchWorkItem] = [:]

    init(store: NotebookStore = NotebookStore()) {
        self.store = store
        if let list = store.loadIndex() {
            notebooks = list
        } else if let migrated = LegacyMigration.migrate(into: store) {
            notebooks = migrated
            save()
            notebooks.forEach { scheduleThumbnail($0.id, delay: 0.5) }
        } else {
            notebooks = Library.seed
            notebooks.forEach { store.createDir($0.id) }
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
        case .title: return list.sorted { $0.title.compare($1.title, locale: Locale(identifier: "tr_TR")) == .orderedAscending }
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
        drawingCache = drawingCache.filter { !$0.key.hasPrefix(id.uuidString) }
        textCache[id] = nil
        store.deleteDir(id)
        save()
    }

    /// Defteri tüm sayfaları, PDF'i ve metniyle çoğaltır.
    func duplicate(_ nb: Notebook) {
        var copy = nb
        copy.id = UUID()
        copy.title += " (kopya)"
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
        if let d = drawingCache[k] { return d }
        let d = store.readDrawing(id, page)
        drawingCache[k] = d
        return d
    }

    /// Yalnızca o sayfanın dosyasını yazar; kütüphane dizini sadece tarih için güncellenir.
    func saveDrawing(_ id: UUID, _ page: UUID, _ data: Data) {
        // Silinmiş bir sayfanın gecikmeli kaydı dosyayı geri yaratmasın
        guard let nb = notebooks.first(where: { $0.id == id }), nb.pages.contains(where: { $0.id == page }) else { return }
        drawingCache[key(id, page)] = data
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

    /// Sayfanın kopyasını hemen arkasına ekler (mürekkep, notlar ve PDF sayfası dahil)
    @discardableResult
    func duplicatePage(_ id: UUID, at index: Int) -> Int? {
        guard let nb = notebooks.first(where: { $0.id == id }), nb.pages.indices.contains(index) else { return nil }
        let src = nb.pages[index]
        var copy = Page()
        copy.pdfPage = src.pdfPage
        copy.notes = src.notes?.map { n in var c = n; c.id = UUID(); return c }
        let data = drawing(id, src.id)
        if !data.isEmpty {
            drawingCache[key(id, copy.id)] = data
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
        drawingCache[key(id, page)] = nil
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

    private func renderThumbnail(_ id: UUID) {
        guard let nb = notebooks.first(where: { $0.id == id }), let first = nb.pages.first else { return }
        let image = PageRenderer.thumbnail(nb, page: first, drawing: drawing(id, first.id),
                                           pdfURL: nb.pdfFile != nil ? store.pdfURL(id) : nil)
        if let png = image?.pngData() {
            store.writeFile(png, to: store.thumbURL(id))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in MainActor.assumeIsolated { self?.bumpThumb(id) } }
        }
    }

    // MARK: Kayıt

    func save() { store.writeIndex(notebooks) }

    /// Uygulama arka plana geçerken bekleyen tüm yazmaları bitirir.
    func flush() {
        thumbWork.values.forEach { $0.perform() }
        thumbWork.removeAll()
        store.flush()
    }

    static var seed: [Notebook] {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        return [
            Notebook(title: "Organik Kimya", subtitle: "Alkenler", cover: .ketenYesil, paper: .cizgili,
                     pages: Notebook.pages(4), favorite: true, modified: ago(0.5)),
            Notebook(title: "Mimarlık Tarihi", subtitle: "Gotik dönem", cover: .deri, paper: .noktali,
                     pages: Notebook.pages(3), modified: ago(5)),
            Notebook(title: "Haftalık Plan", subtitle: "Kasım", cover: .kraft, paper: .kareli, modified: ago(26)),
            Notebook(title: "Fikir Panosu", kind: .whiteboard, cover: .kagit, paper: .bos, modified: ago(30)),
            Notebook(title: "Biyokimya", subtitle: "Enzimler", cover: .ketenLacivert, paper: .kareli,
                     pages: Notebook.pages(2), favorite: true, modified: ago(50)),
            Notebook(title: "Toplantı Notları", subtitle: "Ekip", cover: .tas, paper: .cizgili, modified: ago(75)),
            Notebook(title: "Sözleşme Hukuku", subtitle: "Vize", cover: .bordo, paper: .cizgili,
                     pages: Notebook.pages(2), modified: ago(120)),
            Notebook(title: "Okuma Notu", subtitle: "Romanlar", cover: .keten, paper: .noktali, modified: ago(200)),
        ]
    }
}

extension Date {
    var yaprakRelative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .full
        if Calendar.current.isDateInToday(self) { return "Bugün" }
        if Calendar.current.isDateInYesterday(self) { return "Dün" }
        return f.localizedString(for: self, relativeTo: Date())
    }
}
