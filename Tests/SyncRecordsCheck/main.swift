// SyncRecords için Mac üzerinde gidiş-dönüş denetimi (hesap gerekmez)
import Foundation
import CloudKit

var failed = false
func check(_ ok: Bool, _ msg: String) { if !ok { print("HATA: \(msg)"); failed = true } }

let nbID = UUID(), pgID = UUID()
let nb = SyncNotebookMeta(id: nbID, title: "T", subtitle: "", kind: "note", cover: "c", paper: "p", size: "a4",
    favorite: true, trashed: false, folder: nil, created: Date(timeIntervalSince1970: 100),
    modified: Date(timeIntervalSince1970: 200), pdfAspect: nil, pdfFile: nil, pdfHash: nil, pageOrder: [pgID])
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID()).bin")
try! Data([1, 2, 3]).write(to: tmp)

let r = SyncRecords.record(notebook: nb, pdf: tmp, fields: nil)
check(SyncRecords.notebook(r)?.0 == nb, "defter meta")
check(SyncRecords.notebook(r)?.pdf != nil, "pdf varlığı")
let f = SyncRecords.encodeFields(r)
let r2 = SyncRecords.record(notebook: nb, pdf: nil, fields: f)
check(r2.recordID == r.recordID && r2.recordID.zoneID == SyncRecords.zoneID, "fields recordName")
check(SyncRecords.notebook(r2)?.pdf == nil, "pdf nil")

let pg = SyncPageMeta(id: pgID, notebook: nbID, pdfPage: 2, bookmarked: false, mark: nil, notes: [], images: [], tapes: [], inkHash: "x")
let pr = SyncRecords.record(page: pg, ink: nil, fields: nil)
check(SyncRecords.page(pr)?.0 == pg && SyncRecords.page(pr)?.ink == nil, "sayfa")
check((pr["notebook"] as? CKRecord.Reference)?.recordID.recordName == nbID.uuidString, "sayfa referansı")

let fo = SyncFolderMeta(id: UUID(), name: "K", created: Date(timeIntervalSince1970: 5))
check(SyncRecords.folder(SyncRecords.record(folder: fo, fields: nil)) == fo, "klasör")

let fr = SyncRecords.record(file: tmp, notebook: nbID, name: "img-1.jpg", fields: nil)
let fp = SyncRecords.file(fr)
check(fp?.notebook == nbID && fp?.name == "img-1.jpg", "dosya")
let bad = CKRecord(recordType: "File", recordID: CKRecord.ID(recordName: "\(nbID.uuidString)/a/b.jpg", zoneID: SyncRecords.zoneID))
bad["data"] = CKAsset(fileURL: tmp)
check(SyncRecords.file(bad) == nil, "kötü ad")
let bad2 = CKRecord(recordType: "File", recordID: CKRecord.ID(recordName: "\(nbID.uuidString)/x.txt", zoneID: SyncRecords.zoneID))
bad2["data"] = CKAsset(fileURL: tmp)
check(SyncRecords.file(bad2) == nil, "kötü ad 2")
let junk = CKRecord(recordType: "Notebook", recordID: CKRecord.ID(recordName: "z", zoneID: SyncRecords.zoneID))
junk["meta"] = Data([0xff])
check(SyncRecords.notebook(junk) == nil, "bozuk meta")

SyncRecords.cleanUpOutgoingAssets()
check(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("OpenLeaf-Gonderim").path), "temizlik")
print(failed ? "BAŞARISIZ" : "TAMAM")
exit(failed ? 1 : 0)
