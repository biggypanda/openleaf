// Yedekleme motorunun denetimi. Uygulama hedefinde değildir; Mac'te derlenip çalıştırılır:
//
//   swiftc OpenLeaf/BackupEngine.swift Tests/BackupEngineCheck/main.swift -o /tmp/yedek-test && /tmp/yedek-test
//
// Her denetim geçici bir klasörde sahte bir depo kurar. Biri kalırsa çıkış kodu 1 olur.

import Foundation

let fm = FileManager.default
var failures = 0

struct Fail: Error, CustomStringConvertible { let description: String }

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
    if try !condition() { throw Fail(description: "\(message) (satır \(line))") }
}

func check(_ name: String, _ body: (Sandbox) throws -> Void) {
    let box = Sandbox()
    defer { box.cleanUp() }
    do { try body(box); print("GEÇTİ  \(name)") } catch { failures += 1; print("KALDI  \(name): \(error)") }
}

/// Geçici klasörde yerel depo + yedek hedefi
final class Sandbox {
    let root = fm.temporaryDirectory.appendingPathComponent("yedek-test-" + UUID().uuidString)
    var source: URL { root.appendingPathComponent("yerel") }
    var backupsRoot: URL { root.appendingPathComponent("hedef/Yedekler") }
    var dest: URL { backupsRoot.appendingPathComponent("cihaz-1") }
    var state: URL { root.appendingPathComponent("durum.json") }
    var engine: BackupEngine { BackupEngine(source: source, destination: dest, stateURL: state) }

    init() { try! fm.createDirectory(at: source.appendingPathComponent("Defterler"), withIntermediateDirectories: true) }
    func cleanUp() { try? fm.removeItem(at: root) }

    func localDir(_ id: UUID) -> URL { source.appendingPathComponent("Defterler/\(id.uuidString)") }
    func destDir(_ id: UUID) -> URL { dest.appendingPathComponent("Defterler/\(id.uuidString)") }

    func writeIndex(_ ids: [UUID]) throws {
        let list = ids.map { ["id": $0.uuidString, "title": "Defter", "modified": 784563123.456789] as [String: Any] }
        try JSONSerialization.data(withJSONObject: list).write(to: source.appendingPathComponent("index.json"))
    }

    func write(_ id: UUID, _ name: String, _ text: String) throws {
        try fm.createDirectory(at: localDir(id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: localDir(id).appendingPathComponent(name), options: .atomic)
    }

    func info(_ count: Int) -> BackupEngine.DeviceInfo {
        .init(id: "cihaz-1", name: "iPad", appVersion: "1.0.4", date: Date(), notebookCount: count)
    }

    @discardableResult
    func backUp(_ ids: [UUID], deleted: Set<UUID> = []) throws -> BackupEngine.Outcome? {
        try engine.backUp(info: info(ids.count), deleted: deleted)
    }

    func destText(_ id: UUID, _ name: String) -> String? {
        (try? Data(contentsOf: destDir(id).appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    func destNames(_ id: UUID) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: destDir(id).path)) ?? []).sorted()
    }

    /// Yedeğin dizinindeki defter kimlikleri
    func destIndexIDs() throws -> Set<String> {
        let data = try Data(contentsOf: dest.appendingPathComponent("index.json"))
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0["id"] as? String })
    }

    /// İki defter, üç sayfa dosyası, bir küçük resim
    func seed() throws -> (a: UUID, b: UUID) {
        let a = UUID(), b = UUID()
        try write(a, "s1.drawing", "bir")
        try write(a, "s2.drawing", "iki")
        try write(a, "thumb.png", "resim")
        try write(b, "source.pdf", "pdf içeriği")
        try writeIndex([a, b])
        return (a, b)
    }
}

// MARK: - Yedekleme

check("ilkYedek") { box in
    let (a, b) = try box.seed()
    let out = try box.backUp([a, b])
    try expect(out?.copied == 3, "3 dosya kopyalanmalı, kopyalanan: \(String(describing: out?.copied))")
    try expect(box.destNames(a) == ["s1.drawing", "s2.drawing"], "a klasörü: \(box.destNames(a))")
    try expect(box.destText(b, "source.pdf") == "pdf içeriği", "pdf içeriği farklı")
    let local = try Data(contentsOf: box.source.appendingPathComponent("index.json"))
    let remote = try Data(contentsOf: box.dest.appendingPathComponent("index.json"))
    try expect(local == remote, "dizin bayt bayt aynı olmalı")
    let info = BackupEngine.readInfo(at: box.dest, coordinated: false)
    try expect(info?.notebookCount == 2 && info?.id == "cihaz-1", "cihaz.json okunamadı")
}

check("degismeyenKopyalanmaz") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    let out = try box.backUp([a, b])
    try expect(out == BackupEngine.Outcome(), "ikinci yedek hiçbir şey yapmamalı: \(String(describing: out))")
}

check("tekSayfaDegisince") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try box.write(a, "s2.drawing", "iki, yeni hali")
    let out = try box.backUp([a, b])
    try expect(out?.copied == 1, "yalnızca 1 dosya kopyalanmalı: \(String(describing: out?.copied))")
    try expect(box.destText(a, "s2.drawing") == "iki, yeni hali", "hedef güncellenmedi")
    try expect(box.destText(a, "s1.drawing") == "bir", "dokunulmaması gereken dosya değişti")
}

check("sayfaSilinince") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.removeItem(at: box.localDir(a).appendingPathComponent("s1.drawing"))
    let out = try box.backUp([a, b])
    try expect(out?.removed == 1, "1 dosya silinmeli: \(String(describing: out?.removed))")
    try expect(box.destNames(a) == ["s2.drawing"], "a klasörü: \(box.destNames(a))")
}

check("kaliciSilinenDefter") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.removeItem(at: box.localDir(b))
    try box.writeIndex([a])
    try box.backUp([a], deleted: [b])
    try expect(!fm.fileExists(atPath: box.destDir(b).path), "silinen defter yedekte duruyor")
    try expect(try box.destIndexIDs() == [a.uuidString], "dizin: \(try box.destIndexIDs())")
}

check("listedeOlmayanDefterKorunur") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.removeItem(at: box.localDir(b))
    try box.writeIndex([a])
    try box.backUp([a])
    try expect(box.destText(b, "source.pdf") == "pdf içeriği", "listede olmayan defter yedekten silindi")
    try expect(try box.destIndexIDs() == [a.uuidString, b.uuidString], "yedek dizini kaydı kaybetti: \(try box.destIndexIDs())")
}

check("bosYerelYedegiKorur") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    // Bozuk dizin sonrası uygulama boş kütüphaneyle açılır ve boş dizin yazar; klasörler de gitmiş olsun
    try fm.removeItem(at: box.localDir(a))
    try fm.removeItem(at: box.localDir(b))
    try box.writeIndex([])
    try box.backUp([])
    try expect(box.destNames(a) == ["s1.drawing", "s2.drawing"], "a klasörü silindi: \(box.destNames(a))")
    try expect(box.destText(b, "source.pdf") == "pdf içeriği", "b klasörü silindi")
    try expect(try box.destIndexIDs() == [a.uuidString, b.uuidString], "yedek dizini boşaldı: \(try box.destIndexIDs())")
}

check("klasoruKaybolanDefterKorunur") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    // Dizin defteri gösteriyor ama klasörü yok (bozuk yerel): yedekteki dosyalar silinmemeli
    try fm.removeItem(at: box.localDir(a))
    try box.backUp([a, b])
    try expect(box.destNames(a) == ["s1.drawing", "s2.drawing"], "a klasörü silindi: \(box.destNames(a))")
}

check("yerelDizinYoksaDokunmaz") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.removeItem(at: box.source.appendingPathComponent("index.json"))
    let out = try box.backUp([])
    try expect(out == nil, "nil dönmeli")
    try expect(try box.destIndexIDs() == [a.uuidString, b.uuidString], "yedek değişti")
}

check("bosKutuphaneYedekOlusturmaz") { box in
    try box.writeIndex([])
    try box.backUp([])
    try expect(!fm.fileExists(atPath: box.dest.path), "boş kütüphane için yedek klasörü oluştu")
}

check("yaridaKesilenYedek") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    let before = try Data(contentsOf: box.dest.appendingPathComponent("index.json"))
    let c = UUID()
    try box.write(c, "s1.drawing", "yeni defter")
    try box.write(c, "s2.drawing", "ikinci sayfa")
    try box.writeIndex([a, b, c])
    var calls = 0
    do {
        _ = try box.engine.backUp(info: box.info(3), deleted: []) { calls += 1; return calls > 1 }
        throw Fail(description: "iptal edilmeliydi")
    } catch BackupEngine.Failure.cancelled {}
    let after = try Data(contentsOf: box.dest.appendingPathComponent("index.json"))
    try expect(before == after, "yarıda kesilen yedek dizini değiştirdi")
    try box.backUp([a, b, c])
    try expect(box.destNames(c) == ["s1.drawing", "s2.drawing"], "sonraki yedek tamamlamadı: \(box.destNames(c))")
    try expect(try box.destIndexIDs().contains(c.uuidString), "yeni defter dizinde yok")
}

check("hedefSilinirseYenidenKopyalar") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.removeItem(at: box.dest)
    let out = try box.backUp([a, b])
    try expect(out?.copied == 3, "hepsi yeniden kopyalanmalı: \(String(describing: out?.copied))")
    try expect(box.destText(a, "s1.drawing") == "bir", "dosya geri gelmedi")
    try expect(BackupEngine.readInfo(at: box.dest, coordinated: false) != nil, "cihaz.json geri gelmedi")
}

check("yedekleriListeler") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.createDirectory(at: box.backupsRoot.appendingPathComponent("bos-klasor"), withIntermediateDirectories: true)
    let found = BackupEngine.listBackups(in: box.backupsRoot, coordinated: false)
    try expect(found.count == 1 && found.first?.info.id == "cihaz-1", "bulunan: \(found.map(\.info.id))")
}

// MARK: - Geri yükleme

check("geriYukleme") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    let target = box.root.appendingPathComponent("yeni/\(a.uuidString)")
    let n = try BackupEngine.restoreNotebook(a, from: box.dest, to: target, coordinated: false)
    try expect(n == 2, "2 dosya gelmeli: \(n)")
    for name in ["s1.drawing", "s2.drawing"] {
        let original = try Data(contentsOf: box.localDir(a).appendingPathComponent(name))
        let restored = try Data(contentsOf: target.appendingPathComponent(name))
        try expect(original == restored, "\(name) bayt bayt aynı değil")
    }
    let index = try BackupEngine.readIndex(at: box.dest, coordinated: false)
    try expect(index.index == (try Data(contentsOf: box.source.appendingPathComponent("index.json"))), "dizin farklı")
}

check("geriYuklemeYereliEzmez") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    // Yedekten sonra yerelde daha yeni bir şey yazıldı, bir dosya da kayboldu
    try box.write(a, "s1.drawing", "yerelde daha yeni")
    try fm.removeItem(at: box.localDir(a).appendingPathComponent("s2.drawing"))
    let n = try BackupEngine.restoreNotebook(a, from: box.dest, to: box.localDir(a), coordinated: false)
    try expect(n == 1, "yalnızca eksik dosya gelmeli: \(n)")
    let s1 = String(decoding: try Data(contentsOf: box.localDir(a).appendingPathComponent("s1.drawing")), as: UTF8.self)
    try expect(s1 == "yerelde daha yeni", "yerel dosyanın üstüne yazıldı")
    try expect(fm.fileExists(atPath: box.localDir(a).appendingPathComponent("s2.drawing").path), "eksik dosya gelmedi")
}

check("kotuDosyaAdiAtlanir") { box in
    let (a, b) = try box.seed()
    try box.backUp([a, b])
    try fm.createDirectory(at: box.destDir(a).appendingPathComponent("alt"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: box.destDir(a).appendingPathComponent("alt/kacak.drawing"))
    try Data("x".utf8).write(to: box.destDir(a).appendingPathComponent(".gizli"))
    let target = box.root.appendingPathComponent("yeni/\(a.uuidString)")
    let n = try BackupEngine.restoreNotebook(a, from: box.dest, to: target, coordinated: false)
    try expect(n == 2, "yalnızca 2 düz dosya gelmeli: \(n)")
    let names = try fm.contentsOfDirectory(atPath: target.path).sorted()
    try expect(names == ["s1.drawing", "s2.drawing"], "gelenler: \(names)")
}

check("yedekDiziniYoksaHata") { box in
    do {
        _ = try BackupEngine.readIndex(at: box.dest, coordinated: false)
        throw Fail(description: "hata vermeliydi")
    } catch BackupEngine.Failure.backupUnreadable {}
}

print(failures == 0 ? "Hepsi geçti." : "\(failures) denetim kaldı.")
exit(failures == 0 ? 0 : 1)
