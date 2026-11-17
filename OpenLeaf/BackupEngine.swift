import Foundation

/// Yerel depoyu (Belgeler/OpenLeaf) bir yedek klasörüne dosya dosya aynalar ve oradan geri kopyalar.
///
///     <hedef>/
///       cihaz.json                 hangi cihazın yedeği, en son ne zaman değişti
///       index.json                 kütüphane dizini
///       folders.json               klasörler
///       Defterler/<defter-id>/     sayfa mürekkepleri, PDF, metin, resimler (küçük resim alınmaz)
///
/// Hedefin nerede olduğunu bilmez (iCloud, seçilen bir klasör, testte geçici klasör); yalnızca Foundation kullanır.
///
/// Güvenlik kuralları:
/// - Yerel depo yalnızca okunur.
/// - Bir defter yedekten yalnızca `deleted` listesindeyse silinir. Yerel kütüphane boş ya da bozuk gelirse
///   yedekteki defterler ve dizindeki kayıtları yerinde kalır.
/// - Dizin en son yazılır: yarıda kesilen yedek eski dizini geçerli bırakır.
/// - Geri yükleme var olan yerel dosyaların üstüne yazmaz.
struct BackupEngine {
    struct DeviceInfo: Codable, Equatable {
        var format = 1
        var id: String
        var name: String
        var appVersion: String
        /// Yedeğin en son değiştiği an
        var date: Date
        var notebookCount: Int
    }

    struct Outcome: Equatable {
        var copied = 0
        var removed = 0
        var bytes: Int64 = 0
        var changed: Bool { copied > 0 || removed > 0 }
    }

    struct Found: Equatable {
        var url: URL
        var info: DeviceInfo
    }

    enum Failure: Error { case cancelled, backupUnreadable }

    static let indexName = "index.json"
    static let foldersName = "folders.json"
    static let infoName = "cihaz.json"
    static let notebooksName = "Defterler"
    /// Yedeğe alınmayan dosyalar (geri yüklenince yeniden üretilir)
    static let skipped: Set<String> = ["thumb.png"]

    /// Yerel depo kökü (Belgeler/OpenLeaf)
    let source: URL
    /// Bu cihazın yedek klasörü
    let destination: URL
    /// Neyin kopyalandığını tutan, cihazda duran dosya (göreli yol → boyut + değişiklik tarihi)
    let stateURL: URL
    /// iCloud gibi başka süreçlerin de dokunduğu hedeflerde dosya eşgüdümü kullan
    var coordinated = false

    private struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double
    }

    // MARK: Yedekleme

    /// Yereli hedefe aynalar. Yerel dizin okunamıyorsa hiçbir şeye dokunmaz ve nil döner.
    func backUp(info: DeviceInfo, deleted: Set<UUID>, isCancelled: () -> Bool = { false }) throws -> Outcome? {
        let fm = FileManager.default
        let localIndexURL = source.appendingPathComponent(Self.indexName)
        guard let localIndex = try? Data(contentsOf: localIndexURL),
              let localEntries = Self.entries(localIndex) else { return nil }
        let localIDs = localEntries.compactMap(Self.id)
        let localSet = Set(localIDs)
        // Yeniden eklenmiş bir defter silinmiş sayılmaz
        let deletedIDs = Set(deleted.map(\.uuidString)).subtracting(localSet)

        let destIndexURL = destination.appendingPathComponent(Self.indexName)
        let oldIndex = try? Self.read(destIndexURL, coordinated: coordinated)
        // Boş kütüphane için yedek klasörü açma
        if localIDs.isEmpty && oldIndex == nil { return Outcome() }

        // Yedekte olup yerelde olmayan, kullanıcının da silmediği kayıtlar: korunur
        let kept = (oldIndex.flatMap(Self.entries) ?? []).filter { entry in
            guard let id = Self.id(entry) else { return false }
            return !localSet.contains(id) && !deletedIDs.contains(id)
        }

        let temp = fm.temporaryDirectory.appendingPathComponent("yedek-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let oldState = loadState()
        var state: [String: Stamp] = [:]
        var out = Outcome()
        let sourceNotebooks = source.appendingPathComponent(Self.notebooksName, isDirectory: true)
        let destNotebooks = destination.appendingPathComponent(Self.notebooksName, isDirectory: true)

        // 1. Defter dosyaları
        for id in localIDs {
            let srcDir = sourceNotebooks.appendingPathComponent(id, isDirectory: true)
            let dstDir = destNotebooks.appendingPathComponent(id, isDirectory: true)
            // Dizin defteri gösteriyor ama klasörü yoksa yerel bozuk demektir: yedeğine dokunma
            guard fm.fileExists(atPath: srcDir.path) else {
                for (key, stamp) in oldState where key.hasPrefix(id + "/") { state[key] = stamp }
                continue
            }
            let names = Self.fileNames(in: srcDir)
            for name in names {
                let key = id + "/" + name
                let src = srcDir.appendingPathComponent(name)
                guard let stamp = Self.stamp(src) else { continue }
                let dst = dstDir.appendingPathComponent(name)
                if oldState[key] == stamp, fm.fileExists(atPath: dst.path) {
                    state[key] = stamp
                    continue
                }
                if isCancelled() {
                    // Kopyalananları unutma: sonraki yedek kaldığı yerden sürsün
                    saveState(oldState.merging(state) { _, new in new })
                    throw Failure.cancelled
                }
                let staged = temp.appendingPathComponent(UUID().uuidString)
                try fm.copyItem(at: src, to: staged)
                try place(staged, at: dst)
                state[key] = stamp
                out.copied += 1
                out.bytes += stamp.size
            }
            // Sayfası silinmiş ya da mürekkebi tamamen silinmiş dosyalar
            let current = Set(names)
            for name in Self.fileNames(in: dstDir) where !current.contains(name) {
                try remove(dstDir.appendingPathComponent(name))
                out.removed += 1
            }
        }

        // 2. Kullanıcının kalıcı olarak sildiği defterler
        for id in deletedIDs {
            let dir = destNotebooks.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dir.path) {
                try remove(dir)
                out.removed += 1
            }
        }

        // 3. Klasörler ve dizin (dizin en son)
        let localFoldersURL = source.appendingPathComponent(Self.foldersName)
        let destFoldersURL = destination.appendingPathComponent(Self.foldersName)
        var metaChanged = false
        if kept.isEmpty {
            for (name, src, dst) in [(Self.foldersName, localFoldersURL, destFoldersURL),
                                     (Self.indexName, localIndexURL, destIndexURL)] {
                guard let stamp = Self.stamp(src) else { continue }
                if oldState[name] == stamp, fm.fileExists(atPath: dst.path) {
                    state[name] = stamp
                    continue
                }
                let staged = temp.appendingPathComponent(UUID().uuidString)
                try fm.copyItem(at: src, to: staged)
                try place(staged, at: dst)
                state[name] = stamp
                metaChanged = true
            }
        } else {
            // Korunan kayıtlar var: yerel dizinle birleştir
            let oldFolders = (try? Self.read(destFoldersURL, coordinated: coordinated)).flatMap(Self.entries) ?? []
            let localFolders = (try? Data(contentsOf: localFoldersURL)).flatMap(Self.entries) ?? []
            let localFolderIDs = Set(localFolders.compactMap { $0["id"] as? String })
            let folders = localFolders + oldFolders.filter { !localFolderIDs.contains($0["id"] as? String ?? "") }
            for (items, dst, old) in [(folders, destFoldersURL, try? Self.read(destFoldersURL, coordinated: coordinated)),
                                      (localEntries + kept, destIndexURL, oldIndex)] {
                let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
                if data == old { continue }
                let staged = temp.appendingPathComponent(UUID().uuidString)
                try data.write(to: staged)
                try place(staged, at: dst)
                metaChanged = true
            }
        }

        // 4. Cihaz bilgisi: yalnızca bir şey değiştiyse (her yedekte boşuna yükleme olmasın)
        let infoURL = destination.appendingPathComponent(Self.infoName)
        if out.changed || metaChanged || !fm.fileExists(atPath: infoURL.path) {
            let staged = temp.appendingPathComponent(UUID().uuidString)
            try JSONEncoder().encode(info).write(to: staged)
            try place(staged, at: infoURL)
        }

        saveState(state)
        return out
    }

    // MARK: Geri yükleme

    /// Kök klasördeki (…/Yedekler) cihaz yedekleri, en yenisi başta
    static func listBackups(in root: URL, coordinated: Bool) -> [Found] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in readInfo(at: dir, coordinated: coordinated).map { Found(url: dir, info: $0) } }
            .sorted { $0.info.date > $1.info.date }
    }

    static func readInfo(at backup: URL, coordinated: Bool) -> DeviceInfo? {
        guard let data = try? read(backup.appendingPathComponent(infoName), coordinated: coordinated) else { return nil }
        return try? JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    static func readIndex(at backup: URL, coordinated: Bool) throws -> (index: Data, folders: Data?) {
        guard let index = try? read(backup.appendingPathComponent(indexName), coordinated: coordinated) else {
            throw Failure.backupUnreadable
        }
        return (index, try? read(backup.appendingPathComponent(foldersName), coordinated: coordinated))
    }

    /// Bir defterin dosyalarını yerel klasöre kopyalar; var olan yerel dosyalara dokunmaz.
    /// Kopyalanan dosya sayısını döner.
    @discardableResult
    static func restoreNotebook(_ id: UUID, from backup: URL, to localDir: URL, coordinated: Bool,
                                isCancelled: () -> Bool = { false }) throws -> Int {
        let fm = FileManager.default
        let srcDir = backup.appendingPathComponent(notebooksName, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        var count = 0
        for name in fileNames(in: srcDir) {
            let dst = localDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            if isCancelled() { throw Failure.cancelled }
            // Önce yanına kopyala, sonra adını değiştir: yarım dosya hiç görünmesin
            let staged = localDir.appendingPathComponent("." + UUID().uuidString + ".gelen")
            defer { try? fm.removeItem(at: staged) }
            try coordinate(reading: srcDir.appendingPathComponent(name), coordinated: coordinated) { url in
                try fm.copyItem(at: url, to: staged)
            }
            try fm.moveItem(at: staged, to: dst)
            count += 1
        }
        return count
    }

    /// Bir cihaz yedeğini tümüyle siler
    static func deleteBackup(at backup: URL, coordinated: Bool) throws {
        try coordinate(writing: backup, options: .forDeleting, coordinated: coordinated) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Yardımcılar

    /// JSON dizisinin öğeleri (dizin ve klasör dosyaları `[{ "id": … }]` biçiminde)
    private static func entries(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Kaydın kimliği; yalnızca gerçek bir UUID ise (klasör adı olarak kullanılıyor)
    private static func id(_ entry: [String: Any]) -> String? {
        (entry["id"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
    }

    /// Klasördeki yedeklenebilir düz dosyaların adları. Alt klasörler, gizli dosyalar ve küçük resim alınmaz.
    /// Henüz inmemiş iCloud dosyaları eski biçimde ".ad.icloud" olarak görünebilir; gerçek adına çevrilir.
    private static func fileNames(in dir: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var names: Set<String> = []
        for url in items {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            if name.isEmpty || name.hasPrefix(".") || skipped.contains(name) { continue }
            names.insert(name)
        }
        return names.sorted()
    }

    private static func stamp(_ url: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.int64Value,
              let date = a[.modificationDate] as? Date else { return nil }
        return Stamp(size: size, modified: date.timeIntervalSinceReferenceDate)
    }

    private func loadState() -> [String: Stamp] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Stamp].self, from: data)) ?? [:]
    }

    private func saveState(_ state: [String: Stamp]) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// Hazırlanmış dosyayı hedefteki yerine koyar (varsa eskisinin yerine)
    private func place(_ staged: URL, at dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coordinate(writing: dst, options: .forReplacing, coordinated: coordinated) { url in
            guard fm.fileExists(atPath: url.path) else { return try fm.moveItem(at: staged, to: url) }
            do {
                _ = try fm.replaceItemAt(url, withItemAt: staged)
            } catch {
                // Başka bir birimdeki hedefte yer değiştirme çalışmayabilir
                try fm.removeItem(at: url)
                try fm.moveItem(at: staged, to: url)
            }
        }
    }

    private func remove(_ url: URL) throws {
        try Self.coordinate(writing: url, options: .forDeleting, coordinated: coordinated) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func read(_ url: URL, coordinated: Bool) throws -> Data {
        var data = Data()
        try coordinate(reading: url, coordinated: coordinated) { data = try Data(contentsOf: $0) }
        return data
    }

    /// Eşgüdümlü okuma: dosya iCloud'dan inmemişse inmesini bekler
    private static func coordinate(reading url: URL, coordinated: Bool, _ body: (URL) throws -> Void) throws {
        guard coordinated else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, coordinated: Bool,
                                   _ body: (URL) throws -> Void) throws {
        guard coordinated else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}
