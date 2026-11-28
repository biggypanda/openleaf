import Foundation
import Compression

// MARK: - ZIP okuyucu
//
// Başka not uygulamalarının dışa aktardığı ZIP'leri (ör. GoodNotes klasör dışa aktarımı) açmak için.
// Yalnız Foundation + Compression kullanır. Girdiler belleğe alınmadan, parça parça diske açılır.
// Desteklenen: stored (0) ve deflate (8), ZIP64. Şifreli girdi ve diğer yöntemler hata verir.

struct ZipEntry {
    let path: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let isEncrypted: Bool
    var isDirectory: Bool { path.hasSuffix("/") || path.hasSuffix("\\") }
}

enum ZipError: Error {
    case notZip, corrupt, unsupported, encrypted, crcMismatch, unsafePath, cancelled
}

final class ZipReader {
    let url: URL
    let entries: [ZipEntry]
    private let fileSize: UInt64
    private static let chunk = 64 * 1024

    init(url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ZipError.notZip }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        fileSize = size
        guard size >= 22 else { throw ZipError.notZip }

        // Merkezi dizin sonu (EOCD) kaydı dosyanın son 22 + 65535 baytı içinde
        let tailLen = min(size, 22 + 65_535)
        let tail = try Self.read(handle, at: size - tailLen, count: Int(tailLen))
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw ZipError.notZip }

        var count = UInt64(tail.u16(e + 10))
        var cdSize = UInt64(tail.u32(e + 12))
        var cdOffset = UInt64(tail.u32(e + 16))

        // ZIP64: EOCD'nin hemen önünde konum kaydı (locator) varsa gerçek değerler ZIP64 kaydında
        if e >= 20, tail.u32(e - 20) == 0x0706_4b50 {
            let recOffset = tail.u64(e - 20 + 8)
            // Toplamalar taşmasın: bozuk arşivdeki dev değerler uygulamayı çökertmemeli
            guard size >= 56, recOffset <= size - 56 else { throw ZipError.corrupt }
            let rec = try Self.read(handle, at: recOffset, count: 56)
            guard rec.u32(0) == 0x0606_4b50 else { throw ZipError.corrupt }
            count = rec.u64(32)
            cdSize = rec.u64(40)
            cdOffset = rec.u64(48)
        }
        guard cdSize <= size, cdOffset <= size - cdSize else { throw ZipError.corrupt }

        let cd = try Self.read(handle, at: cdOffset, count: Int(cdSize))
        var list: [ZipEntry] = []
        list.reserveCapacity(Int(min(count, 100_000)))
        var p = 0
        while list.count < count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4b50 else { throw ZipError.corrupt }
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            var offset = UInt64(cd.u32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else { throw ZipError.corrupt }
            let nameData = cd.subdata(in: cd.startIndex + nameStart ..< cd.startIndex + nameStart + nameLen)
            // Bit 11: ad UTF-8. Değilse eski kodlama (CP437); Latin-1 yaklaşık yeterli.
            let name = (flags & 0x0800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            // ZIP64 ekstra alanı: yalnız 0xFFFFFFFF olan değerler, sırayla
            var x = nameStart + nameLen
            let extraEnd = x + extraLen
            while x + 4 <= extraEnd {
                let tag = cd.u16(x), len = Int(cd.u16(x + 2))
                let blockEnd = x + 4 + len
                guard blockEnd <= extraEnd else { throw ZipError.corrupt }
                var f = x + 4
                if tag == 0x0001 {
                    if usize == 0xFFFF_FFFF, f + 8 <= blockEnd { usize = cd.u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= blockEnd { csize = cd.u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= blockEnd { offset = cd.u64(f); f += 8 }
                }
                x = blockEnd
            }

            list.append(ZipEntry(path: name, method: method, crc32: crc, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: offset,
                                 isEncrypted: flags & 0x0001 != 0))
            p = extraEnd + commentLen
        }
        entries = list
    }

    /// Girdiyi `dest` dosyasına açar. Hata olursa yarım dosya silinir.
    /// `isCancelled` her parçada sorulur; true dönerse `ZipError.cancelled` atılır.
    func extract(_ e: ZipEntry, to dest: URL, isCancelled: () -> Bool = { false }) throws {
        if e.isEncrypted { throw ZipError.encrypted }
        guard e.method == 0 || e.method == 8 else { throw ZipError.unsupported }
        guard let input = try? FileHandle(forReadingFrom: url) else { throw ZipError.corrupt }
        defer { try? input.close() }

        guard fileSize >= 30, e.localHeaderOffset <= fileSize - 30 else { throw ZipError.corrupt }
        let header = try Self.read(input, at: e.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4b50 else { throw ZipError.corrupt }
        let dataStart = e.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        guard dataStart <= fileSize, e.compressedSize <= fileSize - dataStart else { throw ZipError.corrupt }

        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: dest.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dest) else { throw ZipError.corrupt }

        let sink = Sink(output, limit: e.uncompressedSize)
        do {
            try input.seek(toOffset: dataStart)
            var left = e.compressedSize
            if e.method == 0 {
                while left > 0 {
                    if isCancelled() { throw ZipError.cancelled }
                    let n = Int(min(left, UInt64(Self.chunk)))
                    // Okunan parça autorelease; havuz boşaltılmazsa tüm girdi bellekte birikir
                    try autoreleasepool {
                        guard let d = try input.read(upToCount: n), d.count == n else { throw ZipError.corrupt }
                        try sink.write(d)
                    }
                    left -= UInt64(n)
                }
            } else {
                let filter: OutputFilter
                do {
                    filter = try OutputFilter(.decompress, using: .zlib) { data in
                        if let data { try sink.write(data) }
                    }
                } catch { throw ZipError.corrupt }
                do {
                    while left > 0 {
                        if isCancelled() { throw ZipError.cancelled }
                        let n = Int(min(left, UInt64(Self.chunk)))
                        try autoreleasepool {
                            guard let d = try input.read(upToCount: n), d.count == n else { throw ZipError.corrupt }
                            try filter.write(d)
                        }
                        left -= UInt64(n)
                    }
                    try filter.finalize()
                } catch let z as ZipError { throw z } catch { throw ZipError.corrupt }
            }
            try output.close()
            guard sink.count == e.uncompressedSize else { throw ZipError.corrupt }
            guard ~sink.crc == e.crc32 else { throw ZipError.crcMismatch }
        } catch {
            try? output.close()
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    // MARK: Yardımcılar

    /// Girdi adını hedef klasör içinde kalacak göreli yola çevirir; dışarı çıkıyorsa nil.
    static func safeRelativePath(_ name: String) -> String? {
        let norm = name.replacingOccurrences(of: "\\", with: "/")
        if norm.hasPrefix("/") { return nil }
        var parts: [Substring] = []
        for c in norm.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { return nil }
            parts.append(c)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// macOS'un arşive kattığı artıklar: `__MACOSX/` klasörü ve `._` ile başlayan kaynak çatalı dosyaları
    static func isJunk(_ path: String) -> Bool {
        let norm = path.replacingOccurrences(of: "\\", with: "/")
        if norm.hasPrefix("__MACOSX/") || norm.contains("/__MACOSX/") { return true }
        let last = norm.split(separator: "/").last.map(String.init) ?? norm
        return last.hasPrefix("._") || last == ".DS_Store"
    }

    /// Tüm arşivi `dir` içine açar. Artıklar sessizce atlanır; açılamayan girdilerin adları `failed`'a yazılır.
    /// `isCancelled` true dönerse o ana dek açılanlarla durur. `progress(bitmiş, toplam)` her girdiden sonra.
    static func extractAll(_ zip: URL, to dir: URL,
                           progress: (Int, Int) -> Void = { _, _ in },
                           isCancelled: () -> Bool = { false }) -> (files: [URL], failed: [String]) {
        guard let reader = try? ZipReader(url: zip) else { return ([], [zip.lastPathComponent]) }
        var files: [URL] = [], failed: [String] = []
        for (i, e) in reader.entries.enumerated() {
            if isCancelled() { break }
            defer { progress(i + 1, reader.entries.count) }
            if isJunk(e.path) || e.isDirectory { continue }
            guard let rel = safeRelativePath(e.path) else { failed.append(e.path); continue }
            let dest = dir.appendingPathComponent(rel)
            do { try reader.extract(e, to: dest, isCancelled: isCancelled); files.append(dest) }
            catch ZipError.cancelled { break }
            catch { failed.append(e.path) }
        }
        return (files, failed)
    }

    private static func read(_ h: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try h.seek(toOffset: offset)
        guard let d = try h.read(upToCount: count), d.count == count else { throw ZipError.corrupt }
        return d
    }

    /// Yazılanı sayar ve CRC32'sini tutar. Bildirilen boyutu aşan veri (ZIP bombası) hemen durdurulur.
    private final class Sink {
        let handle: FileHandle
        let limit: UInt64
        var count: UInt64 = 0
        var crc: UInt32 = 0xFFFF_FFFF
        init(_ h: FileHandle, limit: UInt64) { handle = h; self.limit = limit }
        func write(_ d: Data) throws {
            guard UInt64(d.count) <= limit - count else { throw ZipError.corrupt }
            try handle.write(contentsOf: d)
            count += UInt64(d.count)
            d.withUnsafeBytes { buf in
                for b in buf { crc = ZipReader.crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
            }
        }
    }

    fileprivate static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }
    func u32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
