import Foundation

// iPad'ler arası iCloud eşitlemesinin cihazdaki durumu: CKSyncEngine durumu,
// kayıt başına "taban" (son eşitlenen sürüm) ve CKRecord sistem alanları.
// Application Support altında tutulur (Dosyalar'da ve yedekte görünmesin).
// Tüm erişim tek seri kuyruktan geçer; her yazma dosyaya atomik yapılır.

/// Bir olayın tüm durum yazmaları tek seferde (her kayıt için ayrı dosya yazımı olmasın)
struct SyncStateBatch {
    var notebooks: [SyncNotebookMeta] = []
    var pages: [SyncPageMeta] = []
    var folders: [SyncFolderMeta] = []
    /// Her türden tabanı silinecek kimlikler (ekleme/güncellemeden sonra uygulanır)
    var removed: [UUID] = []
    /// Kayıt adı → sistem alanları; nil silinir
    var fields: [String: Data?] = [:]

    var isEmpty: Bool {
        notebooks.isEmpty && pages.isEmpty && folders.isEmpty && removed.isEmpty && fields.isEmpty
    }
}

final class SyncStateStore: @unchecked Sendable {
    private struct Meta: Codable {
        var enabled = false
        var accountID: String?
    }

    private let root: URL
    private let queue = DispatchQueue(label: "openleaf.sync.state")

    private var meta = Meta()
    private var notebooks: [UUID: SyncNotebookMeta] = [:]
    private var pages: [UUID: SyncPageMeta] = [:]
    private var folders: [UUID: SyncFolderMeta] = [:]
    private var fields: [String: Data] = [:]
    private var engine: Data?

    private enum Dosya {
        static let meta = "meta.json", notebooks = "notebooks.json", pages = "pages.json"
        static let folders = "folders.json", fields = "fields.json", engine = "engine.json"
    }

    /// Varsayılan konum: Application Support/OpenLeaf-Esitleme/
    static var varsayilanKok: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenLeaf-Esitleme", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bozuk ya da eksik dosya boş sayılır; çökme yok.
        meta = oku(Dosya.meta) ?? Meta()
        notebooks = oku(Dosya.notebooks) ?? [:]
        pages = oku(Dosya.pages) ?? [:]
        folders = oku(Dosya.folders) ?? [:]
        fields = oku(Dosya.fields) ?? [:]
        engine = oku(Dosya.engine)
    }

    // MARK: - Dosya yardımcıları (kuyruk içinden ya da init'ten çağrılır)

    private func oku<T: Decodable>(_ ad: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(ad)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func yaz<T: Encodable>(_ deger: T, _ ad: String) {
        guard let data = try? JSONEncoder().encode(deger) else { return }
        try? data.write(to: root.appendingPathComponent(ad), options: .atomic)
    }

    private func sil(_ ad: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(ad))
    }

    // MARK: - Genel durum

    /// `CKSyncEngine.State.Serialization`'ın JSON'u.
    var engineState: Data? {
        get { queue.sync { engine } }
        set {
            queue.sync {
                engine = newValue
                if let v = newValue { yaz(v, Dosya.engine) } else { sil(Dosya.engine) }
            }
        }
    }

    var enabled: Bool {
        get { queue.sync { meta.enabled } }
        set { queue.sync { meta.enabled = newValue; yaz(meta, Dosya.meta) } }
    }

    /// Hesap değişimini tanımak için kullanıcı kaydı kimliği.
    var accountID: String? {
        get { queue.sync { meta.accountID } }
        set { queue.sync { meta.accountID = newValue; yaz(meta, Dosya.meta) } }
    }

    // MARK: - Tabanlar

    func base(notebook id: UUID) -> SyncNotebookMeta? { queue.sync { notebooks[id] } }
    func base(page id: UUID) -> SyncPageMeta? { queue.sync { pages[id] } }
    func base(folder id: UUID) -> SyncFolderMeta? { queue.sync { folders[id] } }

    func setBase(_ m: SyncNotebookMeta) {
        queue.sync { notebooks[m.id] = m; yaz(notebooks, Dosya.notebooks) }
    }
    func setBase(_ m: SyncPageMeta) {
        queue.sync { pages[m.id] = m; yaz(pages, Dosya.pages) }
    }
    func setBase(_ m: SyncFolderMeta) {
        queue.sync { folders[m.id] = m; yaz(folders, Dosya.folders) }
    }

    /// Kimliği her türden tabandan siler.
    func removeBase(_ id: UUID) {
        queue.sync {
            if notebooks.removeValue(forKey: id) != nil { yaz(notebooks, Dosya.notebooks) }
            if pages.removeValue(forKey: id) != nil { yaz(pages, Dosya.pages) }
            if folders.removeValue(forKey: id) != nil { yaz(folders, Dosya.folders) }
        }
    }

    /// Tabanı bilinen sayfalardan bu deftere ait olanlar (silinen defterin sayfa kayıtlarını bulmak için)
    func pageIDs(inNotebook id: UUID) -> [UUID] {
        queue.sync { pages.values.filter { $0.notebook == id }.map(\.id) }
    }

    /// Tüm tabanlar bir görüntü olarak (dosya özetleri boş)
    func allBases() -> SyncSnapshot {
        queue.sync { SyncSnapshot(notebooks: notebooks, pages: pages, folders: folders, files: [:]) }
    }

    /// Toplu yazma: her tür dosyası en çok bir kez yazılır
    func apply(_ b: SyncStateBatch) {
        guard !b.isEmpty else { return }
        queue.sync {
            for m in b.notebooks { notebooks[m.id] = m }
            for m in b.pages { pages[m.id] = m }
            for m in b.folders { folders[m.id] = m }
            var nbDirty = !b.notebooks.isEmpty, pgDirty = !b.pages.isEmpty, flDirty = !b.folders.isEmpty
            for id in b.removed {
                if notebooks.removeValue(forKey: id) != nil { nbDirty = true }
                if pages.removeValue(forKey: id) != nil { pgDirty = true }
                if folders.removeValue(forKey: id) != nil { flDirty = true }
            }
            for (name, data) in b.fields { fields[name] = data }
            if nbDirty { yaz(notebooks, Dosya.notebooks) }
            if pgDirty { yaz(pages, Dosya.pages) }
            if flDirty { yaz(folders, Dosya.folders) }
            if !b.fields.isEmpty { yaz(fields, Dosya.fields) }
        }
    }

    // MARK: - CKRecord sistem alanları

    func systemFields(_ recordName: String) -> Data? { queue.sync { fields[recordName] } }

    /// Bulutta karşılığı bilinen kayıt adları
    func recordNames() -> Set<String> { queue.sync { Set(fields.keys) } }

    /// Bu cihaz bölgeye en az bir kez kayıt göndermiş ya da almış mı (bölge daha önce vardı mı)
    var hasSystemFields: Bool { queue.sync { !fields.isEmpty } }

    func setSystemFields(_ data: Data?, for recordName: String) {
        queue.sync {
            fields[recordName] = data
            yaz(fields, Dosya.fields)
        }
    }

    // MARK: - Sıfırlama

    /// Her şeyi siler; `enabled` kalır.
    func reset() {
        queue.sync {
            engine = nil; notebooks = [:]; pages = [:]; folders = [:]; fields = [:]
            meta.accountID = nil
            for ad in [Dosya.engine, Dosya.notebooks, Dosya.pages, Dosya.folders, Dosya.fields] { sil(ad) }
            yaz(meta, Dosya.meta)
        }
    }

    /// Yazmalar zaten eşzamanlı; kuyruğun boşaldığından emin olmak için (testler).
    func flush() { queue.sync {} }
}
