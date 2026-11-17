import SwiftUI
import UIKit

/// Kullanıcının çöp kutusundan kalıcı olarak sildiği defterler. Otomatik yedek yalnızca bu listedekileri
/// yedekten siler; listede olmayan hiçbir defter yedekten kalkmaz.
enum DeletedNotebooks {
    private static let key = "yedek.silinenler"

    static var all: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func add(_ id: UUID) {
        store(all.union([id]))
    }

    static func remove(_ ids: some Sequence<UUID>) {
        let left = all.subtracting(ids)
        if left.count != all.count { store(left) }
    }

    private static func store(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

/// Otomatik yedek: kütüphane, kullanıcının seçtiği yere kendiliğinden yedeklenir.
///
/// İki yer seçilebilir (aynı anda biri):
/// - **iCloud:** kullanıcının kendi iCloud hesabındaki uygulama klasörü. Kapsayıcının "Documents" klasörü
///   kullanılmaz; yedek Dosyalar'da görünmez, kapladığı yer Ayarlar → iCloud'da görünür.
/// - **Klasör:** Dosyalar penceresinden seçilen herhangi bir klasör (Google Drive, Dropbox, OneDrive,
///   USB bellek, ağ sunucusu…). Uygulama bu hizmetlere kendisi bağlanmaz; yalnızca klasöre yazar.
///
///     <yer>/Yedekler/<cihaz-kimliği>/                 (iCloud)
///     <klasör>/OpenLeaf Yedekleri/<cihaz-kimliği>/    (seçilen klasör)
///
/// Her cihazın kendi klasörü vardır: aynı hesaptaki iki iPad birbirinin yedeğini ezmez.
@MainActor
@Observable
final class AutoBackup {
    enum Destination: String {
        case icloud, folder
    }

    enum Status: Equatable {
        /// Kullanıcı açmamış
        case off
        /// Yere ulaşılamıyor (iCloud oturumu yok, klasör bağlı değil…)
        case unavailable
        case idle
        case running
        case failed(String)
    }

    struct Found: Identifiable, Equatable {
        /// Yedeğin klasör adı (kök klasörün içinde)
        var folder: String
        var info: BackupEngine.DeviceInfo
        var isThisDevice: Bool
        var id: String { folder }
        /// "12 defter · 13 Kas 2026 14:32"
        var summary: String {
            String(localized: "\(info.notebookCount) defter") + " · " + info.date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    struct RestoreResult: Equatable {
        var added = 0
        var skipped = 0
        var failed = 0
    }

    enum BackupError: LocalizedError {
        case unreadable, unavailable
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Yedek okunamadı. İnternet bağlantını kontrol edip yeniden dene.")
            case .unavailable: String(localized: "Yedek yerine ulaşılamıyor.")
            }
        }
    }

    private enum Key {
        static let enabled = "yedek.acik"
        static let asked = "yedek.soruldu"
        static let last = "yedek.son"
        static let device = "yedek.cihazKimligi"
        static let destination = "yedek.yer"
        static let bookmark = "yedek.klasor.imi"
        static let folderName = "yedek.klasor.ad"
    }

    private(set) var enabled: Bool
    /// "Otomatik yedeklensin mi?" sorusu bir kez sorulur
    private(set) var asked: Bool
    private(set) var destination: Destination
    /// Seçilen klasörün adı (klasör seçilmediyse nil)
    private(set) var folderName: String?
    private(set) var status: Status = .off
    /// Yedeğin en son başarıyla tamamlandığı an
    private(set) var lastBackup: Date?
    /// Dosyalar iCloud klasörüne kopyalandı ama iCloud'a yüklenmesi sürüyor
    private(set) var uploading = false
    /// Seçili yerde bulunan cihaz yedekleri, en yenisi başta
    private(set) var found: [Found] = []
    /// En az bir arama tamamlandı
    private(set) var searched = false
    /// Seçili yere ulaşılabiliyor
    private(set) var isAvailable = false
    /// Bu cihazda iCloud oturumu açık
    private(set) var iCloudAvailable = false
    /// Geri yükleme sürüyorsa 0…1 arası ilerleme
    private(set) var restoreProgress: Double?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let queue = DispatchQueue(label: "openleaf.yedek", qos: .utility)
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var firstChange: Date?
    @ObservationIgnored private var lastChange: Date?
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private var search: BackupSearch?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    /// Son değişiklikten bu kadar sonra yedeklenir
    private static let quietDelay: TimeInterval = 60
    /// Hiç ara vermeden yazılıyorsa en geç bu kadar sonra yedeklenir
    private static let longestWait: TimeInterval = 300

    init(library: Library) {
        self.library = library
        enabled = defaults.bool(forKey: Key.enabled)
        asked = defaults.bool(forKey: Key.asked)
        lastBackup = defaults.object(forKey: Key.last) as? Date
        folderName = defaults.string(forKey: Key.folderName)
        let saved = defaults.string(forKey: Key.destination).flatMap(Destination.init(rawValue:)) ?? .icloud
        destination = saved == .folder && defaults.data(forKey: Key.bookmark) == nil ? .icloud : saved
        if let id = defaults.string(forKey: Key.device) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.device)
        }
        status = enabled ? .idle : .off
        library.onChange = { [weak self] in self?.noteChange() }
    }

    // MARK: Yer

    /// Arka plan işine verilen, o anki yer seçimi
    private struct Target {
        var destination: Destination
        var bookmark: Data?
    }

    private var target: Target {
        Target(destination: destination, bookmark: defaults.data(forKey: Key.bookmark))
    }

    /// Açılmış yedek kökü. İş bitince `close()` çağrılır (seçilen klasöre erişim izni geri verilir).
    private struct Root {
        var url: URL
        var coordinated: Bool
        var scope: URL?
        func close() { scope?.stopAccessingSecurityScopedResource() }
    }

    #if DEBUG
    /// Simülatörde iCloud olmadan denemek için: "iCloud" yedeği bu klasöre yazılır
    nonisolated private static var testRoot: String? {
        let path = ProcessInfo.processInfo.environment["OPENLEAF_YEDEK_KOK"] ?? ""
        return path.isEmpty ? nil : path
    }
    #endif

    nonisolated private static var hasICloud: Bool {
        #if DEBUG
        if testRoot != nil { return true }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// Yedeklerin durduğu kök klasörü açar. iCloud'a ilk erişim ve klasör çözümleme yavaş olabildiği için
    /// ana iş parçacığında çağrılmaz.
    nonisolated private static func open(_ target: Target) -> Root? {
        switch target.destination {
        case .icloud:
            #if DEBUG
            if let path = testRoot {
                return Root(url: URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Yedekler", isDirectory: true),
                            coordinated: false)
            }
            #endif
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            return Root(url: container.appendingPathComponent("Yedekler", isDirectory: true), coordinated: true)
        case .folder:
            var stale = false
            guard let data = target.bookmark,
                  let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { return nil }
            // Klasör taşınmış ya da sağlayıcı güncellenmiş: imi yenile ki sonraki açılışlarda da çözülsün
            if stale, let fresh = try? url.bookmarkData() {
                UserDefaults.standard.set(fresh, forKey: Key.bookmark)
            }
            // Klasör yerinde mi (USB çıkarılmış, sunucu kapalı, uygulama silinmiş olabilir)
            guard (try? url.checkResourceIsReachable()) == true else {
                url.stopAccessingSecurityScopedResource()
                return nil
            }
            return Root(url: url.appendingPathComponent("OpenLeaf Yedekleri", isDirectory: true), coordinated: true, scope: url)
        }
    }

    /// Neyin kopyalandığını tutan dosya; her yer için ayrı
    nonisolated private static func stateURL(_ destination: Destination) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yedek-durum-\(destination.rawValue).json")
    }

    private func background<T>(on queue: DispatchQueue = .global(qos: .utility), _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Ayarlar

    func setEnabled(_ on: Bool) {
        markAsked()
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Key.enabled)
        if on {
            status = isAvailable ? .idle : .unavailable
            backUpNow()
        } else {
            timer?.cancel()
            timer = nil
            status = .off
        }
    }

    /// Soru soruldu (kullanıcı ne dediyse)
    func markAsked() {
        guard !asked else { return }
        asked = true
        defaults.set(true, forKey: Key.asked)
    }

    func useICloud() {
        switchTo(.icloud)
    }

    /// Dosyalar penceresinden seçilen klasörü yedek yeri yapar. Klasöre kalıcı erişim alınamazsa false döner.
    @discardableResult
    func useFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else { return false }
        defaults.set(data, forKey: Key.bookmark)
        // Dosyalar'da görünen ad (ör. "iPad'imde"); kök klasörlerin dosya adı anlamsız olabiliyor
        folderName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        defaults.set(folderName, forKey: Key.folderName)
        // Yeni klasöre her şey baştan kopyalanır
        try? FileManager.default.removeItem(at: Self.stateURL(.folder))
        switchTo(.folder, force: true)
        return true
    }

    /// Daha önce seçilmiş klasöre geri döner
    func useSavedFolder() {
        guard defaults.data(forKey: Key.bookmark) != nil else { return }
        switchTo(.folder)
    }

    private func switchTo(_ new: Destination, force: Bool = false) {
        guard force || new != destination else { return }
        destination = new
        defaults.set(new.rawValue, forKey: Key.destination)
        // Önceki yerdeki yedek silinmez; yeni yerin kendi "son yedek" zamanı olur
        lastBackup = nil
        defaults.removeObject(forKey: Key.last)
        found = []
        searched = false
        uploading = false
        dirty = true
        refresh(thenBackUp: true)
    }

    // MARK: Yaşam döngüsü

    /// Uygulama açılınca: yer erişilebilir mi bak, yedekleri ara, açıksa bir yedek al
    func start() {
        guard !started else { return }
        started = true
        var usesTestRoot = false
        #if DEBUG
        usesTestRoot = Self.testRoot != nil
        #endif
        if !usesTestRoot {
            // Yeni kurulumda iCloud'un dosya listesi gecikmeli gelir: gelince haber al
            search = BackupSearch { [weak self] in self?.refresh() }
            search?.start()
        }
        refresh(thenBackUp: true)
    }

    /// Yerin durumunu ve orada bulunan yedekleri yeniler
    func refresh(thenBackUp: Bool = false) {
        // İnmemiş bir dosya beklenirken aramalar üst üste binmesin
        if refreshing {
            refreshAgain = true
            if thenBackUp { backUpNow() }
            return
        }
        refreshing = true
        let device = deviceID
        let target = target
        Task {
            let result = await background { () -> (available: Bool, found: [Found], uploading: Bool, iCloud: Bool) in
                guard let root = Self.open(target) else { return (false, [], false, Self.hasICloud) }
                defer { root.close() }
                let list = BackupEngine.listBackups(in: root.url, coordinated: root.coordinated).map {
                    Found(folder: $0.url.lastPathComponent, info: $0.info, isThisDevice: $0.url.lastPathComponent == device)
                }
                let uploading = target.destination == .icloud
                    && Self.isUploading(root.url.appendingPathComponent(device, isDirectory: true))
                return (true, list, uploading, Self.hasICloud)
            }
            // Arama sürerken yer değiştirildiyse bu sonuç eskidir
            if target.destination == destination {
                isAvailable = result.available
                found = result.found
                uploading = result.uploading
                searched = true
                if enabled, !running {
                    if !isAvailable { status = .unavailable } else if status == .unavailable || status == .off { status = .idle }
                }
            }
            iCloudAvailable = result.iCloud
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
            if thenBackUp { backUpNow() }
        }
    }

    /// Yedeğin dizini iCloud'a henüz yüklenmediyse true
    nonisolated private static func isUploading(_ backup: URL) -> Bool {
        for name in [BackupEngine.infoName, BackupEngine.indexName] {
            let url = backup.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemIsUploaded == false { return true }
        }
        return false
    }

    // MARK: Yedekleme

    /// Kütüphanede bir şey değişti: yazma durulunca yedekle
    func noteChange() {
        guard enabled else { return }
        let now = Date()
        dirty = true
        lastChange = now
        if firstChange == nil { firstChange = now }
        if timer == nil { schedule(after: Self.quietDelay) }
    }

    private func schedule(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.timerFired() }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func timerFired() {
        timer = nil
        guard enabled, dirty, let last = lastChange, let first = firstChange else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(last)
        if quiet >= Self.quietDelay || now.timeIntervalSince(first) >= Self.longestWait {
            backUpNow()
        } else {
            schedule(after: Self.quietDelay - quiet)
        }
    }

    /// Uygulama arka plana geçerken: bekleyen değişiklik varsa hemen yedekle
    func backUpIfNeeded(inBackground: Bool) {
        if dirty || lastBackup == nil { backUpNow(inBackground: inBackground) }
    }

    func backUpNow(inBackground: Bool = false) {
        guard enabled else { return }
        if running {
            again = true
            return
        }
        running = true
        status = .running
        timer?.cancel()
        timer = nil
        dirty = false
        firstChange = nil

        let deleted = DeletedNotebooks.all
        let store = library.store
        let device = deviceID
        let target = target
        let info = BackupEngine.DeviceInfo(
            id: device,
            name: UIDevice.current.name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            date: Date(),
            notebookCount: library.notebooks.filter { !$0.trashed }.count)

        // Arka planda iOS'un verdiği süre dolarsa yarıda bırak; sonraki yedek kaldığı yerden sürer
        let cancel = CancelFlag()
        var task = UIBackgroundTaskIdentifier.invalid
        if inBackground {
            task = UIApplication.shared.beginBackgroundTask(withName: "OpenLeaf yedek") { cancel.set() }
        }

        Task {
            let result = await background(on: queue) { () -> Result<BackupEngine.Outcome?, Error> in
                guard let root = Self.open(target) else { return .failure(BackupError.unavailable) }
                defer { root.close() }
                // Sırada bekleyen yazmalar bitsin
                store.flush()
                let engine = BackupEngine(source: store.root,
                                          destination: root.url.appendingPathComponent(device, isDirectory: true),
                                          stateURL: Self.stateURL(target.destination), coordinated: root.coordinated)
                return Result { try engine.backUp(info: info, deleted: deleted) { cancel.isSet } }
            }
            running = false
            let current = target.destination == destination
            switch result {
            case .success(let outcome):
                // nil: yerel dizin okunamadı, hiçbir şeye dokunulmadı
                if outcome != nil, current {
                    DeletedNotebooks.remove(deleted)
                    let now = Date()
                    lastBackup = now
                    defaults.set(now, forKey: Key.last)
                }
                status = enabled ? .idle : .off
            case .failure(BackupEngine.Failure.cancelled):
                dirty = true
                status = enabled ? .idle : .off
            case .failure(BackupError.unavailable):
                dirty = true
                if current { isAvailable = false }
                status = enabled ? .unavailable : .off
            case .failure(let error):
                dirty = true
                status = enabled ? .failed(error.localizedDescription) : .off
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            if again || !current {
                again = false
                backUpNow()
            } else {
                refresh()
            }
        }
    }

    // MARK: Geri yükleme

    /// Yedekteki, bu iPad'de olmayan defterleri geri getirir. Var olan defterlere ve dosyalara dokunmaz.
    func restore(_ backup: Found) async throws -> RestoreResult {
        guard restoreProgress == nil else { return RestoreResult() }
        restoreProgress = 0
        defer { restoreProgress = nil }

        let target = target
        let folder = backup.folder
        let raw = await background { () -> (index: Data, folders: Data?)? in
            guard let root = Self.open(target) else { return nil }
            defer { root.close() }
            return try? BackupEngine.readIndex(at: root.url.appendingPathComponent(folder, isDirectory: true),
                                               coordinated: root.coordinated)
        }
        // Tanınmayan tek bir defter (daha yeni sürümün yedeği) bütün yedeği okunamaz yapmasın
        guard let raw, let list = (try? JSONDecoder().decode(LossyList<Notebook>.self, from: raw.index))?.items else {
            throw BackupError.unreadable
        }
        let folders = raw.folders.flatMap { try? JSONDecoder().decode(LossyList<Folder>.self, from: $0) }?.items ?? []

        let existing = Set(library.notebooks.map(\.id))
        let missing = list.filter { !existing.contains($0.id) }
        var result = RestoreResult(skipped: list.count - missing.count)
        var ready: [Notebook] = []
        let store = library.store
        for (i, nb) in missing.enumerated() {
            let id = nb.id
            let dir = store.dir(id)
            let ok = await background { () -> Bool in
                guard let root = Self.open(target) else { return false }
                defer { root.close() }
                let existed = FileManager.default.fileExists(atPath: dir.path)
                do {
                    try BackupEngine.restoreNotebook(id, from: root.url.appendingPathComponent(folder, isDirectory: true),
                                                     to: dir, coordinated: root.coordinated)
                    return true
                } catch {
                    // Yarım kalan defter eklenmez; klasörü biz açtıysak geri al
                    if !existed { try? FileManager.default.removeItem(at: dir) }
                    return false
                }
            }
            if ok { ready.append(nb) } else { result.failed += 1 }
            restoreProgress = Double(i + 1) / Double(missing.count)
        }
        result.added = library.addMissing(ready, folders: folders)
        if result.failed > 0, result.added == 0 { throw BackupError.unreadable }
        // Geri yükleyen kişi yedeği kullanıyor demektir: bu cihaz da yedeklenmeye başlasın
        if enabled { backUpNow() } else { setEnabled(true) }
        return result
    }

    /// Başka bir cihazın (ya da eski bir kurulumun) yedeğini siler
    func delete(_ backup: Found) async {
        guard !backup.isThisDevice else { return }
        let target = target
        let folder = backup.folder
        await background {
            guard let root = Self.open(target) else { return }
            defer { root.close() }
            try? BackupEngine.deleteBackup(at: root.url.appendingPathComponent(folder, isDirectory: true),
                                           coordinated: root.coordinated)
        }
        found.removeAll { $0.id == backup.id }
        refresh()
    }
}

/// İş parçacıkları arasında paylaşılan "yarıda bırak" işareti
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// iCloud kapsayıcısında cihaz yedeklerini (cihaz.json) arar ve liste değişince haber verir.
/// Yeni kurulumda dosya listesi hemen gelmez; bu sorgu geldiği anda yakalar ve dosyayı indirtir.
private final class BackupSearch: NSObject {
    private let query = NSMetadataQuery()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, BackupEngine.infoName)
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: query)
        }
    }

    func start() { query.start() }

    @objc private func changed() {
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        query.enableUpdates()
        onChange()
    }

    deinit {
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }
}
