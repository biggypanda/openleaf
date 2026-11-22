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
    /// Kimliğiyle yeniden istenecek kayıt adları: bekletilip bırakılan ya da okunamayan kayıtlar (I1),
    /// kurtarılan sayfaların resim ve PDF dosyaları (I6)
    private var refetch: Set<String> = []
    /// İçeriği henüz gelmemiş yer tutucu sayfalar (defter sırasında görüldü, sayfa kaydı gelmedi). Boş hâlleri
    /// gönderilmez ve silmeleri buluta gitmez: gerçek içeriği ezmesin (I1)
    private var placeholders: Set<UUID> = []
    /// Yerelde silinmiş defterden kurtarılan sayfaların toplandığı defter (eski → yeni); dosyaları sonra gelebilir (I6)
    private var redirects: [UUID: UUID] = [:]
    /// Bir durum dosyası yazılamadı ya da uygulanan değişiklik diske yazılamadı: bu oturumda motor durumu
    /// (değişiklik belirteci) artık diske yazılmaz. Uygulama yeniden açılınca kayıtlar eski belirteçten yeniden alınır;
    /// tabanı yazılamamış bir değişiklik böylece "alındı" sayılıp atlanmaz.
    private var frozen = false

    private enum Dosya {
        static let meta = "meta.json", notebooks = "notebooks.json", pages = "pages.json"
        static let folders = "folders.json", fields = "fields.json", engine = "engine.json"
        static let refetch = "refetch.json", placeholders = "placeholders.json", redirects = "redirects.json"
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
        refetch = oku(Dosya.refetch) ?? []
        placeholders = oku(Dosya.placeholders) ?? []
        redirects = oku(Dosya.redirects) ?? [:]
    }

    // MARK: - Dosya yardımcıları (kuyruk içinden ya da init'ten çağrılır)

    private func oku<T: Decodable>(_ ad: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(ad)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Başarısız yazma motor durumunu dondurur (bkz. `frozen`)
    private func yaz<T: Encodable>(_ deger: T, _ ad: String) {
        do {
            let data = try JSONEncoder().encode(deger)
            try data.write(to: root.appendingPathComponent(ad), options: .atomic)
        } catch {
            frozen = true
        }
    }

    private func sil(_ ad: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(ad))
    }

    // MARK: - Genel durum

    /// `CKSyncEngine.State.Serialization`'ın JSON'u.
    /// Donmuşken (bkz. `frozen`) yalnızca bellekte güncellenir, diske yazılmaz.
    var engineState: Data? {
        get { queue.sync { engine } }
        set {
            queue.sync {
                engine = newValue
                guard !frozen else { return }
                if let v = newValue { yaz(v, Dosya.engine) } else { sil(Dosya.engine) }
            }
        }
    }

    /// Uygulanan bir değişiklik diske yazılamadı: bu oturumda motor durumu artık diske yazılmaz
    func freezeEngineState() { queue.sync { frozen = true } }

    /// Bir durum yazması başarısız oldu mu (ya da donduruldu mu)
    var isFrozen: Bool { queue.sync { frozen } }

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

    // MARK: - Yeniden istenecek kayıtlar, yer tutucular, kurtarma yönlendirmeleri

    func refetchNames() -> Set<String> { queue.sync { refetch } }

    func addRefetch<S: Sequence>(_ names: S) where S.Element == String {
        queue.sync {
            let before = refetch.count
            refetch.formUnion(names)
            if refetch.count != before { yaz(refetch, Dosya.refetch) }
        }
    }

    func removeRefetch<S: Sequence>(_ names: S) where S.Element == String {
        queue.sync {
            let before = refetch.count
            refetch.subtract(names)
            if refetch.count != before { yaz(refetch, Dosya.refetch) }
        }
    }

    func isPlaceholder(_ id: UUID) -> Bool { queue.sync { placeholders.contains(id) } }

    func addPlaceholders<S: Sequence>(_ ids: S) where S.Element == UUID {
        queue.sync {
            let before = placeholders.count
            placeholders.formUnion(ids)
            if placeholders.count != before { yaz(placeholders, Dosya.placeholders) }
        }
    }

    func removePlaceholders<S: Sequence>(_ ids: S) where S.Element == UUID {
        queue.sync {
            let before = placeholders.count
            placeholders.subtract(ids)
            if placeholders.count != before { yaz(placeholders, Dosya.placeholders) }
        }
    }

    func redirect(_ old: UUID) -> UUID? { queue.sync { redirects[old] } }

    func setRedirect(_ old: UUID, to new: UUID) {
        queue.sync { redirects[old] = new; yaz(redirects, Dosya.redirects) }
    }

    // MARK: - Sıfırlama

    /// Her şeyi siler; `enabled` kalır.
    func reset() {
        queue.sync {
            engine = nil; notebooks = [:]; pages = [:]; folders = [:]; fields = [:]
            meta.accountID = nil
            frozen = false
            refetch = []; placeholders = []; redirects = [:]
            for ad in [Dosya.engine, Dosya.notebooks, Dosya.pages, Dosya.folders, Dosya.fields,
                       Dosya.refetch, Dosya.placeholders, Dosya.redirects] { sil(ad) }
            yaz(meta, Dosya.meta)
        }
    }

    /// Yazmalar zaten eşzamanlı; kuyruğun boşaldığından emin olmak için (testler).
    func flush() { queue.sync {} }
}
