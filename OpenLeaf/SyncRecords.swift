// İCloud eşitleme: üst veri türleri ile CloudKit kayıtları arasındaki dönüşüm.
// CloudKit yalnızca bu dosyada içe aktarılır; ağ işlemi yapmaz.

import Foundation
import CloudKit

enum SyncRecords {
    static let zoneID = CKRecordZone.ID(zoneName: "OpenLeaf")

    static let notebookType = "Notebook"
    static let pageType = "Page"
    static let folderType = "Folder"
    static let fileType = "File"

    // MARK: Kodlama yardımcıları

    private static func encodeMeta<T: Encodable>(_ meta: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(meta)
    }

    private static func decodeMeta<T: Decodable>(_ type: T.Type, from r: CKRecord) -> T? {
        guard let data = r["meta"] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Kayıtlı sistem alanlarından kaydı kurar; yoksa bölgede yeni kayıt açar
    private static func makeRecord(type: String, name: String, fields: Data?) -> CKRecord {
        if let fields,
           let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            if let r = CKRecord(coder: coder), r.recordType == type {
                coder.finishDecoding()
                return r
            }
            coder.finishDecoding()
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    static func encodeFields(_ r: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    // MARK: Gönderim için geçici kopya

    private static var outgoingDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenLeaf-Gonderim", isDirectory: true)
    }

    /// Yerel dosya yükleme sırasında değişebilir; benzersiz adlı geçici kopyayı verir
    private static func outgoingAsset(_ url: URL) -> CKAsset? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outgoingDir, withIntermediateDirectories: true)
            let copy = outgoingDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.copyItem(at: url, to: copy)
            return CKAsset(fileURL: copy)
        } catch {
            return nil
        }
    }

    /// Gönderim turu bitince denetleyici çağırır
    static func cleanUpOutgoingAssets() {
        try? FileManager.default.removeItem(at: outgoingDir)
    }

    // MARK: Kayıt oluşturma

    static func record(notebook meta: SyncNotebookMeta, pdf: URL?, fields: Data?) -> CKRecord {
        let r = makeRecord(type: notebookType, name: meta.id.uuidString, fields: fields)
        r["meta"] = encodeMeta(meta)
        r["pdf"] = pdf.flatMap(outgoingAsset)
        return r
    }

    /// Çizim boşsa `ink` nil verilir; alan boşaltılır, karşı taraf boş mürekkep sayar
    static func record(page meta: SyncPageMeta, ink: URL?, fields: Data?) -> CKRecord {
        let r = makeRecord(type: pageType, name: meta.id.uuidString, fields: fields)
        r["meta"] = encodeMeta(meta)
        r["notebook"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: meta.notebook.uuidString, zoneID: zoneID),
            action: .none)
        r["ink"] = ink.flatMap(outgoingAsset)
        return r
    }

    static func record(folder meta: SyncFolderMeta, fields: Data?) -> CKRecord {
        let r = makeRecord(type: folderType, name: meta.id.uuidString, fields: fields)
        r["meta"] = encodeMeta(meta)
        return r
    }

    static func record(file: URL, notebook: UUID, name: String, fields: Data?) -> CKRecord {
        let r = makeRecord(type: fileType, name: "\(notebook.uuidString)/\(name)", fields: fields)
        r["notebook"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: notebook.uuidString, zoneID: zoneID),
            action: .none)
        r["data"] = outgoingAsset(file)
        return r
    }

    // MARK: Kayıttan okuma (varlık URL'si olduğu gibi döner; denetleyici hemen okur)

    static func notebook(_ r: CKRecord) -> (SyncNotebookMeta, pdf: URL?)? {
        guard r.recordType == notebookType,
              let meta = decodeMeta(SyncNotebookMeta.self, from: r) else { return nil }
        return (meta, (r["pdf"] as? CKAsset)?.fileURL)
    }

    static func page(_ r: CKRecord) -> (SyncPageMeta, ink: URL?)? {
        guard r.recordType == pageType,
              let meta = decodeMeta(SyncPageMeta.self, from: r) else { return nil }
        return (meta, (r["ink"] as? CKAsset)?.fileURL)
    }

    static func folder(_ r: CKRecord) -> SyncFolderMeta? {
        guard r.recordType == folderType else { return nil }
        return decodeMeta(SyncFolderMeta.self, from: r)
    }

    static func file(_ r: CKRecord) -> (notebook: UUID, name: String, url: URL)? {
        guard r.recordType == fileType,
              let url = (r["data"] as? CKAsset)?.fileURL else { return nil }
        let parts = r.recordID.recordName.components(separatedBy: "/")
        guard parts.count == 2, let nb = UUID(uuidString: parts[0]) else { return nil }
        let name = parts[1]
        let isImage = name.hasPrefix("img-") && name.hasSuffix(".jpg") && name.count > 8
        guard isImage || name == "source.pdf" else { return nil }
        return (nb, name, url)
    }
}
