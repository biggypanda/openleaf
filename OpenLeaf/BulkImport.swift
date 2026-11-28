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
        let top = visibleChildren(root)
        if top.count == 1, isDirectory(top[0]) {
            let wrapper = top[0]
            let hasSubfolders = visibleChildren(wrapper).contains(where: isDirectory)
            return collect(wrapper, rootFolder: hasSubfolders ? rootFolder : wrapper.lastPathComponent)
        }
        return collect(root, rootFolder: rootFolder)
    }

    private static func collect(_ base: URL, rootFolder: String?) -> [ImportItem] {
        let fm = FileManager.default
        let baseParts = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [(rel: String, item: ImportItem)] = []
        for case let url as URL in walker {
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard parts.count > baseParts.count, Array(parts.prefix(baseParts.count)) == baseParts else { continue }
            let relParts = Array(parts.dropFirst(baseParts.count))
            let rel = relParts.joined(separator: "/")
            if ZipReader.isJunk(rel) || relParts.contains(where: { $0.hasPrefix(".") }) {
                if isDirectory(url) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "pdf", !isDirectory(url) else { continue }
            let folder = relParts.count > 1 ? relParts[0] : rootFolder
            found.append((rel, ImportItem(pdf: url, folderName: folder)))
        }
        return found.sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }.map(\.item)
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
                items += ImportPlan.items(in: src, rootFolder: src.lastPathComponent)
            } else if src.pathExtension.lowercased() == "zip" {
                let tmp = fm.temporaryDirectory.appendingPathComponent("ice-aktar-" + UUID().uuidString)
                temps.append(tmp)
                let result = await Task.detached(priority: .userInitiated) { ZipReader.extractAll(src, to: tmp) }.value
                summary.skipped += result.failed.map { ($0 as NSString).lastPathComponent }
                items += ImportPlan.items(in: tmp)
            } else if src.pathExtension.lowercased() == "pdf" {
                items.append(ImportItem(pdf: src, folderName: nil))
            } else {
                summary.skipped.append(src.lastPathComponent)
            }
        }

        // Aynı adlı klasör varsa onu kullan; yoksa ilk defter girerken aç (boş klasör kalmasın)
        var folderIDs: [String: UUID] = [:]
        func folderID(_ name: String) -> UUID {
            let key = name.lowercased()
            if let id = folderIDs[key] { return id }
            let id = folders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id ?? createFolder(name)
            folderIDs[key] = id
            return id
        }

        progress(0, items.count)
        for (i, item) in items.enumerated() {
            if Task.isCancelled { break }
            do {
                let id = try importPDF(from: item.pdf)
                if let name = item.folderName {
                    move(id, toFolder: folderID(name))
                } else if let folder {
                    move(id, toFolder: folder)
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
