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

/// Her sayfanın kalıcı kimliği var; kayıt, sayfa sırası değişse de doğru sayfaya yazılır.
struct Page: Identifiable, Codable, Equatable {
    var id = UUID()
    var data = Data()
    /// İçe aktarılmış PDF'teki sayfa numarası (0'dan); boş sayfada nil
    var pdfPage: Int?
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
            pages = try c.decode([Data].self, forKey: .pages).map { Page(data: $0) }
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

@Observable
final class Library {
    var notebooks: [Notebook] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("yaprak-kutuphane.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Notebook].self, from: data) {
            notebooks = list
        } else {
            notebooks = Library.seed
            save()
        }
    }

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

    @discardableResult
    func create(_ nb: Notebook) -> UUID {
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
        if let file = notebooks.first(where: { $0.id == id })?.pdfFile {
            try? FileManager.default.removeItem(at: Library.pdfURL(file))
        }
        notebooks.removeAll { $0.id == id }
        save()
    }

    /// Kayıtlar tek sıralı kuyrukta yazılır; eski bir kayıt yenisinin üstüne yazılamaz.
    private let saveQueue = DispatchQueue(label: "yaprak.kayit", qos: .utility)

    func save() {
        let list = notebooks
        let target = url
        saveQueue.async {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: target, options: .atomic) }
        }
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
