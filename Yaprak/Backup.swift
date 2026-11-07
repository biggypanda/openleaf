import SwiftUI
import UniformTypeIdentifiers

/// Tüm kütüphanenin tek dosyalık yedeği: defter dizini + her defterin klasöründeki dosyalar
/// (mürekkep, PDF, aranabilir metin). Küçük resimler alınmaz; geri yüklenince yeniden üretilir.
struct LibraryBackup: Codable {
    var version = 1
    var created = Date()
    var notebooks: [Notebook]
    /// "<defter-id>/<dosya-adı>" → içerik
    var files: [String: Data]

    static let fileExtension = "yaprakyedek"
}

extension Library {
    enum BackupError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Bu dosya bir Yaprak yedeği değil ya da bozuk." }
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
        let backup = LibraryBackup(notebooks: notebooks, files: files)
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
        var added = 0, skipped = 0
        for nb in backup.notebooks {
            if existing.contains(nb.id) { skipped += 1; continue }
            store.createDir(nb.id)
            let prefix = nb.id.uuidString + "/"
            for (path, content) in backup.files where path.hasPrefix(prefix) {
                let name = String(path.dropFirst(prefix.count))
                // Yalnızca düz dosya adlarına izin ver (klasör dışına yazılmasın)
                guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { continue }
                store.writeFile(content, to: store.dir(nb.id).appendingPathComponent(name))
            }
            notebooks.append(nb)
            added += 1
        }
        save()
        flush()
        backup.notebooks.filter { !existing.contains($0.id) }.forEach { scheduleThumbnail($0.id, delay: 0.3) }
        return (added, skipped)
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
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "yyyy-MM-dd"
        return "Yaprak Yedek \(f.string(from: Date())).\(LibraryBackup.fileExtension)"
    }
}
