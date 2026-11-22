// İCloud eşitleme saf mantığının denetimi. Uygulama hedefinde değildir; Mac'te derlenip çalıştırılır:
//
//   swiftc OpenLeaf/SyncMerge.swift Tests/SyncCheck/main.swift -o "$TMPDIR/esitleme-test" && "$TMPDIR/esitleme-test"
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
    try expect(SyncMerge.resolveRemoteDelete(base: "h1", local: "h1") == .delete, "h1,h1")
    try expect(SyncMerge.resolveRemoteDelete(base: "h1", local: "h2") == .rescue, "h1,h2")
    try expect(SyncMerge.resolveRemoteDelete(base: nil, local: nil) == .delete, "nil,nil")
    try expect(SyncMerge.resolveRemoteDelete(base: nil, local: "h1") == .rescue, "nil,h1")
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

if failures > 0 { print("\n\(failures) denetim kaldı."); exit(1) }
print("\nTüm denetimler geçti.")
