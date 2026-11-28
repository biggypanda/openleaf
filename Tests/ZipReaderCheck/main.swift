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


// MARK: - İnceleme düzeltmeleri

func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

func eocd(count: UInt16, cdSize: UInt32, cdOffset: UInt32) -> Data {
    le32(0x0605_4b50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(cdSize) + le32(cdOffset) + le16(0)
}

/// Merkezi dizin girdisi (yerel başlık yazılmaz; ofset elle verilir)
func cdEntry(name: String, csize: UInt32, usize: UInt32, offset: UInt32, extra: Data) -> Data {
    let n = Data(name.utf8)
    var d = le32(0x0201_4b50) + le16(45) + le16(45) + le16(0x0800) + le16(0) + le16(0) + le16(0) + le32(0)
    d += le32(csize) + le32(usize) + le16(UInt16(n.count)) + le16(UInt16(extra.count)) + le16(0)
    d += le16(0) + le16(0) + le32(0) + le32(offset)
    return d + n + extra
}

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

check("bozuk: ZIP64 konum taşması") { b in
    let locator = le32(0x0706_4b50) + le32(0) + le64(0xFFFF_FFFF_FFFF_FFF0) + le32(1)
    try (locator + eocd(count: 0, cdSize: 0, cdOffset: 0)).write(to: b.zip)
    do { _ = try ZipReader(url: b.zip); throw Fail(description: "hata atmadı") } catch ZipError.corrupt {}
}

check("bozuk: ekstra alan taşması") { b in
    let extra = le16(0x0001) + le16(100)
    let cd = cdEntry(name: "a", csize: 0xFFFF_FFFF, usize: 0xFFFF_FFFF, offset: 0, extra: extra)
    try (cd + eocd(count: 1, cdSize: UInt32(cd.count), cdOffset: 0)).write(to: b.zip)
    do { _ = try ZipReader(url: b.zip); throw Fail(description: "hata atmadı") } catch ZipError.corrupt {}
}

check("bozuk: girdi ofseti taşması") { b in
    let extra = le16(0x0001) + le16(8) + le64(0xFFFF_FFFF_FFFF_FFF0)
    let cd = cdEntry(name: "a.pdf", csize: 3, usize: 3, offset: 0xFFFF_FFFF, extra: extra)
    try (cd + eocd(count: 1, cdSize: UInt32(cd.count), cdOffset: 0)).write(to: b.zip)
    let r = try ZipReader(url: b.zip)
    do { try r.extract(r.entries[0], to: b.out.appendingPathComponent("a.pdf")); throw Fail(description: "hata atmadı") }
    catch ZipError.corrupt {}
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out)
    try expect(files.isEmpty && failed == ["a.pdf"], "atlandı: \(failed)")
}

check("bomba: bildirilenden büyük veri") { b in
    b.write("a.txt", repeated)
    try b.zipCmd(["-9", b.zip.path, "a.txt"])
    var data = try Data(contentsOf: b.zip)
    // Merkezi dizindeki açılmış boyutu 10 bayta indir
    let sig = le32(0x0201_4b50)
    guard let r = data.range(of: sig) else { throw Fail(description: "CD yok") }
    data.replaceSubrange(r.lowerBound + 24 ..< r.lowerBound + 28, with: le32(10))
    try data.write(to: b.zip)
    let reader = try ZipReader(url: b.zip)
    do { try reader.extract(reader.entries[0], to: b.out.appendingPathComponent("a.txt")); throw Fail(description: "hata atmadı") }
    catch ZipError.corrupt {}
}

check("iptal") { b in
    for i in 0..<5 { b.write("d\(i).pdf", bytes(100)) }
    try b.zipCmd([b.zip.path, "d0.pdf", "d1.pdf", "d2.pdf", "d3.pdf", "d4.pdf"])
    // İki dosya açılınca iptal et
    let (files, failed) = ZipReader.extractAll(b.zip, to: b.out) {
        ((try? fm.contentsOfDirectory(atPath: b.out.path))?.count ?? 0) >= 2
    }
    // İkinci dosya yazılmaya başlayınca iptal görülür: yarım dosya silinir, yalnız ilki kalır
    try expect(files.count == 1 && failed.isEmpty, "erken durdu: \(files.count) \(failed)")
    let left = try fm.contentsOfDirectory(atPath: b.out.path)
    try expect(left == ["d0.pdf"], "yarım dosya kalmadı: \(left)")
}

check("bellek sınırlı") { b in
    // 200 MB'lık girdi: açarken bellek girdi boyutuyla büyümemeli
    let big = b.src.appendingPathComponent("buyuk.bin")
    fm.createFile(atPath: big.path, contents: nil)
    let h = try FileHandle(forWritingTo: big)
    let mb = bytes(1 << 20)
    for _ in 0..<200 { try h.write(contentsOf: mb) }
    try h.close()
    for (name, level) in [("stored", "-0"), ("deflate", "-1")] {
        try? fm.removeItem(at: b.zip)
        try b.zipCmd([level, b.zip.path, "buyuk.bin"])
        let before = footprint()
        let r = try ZipReader(url: b.zip)
        try r.extract(r.entries[0], to: b.out.appendingPathComponent("buyuk.bin"))
        let grew = Int64(footprint()) - Int64(before)
        try expect(grew < 64 << 20, "\(name): bellek \(grew >> 20) MB büyüdü")
        try? fm.removeItem(at: b.out.appendingPathComponent("buyuk.bin"))
    }
}

print(failures == 0 ? "\nTümü geçti." : "\n\(failures) denetim kaldı.")
exit(failures == 0 ? 0 : 1)
