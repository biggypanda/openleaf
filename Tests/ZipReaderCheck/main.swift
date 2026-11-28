// ZIP okuyucunun denetimi. Uygulama hedefinde değildir; Mac'te derlenip çalıştırılır:
//
//   swiftc OpenLeaf/ZipReader.swift Tests/ZipReaderCheck/main.swift -o /tmp/zip-check && /tmp/zip-check
//
// Örnek arşivler geçici klasörde /usr/bin/zip ve python3 ile üretilir. Biri kalırsa çıkış kodu 1 olur.

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

final class Sandbox {
    let root = fm.temporaryDirectory.appendingPathComponent("zip-test-" + UUID().uuidString)
    var src: URL { root.appendingPathComponent("kaynak") }
    var out: URL { root.appendingPathComponent("cikis") }
    var zip: URL { root.appendingPathComponent("arsiv.zip") }

    init() {
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    }
    func cleanUp() { try? fm.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, _ data: Data) -> URL {
        let url = src.appendingPathComponent(rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    /// `zip` komutunu kaynak klasörde çalıştırır
    func zipCmd(_ args: [String]) throws {
        try run("/usr/bin/zip", ["-q", "-X"] + args, cwd: src)
    }

    /// python3 zipfile ile adları elle verilmiş arşiv yazar
    func pyZip(_ entries: [(String, String)], deflate: Bool = true) throws {
        let list = entries.map { "(\(pyStr($0.0)), \(pyStr($0.1)))" }.joined(separator: ",")
        let mode = deflate ? "zipfile.ZIP_DEFLATED" : "zipfile.ZIP_STORED"
        let script = "import zipfile\nwith zipfile.ZipFile(\(pyStr(zip.path)), 'w', \(mode)) as z:\n    for n, d in [\(list)]:\n        z.writestr(n, d)\n"
        try run("/usr/bin/env", ["python3", "-I", "-c", script], cwd: root)
    }

    private func pyStr(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func run(_ exe: String, _ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Fail(description: "\(exe) \(args) çıkış \(p.terminationStatus)") }
    }
}

func bytes(_ n: Int, seed: UInt8 = 7) -> Data {
    var d = Data(count: n)
    var x = seed
    for i in 0..<n { x = x &* 31 &+ 11; d[i] = x }
    return d
}

let repeated = Data(String(repeating: "OpenLeaf defter sayfası satırı. ", count: 10_000).utf8)

check("stored") { b in
    let a = bytes(5000), c = bytes(123, seed: 3)
    b.write("a.bin", a); b.write("c.bin", c)
    try b.zipCmd(["-0", b.zip.path, "a.bin", "c.bin"])
    let r = try ZipReader(url: b.zip)
    try expect(r.entries.count == 2, "iki girdi")
    for e in r.entries {
        let dest = b.out.appendingPathComponent(e.path)
        try r.extract(e, to: dest)
        let want = e.path == "a.bin" ? a : c
        try expect(try Data(contentsOf: dest) == want, "\(e.path) içerik")
    }
}

check("deflate") { b in
    b.write("Ders/a.txt", repeated)
    try b.zipCmd(["-9", "-r", b.zip.path, "Ders"])
    let r = try ZipReader(url: b.zip)
    guard let e = r.entries.first(where: { $0.path == "Ders/a.txt" }) else { throw Fail(description: "Ders/a.txt yok: \(r.entries.map(\.path))") }
    try expect(e.method == 8, "deflate yöntemi")
    try expect(e.compressedSize < e.uncompressedSize, "sıkıştırılmış")
    let dest = b.out.appendingPathComponent("a.txt")
    try r.extract(e, to: dest)
    try expect(try Data(contentsOf: dest) == repeated, "içerik aynı")
}

check("zip64") { b in
    b.write("buyuk.txt", repeated)
    b.write("kucuk.bin", bytes(10))
    try b.zipCmd(["-fz", b.zip.path, "buyuk.txt", "kucuk.bin"])
    let r = try ZipReader(url: b.zip)
    try expect(r.entries.count == 2, "iki girdi")
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(failed.isEmpty, "hata yok: \(failed)")
    try expect(files.count == 2, "iki dosya")
    try expect(try Data(contentsOf: b.out.appendingPathComponent("buyuk.txt")) == repeated, "içerik aynı")
}

check("encrypted") { b in
    b.write("gizli.txt", repeated)
    try b.zipCmd(["-P", "x", b.zip.path, "gizli.txt"])
    let r = try ZipReader(url: b.zip)
    guard let e = r.entries.first else { throw Fail(description: "girdi yok") }
    try expect(e.isEncrypted, "şifreli işaretli")
    do {
        try r.extract(e, to: b.out.appendingPathComponent("g.txt"))
        throw Fail(description: "hata atmadı")
    } catch ZipError.encrypted {}
}

check("crc") { b in
    b.write("a.txt", repeated)
    try b.zipCmd(["-0", b.zip.path, "a.txt"])
    var data = try Data(contentsOf: b.zip)
    // Stored verinin ortasında bir bayt boz (yerel başlık 30 + ad 5 bayt)
    data[30 + 5 + 1000] ^= 0xFF
    try data.write(to: b.zip)
    let r = try ZipReader(url: b.zip)
    do {
        try r.extract(r.entries[0], to: b.out.appendingPathComponent("a.txt"))
        throw Fail(description: "hata atmadı")
    } catch ZipError.crcMismatch {
    } catch ZipError.corrupt {}
    try expect(!fm.fileExists(atPath: b.out.appendingPathComponent("a.txt").path), "bozuk çıktı silindi")
}

check("deflate crc") { b in
    b.write("a.txt", repeated)
    try b.zipCmd(["-9", b.zip.path, "a.txt"])
    var data = try Data(contentsOf: b.zip)
    data[30 + 5 + 40] ^= 0x55
    try data.write(to: b.zip)
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(files.isEmpty, "dosya çıkmadı")
    try expect(failed == ["a.txt"], "a.txt atlandı: \(failed)")
}

check("slip") { b in
    try b.pyZip([("../kotu.pdf", "x"), ("/abs.pdf", "y"), ("Ders/../../k2.pdf", "z"), ("iyi.pdf", "ok")])
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(files.map(\.lastPathComponent) == ["iyi.pdf"], "yalnız iyi.pdf: \(files)")
    try expect(Set(failed) == ["../kotu.pdf", "/abs.pdf", "Ders/../../k2.pdf"], "üçü atlandı: \(failed)")
    try expect(!fm.fileExists(atPath: b.root.appendingPathComponent("kotu.pdf").path), "dışarı yazılmadı")
    try expect(!fm.fileExists(atPath: b.root.appendingPathComponent("k2.pdf").path), "dışarı yazılmadı 2")
    try expect(ZipReader.safeRelativePath("a/./b.pdf") == "a/b.pdf", "nokta bileşeni temizlenir")
    try expect(ZipReader.safeRelativePath("..") == nil, "salt ..")
}

check("junk") { b in
    try b.pyZip([("__MACOSX/._a.pdf", "x"), ("Ders/._b.pdf", "y"), ("a.pdf", "ok"), ("Ders/", "")])
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(files.map(\.lastPathComponent) == ["a.pdf"], "yalnız a.pdf: \(files)")
    try expect(failed.isEmpty, "junk atlandı sayılmaz: \(failed)")
    try expect(ZipReader.isJunk("__MACOSX/x/y.pdf"), "__MACOSX")
    try expect(ZipReader.isJunk("a/._y.pdf"), "._")
    try expect(!ZipReader.isJunk("a/y.pdf"), "normal dosya")
}

check("notZip") { b in
    try bytes(4000).write(to: b.zip)
    do { _ = try ZipReader(url: b.zip); throw Fail(description: "hata atmadı") } catch ZipError.notZip {}
    try Data().write(to: b.zip)
    do { _ = try ZipReader(url: b.zip); throw Fail(description: "boş dosyada hata atmadı") } catch ZipError.notZip {}
}

check("unicode") { b in
    let name = "Türkçe ğüş 📓.pdf"
    try b.pyZip([(name, "pdf")])
    let r = try ZipReader(url: b.zip)
    try expect(r.entries.first?.path == name, "ad aynen: \(r.entries.map(\.path))")
    let (files, _) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(files.first?.lastPathComponent == name, "dosya adı aynen")
}

check("empty file entry") { b in
    try b.pyZip([("bos.txt", "")])
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(failed.isEmpty && files.count == 1, "boş dosya açılır: \(files) \(failed)")
    try expect(try Data(contentsOf: files[0]).isEmpty, "boş")
}

print(failures == 0 ? "\nTümü geçti." : "\n\(failures) denetim kaldı.")
exit(failures == 0 ? 0 : 1)
