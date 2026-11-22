// İCloud eşitlemenin saf mantığı: veri modeli, fark çıkarma ve birleştirme.
// Yalnızca Foundation ve CryptoKit kullanır; ağ, dosya ve arayüz bilmez.

import Foundation
import CryptoKit

// MARK: Veri modeli

/// Defterin eşitlenen üst verisi (mürekkep ve sayfa içeriği hariç)
struct SyncNotebookMeta: Codable, Equatable {
    var id: UUID
    var title: String
    var subtitle: String
    var kind: String
    var cover: String
    var paper: String
    var size: String
    var favorite: Bool
    var trashed: Bool
    var folder: UUID?
    var created: Date
    var modified: Date
    var pdfAspect: Double?
    var pdfFile: String?
    var pdfHash: String?
    var pageOrder: [UUID]
}

/// Sayfanın eşitlenen üst verisi; mürekkep yalnızca özetiyle (`inkHash`) temsil edilir
struct SyncPageMeta: Codable, Equatable {
    var id: UUID
    var notebook: UUID
    var pdfPage: Int?
    var bookmarked: Bool
    var mark: String?
    var notes: [SyncItem]
    var images: [SyncItem]
    var tapes: [SyncItem]
    var inkHash: String?
}

/// Yapışkan not, resim veya bant öğesinin JSON kodlanmış hâli
struct SyncItem: Codable, Equatable, Identifiable {
    var id: UUID
    var data: Data
}

struct SyncFolderMeta: Codable, Equatable {
    var id: UUID
    var name: String
    var created: Date
}

/// Bir andaki eşitlenebilir durumun tamamı
struct SyncSnapshot: Equatable {
    var notebooks: [UUID: SyncNotebookMeta]
    var pages: [UUID: SyncPageMeta]
    var folders: [UUID: SyncFolderMeta]
    /// "<defter>/<dosya>" → SHA256; resimler ve source.pdf
    var files: [String: String]
}

enum SyncChange: Hashable {
    case notebook(UUID), page(UUID), folder(UUID)
    case file(notebook: UUID, name: String)
    case deleteNotebook(UUID), deletePage(UUID), deleteFolder(UUID)
    case deleteFile(notebook: UUID, name: String)
}

/// CloudKit hatasının durum satırına etkisi
enum SyncStatusKind: Equatable { case offline, quotaFull, retry, other }

// MARK: Birleştirme

enum SyncMerge {
    enum InkResolution: Equatable { case same, takeLocal, takeServer, keepBoth }
    enum DeleteResolution: Equatable { case delete, rescue }

    /// Boş veri → nil; değilse SHA256 onaltılık
    static func hash(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Eski ile yeni görüntü arasındaki yerel değişiklikler
    static func diff(old: SyncSnapshot, new: SyncSnapshot) -> Set<SyncChange> {
        var out = Set<SyncChange>()
        for (id, v) in new.notebooks where old.notebooks[id] != v { out.insert(.notebook(id)) }
        for (id, v) in new.pages where old.pages[id] != v { out.insert(.page(id)) }
        for (id, v) in new.folders where old.folders[id] != v { out.insert(.folder(id)) }
        for (key, h) in new.files where old.files[key] != h {
            if let (nbID, name) = splitFileKey(key) { out.insert(.file(notebook: nbID, name: name)) }
        }

        // Silinen defterin sayfaları ve dosyaları için ayrıca silme üretilmez
        let removedNotebooks = Set(old.notebooks.keys).subtracting(new.notebooks.keys)
        for id in removedNotebooks { out.insert(.deleteNotebook(id)) }
        for (id, p) in old.pages where new.pages[id] == nil && !removedNotebooks.contains(p.notebook) {
            out.insert(.deletePage(id))
        }
        for id in old.folders.keys where new.folders[id] == nil { out.insert(.deleteFolder(id)) }
        for key in old.files.keys where new.files[key] == nil {
            if let (nbID, name) = splitFileKey(key), !removedNotebooks.contains(nbID) {
                out.insert(.deleteFile(notebook: nbID, name: name))
            }
        }
        return out
    }

    private static func splitFileKey(_ key: String) -> (UUID, String)? {
        guard let slash = key.firstIndex(of: "/"),
              let id = UUID(uuidString: String(key[..<slash])) else { return nil }
        return (id, String(key[key.index(after: slash)...]))
    }

    /// Sunucu sırasını esas alır; yerelde silinenleri çıkarır, yerelde eklenenleri önceki komşusunun arkasına koyar
    static func mergeOrder(base: [UUID], local: [UUID], server: [UUID]) -> [UUID] {
        let deleted = Set(base).subtracting(local).union(Set(base).subtracting(server))
        var result = server.filter { !deleted.contains($0) }
        let baseSet = Set(base), serverSet = Set(server)
        for (index, id) in local.enumerated() where !baseSet.contains(id) && !serverSet.contains(id) {
            if result.contains(id) { continue }
            if let prev = local[..<index].reversed().first(where: { result.contains($0) }),
               let at = result.firstIndex(of: prev) {
                result.insert(id, at: at + 1)
            } else {
                result.insert(id, at: 0)
            }
        }
        return result
    }

    /// Öğeleri kimliğe göre birleştirir; iki tarafta da değiştiyse `localWins` karar verir
    static func mergeItems(base: [SyncItem], local: [SyncItem], server: [SyncItem], localWins: Bool) -> [SyncItem] {
        let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, x in x })
        let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, x in x })
        let s = Dictionary(server.map { ($0.id, $0) }, uniquingKeysWith: { _, x in x })
        var result: [SyncItem] = []
        var seen = Set<UUID>()
        for id in server.map(\.id) + local.map(\.id) where seen.insert(id).inserted {
            switch (l[id], s[id]) {
            case let (lv?, sv?):
                if lv == sv { result.append(lv) }
                else if lv == b[id] { result.append(sv) }
                else if sv == b[id] { result.append(lv) }
                else { result.append(localWins ? lv : sv) }
            case let (lv?, nil):
                // Sunucuda silinmiş: yerelde değişmediyse silinir
                if b[id] == nil || lv != b[id] { result.append(lv) }
            case let (nil, sv?):
                // Yerelde silinmiş: sunucuda değişmediyse silinir
                if b[id] == nil || sv != b[id] { result.append(sv) }
            case (nil, nil):
                break
            }
        }
        return result
    }

    /// Her alanda: yalnız bir taraf değiştiyse o taraf, ikisi de değiştiyse (veya base yoksa) `preferLocal`.
    /// Base'i anahtar yoluyla okur; böylece isteğe bağlı alanlarda "base yok" ile "base değeri nil" karışmaz.
    private static func pick<R, T: Equatable>(_ base: R?, _ key: KeyPath<R, T>, _ local: R, _ server: R, preferLocal: Bool) -> T {
        let l = local[keyPath: key], s = server[keyPath: key]
        if l == s { return l }
        guard let base else { return preferLocal ? l : s }
        let b = base[keyPath: key]
        if l == b { return s }
        if s == b { return l }
        return preferLocal ? l : s
    }

    static func mergeNotebook(base: SyncNotebookMeta?, local: SyncNotebookMeta, server: SyncNotebookMeta) -> SyncNotebookMeta {
        let pl = local.modified > server.modified
        var m = local
        m.title = pick(base, \.title, local, server, preferLocal: pl)
        m.subtitle = pick(base, \.subtitle, local, server, preferLocal: pl)
        m.kind = pick(base, \.kind, local, server, preferLocal: pl)
        m.cover = pick(base, \.cover, local, server, preferLocal: pl)
        m.paper = pick(base, \.paper, local, server, preferLocal: pl)
        m.size = pick(base, \.size, local, server, preferLocal: pl)
        m.favorite = pick(base, \.favorite, local, server, preferLocal: pl)
        m.trashed = pick(base, \.trashed, local, server, preferLocal: pl)
        m.folder = pick(base, \.folder, local, server, preferLocal: pl)
        m.created = pick(base, \.created, local, server, preferLocal: pl)
        m.pdfAspect = pick(base, \.pdfAspect, local, server, preferLocal: pl)
        m.pdfFile = pick(base, \.pdfFile, local, server, preferLocal: pl)
        m.pdfHash = pick(base, \.pdfHash, local, server, preferLocal: pl)
        m.pageOrder = mergeOrder(base: base?.pageOrder ?? [], local: local.pageOrder, server: server.pageOrder)
        m.modified = max(local.modified, server.modified)
        return m
    }

    /// Mürekkep hariç sayfa alanlarını birleştirir; `inkHash` yereldeki kalır, onu `resolveInk` çözer
    static func mergePage(base: SyncPageMeta?, local: SyncPageMeta, server: SyncPageMeta, localWins: Bool) -> SyncPageMeta {
        var m = local
        m.pdfPage = pick(base, \.pdfPage, local, server, preferLocal: localWins)
        m.bookmarked = pick(base, \.bookmarked, local, server, preferLocal: localWins)
        m.mark = pick(base, \.mark, local, server, preferLocal: localWins)
        m.notes = mergeItems(base: base?.notes ?? [], local: local.notes, server: server.notes, localWins: localWins)
        m.images = mergeItems(base: base?.images ?? [], local: local.images, server: server.images, localWins: localWins)
        m.tapes = mergeItems(base: base?.tapes ?? [], local: local.tapes, server: server.tapes, localWins: localWins)
        return m
    }

    /// Mürekkep özetlerinden hangisinin alınacağını belirler
    static func resolveInk(base: String?, local: String?, server: String?) -> InkResolution {
        if local == server { return .same }
        if local == base { return .takeServer }
        if server == base { return .takeLocal }
        return .keepBoth
    }

    /// Sunucuda silinen sayfanın yerelde değişmişse kurtarılması gerekir
    static func resolveRemoteDelete(base: String?, local: String?) -> DeleteResolution {
        local == base ? .delete : .rescue
    }

    // MARK: Denetleyici kararları (CloudKit'siz, Mac'te denetlenir)

    /// `CKError.Code` ham değerinden durum türü (CloudKit içe aktarılmasın diye sayılarla)
    static func statusKind(forErrorCode code: Int) -> SyncStatusKind {
        switch code {
        case 3, 4: .offline          // networkUnavailable, networkFailure
        case 25: .quotaFull          // quotaExceeded
        case 6, 7, 23: .retry        // serviceUnavailable, requestRateLimited, zoneBusy
        default: .other
        }
    }

    /// Klasörde değişiklik tarihi yok; iki taraf da değiştiyse sunucu kazanır
    static func mergeFolder(base: SyncFolderMeta?, local: SyncFolderMeta, server: SyncFolderMeta) -> SyncFolderMeta {
        var m = local
        m.name = pick(base, \.name, local, server, preferLocal: false)
        m.created = pick(base, \.created, local, server, preferLocal: false)
        return m
    }

    /// `resolveInk` ile aynı; ancak çakışmada bir taraf boşsa kopya üretmez, dolu taraf kazanır
    /// (boş taraf kaybolunca mürekkep kaybolmaz, gereksiz boş çakışma sayfası da çıkmaz)
    static func inkAction(base: String?, local: String?, server: String?) -> InkResolution {
        let r = resolveInk(base: base, local: local, server: server)
        guard r == .keepBoth else { return r }
        if local == nil { return .takeServer }
        if server == nil { return .takeLocal }
        return .keepBoth
    }

    /// Başka cihazda silinen defterin kurtarılacak sayfaları (yerel sırayla)
    static func pagesToRescue(local: [SyncPageMeta], bases: [UUID: SyncPageMeta]) -> [UUID] {
        local.filter { resolveRemoteDelete(base: bases[$0.id]?.inkHash, local: $0.inkHash) == .rescue }.map(\.id)
    }

    enum RemotePageAction: Equatable {
        /// Yerelle birleştir (yerelde yoksa olduğu gibi ekle)
        case merge
        /// Yerelde silinmiş ama uzakta yeni mürekkep var: sayfa deftere geri gelir
        case resurrect
        /// Defteri yerelde silinmiş ama uzakta yeni mürekkep var: kurtarma defterine alınır
        case rescueOrphan
        /// Yerel silme kazanır (uzakta mürekkep değişmedi)
        case skip
        /// Defteri henüz gelmedi; aynı alımda gelene kadar beklet
        case hold
    }

    /// Gelen sayfa kaydı yerelde karşılıksızsa ne yapılacağı. Yazılan kazanır: uzaktaki mürekkep
    /// son eşitlenen hâlden farklıysa yerel silme onu yutmaz.
    static func remotePageAction(localExists: Bool, notebookExists: Bool, base: SyncPageMeta?,
                                 notebookBaseKnown: Bool, server: SyncPageMeta) -> RemotePageAction {
        if localExists { return .merge }
        let newInk = server.inkHash != nil && server.inkHash != base?.inkHash
        if notebookExists {
            guard base != nil else { return .merge }
            return newInk ? .resurrect : .skip
        }
        guard notebookBaseKnown else { return .hold }
        return newInk ? .rescueOrphan : .skip
    }

    /// Tabanlara (son eşitlenen hâl) göre gönderilmesi gerekenler. Eşitleme açılınca ve her başlatmada
    /// çağrılır: kapalıyken ya da gönderilemeden kapanan değişiklikler böylece kaybolmaz.
    /// `knownFiles` buluttaki dosya kayıt adlarıdır ("<defter>/<ad>"); içerik özetleri tutulmaz,
    /// source.pdf'in değişip değişmediği defter tabanındaki `pdfHash`'ten anlaşılır.
    static func resumeChanges(bases: SyncSnapshot, knownFiles: Set<String>, local: SyncSnapshot) -> Set<SyncChange> {
        var old = SyncSnapshot(notebooks: bases.notebooks, pages: bases.pages, folders: bases.folders, files: [:])
        for key in knownFiles where key.contains("/") {
            var same = local.files[key]
            if let (nb, name) = splitFileKey(key), name == "source.pdf",
               bases.notebooks[nb]?.pdfHash != local.notebooks[nb]?.pdfHash {
                same = nil
            }
            // Yerelde yoksa ya da değiştiyse eski özet bilinmiyor: fark üretsin
            old.files[key] = same ?? "?"
        }
        return diff(old: old, new: local)
    }

    /// Devam farkındaki silmeler şüpheliyse (yerel kütüphane boş ya da defterlerin yarısından fazlası gitmiş,
    /// ör. dizin okunamadı) gönderilmez. Sonuç en kötü ihtimalle buluttaki fazladan bir kopyadır, kayıp değil.
    static func holdResumeDeletes(baseNotebooks: Int, localNotebooks: Int, deletedNotebooks: Int) -> Bool {
        guard baseNotebooks > 0, deletedNotebooks > 0 else { return false }
        if localNotebooks == 0 { return true }
        return baseNotebooks >= 4 && deletedNotebooks * 2 > baseNotebooks
    }

    /// Silinen defterden, yalnızca kurtarılan sayfaları içeren yeni bir defter üstverisi üretir
    static func rescueNotebook(from deleted: SyncNotebookMeta, keeping pages: [UUID], newID: UUID, now: Date) -> SyncNotebookMeta {
        var m = deleted
        let keep = Set(pages)
        m.id = newID
        m.trashed = false
        m.pageOrder = deleted.pageOrder.filter { keep.contains($0) }
        m.created = now
        m.modified = now
        return m
    }
}
