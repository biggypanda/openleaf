// İCloud eşitleme saf mantığının denetimi. Uygulama hedefinde değildir; Mac'te derlenip çalıştırılır:
//
//   swiftc OpenLeaf/SyncMerge.swift OpenLeaf/SyncState.swift Tests/SyncCheck/main.swift -o "$TMPDIR/esitleme-test" && "$TMPDIR/esitleme-test"
//
// Biri kalırsa çıkış kodu 1 olur.

import Foundation

var failures = 0

struct Fail: Error, CustomStringConvertible { let description: String }

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
    if try !condition() { throw Fail(description: "\(message) (satır \(line))") }
}

func check(_ name: String, _ body: () throws -> Void) {
    do { try body(); print("GEÇTİ  \(name)") } catch { failures += 1; print("KALDI  \(name): \(error)") }
}

// MARK: Yardımcılar

let t0 = Date(timeIntervalSince1970: 1_000)
let t1 = Date(timeIntervalSince1970: 2_000)
let t2 = Date(timeIntervalSince1970: 3_000)

func nb(_ id: UUID, title: String = "Defter", favorite: Bool = false, modified: Date = t0, order: [UUID] = []) -> SyncNotebookMeta {
    SyncNotebookMeta(id: id, title: title, subtitle: "", kind: "notebook", cover: "mavi", paper: "cizgili", size: "a4",
                     favorite: favorite, trashed: false, folder: nil, created: t0, modified: modified,
                     pdfAspect: nil, pdfFile: nil, pdfHash: nil, pageOrder: order)
}

func pg(_ id: UUID, _ notebook: UUID, bookmarked: Bool = false, ink: String? = nil) -> SyncPageMeta {
    SyncPageMeta(id: id, notebook: notebook, pdfPage: nil, bookmarked: bookmarked, mark: nil,
                 notes: [], images: [], tapes: [], inkHash: ink)
}

func item(_ id: UUID, _ byte: UInt8) -> SyncItem { SyncItem(id: id, data: Data([byte])) }

func snap(_ notebooks: [SyncNotebookMeta] = [], _ pages: [SyncPageMeta] = [], _ folders: [SyncFolderMeta] = [],
          files: [String: String] = [:]) -> SyncSnapshot {
    SyncSnapshot(notebooks: Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0) }),
                 pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) }),
                 folders: Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) }),
                 files: files)
}

// MARK: Denetimler

check("hashEmptyIsNil") {
    try expect(SyncMerge.hash(Data()) == nil, "boş veri nil olmalı")
    try expect(SyncMerge.hash(Data([1])) == SyncMerge.hash(Data([1])), "aynı veri aynı özet")
    try expect(SyncMerge.hash(Data([1])) != SyncMerge.hash(Data([2])), "farklı veri farklı özet")
    try expect(SyncMerge.hash(Data([1]))?.count == 64, "SHA256 hex 64 karakter")
}

check("diffDetectsEachKind") {
    let a = UUID(), b = UUID(), p1 = UUID(), p2 = UUID(), pb = UUID(), f = UUID()
    let old = snap([nb(a, title: "Eski"), nb(b)],
                   [pg(p1, a), pg(p2, a, ink: "h1"), pg(pb, b)])
    let new = snap([nb(a, title: "Yeni")],
                   [pg(p1, a, bookmarked: true), pg(p2, a, ink: "h2")],
                   [SyncFolderMeta(id: f, name: "K", created: t0)],
                   files: ["\(a.uuidString)/img-x.jpg": "abc"])
    let expected: Set<SyncChange> = [.notebook(a), .page(p1), .page(p2), .folder(f), .deleteNotebook(b),
                                     .file(notebook: a, name: "img-x.jpg")]
    let got = SyncMerge.diff(old: old, new: new)
    try expect(got == expected, "beklenen küme değil: \(got)")
}

check("diffIgnoresAppliedRemote") {
    let a = UUID()
    let s = snap([nb(a)], [pg(UUID(), a)], files: ["\(a.uuidString)/source.pdf": "x"])
    try expect(SyncMerge.diff(old: s, new: s).isEmpty, "aynı görüntü fark üretmemeli")
}

check("diffPdfOnlyWhenFileChanges") {
    let a = UUID()
    let key = "\(a.uuidString)/source.pdf"
    let old = snap([nb(a, title: "A")], files: [key: "h1"])
    let titleOnly = snap([nb(a, title: "B")], files: [key: "h1"])
    let d1 = SyncMerge.diff(old: old, new: titleOnly)
    try expect(!d1.contains(.file(notebook: a, name: "source.pdf")), "yalnız başlıkta pdf olmamalı")
    try expect(d1.contains(.notebook(a)), "defter değişmeli")
    let changed = snap([nb(a, title: "A")], files: [key: "h2"])
    try expect(SyncMerge.diff(old: old, new: changed).contains(.file(notebook: a, name: "source.pdf")), "pdf değişince olmalı")
}

check("orderKeepsServerAndInsertsLocal") {
    let A = UUID(), B = UUID(), C = UUID(), X = UUID()
    try expect(SyncMerge.mergeOrder(base: [A, B, C], local: [A, X, B, C], server: [C, A, B]) == [C, A, X, B],
               "sonuç [C,A,X,B] olmalı")
}

check("orderDeletedStaysDeleted") {
    let A = UUID(), B = UUID(), C = UUID(), D = UUID(), E = UUID()
    try expect(SyncMerge.mergeOrder(base: [A, B, C], local: [A, C], server: [A, B, C, D]) == [A, C, D], "[A,C,D]")
    try expect(SyncMerge.mergeOrder(base: [A, B], local: [A, B, E], server: [A]) == [A, E], "[A,E]")
}

check("orderNoBase") {
    let A = UUID(), B = UUID(), C = UUID()
    try expect(SyncMerge.mergeOrder(base: [], local: [A, B], server: [B, C]) == [A, B, C], "[A,B,C]")
}

check("itemsUnionAndLWW") {
    let i1 = UUID(), i2 = UUID(), i3 = UUID()
    let n1 = item(i1, 1), n1l = item(i1, 2), n1s = item(i1, 3), n2 = item(i2, 4), n3 = item(i3, 5)
    let s1 = SyncMerge.mergeItems(base: [n1], local: [n1l, n2], server: [n1s, n3], localWins: false)
    try expect(Set(s1.map(\.id)) == [i1, i2, i3] && s1.count == 3, "üç öğe")
    try expect(s1.first { $0.id == i1 } == n1s, "sunucu kazanmalı")
    let s2 = SyncMerge.mergeItems(base: [n1], local: [n1l, n2], server: [n1s, n3], localWins: true)
    try expect(s2.first { $0.id == i1 } == n1l && s2.count == 3, "yerel kazanmalı")
    let s3 = SyncMerge.mergeItems(base: [n1, n2], local: [n1], server: [n1, n2], localWins: false)
    try expect(s3 == [n1], "yerelde silinen silinmiş kalmalı")
}

check("notebookFieldMerge") {
    let id = UUID()
    let base = nb(id, title: "A", favorite: false, modified: t0)
    var local = base; local.title = "B"; local.modified = t1
    var server = base; server.favorite = true; server.modified = t2
    let m = SyncMerge.mergeNotebook(base: base, local: local, server: server)
    try expect(m.title == "B" && m.favorite, "alan alan birleşmeli")
    try expect(m.modified == t2, "modified büyük olan")

    var s2 = base; s2.title = "C"; s2.modified = t2
    try expect(SyncMerge.mergeNotebook(base: base, local: local, server: s2).title == "C", "yeni olan server")
    var l2 = base; l2.title = "B"; l2.modified = t2
    var s3 = base; s3.title = "C"; s3.modified = t1
    try expect(SyncMerge.mergeNotebook(base: base, local: l2, server: s3).title == "B", "yeni olan local")

    // base yok: daha yeni modified tarafı
    let A = UUID(), B = UUID(), C = UUID()
    var ln = nb(id, title: "L", modified: t1, order: [A, B])
    var sn = nb(id, title: "S", modified: t2, order: [B, C])
    let m2 = SyncMerge.mergeNotebook(base: nil, local: ln, server: sn)
    try expect(m2.title == "S", "base yok: yeni olan")
    try expect(m2.pageOrder == [A, B, C], "pageOrder birleşmeli: \(m2.pageOrder)")
    ln.modified = t2; sn.modified = t1
    try expect(SyncMerge.mergeNotebook(base: nil, local: ln, server: sn).title == "L", "base yok: local yeni")

    // base yok, isteğe bağlı alan: yeni olan sunucunun nil'i kazanmalı
    var lf = nb(id, modified: t1); lf.folder = UUID(); lf.pdfFile = "x.pdf"
    let sf = nb(id, modified: t2)
    let m3 = SyncMerge.mergeNotebook(base: nil, local: lf, server: sf)
    try expect(m3.folder == nil && m3.pdfFile == nil, "base yok: yeni sunucunun nil alanları kazanmalı")
}

check("pageNoBaseOptional") {
    let nbID = UUID(), id = UUID()
    var l = pg(id, nbID); l.mark = "yildiz"; l.pdfPage = 3
    let s = pg(id, nbID)
    let m = SyncMerge.mergePage(base: nil, local: l, server: s, localWins: false)
    try expect(m.mark == nil && m.pdfPage == nil, "base yok, localWins false: sunucu kazanmalı")
    let m2 = SyncMerge.mergePage(base: nil, local: l, server: s, localWins: true)
    try expect(m2.mark == "yildiz" && m2.pdfPage == 3, "base yok, localWins true: yerel kazanmalı")
}

check("inkResolution") {
    typealias R = SyncMerge.InkResolution
    let cases: [(String?, String?, String?, R)] = [
        ("h1", "h1", "h1", .same), ("h1", "h2", "h1", .takeLocal), ("h1", "h1", "h2", .takeServer),
        ("h1", "h2", "h2", .same), ("h1", "h2", "h3", .keepBoth), (nil, "h2", "h3", .keepBoth),
        (nil, "h2", "h2", .same), (nil, nil, "h1", .takeServer),
    ]
    for (b, l, s, want) in cases {
        let got = SyncMerge.resolveInk(base: b, local: l, server: s)
        try expect(got == want, "(\(b ?? "nil"),\(l ?? "nil"),\(s ?? "nil")) → \(got), beklenen \(want)")
    }
}

check("remoteDelete") {
    let n = UUID(), p = UUID()
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: pg(p, n, ink: "h1")) == .delete, "h1,h1")
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: pg(p, n, ink: "h2")) == .rescue, "h1,h2")
    try expect(SyncMerge.resolveRemoteDelete(base: nil, local: pg(p, n)) == .delete, "nil,boş")
    try expect(SyncMerge.resolveRemoteDelete(base: nil, local: pg(p, n, ink: "h1")) == .rescue, "nil,h1")
    // Yer imi ve işaret içerik sayılmaz
    var marked = pg(p, n, bookmarked: true, ink: "h1"); marked.mark = "rescued"
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: marked) == .delete, "yalnız yer imi/işaret")
}

check("remoteDeleteRescuesNoteOnlyChange") {
    // I5: başka cihaz sayfayı sildi; burada yalnızca yapışkan not eklendi (mürekkep aynı) → kurtarılır
    let n = UUID(), p = UUID()
    var local = pg(p, n, ink: "h1"); local.notes = [item(UUID(), 1)]
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: local) == .rescue, "yalnız not")
    // Mürekkepsiz, yalnız notlu yeni sayfa (taban yok)
    var fresh = pg(p, n); fresh.notes = [item(UUID(), 2)]
    try expect(SyncMerge.resolveRemoteDelete(base: nil, local: fresh) == .rescue, "tabansız notlu sayfa")
    // Not metni değişti
    let noteID = UUID()
    var b = pg(p, n); b.notes = [item(noteID, 1)]
    var l = pg(p, n); l.notes = [item(noteID, 2)]
    try expect(SyncMerge.resolveRemoteDelete(base: b, local: l) == .rescue, "not değişti")
    try expect(SyncMerge.resolveRemoteDelete(base: b, local: b) == .delete, "not aynı")
}

check("remoteDeleteRescuesImageOnlyChange") {
    let n = UUID(), p = UUID()
    var local = pg(p, n, ink: "h1"); local.images = [item(UUID(), 7)]
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: local) == .rescue, "yalnız resim")
    var taped = pg(p, n, ink: "h1"); taped.tapes = [item(UUID(), 3)]
    try expect(SyncMerge.resolveRemoteDelete(base: pg(p, n, ink: "h1"), local: taped) == .rescue, "yalnız bant")
    // Defter silmesinde de aynı kural
    let a = UUID(), c = UUID()
    var withImage = pg(a, n); withImage.images = [item(UUID(), 9)]
    try expect(SyncMerge.pagesToRescue(local: [withImage, pg(c, n)], bases: [a: pg(a, n)]) == [a], "defter silmesi: resimli sayfa kurtarılır")
}

check("rescuePlan") {
    let A = UUID(), B = UUID(), C = UUID(), newID = UUID(), old = UUID()
    var deleted = nb(old, title: "Biyoloji", order: [A, B, C])
    deleted.cover = "kirmizi"; deleted.paper = "kareli"; deleted.size = "a5"; deleted.kind = "pdf"; deleted.trashed = true
    let now = Date(timeIntervalSince1970: 9_999)
    let r = SyncMerge.rescueNotebook(from: deleted, keeping: [C, A], newID: newID, now: now)
    try expect(r.id == newID && r.title == "Biyoloji", "yeni id, aynı başlık")
    try expect(r.cover == "kirmizi" && r.paper == "kareli" && r.size == "a5" && r.kind == "pdf", "görünüm korunmalı")
    try expect(!r.trashed, "çöpte olmamalı")
    try expect(r.pageOrder == [A, C], "özgün sıra: \(r.pageOrder)")
    try expect(r.created == now && r.modified == now, "tarihler now")
}

func geciciKok() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("esitleme-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

check("stateRoundTrip") {
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let nbID = UUID(), pgID = UUID(), flID = UUID()
    let n = nb(nbID, title: "Fizik", order: [pgID])
    let p = SyncPageMeta(id: pgID, notebook: nbID, pdfPage: 2, bookmarked: true, mark: "yildiz",
                         notes: [], images: [], tapes: [], inkHash: "h1")
    let f = SyncFolderMeta(id: flID, name: "Ders", created: Date(timeIntervalSince1970: 100))
    let s1 = SyncStateStore(root: root)
    s1.engineState = Data([7])
    s1.enabled = true
    s1.accountID = "hesap-1"
    s1.setBase(n); s1.setBase(p); s1.setBase(f)
    s1.setSystemFields(Data([1, 2, 3]), for: "rec-1")
    s1.flush()
    let s2 = SyncStateStore(root: root)
    try expect(s2.engineState == Data([7]), "engineState")
    try expect(s2.enabled && s2.accountID == "hesap-1", "enabled/accountID")
    try expect(s2.base(notebook: nbID) == n, "defter tabanı")
    try expect(s2.base(page: pgID) == p, "sayfa tabanı")
    try expect(s2.base(folder: flID) == f, "klasör tabanı")
    try expect(s2.systemFields("rec-1") == Data([1, 2, 3]), "sistem alanı")
    s2.removeBase(nbID)
    try expect(s2.base(notebook: nbID) == nil, "removeBase")
}

check("stateResetKeepsEnabled") {
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let s = SyncStateStore(root: root)
    s.enabled = true
    s.engineState = Data([9]); s.accountID = "a"
    s.setBase(nb(id, title: "X", order: []))
    s.setSystemFields(Data([4]), for: "r")
    s.reset()
    try expect(s.base(notebook: id) == nil && s.engineState == nil && s.accountID == nil, "temizlenmeli")
    try expect(s.systemFields("r") == nil, "sistem alanı temizlenmeli")
    try expect(s.enabled, "enabled kalmalı")
    s.flush()
    let s2 = SyncStateStore(root: root)
    try expect(s2.enabled && s2.base(notebook: id) == nil && s2.accountID == nil, "diskte de öyle")
}

check("stateCorruptFileIsNil") {
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let s = SyncStateStore(root: root)
    s.setBase(nb(id, title: "X", order: []))
    s.flush()
    try Data([0xFF, 0x00, 0x13]).write(to: root.appendingPathComponent("notebooks.json"))
    let s2 = SyncStateStore(root: root)
    try expect(s2.base(notebook: id) == nil, "bozuk dosya nil vermeli")
}

check("syncErrorMapping") {
    typealias K = SyncStatusKind
    let cases: [(Int, K)] = [(3, .offline), (4, .offline), (25, .quotaFull), (6, .retry), (7, .retry), (23, .retry),
                             (14, .other), (999, .other)]
    for (code, want) in cases {
        let got = SyncMerge.statusKind(forErrorCode: code)
        try expect(got == want, "\(code) → \(got), beklenen \(want)")
    }
}

check("folderMerge") {
    let id = UUID()
    let b = SyncFolderMeta(id: id, name: "Ders", created: t0)
    var l = b; l.name = "Okul"
    var s = b; s.name = "İş"
    try expect(SyncMerge.mergeFolder(base: b, local: l, server: b).name == "Okul", "yalnız yerel değişti")
    try expect(SyncMerge.mergeFolder(base: b, local: b, server: s).name == "İş", "yalnız sunucu değişti")
    try expect(SyncMerge.mergeFolder(base: b, local: l, server: s).name == "İş", "ikisi de değişti: sunucu")
    try expect(SyncMerge.mergeFolder(base: nil, local: l, server: s).name == "İş", "taban yok: sunucu")
}

check("inkActionEmptySide") {
    typealias R = SyncMerge.InkResolution
    let cases: [(String?, String?, String?, R)] = [
        ("h1", "h2", "h3", .keepBoth), (nil, "h2", "h3", .keepBoth),
        // Bir taraf boşsa kopya gereksiz: dolu taraf kazanır, mürekkep kaybolmaz
        ("h1", nil, "h3", .takeServer), ("h1", "h2", nil, .takeLocal),
        ("h1", "h1", "h2", .takeServer), ("h1", "h2", "h1", .takeLocal), ("h1", "h1", "h1", .same),
        ("h1", "h1", nil, .takeServer), ("h1", nil, "h1", .takeLocal),
    ]
    for (b, l, s, want) in cases {
        let got = SyncMerge.inkAction(base: b, local: l, server: s)
        try expect(got == want, "(\(b ?? "nil"),\(l ?? "nil"),\(s ?? "nil")) → \(got), beklenen \(want)")
    }
}

check("pagesToRescue") {
    let n = UUID(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let local = [pg(a, n, ink: "h1"), pg(b, n, ink: "h2"), pg(c, n, ink: "h3"), pg(d, n)]
    let bases = [a: pg(a, n, ink: "h1"), b: pg(b, n, ink: "eski")]
    // a değişmedi, b değişti, c hiç eşitlenmedi ama mürekkepli, d boş ve tabansız
    try expect(SyncMerge.pagesToRescue(local: local, bases: bases) == [b, c], "yalnız b ve c, yerel sırayla")
}

check("remotePageAction") {
    typealias A = SyncMerge.RemotePageAction
    let n = UUID(), p = UUID()
    let srv = pg(p, n, ink: "yeni")
    let baseSame = pg(p, n, ink: "yeni"), baseOld = pg(p, n, ink: "eski")
    try expect(SyncMerge.remotePageAction(localExists: true, notebookExists: true, base: baseOld, notebookBaseKnown: true, server: srv) == A.merge, "yerelde var: birleştir")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: nil, notebookBaseKnown: true, server: srv) == A.merge, "yeni sayfa")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: baseOld, notebookBaseKnown: true, server: srv) == A.resurrect, "yerelde silindi, uzakta yazıldı: geri gelir")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: baseSame, notebookBaseKnown: true, server: srv) == A.skip, "yerelde silindi, uzakta mürekkep aynı: silme kazanır")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: baseOld, notebookBaseKnown: true, server: pg(p, n)) == A.skip, "uzakta mürekkep boşaldı: silme kazanır")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: false, base: baseOld, notebookBaseKnown: true, server: srv) == A.rescueOrphan, "defter yerelde silindi, uzakta yazıldı")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: false, base: nil, notebookBaseKnown: true, server: srv) == A.rescueOrphan, "tabansız mürekkepli sayfa, silinen deftere")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: false, base: baseSame, notebookBaseKnown: true, server: srv) == A.skip, "defter silindi, sayfa değişmedi")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: false, base: nil, notebookBaseKnown: false, server: srv) == A.hold, "defter henüz gelmedi: beklet")
    // I5: uzakta yalnızca not eklendi (mürekkep aynı): yerel silme onu yutmaz
    var noteOnly = pg(p, n, ink: "yeni"); noteOnly.notes = [item(UUID(), 4)]
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: baseSame, notebookBaseKnown: true, server: noteOnly) == A.resurrect, "yalnız not: geri gelir")
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: false, base: baseSame, notebookBaseKnown: true, server: noteOnly) == A.rescueOrphan, "yalnız not, defter silindi: kurtarılır")
    var imgOnly = pg(p, n); imgOnly.images = [item(UUID(), 5)]
    try expect(SyncMerge.remotePageAction(localExists: false, notebookExists: true, base: pg(p, n), notebookBaseKnown: true, server: imgOnly) == A.resurrect, "yalnız resim: geri gelir")
}

check("resumeChanges") {
    let a = UUID(), b = UUID(), gone = UUID(), p1 = UUID(), p2 = UUID(), p3 = UUID(), pNew = UUID(), f = UUID()
    let imgOld = "\(a.uuidString)/img-eski.jpg", imgNew = "\(a.uuidString)/img-yeni.jpg", imgGone = "\(a.uuidString)/img-sil.jpg"
    let pdfA = "\(a.uuidString)/source.pdf", pdfB = "\(b.uuidString)/source.pdf"
    var na = nb(a, order: [p1, p2]); na.pdfHash = "pa"
    var nbB = nb(b, order: [p3]); nbB.pdfHash = "pb1"
    let bases = snap([na, nbB, nb(gone)], [pg(p1, a, ink: "h1"), pg(p2, a, ink: "h2"), pg(p3, b)],
                     [SyncFolderMeta(id: f, name: "K", created: t0)])
    var nbB2 = nbB; nbB2.pdfHash = "pb2"
    let local = snap([na, nbB2], [pg(p1, a, ink: "h1"), pg(p3, b), pg(pNew, b, ink: "x")], [],
                     files: [imgOld: "i1", imgNew: "i2", pdfA: "pa", pdfB: "pb2"])
    let known: Set<String> = [imgOld, imgGone, pdfA, pdfB, a.uuidString]
    let got = SyncMerge.resumeChanges(bases: bases, knownFiles: known, local: local)
    let want: Set<SyncChange> = [.notebook(b), .page(pNew), .deletePage(p2), .deleteNotebook(gone), .deleteFolder(f),
                                 .file(notebook: a, name: "img-yeni.jpg"), .deleteFile(notebook: a, name: "img-sil.jpg"),
                                 .file(notebook: b, name: "source.pdf")]
    try expect(got == want, "fark: fazla \(got.subtracting(want)), eksik \(want.subtracting(got))")
    // Taban yoksa (ilk açılış) her şey gönderilir, hiçbir şey silinmez
    let first = SyncMerge.resumeChanges(bases: snap(), knownFiles: [], local: local)
    try expect(first.count == 2 + 3 + 4 && !first.contains(where: {
        if case .deleteNotebook = $0 { return true }; if case .deletePage = $0 { return true }; return false }), "ilk açılış: \(first)")
}

check("stateBatchAndQueries") {
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let n = UUID(), p1 = UUID(), p2 = UUID(), other = UUID(), f = UUID()
    let s = SyncStateStore(root: root)
    try expect(!s.hasSystemFields, "başta sistem alanı yok")
    var b = SyncStateBatch()
    b.notebooks = [nb(n, order: [p1, p2])]
    b.pages = [pg(p1, n), pg(p2, n), pg(other, UUID())]
    b.folders = [SyncFolderMeta(id: f, name: "K", created: t0)]
    b.fields = ["\(n.uuidString)/img-a.jpg": Data([1]), p1.uuidString: Data([2]), "silinecek": Data([3])]
    s.apply(b)
    var b2 = SyncStateBatch()
    b2.removed = [p2]
    b2.fields = ["silinecek": nil]
    s.apply(b2)
    s.flush()
    let s2 = SyncStateStore(root: root)
    try expect(s2.hasSystemFields, "sistem alanı var")
    try expect(s2.base(page: p2) == nil && s2.base(page: p1) != nil, "removed")
    try expect(s2.pageIDs(inNotebook: n) == [p1], "defterin sayfaları")
    try expect(s2.recordNames() == ["\(n.uuidString)/img-a.jpg", p1.uuidString], "kayıt adları: \(s2.recordNames())")
    let all = s2.allBases()
    try expect(all.notebooks.count == 1 && all.pages.count == 2 && all.folders[f] != nil, "tüm tabanlar")
}

check("duplicatePageIDs") {
    // C1: eski sürümde çoğaltılan defter (N2) N1'in sayfa kimliklerini paylaşıyor
    let n1 = UUID(), n2 = UUID(), n3 = UUID(), p = UUID(), q = UUID(), r = UUID()
    let list: [(id: UUID, created: Date, pages: [UUID])] = [
        (n2, t1, [p, q]),          // kopya, sonra oluşturuldu; dizide önce gelse de kimlikleri değişir
        (n1, t0, [p, q, r]),
        (n3, t2, [UUID()]),
    ]
    let re = SyncMerge.duplicatePageIDs(list)
    try expect(re.count == 2, "iki sayfa yeniden kimlik almalı: \(re)")
    try expect(re.allSatisfy { $0.notebook == n2 }, "en eski defter (n1) kimliklerini korur")
    try expect(re.map(\.index) == [0, 1] && re.map(\.old) == [p, q], "sıra ve eski kimlik")
    try expect(Set(re.map(\.new)).count == 2 && !re.contains { [p, q, r].contains($0.new) }, "yeni kimlikler benzersiz")
    // Her cihazda aynı sonuç: dizi sırası farklı olsa da
    let again = SyncMerge.duplicatePageIDs([list[1], list[2], list[0]])
    try expect(again == re, "kararlı ve sıradan bağımsız")
    // Yinelenme yoksa boş
    try expect(SyncMerge.duplicatePageIDs([(n1, t0, [p, q]), (n2, t1, [r])]).isEmpty, "yinelenme yok")
    // Aynı defterde iki kez geçen kimlik
    let same = SyncMerge.duplicatePageIDs([(n1, t0, [p, p, p])])
    try expect(same.map(\.index) == [1, 2] && Set(same.map(\.new)).count == 2, "aynı defterde: \(same)")
    // Eşit tarihte kimlik metni karar verir
    let (a, b) = n1.uuidString < n2.uuidString ? (n1, n2) : (n2, n1)
    let tie = SyncMerge.duplicatePageIDs([(b, t0, [p]), (a, t0, [p])])
    try expect(tie.count == 1 && tie[0].notebook == b, "eşit tarih")
}

check("stateFreezeKeepsOldEngineState") {
    // I3: uygulanan değişiklik diske yazılamadıysa motor durumu (belirteç) diske yazılmaz
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = SyncStateStore(root: root)
    s.engineState = Data([1])
    s.freezeEngineState()
    s.engineState = Data([2])
    try expect(s.engineState == Data([2]), "bellekte güncel")
    try expect(SyncStateStore(root: root).engineState == Data([1]), "diskte eski belirteç kalır")
    // Durum dosyası yazılamazsa da donar
    let bad = geciciKok()
    defer { try? FileManager.default.removeItem(at: bad) }
    let s2 = SyncStateStore(root: bad)
    try FileManager.default.removeItem(at: bad)
    try Data().write(to: bad)   // kök artık bir dosya: yazmalar başarısız
    s2.setBase(pg(UUID(), UUID()))
    try expect(s2.isFrozen, "taban yazılamadı: dondu")
    try FileManager.default.removeItem(at: bad)
}

check("deleteGateWaitsForFetch") {
    // I2: silme, sıraya girdikten sonra bir alım bitmeden gönderilmez
    try expect(!SyncMerge.deleteReady(queuedAt: nil, completedFetches: 0), "oturum başı, alım yok")
    try expect(SyncMerge.deleteReady(queuedAt: nil, completedFetches: 1), "ilk alımdan sonra")
    try expect(!SyncMerge.deleteReady(queuedAt: 3, completedFetches: 3), "alımdan sonra sıraya girdi")
    try expect(SyncMerge.deleteReady(queuedAt: 3, completedFetches: 4), "sonraki alım bitti")
}

check("stateRefetchPlaceholdersRedirects") {
    // I1/I6: yeniden istenecek kayıtlar, yer tutucular ve kurtarma yönlendirmeleri uygulama kapansa da kalır
    let root = geciciKok()
    defer { try? FileManager.default.removeItem(at: root) }
    let ph = UUID(), old = UUID(), new = UUID()
    let s = SyncStateStore(root: root)
    s.addRefetch(["a", "b"])
    s.removeRefetch(["a"])
    s.addPlaceholders([ph, UUID()])
    s.setRedirect(old, to: new)
    let s2 = SyncStateStore(root: root)
    try expect(s2.refetchNames() == ["b"], "yeniden istenecekler: \(s2.refetchNames())")
    try expect(s2.isPlaceholder(ph), "yer tutucu kalıcı")
    s2.removePlaceholders([ph])
    try expect(!SyncStateStore(root: root).isPlaceholder(ph), "yer tutucu çıkarıldı")
    try expect(s2.redirect(old) == new, "yönlendirme kalıcı")
    s2.reset()
    let s3 = SyncStateStore(root: root)
    try expect(s3.refetchNames().isEmpty && s3.redirect(old) == nil, "sıfırlama temizler")
}

check("untrackedPlaceholders") {
    // I1: buluttan gelen sırada olup kaydı gelmemiş boş sayfa yer tutucudur; yerelde yeni boş sayfa değildir
    let n = UUID(), ph = UUID(), fresh = UUID(), real = UUID(), inked = UUID()
    let bases = snap([nb(n, order: [real, ph, inked])], [pg(real, n)])
    let local = snap([nb(n, order: [real, ph, inked, fresh])], [pg(real, n), pg(ph, n), pg(fresh, n), pg(inked, n, ink: "h")])
    try expect(SyncMerge.untrackedPlaceholders(local: local, bases: bases) == [ph], "yalnız ph")
}

check("resumeMassDeleteGuard") {
    // Yerel kütüphane boş görünüyorsa (ör. dizin okunamadı) devam farkı buluttaki her şeyi silmesin
    try expect(SyncMerge.holdResumeDeletes(baseNotebooks: 3, localNotebooks: 0, deletedNotebooks: 3), "yerel boş")
    try expect(SyncMerge.holdResumeDeletes(baseNotebooks: 10, localNotebooks: 4, deletedNotebooks: 6), "yarıdan fazlası")
    try expect(!SyncMerge.holdResumeDeletes(baseNotebooks: 10, localNotebooks: 8, deletedNotebooks: 2), "birkaç silme normal")
    try expect(!SyncMerge.holdResumeDeletes(baseNotebooks: 3, localNotebooks: 1, deletedNotebooks: 2), "küçük kütüphane")
    try expect(!SyncMerge.holdResumeDeletes(baseNotebooks: 0, localNotebooks: 0, deletedNotebooks: 0), "ilk açılış")
}

if failures > 0 { print("\n\(failures) denetim kaldı."); exit(1) }
print("\nTüm denetimler geçti.")
