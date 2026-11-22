// İCloud eşitleme: motor olaylarının Sendable özeti ve gelen değişikliklerin yerele uygulanması
// (birleştirme, çakışma kopyası, silme ve kurtarma). Karar kuralları SyncMerge.swift'te.

import Foundation
import CloudKit

// MARK: - Olay özeti (ana iş parçacığı dışında kurulur)

/// Ayrıştırılmış kayıt içeriği. Varlıklar baytlarıyla taşınır (olay bitince dosyaları silinebilir).
enum SyncIncoming: Sendable {
    case notebook(SyncNotebookMeta)
    /// `ink == nil` boş mürekkep demek; `inkHash` gelen baytlardan yeniden hesaplanmıştır
    case page(SyncPageMeta, ink: Data?)
    case folder(SyncFolderMeta)
    case file(notebook: UUID, name: String, data: Data)

    var rank: Int {
        switch self {
        case .folder: 0
        case .notebook: 1
        case .page: 2
        case .file: 3
        }
    }
}

struct SyncRecordIn: Sendable {
    var name: String
    var fields: Data
    var content: SyncIncoming

    /// Varlığı okunamayan ya da tanınmayan kayıt nil döner; çağıran atlar (taban ve sistem alanı değişmez,
    /// böylece kayıt bir sonraki çakışmada ya da değişiklikte yeniden gelir)
    static func parse(_ r: CKRecord) -> SyncRecordIn? {
        guard r.recordID.zoneID == SyncRecords.zoneID else { return nil }
        let name = r.recordID.recordName
        let fields = SyncRecords.encodeFields(r)
        switch r.recordType {
        case SyncRecords.notebookType:
            guard let (m, _) = SyncRecords.notebook(r) else { return nil }
            return SyncRecordIn(name: name, fields: fields, content: .notebook(m))
        case SyncRecords.pageType:
            guard let (read, url) = SyncRecords.page(r) else { return nil }
            var m = read
            var ink: Data?
            if let url {
                guard let d = try? Data(contentsOf: url) else { return nil }
                m.inkHash = SyncMerge.hash(d)
                ink = d.isEmpty ? nil : d
            } else if m.inkHash != nil {
                // Özet mürekkep var diyor ama varlık yok: boş sanıp yerel mürekkebi silmeyelim
                return nil
            }
            return SyncRecordIn(name: name, fields: fields, content: .page(m, ink: ink))
        case SyncRecords.folderType:
            guard let m = SyncRecords.folder(r) else { return nil }
            return SyncRecordIn(name: name, fields: fields, content: .folder(m))
        case SyncRecords.fileType:
            guard let (nb, file, url) = SyncRecords.file(r), let d = try? Data(contentsOf: url) else { return nil }
            return SyncRecordIn(name: name, fields: fields, content: .file(notebook: nb, name: file, data: d))
        default:
            return nil
        }
    }
}

struct SyncFetched: Sendable {
    var records: [SyncRecordIn] = []
    var deletions: [(name: String, type: String)] = []

    init(_ e: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for m in e.modifications where m.record.recordID.zoneID == SyncRecords.zoneID {
            if let r = SyncRecordIn.parse(m.record) { records.append(r) }
            else { syncLog.error("Gelen kayıt okunamadı: \(m.record.recordType, privacy: .public)") }
        }
        for d in e.deletions where d.recordID.zoneID == SyncRecords.zoneID {
            deletions.append((d.recordID.recordName, d.recordType))
        }
    }
}

struct SyncSent: Sendable {
    /// Gönderilen hâl: sistem alanları ve (dosya dışı kayıtlarda) yeni taban
    var saved: [(name: String, fields: Data, base: SyncIncoming?)] = []
    /// `serverRecordChanged`: sunucudaki kayıt
    var conflicts: [SyncRecordIn] = []
    var failures: [(name: String, code: Int)] = []
    var deleted: [String] = []
    var failedDeletes: [(name: String, code: Int)] = []

    init(_ e: CKSyncEngine.Event.SentRecordZoneChanges) {
        for r in e.savedRecords {
            var base: SyncIncoming?
            switch r.recordType {
            case SyncRecords.notebookType: base = SyncRecords.notebook(r).map { .notebook($0.0) }
            case SyncRecords.pageType: base = SyncRecords.page(r).map { .page($0.0, ink: nil) }
            case SyncRecords.folderType: base = SyncRecords.folder(r).map { .folder($0) }
            default: base = nil
            }
            saved.append((r.recordID.recordName, SyncRecords.encodeFields(r), base))
        }
        for f in e.failedRecordSaves {
            if f.error.code == .serverRecordChanged, let server = f.error.serverRecord,
               let parsed = SyncRecordIn.parse(server) {
                conflicts.append(parsed)
            } else {
                failures.append((f.record.recordID.recordName, f.error.code.rawValue))
            }
        }
        deleted = e.deletedRecordIDs.map(\.recordName)
        failedDeletes = e.failedRecordDeletes.map { ($0.key.recordName, $0.value.code.rawValue) }
    }
}

enum SyncPrepared: Sendable {
    case state(Data?)
    case signIn(String), signOutOrSwitch, zoneDeleted
    case zoneSaveFailed([Int])
    case fetched(SyncFetched), sent(SyncSent)
    case willSync(sending: Bool), didFetch, didSend

    init?(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let e):
            self = .state(try? JSONEncoder().encode(e.stateSerialization))
        case .accountChange(let e):
            switch e.changeType {
            case .signIn(let user): self = .signIn(user.recordName)
            case .signOut, .switchAccounts: self = .signOutOrSwitch
            @unknown default: return nil
            }
        case .fetchedDatabaseChanges(let e):
            // Silinme, temizlenme ya da şifreli veri sıfırlaması: hepsinde bölge gitti
            guard e.deletions.contains(where: { $0.zoneID == SyncRecords.zoneID }) else { return nil }
            self = .zoneDeleted
        case .fetchedRecordZoneChanges(let e):
            self = .fetched(SyncFetched(e))
        case .sentDatabaseChanges(let e):
            let codes = e.failedZoneSaves.map { $0.error.code.rawValue }
            guard !codes.isEmpty else { return nil }
            self = .zoneSaveFailed(codes)
        case .sentRecordZoneChanges(let e):
            self = .sent(SyncSent(e))
        case .willFetchChanges: self = .willSync(sending: false)
        case .willSendChanges: self = .willSync(sending: true)
        case .didFetchChanges: self = .didFetch
        case .didSendChanges: self = .didSend
        default: return nil
        }
    }
}

// MARK: - Uygulama

extension SyncStateBatch {
    /// Sistem alanını siler (sözlükte nil değer = sil)
    mutating func clearFields(_ name: String) { fields.updateValue(nil, forKey: name) }
}

/// Bir olayın uygulanması sırasında biriken işler
struct SyncApplyContext {
    var batch = SyncStateBatch()
    /// Uygulanan sunucu hâlleri; sonunda yerelle karşılaştırılır, farklıysa yerel hâl gönderilir
    var touched: [SyncIncoming] = []
    var saves: [String] = []
    /// Yerelde silinmiş deftere uzaktan yazılmış sayfalar (eski defter → sayfalar)
    var orphans: [UUID: [(SyncPageMeta, Data?)]] = [:]
    var rescued = 0
}

extension SyncController {
    // MARK: Alınan değişiklikler

    func applyFetched(_ f: SyncFetched) {
        // Açık sayfanın bekleyen çizgisi önce kaydedilsin: sessizce ezilmesin, çakışma kuralına girsin
        library.flushOpenEditors?()
        var ctx = SyncApplyContext()

        // 1) Silmeler, üst verilerden önce (R-b): defter sırası uygulanınca silinen sayfa geri bildirilmesin
        let deletedNotebooks = Set(f.deletions.filter { $0.type == SyncRecords.notebookType }
            .compactMap { UUID(uuidString: $0.name) })
        for d in f.deletions {
            guard let id = UUID(uuidString: d.name) else {
                // Dosya kaydı: yerel dosya kalır (kurtarılmış bir sayfa kullanıyor olabilir)
                var b = SyncStateBatch(); b.clearFields(d.name); state.apply(b)
                continue
            }
            switch d.type {
            case SyncRecords.notebookType:
                ctx.rescued += remoteDeleteNotebook(id)
            case SyncRecords.pageType:
                let nb = library.syncPage(id)?.notebook ?? state.base(page: id)?.notebook
                if let nb, deletedNotebooks.contains(nb) {
                    // Defteriyle birlikte değerlendirilir; defter silmesi bu sayfayı da ele alır
                    continue
                }
                ctx.rescued += remoteDeletePage(id)
            case SyncRecords.folderType:
                library.removeRemote(folder: id)
                forget([id])
            default:
                forget([id])
            }
        }

        // 2) Klasör → defter → sayfa (R-c); bekleyen yetimler; en son dosyalar
        let sorted = f.records.enumerated().sorted {
            ($0.element.content.rank, $0.offset) < ($1.element.content.rank, $1.offset)
        }.map(\.element)
        for r in sorted { if case .file = r.content { continue }; applyRecord(r, &ctx) }
        rescueOrphans(&ctx)
        for r in sorted { if case .file = r.content { applyRecord(r, &ctx) } }
        finish(&ctx)
    }

    // MARK: Gönderim sonucu

    func applySent(_ s: SyncSent) {
        var ctx = SyncApplyContext()
        let zoneKnown = state.hasSystemFields
        for (name, fields, base) in s.saved {
            ctx.batch.fields[name] = fields
            // Taban = gönderilen hâl
            switch base {
            case .notebook(let m)?: ctx.batch.notebooks.append(m)
            case .page(let m, _)?: ctx.batch.pages.append(m)
            case .folder(let m)?: ctx.batch.folders.append(m)
            default: break
            }
        }
        var gone = s.deleted
        for (name, code) in s.failedDeletes {
            if code == CKError.Code.unknownItem.rawValue { gone.append(name) } else { noteErrorCode(code) }
        }
        for name in gone {
            ctx.batch.clearFields(name)
            if let id = UUID(uuidString: name) { ctx.batch.removed.append(id) }
        }
        state.apply(ctx.batch)
        ctx.batch = SyncStateBatch()

        // Sunucu hâli uygulanmadan önce açık sayfanın bekleyen çizgisi kaydedilsin (alınan değişikliklerdeki gibi)
        if !s.conflicts.isEmpty { library.flushOpenEditors?() }
        for c in s.conflicts {
            if case .file = c.content {
                // Dosyada yerel hâl kazanır: sunucunun sistem alanlarıyla yeniden gönderilir
                ctx.batch.fields[c.name] = c.fields
                ctx.saves.append(c.name)
            } else {
                applyRecord(c, &ctx)
                // Motor başarısız kaydı bekleyenlerden çıkardı; birleşen hâl sunucudan farklıysa `finish` geri ekler
            }
        }
        rescueOrphans(&ctx)

        for (name, code) in s.failures {
            switch CKError.Code(rawValue: code) {
            case .unknownItem?:
                // Gönderilen kayıt sunucuda silinmiş: alınan silmeyle aynı kural
                ctx.rescued += remoteRecordGone(name, &ctx)
            case .zoneNotFound?:
                if zoneKnown {
                    // Bölge daha önce vardı: başka cihaz sildi (R-j); yeniden kurulmaz
                    stop(.cloudDataDeleted)
                    return
                }
                // Bölge henüz kurulmadı: kur ve yeniden gönder
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecords.zoneID))])
                ctx.batch.clearFields(name)
                ctx.saves.append(name)
            case .userDeletedZone?:
                stop(.cloudDataDeleted)
                return
            case .limitExceeded?:
                batchByteLimit = max(1_000_000, batchByteLimit / 2)
                ctx.saves.append(name)
            case .assetFileNotFound?, .assetFileModified?:
                ctx.saves.append(name)
            default:
                // Ağ ve geçici hatalarda motor kendisi yeniden dener; kalıcı hatada değişiklik
                // tabanla farklı kaldığı için bir sonraki başlatmada yeniden sıraya girer
                noteErrorCode(code)
            }
        }
        finish(&ctx)
    }

    // MARK: Tek kayıt

    func applyRecord(_ r: SyncRecordIn, _ ctx: inout SyncApplyContext) {
        switch r.content {
        case .folder(let server):
            let local = library.syncFolder(server.id), base = state.base(folder: server.id)
            ctx.batch.fields[r.name] = r.fields
            // Yerelde silinmiş: silme kazanır, bekleyen silme gönderilir
            if local == nil, base != nil { return }
            library.applyRemote(folder: local.map { SyncMerge.mergeFolder(base: base, local: $0, server: server) } ?? server)
            ctx.batch.folders.append(server)
            ctx.touched.append(r.content)

        case .notebook(let server):
            let local = library.syncMeta(server.id), base = state.base(notebook: server.id)
            ctx.batch.fields[r.name] = r.fields
            // Yerelde silinmiş defter: silme kazanır (uzakta yazılmış sayfalar ayrıca kurtarılır)
            if local == nil, base != nil { return }
            library.applyRemote(notebook: local.map { SyncMerge.mergeNotebook(base: base, local: $0, server: server) } ?? server)
            ctx.batch.notebooks.append(server)
            ctx.touched.append(r.content)
            // Daha önce defteri beklenen sayfa ve dosyalar artık uygulanabilir
            if let held = heldRecords.removeValue(forKey: server.id) {
                for h in held.sorted(by: { $0.content.rank < $1.content.rank }) { applyRecord(h, &ctx) }
            }

        case .page(let server, let ink):
            let id = server.id
            let local = library.syncPage(id), base = state.base(page: id)
            let action = SyncMerge.remotePageAction(
                localExists: local != nil, notebookExists: library.index(of: server.notebook) != nil,
                base: base, notebookBaseKnown: state.base(notebook: server.notebook) != nil, server: server)
            switch action {
            case .hold:
                heldRecords[server.notebook, default: []].append(r)
                return
            case .skip:
                ctx.batch.fields[r.name] = r.fields
                return
            case .rescueOrphan:
                ctx.orphans[server.notebook, default: []].append((server, ink))
                ctx.batch.fields[r.name] = r.fields
                return
            case .resurrect:
                // Yerelde silinmişti ama başka cihazda yazıldı: yazılan kazanır, sayfa geri gelir
                var m = server
                m.mark = SyncMark.rescued.rawValue
                m.bookmarked = true
                library.applyRemote(page: m, ink: ink)
                engine?.state.remove(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(r.name))])
                ctx.saves.append(server.notebook.uuidString)
                ctx.rescued += 1
            case .merge:
                if let local {
                    let merged = SyncMerge.mergePage(base: base, local: local, server: server, localWins: false)
                    switch SyncMerge.inkAction(base: base?.inkHash, local: local.inkHash, server: server.inkHash) {
                    case .same, .takeLocal:
                        library.applyRemote(page: merged, ink: nil)
                    case .takeServer:
                        library.applyRemote(page: merged, ink: ink ?? Data())
                    case .keepBoth:
                        // R-d: önce bu cihazın mürekkebi kopyaya, sonra sunucunun mürekkebi sayfaya
                        _ = library.insertConflictCopy(of: id, ink: library.drawing(local.notebook, id))
                        library.applyRemote(page: merged, ink: ink ?? Data())
                    }
                } else {
                    library.applyRemote(page: server, ink: ink)
                }
            }
            ctx.batch.pages.append(server)
            ctx.batch.fields[r.name] = r.fields
            ctx.touched.append(r.content)

        case .file(let nb, let name, let data):
            if library.index(of: nb) != nil {
                library.applyRemote(file: data, notebook: nb, name: name)
                ctx.batch.fields[r.name] = r.fields
            } else if let target = rescueRedirect[nb] {
                // Kurtarma defterine giden sayfaların resimleri ve PDF'i
                library.applyRemote(file: data, notebook: target, name: name)
                ctx.saves.append(Self.fileRecordName(target, name))
            } else if state.base(notebook: nb) != nil {
                ctx.batch.fields[r.name] = r.fields   // yerelde silinmiş defterin dosyası
            } else {
                heldRecords[nb, default: []].append(r)
            }
        }
    }

    /// Yerelde silinmiş deftere başka cihazda yazılmış sayfalar yeni bir deftere toplanır.
    /// Sayfalar yeni kimlik alır: eski kayıtlar için bekleyen silme gönderildiğinde bunlara dokunmasın.
    private func rescueOrphans(_ ctx: inout SyncApplyContext) {
        for (oldID, list) in ctx.orphans {
            guard let baseMeta = state.base(notebook: oldID) else { continue }
            let newID = rescueRedirect[oldID] ?? UUID()
            rescueRedirect[oldID] = newID
            var pages: [SyncPageMeta] = [], inks: [UUID: Data] = [:]
            for (server, ink) in list {
                var m = server
                m.id = UUID()
                m.notebook = newID
                pages.append(m)
                if let ink { inks[m.id] = ink }
            }
            var meta = SyncMerge.rescueNotebook(from: baseMeta, keeping: [], newID: newID, now: Date())
            meta.pageOrder = pages.map(\.id)
            library.rescue(pages: pages, inks: inks, into: meta)
            ctx.rescued += pages.count
        }
        ctx.orphans = [:]
    }

    private func finish(_ ctx: inout SyncApplyContext) {
        state.apply(ctx.batch)
        var saves = ctx.saves
        for t in ctx.touched {
            switch t {
            case .notebook(let s):
                guard var l = library.syncMeta(s.id) else { continue }
                // PDF dosyası henüz gelmediyse özeti yok; bu yüzden geri gönderilmesin
                if l.pdfHash == nil { l.pdfHash = s.pdfHash }
                if l != s { saves.append(s.id.uuidString) }
            case .page(let s, _):
                if let l = library.syncPage(s.id), l != s { saves.append(s.id.uuidString) }
            case .folder(let s):
                if let l = library.syncFolder(s.id), l != s { saves.append(s.id.uuidString) }
            case .file:
                break
            }
        }
        addPendingSaves(saves)
        if ctx.rescued > 0 { addRescued(ctx.rescued) }
        if heldRecords.isEmpty, let d = deferredEngineState {
            state.engineState = d
            deferredEngineState = nil
        }
    }

    // MARK: Silme ve kurtarma (durum yazmaları hemen yapılır; sonraki kararlar güncel tabanı görsün)

    /// Tabanları ve sistem alanlarını unutur
    private func forget(_ ids: [UUID], names: [String] = []) {
        var b = SyncStateBatch()
        b.removed = ids
        for id in ids { b.clearFields(id.uuidString) }
        for n in names { b.clearFields(n) }
        state.apply(b)
    }

    /// Başka cihazda silinen defter. Yerelde mürekkebi değişmiş sayfalar aynı başlık ve ayarlarla yeni bir
    /// deftere kurtarılır; değişmemişler silinir. Kurtarılan sayfa sayısını döndürür.
    func remoteDeleteNotebook(_ id: UUID) -> Int {
        var ids = [id] + state.pageIDs(inNotebook: id)
        let prefix = id.uuidString + "/"
        let fileNames = state.recordNames().filter { $0.hasPrefix(prefix) }.sorted()
        var count = 0
        if let nb = library.notebooks.first(where: { $0.id == id }), let meta = library.syncMeta(id) {
            let local = nb.pages.compactMap { library.syncPage($0.id) }
            ids += local.map(\.id)
            let bases = Dictionary(local.compactMap { p in state.base(page: p.id).map { (p.id, $0) } },
                                   uniquingKeysWith: { a, _ in a })
            let keep = SyncMerge.pagesToRescue(local: local, bases: bases)
            if keep.isEmpty {
                library.removeRemote(notebook: id)
            } else {
                let newID = UUID()
                let keepSet = Set(keep)
                let pages = local.filter { keepSet.contains($0.id) }
                // R-e: mürekkep, resimler ve PDF defter klasörü silinmeden alınır (rescue dosya kopyalamaz)
                var inks: [UUID: Data] = [:]
                for p in pages {
                    let d = library.drawing(id, p.id)
                    if !d.isEmpty { inks[p.id] = d }
                }
                var files = Set(nb.pages.filter { keepSet.contains($0.id) }.flatMap { $0.pageImages.map(\.file) })
                if let pdf = nb.pdfFile { files.insert(pdf) }
                library.store.flush()
                library.store.createDir(newID)
                let from = library.store.dir(id), to = library.store.dir(newID)
                for f in files {
                    try? FileManager.default.copyItem(at: from.appendingPathComponent(f), to: to.appendingPathComponent(f))
                }
                library.removeRemote(notebook: id)
                library.rescue(pages: pages, inks: inks,
                               into: SyncMerge.rescueNotebook(from: meta, keeping: keep, newID: newID, now: Date()))
                count = keep.count
            }
        }
        // Kurtarılan sayfalar sistem alanı ve taban olmadan yeni kayıt olarak gönderilir
        forget(Array(Set(ids)), names: fileNames)
        return count
    }

    /// Başka cihazda silinen sayfa: mürekkebi burada değiştiyse yerinde kalır ("Kurtarıldı"), yoksa silinir
    func remoteDeletePage(_ id: UUID) -> Int {
        guard let local = library.syncPage(id) else { forget([id]); return 0 }
        switch SyncMerge.resolveRemoteDelete(base: state.base(page: id)?.inkHash, local: local.inkHash) {
        case .delete:
            library.removeRemote(page: id)
            forget([id])
            return 0
        case .rescue:
            // Defter tabanının sırasından çıkar: sıra birleşince sayfa "yerelde eklenmiş" sayılır, yerinde kalır
            if var nbBase = state.base(notebook: local.notebook) {
                nbBase.pageOrder.removeAll { $0 == id }
                state.setBase(nbBase)
            }
            forget([id])
            library.markRescued(page: id)
            return 1
        }
    }

    /// Gönderilen kayıt sunucuda yok (`unknownItem`)
    private func remoteRecordGone(_ name: String, _ ctx: inout SyncApplyContext) -> Int {
        guard let id = UUID(uuidString: name) else {
            // Dosya: defteri yerelde duruyorsa yeni kayıt olarak yeniden gönderilir
            forget([], names: [name])
            if let nb = UUID(uuidString: String(name.prefix { $0 != "/" })), library.index(of: nb) != nil {
                ctx.saves.append(name)
            }
            return 0
        }
        if library.syncMeta(id) != nil { return remoteDeleteNotebook(id) }
        if library.syncPage(id) != nil { return remoteDeletePage(id) }
        if library.syncFolder(id) != nil { library.removeRemote(folder: id) }
        forget([id])
        return 0
    }
}
