import SwiftUI
import UniformTypeIdentifiers

/// Tüm kütüphanenin tek dosyalık yedeği: defter dizini + her defterin klasöründeki dosyalar
/// (mürekkep, PDF, aranabilir metin). Küçük resimler alınmaz; geri yüklenince yeniden üretilir.
struct LibraryBackup: Codable {
    var version = 1
    var created = Date()
    var notebooks: [Notebook]
    /// Klasörler (eski yedeklerde yok)
    var folders: [Folder]? = nil
    /// "<defter-id>/<dosya-adı>" → içerik
    var files: [String: Data]

    static let fileExtension = "openleafyedek"
}

extension Library {
    enum BackupError: LocalizedError {
        case unreadable
        var errorDescription: String? { String(localized: "Bu dosya bir OpenLeaf yedeği değil ya da bozuk.") }
    }

    /// Bekleyen kayıtları yazıp tüm kütüphaneyi tek bir veriye paketler
    func makeBackup() throws -> Data {
        flush()
        let fm = FileManager.default
        var files: [String: Data] = [:]
        for nb in notebooks {
            let dir = store.dir(nb.id)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name != "thumb.png" {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                    files["\(nb.id.uuidString)/\(name)"] = data
                }
            }
        }
        let backup = LibraryBackup(notebooks: notebooks, folders: folders, files: files)
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        return try enc.encode(backup)
    }

    /// Yedekteki, bu iPad'de olmayan defterleri ekler. Aynı defter zaten varsa dokunulmaz.
    func restoreBackup(from url: URL) throws -> (added: Int, skipped: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let backup = try? PropertyListDecoder().decode(LibraryBackup.self, from: data) else {
            throw BackupError.unreadable
        }
        let existing = Set(notebooks.map(\.id))
        let fresh = backup.notebooks.filter { !existing.contains($0.id) }
        for nb in fresh {
            store.createDir(nb.id)
            let prefix = nb.id.uuidString + "/"
            for (path, content) in backup.files where path.hasPrefix(prefix) {
                let name = String(path.dropFirst(prefix.count))
                // Yalnızca düz dosya adlarına izin ver (klasör dışına yazılmasın)
                guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { continue }
                store.writeFile(content, to: store.dir(nb.id).appendingPathComponent(name))
            }
        }
        flush()
        let added = addMissing(fresh, folders: backup.folders ?? [])
        return (added, backup.notebooks.count - fresh.count)
    }

    /// Bu iPad'de olmayan defterleri ve klasörleri kütüphaneye ekler; var olanlara dokunmaz.
    /// Defterlerin dosyaları önceden klasörlerine konmuş olmalı. Eklenen defter sayısını döner.
    @discardableResult
    func addMissing(_ list: [Notebook], folders incoming: [Folder]) -> Int {
        let knownFolders = Set(folders.map(\.id))
        let newFolders = incoming.filter { !knownFolders.contains($0.id) }
        if !newFolders.isEmpty {
            folders.append(contentsOf: newFolders)
            saveFolders()
        }
        let existing = Set(notebooks.map(\.id))
        let fresh = list.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        for nb in fresh {
            store.createDir(nb.id)
            notebooks.append(nb)
        }
        // Geri gelen defter artık "silinmiş" sayılmaz
        DeletedNotebooks.remove(fresh.map(\.id))
        save()
        fresh.forEach { scheduleThumbnail($0.id, delay: 0.3) }
        return fresh.count
    }
}

/// Dosyalar'a kaydedilecek yedek dosyası
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return String(localized: "OpenLeaf Yedek \(f.string(from: Date()))") + ".\(LibraryBackup.fileExtension)"
    }
}
