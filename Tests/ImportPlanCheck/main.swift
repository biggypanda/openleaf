// Toplu içe aktarma planının (hangi PDF hangi klasöre) denetimi. Mac'te derlenip çalıştırılır:
//
//   swiftc OpenLeaf/ZipReader.swift OpenLeaf/BulkImport.swift Tests/ImportPlanCheck/main.swift -o /tmp/plan-check && /tmp/plan-check

import Foundation

let fm = FileManager.default
var failures = 0

struct Fail: Error, CustomStringConvertible { let description: String }

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
    if try !condition() { throw Fail(description: "\(message) (satır \(line))") }
}

func check(_ name: String, _ body: (URL) throws -> Void) {
    let root = fm.temporaryDirectory.appendingPathComponent("plan-test-" + UUID().uuidString)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    do { try body(root); print("GEÇTİ  \(name)") } catch { failures += 1; print("KALDI  \(name): \(error)") }
}

func touch(_ root: URL, _ rel: String) {
    let url = root.appendingPathComponent(rel)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data("x".utf8))
}

/// Karşılaştırma için: (kökten göreli yol, klasör adı)
func summary(_ items: [ImportItem], _ root: URL) -> [String] {
    let base = root.resolvingSymlinksInPath().standardizedFileURL.path
    return items.map {
        let p = $0.pdf.resolvingSymlinksInPath().standardizedFileURL.path
        let rel = p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : p
        return rel + " | " + ($0.folderName ?? "-")
    }
}

check("klasör eşleme") { root in
    for r in ["a.pdf", "Matematik/b.PDF", "Matematik/Ünite 1/c.pdf", "Fizik/not.txt", "__MACOSX/._a.pdf", "._x.pdf", "Matematik/._b.pdf"] {
        touch(root, r)
    }
    let got = summary(ImportPlan.items(in: root), root)
    try expect(got == ["a.pdf | -", "Matematik/b.PDF | Matematik", "Matematik/Ünite 1/c.pdf | Matematik"], "\(got)")
}

check("sıralama doğal") { root in
    for r in ["Ders 10.pdf", "Ders 2.pdf", "ders 1.pdf"] { touch(root, r) }
    let got = ImportPlan.items(in: root).map { $0.pdf.lastPathComponent }
    try expect(got == ["ders 1.pdf", "Ders 2.pdf", "Ders 10.pdf"], "\(got)")
}

check("boş klasör") { root in
    try expect(ImportPlan.items(in: root).isEmpty, "boş")
}

check("unicode ad") { root in
    touch(root, "Türkçe 📓.pdf")
    let got = ImportPlan.items(in: root).map { $0.pdf.lastPathComponent }
    try expect(got == ["Türkçe 📓.pdf"], "\(got)")
}

check("ZIP'ten plan") { root in
    let src = root.appendingPathComponent("kaynak")
    touch(src, "Defterler/Biyoloji/hucre.pdf")
    touch(src, "Defterler/kok.pdf")
    let zip = root.appendingPathComponent("a.zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.arguments = ["-q", "-r", zip.path, "Defterler"]
    p.currentDirectoryURL = src
    try p.run(); p.waitUntilExit()
    let out = root.appendingPathComponent("cikis")
    let (_, failed) = ZipReader.extractAll(zip, to: out)
    try expect(failed.isEmpty, "\(failed)")
    // GoodNotes ZIP'i tek bir üst klasörle sarar: o sarmalayıcı klasör sayılmaz
    let got = summary(ImportPlan.items(in: out), out)
    try expect(got == ["Defterler/Biyoloji/hucre.pdf | Biyoloji", "Defterler/kok.pdf | -"], "\(got)")
}

check("tek sarmalayıcı, alt klasörsüz") { root in
    // Tek klasör dışa aktarımı: klasör adı korunur
    touch(root, "Matematik/a.pdf")
    touch(root, "Matematik/b.pdf")
    let got = summary(ImportPlan.items(in: root), root)
    try expect(got == ["Matematik/a.pdf | Matematik", "Matematik/b.pdf | Matematik"], "\(got)")
}

check("seçilen klasör adı") { root in
    // Files'tan seçilen klasör: kökteki PDF'ler o klasörün adını alır
    touch(root, "a.pdf")
    touch(root, "Alt/b.pdf")
    let got = summary(ImportPlan.items(in: root, rootFolder: "Ders"), root)
    try expect(got == ["a.pdf | Ders", "Alt/b.pdf | Alt"], "\(got)")
}

check("PDF olmayanlar atlandı sayılır") { root in
    for r in ["a.pdf", "Ders/b.goodnotes", "Ders/c.note", "resim.png", "__MACOSX/._a.pdf", "._x.pdf", ".DS_Store"] { touch(root, r) }
    let scan = ImportPlan.scan(in: root)
    try expect(scan.items.map { $0.pdf.lastPathComponent } == ["a.pdf"], "\(scan.items)")
    try expect(scan.skipped == ["b.goodnotes", "c.note", "resim.png"], "\(scan.skipped)")
}

print(failures == 0 ? "\nTümü geçti." : "\n\(failures) denetim kaldı.")
exit(failures == 0 ? 0 : 1)
