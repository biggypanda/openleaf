import Foundation

/// OpenLeaf'in yerel dosya deposu.
///
///     Belgeler/OpenLeaf/
///       index.json                 kütüphane dizini (defter bilgileri ve sayfa listeleri; çizim yok)
///       Defterler/<defter-id>/
///         <sayfa-id>.drawing       her sayfanın mürekkebi (PencilKit verisi, kanonik koordinatlarda)
///         source.pdf               içe aktarılan PDF (varsa)
///         text.txt                 PDF'ten çıkarılmış aranabilir metin (varsa)
///         thumb.png                kütüphane küçük resmi (mürekkepli ilk sayfa)
///
/// Tüm yazmalar tek sıralı kuyrukta ve atomik yapılır; okumalar aynı kuyruktan geçer,
/// böylece yarım yazılmış bir dosya hiç okunmaz.
///
/// Değişen durumu yoktur (kök klasör ve kuyruk sabit), bu yüzden iş parçacıkları arasında paylaşılabilir.
final class NotebookStore: @unchecked Sendable {
    let root: URL
    // Okumalar ana iş parçacığından eşzamanlı bekleniyor; düşük öncelik takılmaya yol açmasın
    private let queue = DispatchQueue(label: "openleaf.depo", qos: .userInitiated)
    private let fm = FileManager.default

    init(root: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultRoot = docs.appendingPathComponent("OpenLeaf", isDirectory: true)
        // Uygulamanın eski adı Yaprak'tı: eski klasör varsa yeni adına taşı
        let oldRoot = docs.appendingPathComponent("Yaprak", isDirectory: true)
        if root == nil, !fm.fileExists(atPath: defaultRoot.path), fm.fileExists(atPath: oldRoot.path) {
            try? fm.moveItem(at: oldRoot, to: defaultRoot)
        }
        self.root = root ?? defaultRoot
        try? fm.createDirectory(at: notebooksDir, withIntermediateDirectories: true)
    }

    // MARK: Yollar

    var indexURL: URL { root.appendingPathComponent("index.json") }
    var foldersURL: URL { root.appendingPathComponent("folders.json") }
    var notebooksDir: URL { root.appendingPathComponent("Defterler", isDirectory: true) }
    func dir(_ id: UUID) -> URL { notebooksDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    func drawingURL(_ id: UUID, _ page: UUID) -> URL { dir(id).appendingPathComponent(page.uuidString + ".drawing") }
    func pdfURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("source.pdf") }
    func textURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("text.txt") }
    func thumbURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("thumb.png") }

    // MARK: Dizin

    /// Dizin dosyası yoksa nil döner. Dosya var ama okunamıyorsa ya da bazı defterler çözülemiyorsa
    /// özgün dosya kenara kopyalanır (sonraki kayıt üstüne yazsa da kaybolmasın) ve okunabilenler döner.
    func loadIndex() -> [Notebook]? {
        queue.sync {
            guard let data = try? Data(contentsOf: indexURL) else { return nil }
            guard let list = try? JSONDecoder().decode(LossyList<Notebook>.self, from: data) else {
                keepAside(data)
                return []
            }
            if list.skipped > 0 { keepAside(data) }
            return list.items
        }
    }

    /// Okunamayan dizinin kopyası: index-kurtarma-<zaman>.json
    private func keepAside(_ data: Data) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = root.appendingPathComponent("index-kurtarma-\(f.string(from: Date())).json")
        attempt { try data.write(to: url, options: .atomic) }
    }

    func writeIndex(_ list: [Notebook]) {
        let url = indexURL
        queue.async {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            self.attempt { try enc.encode(list).write(to: url, options: .atomic) }
        }
    }

    // MARK: Yazma hatası

    /// Bir dosya yazılamadığında (ör. disk dolu) yayınlanır; arayüz kullanıcıyı uyarır.
    static let writeFailed = Notification.Name("openleaf.yazmaHatasi")

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch {
            NotificationCenter.default.post(name: Self.writeFailed, object: nil)
        }
    }

    // MARK: Klasörler (kullanıcının defter grupları)

    func loadFolders() -> [Folder] {
        queue.sync {
            guard let data = try? Data(contentsOf: foldersURL) else { return [] }
            return (try? JSONDecoder().decode(LossyList<Folder>.self, from: data))?.items ?? []
        }
    }

    func writeFolders(_ list: [Folder]) {
        let url = foldersURL
        queue.async {
            self.attempt { try JSONEncoder().encode(list).write(to: url, options: .atomic) }
        }
    }

    // MARK: Defter klasörü

    func createDir(_ id: UUID) {
        try? fm.createDirectory(at: dir(id), withIntermediateDirectories: true)
    }

    func deleteDir(_ id: UUID) {
        let url = dir(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Bekleyen yazmalar bittikten sonra klasörü kopyalar.
    func copyDir(_ from: UUID, to: UUID) {
        let src = dir(from), dst = dir(to)
        queue.sync {
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) == nil {
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: Sayfalar

    func readDrawing(_ id: UUID, _ page: UUID) -> Data {
        let url = drawingURL(id, page)
        return queue.sync { (try? Data(contentsOf: url)) ?? Data() }
    }

    func writeDrawing(_ id: UUID, _ page: UUID, _ data: Data) {
        let url = drawingURL(id, page)
        let folder = dir(id)
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if data.isEmpty { try? FileManager.default.removeItem(at: url) }
            else { self.attempt { try data.write(to: url, options: .atomic) } }
        }
    }

    func deleteDrawing(_ id: UUID, _ page: UUID) {
        let url = drawingURL(id, page)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Ek dosyalar

    func writeFile(_ data: Data, to url: URL) {
        queue.async {
            // Defter bu arada silindiyse (klasörü yok) yazma; bu bir kayıt hatası değil
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
            self.attempt { try data.write(to: url, options: .atomic) }
        }
    }

    func readText(_ id: UUID) -> String {
        let url = textURL(id)
        return queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    /// Bekleyen tüm yazmaların bitmesini bekler (uygulama arka plana giderken).
    func flush() { queue.sync {} }
}

// MARK: - Eski biçimden taşıma

/// İlk sürümde her şey Belgeler/yaprak-kutuphane.json içindeydi (sayfa çizimleri dahil),
/// PDF'ler Belgeler/PDF/ klasöründeydi. Bunları yeni yapıya taşır; eski dosyayı yedek olarak bırakır.
enum LegacyMigration {
    private struct LegacyNotebook: Decodable {
        var pages: [LegacyPage]
    }

    /// Sayfa ya düz base64 Data ya da {id, data, pdfPage} nesnesiydi.
    private struct LegacyPage: Decodable {
        var data: Data
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let d = try? single.decode(Data.self) {
                data = d
            } else {
                let c = try decoder.container(keyedBy: Key.self)
                data = try c.decodeIfPresent(Data.self, forKey: .data) ?? Data()
            }
        }
        enum Key: String, CodingKey { case data }
    }

    static var legacyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yaprak-kutuphane.json")
    }

    static func migrate(into store: NotebookStore) -> [Notebook]? {
        let fm = FileManager.default
        guard let raw = try? Data(contentsOf: legacyURL),
              var notebooks = try? JSONDecoder().decode([Notebook].self, from: raw),
              let legacy = try? JSONDecoder().decode([LegacyNotebook].self, from: raw),
              legacy.count == notebooks.count else { return nil }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for i in notebooks.indices {
            let id = notebooks[i].id
            store.createDir(id)
            // Sayfa verisini sıraya göre eşle (eski [Data] biçiminde kimlikler yeni üretildi)
            for (j, page) in notebooks[i].pages.enumerated() where j < legacy[i].pages.count {
                let data = legacy[i].pages[j].data
                if !data.isEmpty { try? data.write(to: store.drawingURL(id, page.id), options: .atomic) }
            }
            // PDF'i defter klasörüne taşı
            if let file = notebooks[i].pdfFile, file != "source.pdf" {
                let old = docs.appendingPathComponent("PDF").appendingPathComponent(file)
                if (try? fm.moveItem(at: old, to: store.pdfURL(id))) != nil || fm.fileExists(atPath: store.pdfURL(id).path) {
                    notebooks[i].pdfFile = "source.pdf"
                } else {
                    notebooks[i].pdfFile = nil
                }
            }
        }
        // Eski dosyayı silme, yedek olarak yeniden adlandır
        let backup = legacyURL.deletingPathExtension().appendingPathExtension("eski.json")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: legacyURL, to: backup)
        // Eski PDF klasörünü yalnızca tamamen boşaldıysa kaldır
        let oldPDFDir = docs.appendingPathComponent("PDF")
        if let left = try? fm.contentsOfDirectory(atPath: oldPDFDir.path), left.isEmpty {
            try? fm.removeItem(at: oldPDFDir)
        }
        return notebooks
    }
}
