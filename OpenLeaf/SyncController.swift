// İCloud eşitleme denetleyicisi: kullanıcının özel CloudKit veritabanında bir `CKSyncEngine` çalıştırır.
// Yerel değişiklikleri `Library`'den alıp gönderir; gelenleri SyncApply.swift'teki kurallarla uygular.
// Kararların saf kısmı SyncMerge.swift'te (Mac'te denetlenir). Üst kural: hiçbir mürekkep sessizce kaybolmaz.

import Foundation
import CloudKit
import os

enum SyncStopReason: Equatable { case accountChanged, cloudDataDeleted }

enum SyncStatus: Equatable {
    case off, noAccount, syncing, upToDate(Date), offline, quotaFull, stopped(SyncStopReason)
}

/// Arayüzün bir kez gösterip `clearNotice()` ile kapattığı bildirim
enum SyncNotice: Identifiable, Equatable {
    case rescued(count: Int), stopped(SyncStopReason)

    var id: String {
        switch self {
        case .rescued(let n): "kurtarildi-\(n)"
        case .stopped(.accountChanged): "durdu-hesap"
        case .stopped(.cloudDataDeleted): "durdu-bulut"
        }
    }
}

let syncLog = Logger(subsystem: "io.github.biggypanda.openleaf", category: "esitleme")

@MainActor
@Observable
final class SyncController {
    static let containerID = "iCloud.io.github.biggypanda.openleaf"

    private(set) var status: SyncStatus = .off
    private(set) var notice: SyncNotice?

    @ObservationIgnored let library: Library
    @ObservationIgnored let state: SyncStateStore
    @ObservationIgnored var engine: CKSyncEngine?
    /// Kullanıcı kapatınca motorun gecikmeli son durum kaydı yine yazılsın diye tutulur (yeniden açınca bırakılır)
    @ObservationIgnored private var closedEngine: CKSyncEngine?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Bu gönderim turunda kaydı kurulamayan (geçici kopya yazılamadı) kayıtlar; bekler, tur sonunda yeniden denenir
    @ObservationIgnored var skippedThisRound = Set<CKRecord.ID>()
    /// Turdaki gönderim hatasının durum satırına etkisi
    @ObservationIgnored var sendProblem: SyncStatusKind?
    /// Bir gönderim grubundaki varlıkların üst sınırı; `limitExceeded` gelirse yarıya iner
    @ObservationIgnored var batchByteLimit = 20_000_000
    /// Defteri henüz gelmemiş sayfa/dosya kayıtları (defter kimliğine göre; aynı alım içinde beklenir)
    @ObservationIgnored var heldRecords: [UUID: [SyncRecordIn]] = [:]
    /// Bekletilen kayıt varken motor durumu diske yazılmaz: uygulama kapanırsa kayıtlar yeniden alınır
    @ObservationIgnored var deferredEngineState: Data?
    /// Bu oturumda, yerelde silinmiş defterden kurtarılan sayfaların toplandığı defter (eski → yeni)
    @ObservationIgnored var rescueRedirect: [UUID: UUID] = [:]
    /// Motor başlarken kütüphane deposunun yazma hatası sayısı; artarsa motor durumu artık diske yazılmaz (I3)
    @ObservationIgnored var diskFailuresAtStart = 0

    private var container: CKContainer { CKContainer(identifier: Self.containerID) }

    init(library: Library, state: SyncStateStore) {
        self.library = library
        self.state = state
        status = state.enabled ? .syncing : .off
    }

    // MARK: Açma / kapama

    /// Uygulama açılışında: eşitleme açık bırakıldıysa başlatır
    func startIfEnabled() {
        if state.enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        if on {
            state.enabled = true
            start()
        } else {
            // engineState ve tabanlar silinmez: yeniden açılınca kaldığı yerden devam eder, silmeler geri gelmez
            stopEngine(keepLastState: true)
            state.enabled = false
            status = .off
        }
    }

    func clearNotice() { notice = nil }

    /// Eşitleme kapalıyken iCloud oturumu yoksa durum `.noAccount` olur (menüde anahtar devre dışı);
    /// oturum açılınca yeniden `.off`. Açıkken durumu motor yönetir.
    func refreshAccountStatus() async {
        guard !state.enabled, status == .off || status == .noAccount else { return }
        let account = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard !state.enabled, status == .off || status == .noAccount else { return }
        status = (account == .noAccount || account == .restricted) ? .noAccount : .off
    }

    /// Kurtarma bildirimi; gösterilmemiş bir kurtarma varsa sayılar toplanır
    func addRescued(_ n: Int) {
        if case .rescued(let c)? = notice { notice = .rescued(count: c + n) } else { notice = .rescued(count: n) }
    }

    /// Buluttaki eşitleme bölgesini siler. Bu cihazın yerel kütüphanesine dokunmaz; eşitleme kapanır.
    func deleteCloudData() async throws {
        let wasEnabled = state.enabled
        stopEngine(keepLastState: false)
        let db = container.privateCloudDatabase
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [SyncRecords.zoneID])
                op.qualityOfService = .userInitiated
                op.modifyRecordZonesResultBlock = { c.resume(with: $0) }
                db.add(op)
            }
        } catch let e as CKError where e.code == .zoneNotFound || e.code == .userDeletedZone {
            // Bölge zaten yok: silinmiş sayılır
        } catch {
            if wasEnabled { start() }
            throw error
        }
        state.reset()
        state.enabled = false
        status = .off
    }

    private func start() {
        guard engine == nil, startTask == nil else { return }
        status = .syncing
        startTask = Task { [weak self] in
            await self?.startEngine()
            self?.startTask = nil
        }
    }

    private func startEngine() async {
        let container = self.container
        let account = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard !Task.isCancelled, state.enabled, engine == nil else { return }
        if account == .available, let id = try? await container.userRecordID().recordName {
            guard !Task.isCancelled, state.enabled, engine == nil else { return }
            // Kapalıyken başka hesaba geçilmiş: eski durumla devam etmek yanlış hesaba yazardı
            if let known = state.accountID, known != id {
                stop(.accountChanged)
                return
            }
            state.accountID = id
        }

        var serialization: CKSyncEngine.State.Serialization?
        if let data = state.engineState {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        diskFailuresAtStart = library.store.failureCount
        let config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialization, delegate: self)
        let engine = CKSyncEngine(config)
        closedEngine = nil
        self.engine = engine
        status = (account == .noAccount || account == .restricted) ? .noAccount : .syncing

        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecords.zoneID))])
        }
        // C1: eski sürümde çoğaltılan defterlerin paylaştığı sayfa kimlikleri, ilk görüntüden önce ayrılır
        library.flushOpenEditors?()
        let reIDs = library.reassignDuplicatePageIDs()
        if reIDs > 0 { syncLog.notice("Yinelenen \(reIDs) sayfa kimliği yenilendi") }
        // R-a: atama lastSnapshot'ı sıfırlar; başlangıç açıkça kurulur
        library.onSyncChanges = { [weak self] changes in self?.enqueue(changes) }
        let snapshot = library.seedSyncBaseline()
        // Tabanlara göre gönderilmemiş her şey (ilk açılışta tüm kütüphane; kapalıyken yapılanlar dahil)
        let bases = state.allBases()
        var resume = SyncMerge.resumeChanges(bases: bases, knownFiles: state.recordNames(), local: snapshot)
        let deletedNotebooks = resume.filter { if case .deleteNotebook = $0 { true } else { false } }.count
        if SyncMerge.holdResumeDeletes(baseNotebooks: bases.notebooks.count, localNotebooks: snapshot.notebooks.count,
                                       deletedNotebooks: deletedNotebooks) {
            syncLog.error("Devam farkında şüpheli toplu silme; silmeler gönderilmedi")
            resume = resume.filter {
                switch $0 {
                case .deleteNotebook, .deletePage, .deleteFolder, .deleteFile: false
                default: true
                }
            }
        }
        enqueue(resume)

        // Ağ hatası durum satırında görünsün (motor kendi de yeniden dener)
        Task { [weak self] in
            do { try await engine.fetchChanges() } catch { self?.noteError(error) }
        }
    }

    /// Hesap değişimi ya da bulut verisinin silinmesi: yerel veri kalır, eşitleme durur
    func stop(_ reason: SyncStopReason) {
        stopEngine(keepLastState: false)
        state.reset()
        state.enabled = false
        status = .stopped(reason)
        notice = .stopped(reason)
        syncLog.notice("Eşitleme durdu: \(String(describing: reason), privacy: .public)")
    }

    private func stopEngine(keepLastState: Bool) {
        startTask?.cancel()
        startTask = nil
        library.onSyncChanges = nil
        if let old = engine {
            closedEngine = keepLastState ? old : nil
            Task { await old.cancelOperations() }
        }
        engine = nil
        heldRecords = [:]
        deferredEngineState = nil
        skippedThisRound = []
        sendProblem = nil
        rescueRedirect = [:]
    }

    // MARK: Yerel değişiklikler

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: SyncRecords.zoneID)
    }

    static func fileRecordName(_ notebook: UUID, _ name: String) -> String { "\(notebook.uuidString)/\(name)" }

    /// `Library`'nin fark kümesini motorun bekleyen listesine çevirir (kayıtlar gönderim anında kurulur, R-g)
    func enqueue(_ changes: Set<SyncChange>) {
        guard let engine, !changes.isEmpty else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        func save(_ n: String) { pending.append(.saveRecord(Self.recordID(n))) }
        func delete(_ n: String) { pending.append(.deleteRecord(Self.recordID(n))) }
        var names: Set<String>?
        for change in changes {
            switch change {
            case .notebook(let id), .page(let id), .folder(let id): save(id.uuidString)
            case .file(let nb, let name): save(Self.fileRecordName(nb, name))
            case .deletePage(let id), .deleteFolder(let id): delete(id.uuidString)
            case .deleteFile(let nb, let name): delete(Self.fileRecordName(nb, name))
            case .deleteNotebook(let id):
                delete(id.uuidString)
                // R-f: defterin sayfa ve dosya kayıtları da silinir, bulutta yetim kalmasın
                for p in state.pageIDs(inNotebook: id) { delete(p.uuidString) }
                if names == nil { names = state.recordNames() }
                let prefix = id.uuidString + "/"
                for n in names! where n.hasPrefix(prefix) { delete(n) }
            }
        }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    func addPendingSaves(_ names: [String]) {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(Self.recordID($0)) })
    }

    // MARK: Gönderim grubu

    enum Built { case record(CKRecord, bytes: Int), gone, failed }

    /// Bekleyen değişikliklerden bir gönderim grubu kurar; kayıtlar şimdiki yerel durumdan üretilir (R-g)
    func makeBatch(_ pending: [CKSyncEngine.PendingRecordZoneChange],
                   engineID: ObjectIdentifier) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let engine, ObjectIdentifier(engine) == engineID else { return nil }
        library.store.flush()
        var saves: [CKRecord] = [], deletes: [CKRecord.ID] = [], gone: [CKSyncEngine.PendingRecordZoneChange] = []
        var bytes = 0
        for change in pending {
            if saves.count + deletes.count >= 200 || bytes >= batchByteLimit { break }
            switch change {
            case .deleteRecord(let id):
                deletes.append(id)
            case .saveRecord(let id):
                if skippedThisRound.contains(id) { continue }
                switch buildRecord(id) {
                case .record(let r, let size): saves.append(r); bytes += size
                case .gone: gone.append(change)          // yerelde artık yok; silmesi ayrıca bekliyor
                case .failed: skippedThisRound.insert(id) // varlık olmadan asla gönderilmez; sonra yeniden denenir
                }
            @unknown default:
                break
            }
        }
        if !gone.isEmpty { engine.state.remove(pendingRecordZoneChanges: gone) }
        guard !saves.isEmpty || !deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes, atomicByZone: false)
    }

    private func buildRecord(_ id: CKRecord.ID) -> Built {
        let name = id.recordName
        let fields = state.systemFields(name)
        if let slash = name.firstIndex(of: "/") {
            guard let nb = UUID(uuidString: String(name[..<slash])), library.index(of: nb) != nil else { return .gone }
            let file = String(name[name.index(after: slash)...])
            let url = library.store.dir(nb).appendingPathComponent(file)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            else { return .gone }
            guard let r = SyncRecords.record(file: url, notebook: nb, name: file, fields: fields) else { return .failed }
            return .record(r, bytes: size.intValue)
        }
        guard let uuid = UUID(uuidString: name) else { return .gone }
        if let m = library.syncMeta(uuid) {
            // PDF, "source.pdf" dosya kaydıyla gider; defter kaydında ikinci kez yüklenmez
            guard let r = SyncRecords.record(notebook: m, pdf: nil, fields: fields) else { return .failed }
            return .record(r, bytes: 2_000)
        }
        if var m = library.syncPage(uuid) {
            let ink = library.drawing(m.notebook, uuid)
            // Özet, gönderilen baytlardan: taban (gönderilen hâl) varlıkla birebir tutarlı olsun
            m.inkHash = SyncMerge.hash(ink)
            var inkURL: URL?
            if !ink.isEmpty {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLeaf-Murekkep", isDirectory: true)
                let url = dir.appendingPathComponent(UUID().uuidString + ".drawing")
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try ink.write(to: url)
                } catch {
                    return .failed
                }
                inkURL = url
            }
            defer { if let inkURL { try? FileManager.default.removeItem(at: inkURL) } }
            guard let r = SyncRecords.record(page: m, ink: inkURL, fields: fields) else { return .failed }
            return .record(r, bytes: ink.count + 4_000)
        }
        if let m = library.syncFolder(uuid) {
            return .record(SyncRecords.record(folder: m, fields: fields), bytes: 500)
        }
        return .gone
    }

    // MARK: Olaylar (ana iş parçacığında)

    func handle(_ event: SyncPrepared, engineID: ObjectIdentifier) {
        if case .state(let data) = event {
            if let engine, ObjectIdentifier(engine) == engineID {
                if heldRecords.isEmpty { persistEngineState(data) } else { deferredEngineState = data }
            } else if let closedEngine, ObjectIdentifier(closedEngine) == engineID, !state.enabled {
                persistEngineState(data)
            }
            return
        }
        guard let engine, ObjectIdentifier(engine) == engineID else { return }

        switch event {
        case .state:
            break
        case .signIn(let user):
            if let known = state.accountID, known != user {
                stop(.accountChanged)
            } else {
                state.accountID = user
                if status == .noAccount { status = .syncing }
            }
        case .signOutOrSwitch:
            stop(.accountChanged)
        case .zoneDeleted:
            // R-j: yerel veri kalır; bölge kendiliğinden yeniden kurulmaz
            stop(.cloudDataDeleted)
        case .zoneSaveFailed(let codes):
            if codes.contains(CKError.Code.userDeletedZone.rawValue) { stop(.cloudDataDeleted); return }
            for code in codes { noteErrorCode(code) }
        case .fetched(let batch):
            applyFetched(batch)
        case .sent(let result):
            applySent(result)
        case .willSync:
            // Önceki turun hatası unutulur; bu turun sonucu `did…` olayında değerlendirilir
            sendProblem = nil
            if status != .noAccount { status = .syncing }
        case .didFetch:
            if !heldRecords.isEmpty {
                // Defteri hiç gelmedi: defter bulutta yok (silinmiş); sayfaları da silinmiş olmalı
                syncLog.error("Defteri gelmeyen \(self.heldRecords.count) defter için kayıtlar bırakıldı")
                heldRecords = [:]
            }
            if let d = deferredEngineState { persistEngineState(d); deferredEngineState = nil }
            updateIdleStatus(engine)
        case .didSend:
            // R-h: geçici kopyalar yalnızca gönderim turu bütünüyle bitince silinir
            SyncRecords.cleanUpOutgoingAssets()
            skippedThisRound = []
            updateIdleStatus(engine)
        }
    }

    /// Motor durumunu (değişiklik belirteci) yazar. Önce kütüphanenin kuyruktaki disk yazmaları bitirilir (I3):
    /// belirteç, uygulanan değişiklik diske inmeden ilerlemesin. Yazma hatası olduysa belirteç diske yazılmaz.
    func persistEngineState(_ data: Data?) {
        // `failureCount` kuyruğu bekler: okunduğunda bekleyen yazmalar bitmiştir
        if library.store.failureCount != diskFailuresAtStart { state.freezeEngineState() }
        state.engineState = data
    }

    private func updateIdleStatus(_ engine: CKSyncEngine) {
        if case .stopped = status { return }
        if status == .noAccount { return }
        switch sendProblem {
        case .offline?: status = .offline
        case .quotaFull?: status = .quotaFull
        default:
            if engine.state.pendingRecordZoneChanges.isEmpty && engine.state.pendingDatabaseChanges.isEmpty {
                status = .upToDate(Date())
            } else {
                status = .syncing
            }
        }
    }

    func noteError(_ error: Error) {
        guard let ck = error as? CKError else { return }
        noteErrorCode(ck.code.rawValue)
        if case .offline = SyncMerge.statusKind(forErrorCode: ck.code.rawValue), engine != nil { status = .offline }
    }

    func noteErrorCode(_ code: Int) {
        switch SyncMerge.statusKind(forErrorCode: code) {
        case .offline: sendProblem = .offline
        case .quotaFull: sendProblem = .quotaFull
        case .retry: break        // motor kendisi yeniden dener
        case .other: syncLog.error("CloudKit hatası: \(code, privacy: .public)")
        }
    }
}

// MARK: - CKSyncEngine temsilcisi

/// Temsilci çağrıları ana iş parçacığı dışında gelir. Varlık dosyaları burada okunur (ana iş parçacığını
/// bekletmesin), sonra Sendable bir özetle `Library` işi için ana aktöre geçilir.
extension SyncController: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let prepared = SyncPrepared(event) else { return }
        await handle(prepared, engineID: ObjectIdentifier(syncEngine))
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await makeBatch(pending, engineID: ObjectIdentifier(syncEngine))
    }
}
