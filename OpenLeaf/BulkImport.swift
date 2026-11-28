import Foundation

// MARK: - Toplu içe aktarma
//
// Başka not uygulamalarından taşınma: bir ZIP (ör. GoodNotes klasör dışa aktarımı), bir klasör ya da
// birden çok PDF. Her PDF bir defter olur; ilk seviye alt klasörler OpenLeaf klasörü olur.

struct ImportItem: Equatable {
    let pdf: URL
    /// Defterin gireceği OpenLeaf klasörünün adı; nil ise o an seçili klasör (ya da klasörsüz)
    let folderName: String?
}

enum ImportPlan {
    /// `root` altındaki PDF'leri bulur ve her birine klasör adı eşler.
    ///
    /// - Klasör adı kökten sonraki ilk bileşendir (OpenLeaf klasörleri düz; daha derindekiler ona katılır).
    /// - Kökteki PDF'ler `rootFolder` adını alır.
    /// - Kökte yalnız tek bir klasör varsa o bir sarmalayıcıdır: içinde alt klasör varsa adı yok sayılır,
    ///   yoksa (tek klasör dışa aktarımı) kökteki PDF'ler onun adını alır.
    static func items(in root: URL, rootFolder: String? = nil) -> [ImportItem] {
        scan(in: root, rootFolder: rootFolder).items
    }

    /// `items(in:)` ile aynı; ayrıca PDF olmayan dosyaların adlarını (`skipped`) döndürür ki özette görünsün.
    static func scan(in root: URL, rootFolder: String? = nil) -> (items: [ImportItem], skipped: [String]) {
        let top = visibleChildren(root)
        if top.count == 1, isDirectory(top[0]) {
            let wrapper = top[0]
            let hasSubfolders = visibleChildren(wrapper).contains(where: isDirectory)
            return collect(wrapper, rootFolder: hasSubfolders ? rootFolder : wrapper.lastPathComponent)
        }
        return collect(root, rootFolder: rootFolder)
    }

    private static func collect(_ base: URL, rootFolder: String?) -> (items: [ImportItem], skipped: [String]) {
        let fm = FileManager.default
        let baseParts = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return ([], []) }
        var found: [(rel: String, item: ImportItem)] = []
        var skipped: [(rel: String, name: String)] = []
        for case let url as URL in walker {
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard parts.count > baseParts.count, Array(parts.prefix(baseParts.count)) == baseParts else { continue }
            let relParts = Array(parts.dropFirst(baseParts.count))
            let rel = relParts.joined(separator: "/")
            if ZipReader.isJunk(rel) || relParts.contains(where: { $0.hasPrefix(".") }) {
                if isDirectory(url) { walker.skipDescendants() }
                continue
            }
            if isDirectory(url) { continue }
            guard url.pathExtension.lowercased() == "pdf" else {
                skipped.append((rel, url.lastPathComponent))
                continue
            }
            let folder = relParts.count > 1 ? relParts[0] : rootFolder
            found.append((rel, ImportItem(pdf: url, folderName: folder)))
        }
        let order = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return (found.sorted { order($0.rel, $1.rel) }.map(\.item), skipped.sorted { order($0.rel, $1.rel) }.map(\.name))
    }

    private static func visibleChildren(_ dir: URL) -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return list.filter { !$0.lastPathComponent.hasPrefix(".") && !ZipReader.isJunk($0.lastPathComponent + (isDirectory($0) ? "/" : "")) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}

struct ImportSummary {
    var imported: [UUID] = []
    /// Aktarılamayan dosyaların adları
    var skipped: [String] = []
}

/// Ayrık göreve iptal iletmek için iş parçacığı güvenli bayrak
private final class ImportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

#if canImport(UIKit)
extension Library {
    /// Kaynakları (PDF, ZIP, klasör) sırayla içe aktarır. Bozuk dosyalar atlanır, aktarım sürer.
    /// `progress(bitmiş, toplam)`: toplam henüz bilinmiyorsa 0 (ZIP açılıyor).
    /// İptal edilirse o ana dek açılan defterler kalır; geçici dosyalar her durumda silinir.
    func importBatch(_ sources: [URL], into folder: UUID?, progress: @escaping (Int, Int) -> Void) async -> ImportSummary {
        let fm = FileManager.default
        var summary = ImportSummary()
        var temps: [URL] = []
        var scoped: [URL] = []
        defer {
            for t in temps { try? fm.removeItem(at: t) }
            for s in scoped { s.stopAccessingSecurityScopedResource() }
        }

        progress(0, 0)
        var items: [ImportItem] = []
        for src in sources {
            if Task.isCancelled { return summary }
            if src.startAccessingSecurityScopedResource() { scoped.append(src) }
            if ImportPlan.isDirectory(src) {
                // Klasör taraması (File Provider'da yavaş olabilir) ana iş parçacığını tutmasın
                let scan = await Task.detached(priority: .userInitiated) { ImportPlan.scan(in: src, rootFolder: src.lastPathComponent) }.value
                items += scan.items
                summary.skipped += scan.skipped
            } else if src.pathExtension.lowercased() == "zip" {
                let tmp = fm.temporaryDirectory.appendingPathComponent("ice-aktar-" + UUID().uuidString)
                temps.append(tmp)
                // Ayrık görev iptali devralmaz: bayrakla ilet ki "Vazgeç" açma sırasında da çalışsın
                let flag = ImportCancelFlag()
                let result = await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) { () -> (items: [ImportItem], skipped: [String]) in
                        let r = ZipReader.extractAll(src, to: tmp, isCancelled: { flag.isSet })
                        let scan = ImportPlan.scan(in: tmp)
                        return (scan.items, r.failed.map { ($0 as NSString).lastPathComponent } + scan.skipped)
                    }.value
                } onCancel: { flag.set() }
                if Task.isCancelled { return summary }
                items += result.items
                summary.skipped += result.skipped
            } else if src.pathExtension.lowercased() == "pdf" {
                items.append(ImportItem(pdf: src, folderName: nil))
            } else {
                summary.skipped.append(src.lastPathComponent)
            }
        }

        // Aynı adlı klasör varsa onu kullan; yoksa ilk defter girdikten sonra aç (boş klasör kalmasın)
        var folderIDs: [String: UUID] = [:]
        func existingFolder(_ name: String) -> UUID? {
            let key = name.lowercased()
            if let id = folderIDs[key] { return id }
            let id = folders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            folderIDs[key] = id
            return id
        }

        progress(0, items.count)
        for (i, item) in items.enumerated() {
            if Task.isCancelled { break }
            do {
                let target = item.folderName.map(existingFolder) ?? folder
                let id = try importPDF(from: item.pdf, folder: target)
                if let name = item.folderName, target == nil {
                    let created = createFolder(name)
                    folderIDs[name.lowercased()] = created
                    move(id, toFolder: created)
                }
                summary.imported.append(id)
            } catch {
                summary.skipped.append(item.pdf.lastPathComponent)
            }
            progress(i + 1, items.count)
            await Task.yield()
        }
        return summary
    }
}
#endif
