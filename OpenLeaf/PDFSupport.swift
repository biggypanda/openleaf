import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

// MARK: - PDF içe aktarma

extension Library {
    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { String(localized: "Bu dosya açılamadı. Bozuk ya da parola korumalı bir PDF olabilir.") }
    }

    /// PDF'i yeni defterin klasörüne kopyalar, her sayfası için bir not sayfası açar
    /// ve metnini aranabilir olsun diye `text.txt` olarak saklar (metin arka planda çıkarılır).
    func importPDF(from source: URL) throws -> UUID {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        store.createDir(id)
        let dest = store.pdfURL(id)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            store.deleteDir(id)
            throw error
        }
        guard let doc = PDFDocument(url: dest), !doc.isLocked, doc.pageCount > 0, let first = doc.page(at: 0) else {
            store.deleteDir(id)
            throw ImportError.unreadable
        }

        // Aranabilir metni çıkarmak büyük kitaplarda saniyeler sürer: arayüzü bekletmeden arka planda yap.
        // (Bitmeden arama yapılırsa `searchText` metni kendisi çıkarır.)
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let text = PDFRender.text(of: dest)
            if !text.isEmpty, let data = text.data(using: .utf8) { store.writeFile(data, to: store.textURL(id)) }
        }

        let size = PDFRender.displaySize(of: first)
        var nb = Notebook(
            title: source.deletingPathExtension().lastPathComponent,
            subtitle: "PDF",
            kind: .pdf,
            cover: .kagit,
            paper: .bos,
            pages: (0..<doc.pageCount).map { Page(pdfPage: $0) },
            pdfFile: "source.pdf",
            pdfAspect: Double(size.height / size.width)
        )
        nb.id = id
        create(nb)
        scheduleThumbnail(id, delay: 0.3)
        return id
    }

    func pdfURL(_ nb: Notebook) -> URL? { nb.pdfFile != nil ? store.pdfURL(nb.id) : nil }

    /// Başka bir PDF'in sayfalarını deftere, `index` konumuna ekler ve eklenen sayfa sayısını döndürür.
    /// Yeni sayfalar defterin PDF dosyasının sonuna yazılır; böylece mevcut sayfaların numaraları değişmez.
    /// Defterin PDF'i yoksa (düz defter) oluşturulur. Birleştirme arka planda yapılır.
    func insertPDF(_ id: UUID, from source: URL, at index: Int) async throws -> Int {
        guard let nb = notebooks.first(where: { $0.id == id }) else { return 0 }
        let dest = store.pdfURL(id)
        let hasPDF = nb.pdfFile != nil
        let added: (base: Int, count: Int) = try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard let incoming = PDFDocument(url: source), !incoming.isLocked, incoming.pageCount > 0 else {
                throw ImportError.unreadable
            }
            let merged = (hasPDF ? PDFDocument(url: dest) : nil) ?? PDFDocument()
            let base = merged.pageCount
            for i in 0..<incoming.pageCount {
                if let page = incoming.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
            let count = merged.pageCount - base
            guard count > 0 else { throw ImportError.unreadable }
            // Önce yan dosyaya yaz, sonra yerine koy: yarıda kalırsa eski PDF bozulmaz
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = dest.deletingLastPathComponent().appendingPathComponent("source-yeni.pdf")
            try? fm.removeItem(at: temp)
            guard merged.write(to: temp) else { throw ImportError.unreadable }
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: dest)
            }
            return (base, count)
        }.value

        PageThumbRenderer.shared.forget(dest)
        // Aranabilir metin yeniden çıkarılsın
        textCache[id] = nil
        try? FileManager.default.removeItem(at: store.textURL(id))
        update(id) { nb in
            nb.pdfFile = "source.pdf"
            let pages = (0..<added.count).map { Page(pdfPage: added.base + $0) }
            nb.pages.insert(contentsOf: pages, at: min(max(index, 0), nb.pages.count))
            nb.modified = Date()
        }
        scheduleThumbnail(id)
        return added.count
    }
}

// MARK: - Çizim yardımcıları

enum PDFRender {
    /// Aranabilir metin (çok büyük kitaplarda ilk ~400 bin karakter)
    static func text(of doc: PDFDocument) -> String {
        var text = ""
        for i in 0..<doc.pageCount where text.count < 400_000 {
            if let s = doc.page(at: i)?.string { text += s + "\n" }
        }
        return text
    }

    static func text(of url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return text(of: doc)
    }

    /// Sayfanın döndürme hesaba katılmış görünen boyutu
    static func displaySize(of page: PDFPage) -> CGSize {
        let b = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// `size` kutusuna oranı korunarak sığan dikdörtgen
    static func fit(_ content: CGSize, in rect: CGRect) -> CGRect {
        let s = min(rect.width / content.width, rect.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Sayfayı vektör olarak bir grafik bağlamına çizer (UIKit koordinatları, y aşağı).
    static func draw(_ page: PDFPage, in rect: CGRect, context cg: CGContext) {
        let target = fit(displaySize(of: page), in: rect)
        let size = displaySize(of: page)
        let s = target.width / size.width
        cg.saveGState()
        cg.translateBy(x: target.minX, y: target.maxY)
        cg.scaleBy(x: s, y: -s)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()
    }

    /// Ekranda gösterilecek bitmap (Retina keskinliğinde)
    static func image(_ page: PDFPage, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            draw(page, in: CGRect(origin: .zero, size: size), context: ctx.cgContext)
        }
    }
}

// MARK: - Sayfa çizimi (küçük resim ve dışa aktarma aynı kodu kullanır)

enum PageRenderer {
    /// Bir sayfayı (PDF sayfası veya kâğıt deseni + resimler, mürekkep, bantlar, notlar) kanonik boyutta `cg` bağlamına çizer.
    /// Arka planda da çağrılabilir; o zaman `source` yalnızca o iş parçacığının kullandığı bir belge olmalı.
    static func draw(_ nb: Notebook, page: Page, drawing: Data, source: PDFDocument?, in cg: CGContext,
                     exporting: Bool = false) {
        let bounds = CGRect(origin: .zero, size: nb.canonicalSize)
        let light = UITraitCollection(userInterfaceStyle: .light)
        light.performAsCurrent {
            if let i = page.pdfPage, let pdfPage = source?.page(at: i) {
                UIColor.white.setFill(); cg.fill(bounds)
                PDFRender.draw(pdfPage, in: bounds, context: cg)
            } else {
                Y.paperUI.resolvedColor(with: light).setFill(); cg.fill(bounds)
                if nb.kind == .defter {
                    PaperPattern.draw(nb.paper, in: bounds, scale: 1) { path, color, width in
                        cg.addPath(path.cgPath)
                        cg.setStrokeColor(color.resolvedColor(with: light).cgColor)
                        cg.setLineWidth(width)
                        cg.strokePath()
                    } fill: { path, color in
                        cg.addPath(path.cgPath)
                        cg.setFillColor(color.resolvedColor(with: light).cgColor)
                        cg.fillPath()
                    } text: { string, point, size, align in
                        PaperText.draw(string, at: point, size: size, align: align,
                                       color: Y.paperTextUI.resolvedColor(with: light), in: cg)
                    }
                }
            }
            UIGraphicsPushContext(cg)
            // Resimler kâğıdın üstünde, mürekkebin altında
            for img in page.pageImages {
                ImageStore.image(nb.id, img.file)?.draw(in: img.frame)
            }
            if let d = try? PKDrawing(data: drawing), !d.strokes.isEmpty {
                d.image(from: bounds, scale: 2).draw(in: bounds)
            }
            // Bantlar küçük resimlerde ekrandaki gibi örter; dışa aktarılan PDF'te yarı saydamdır ki not kaybolmasın
            TapeArt.draw(page.pageTapes, look: exporting ? .export : .covered, in: cg)
            StickyRenderer.draw(page.stickyNotes, in: cg)
            UIGraphicsPopContext()
        }
    }

    /// Kütüphane için küçük resim (genişlik 360 piksel). Whiteboard'da çizimin bulunduğu bölge gösterilir.
    /// PDF'i kendisi açar, bu yüzden arka planda çağrılabilir.
    static func thumbnail(_ nb: Notebook, page: Page, drawing: Data, pdfURL: URL?) -> UIImage? {
        let source = pdfURL.flatMap { PDFDocument(url: $0) }
        let canonical = nb.canonicalSize
        var focus = CGRect(origin: .zero, size: canonical)
        if nb.kind == .whiteboard {
            // Whiteboard: mürekkebin olduğu bölgeyi 3:4 oranında göster
            if let d = try? PKDrawing(data: drawing), !d.strokes.isEmpty {
                let b = d.bounds.insetBy(dx: -40, dy: -40)
                let h = max(b.height, b.width * 4 / 3)
                focus = CGRect(x: b.midX - h * 3 / 8, y: b.midY - h / 2, width: h * 3 / 4, height: h)
            } else {
                return nil
            }
        }
        let width: CGFloat = 360
        let size = CGSize(width: width, height: width * focus.height / focus.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let s = width / focus.width
            ctx.cgContext.scaleBy(x: s, y: s)
            ctx.cgContext.translateBy(x: -focus.minX, y: -focus.minY)
            draw(nb, page: page, drawing: drawing, source: source, in: ctx.cgContext)
        }
        return withExtendedLifetime(source) { image }
    }
}

/// Sayfa küçük resimlerini arayüzü bekletmeden, tek bir arka plan kuyruğunda sırayla çizer.
/// PDFKit belgeleri iş parçacıkları arasında paylaşılmaya uygun olmadığından kuyruk kendi kopyasını açar.
final class PageThumbRenderer: @unchecked Sendable {
    static let shared = PageThumbRenderer()
    private let queue = DispatchQueue(label: "openleaf.kucukresim", qos: .userInitiated)
    /// Yalnızca kuyrukta kullanılır: son açılan PDF
    private var openURL: URL?
    private var openDoc: PDFDocument?

    func render(_ nb: Notebook, page: Page, drawing: Data, pdfURL: URL?, width: CGFloat) async -> UIImage {
        await withCheckedContinuation { done in
            queue.async {
                let source = self.document(pdfURL)
                let canonical = nb.canonicalSize
                let size = CGSize(width: width, height: width * canonical.height / canonical.width)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    let s = width / canonical.width
                    ctx.cgContext.scaleBy(x: s, y: s)
                    PageRenderer.draw(nb, page: page, drawing: drawing, source: source, in: ctx.cgContext)
                }
                done.resume(returning: image)
            }
        }
    }

    private func document(_ url: URL?) -> PDFDocument? {
        guard let url else { return nil }
        if url != openURL {
            openURL = url
            openDoc = PDFDocument(url: url)
        }
        return openDoc
    }

    /// Defterin PDF'i değişince (sayfa eklenince) eski kopya bırakılsın
    func forget(_ url: URL) {
        queue.async { if self.openURL == url { self.openURL = nil; self.openDoc = nil } }
    }
}

final class ThumbCache {
    static let shared = NSCache<NSString, UIImage>()
}

/// Kütüphanedeki PDF ve whiteboard küçük resmi (mürekkepli). Dosya henüz yoksa yer tutucu gösterir.
struct NotebookThumb: View {
    var nb: Notebook
    @Environment(Library.self) private var library
    @State private var image: UIImage?

    var body: some View {
        let version = library.thumbVersion[nb.id, default: 0]
        RoundedRectangle(cornerRadius: nb.kind == .pdf ? 6 : 12, style: .continuous)
            .fill(nb.kind == .pdf ? Color.white : Y.surface)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if nb.kind == .whiteboard {
                    WhiteboardThumb(title: nb.title)
                } else {
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(Y.ink3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: nb.kind == .pdf ? 6 : 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if nb.kind == .pdf {
                    Text("PDF")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Y.accentInk)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Y.accent, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: nb.kind == .pdf ? 6 : 12, style: .continuous).strokeBorder(Y.line, lineWidth: 1))
            .aspectRatio(3 / 4, contentMode: .fit)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .task(id: "\(nb.id)-\(version)") { image = await Self.load(library.thumbnailURL(nb.id), version: version) }
    }

    static func load(_ url: URL, version: Int) async -> UIImage? {
        let key = "\(url.path)#\(version)" as NSString
        if let cached = ThumbCache.shared.object(forKey: key) { return cached }
        let img: UIImage? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let img { ThumbCache.shared.setObject(img, forKey: key) }
        return img
    }
}

// MARK: - PDF olarak dışa aktarma

enum PDFExporter {
    /// Paylaşılacak dosyanın yeri: her dışa aktarma kendi geçici klasörüne, defter adıyla
    static func exportURL(_ nb: Notebook, suffix: String = "", ext: String) -> URL {
        let safe = nb.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent((safe.isEmpty ? "OpenLeaf" : safe) + suffix + "." + ext)
    }

    /// Defteri (kâğıt deseni veya PDF sayfası + mürekkep) tek bir PDF dosyasına yazar.
    /// `only` verilirse yalnızca o sayfa yazılır.
    @MainActor
    static func render(_ nb: Notebook, library: Library, only: Page? = nil) -> URL {
        let bounds = CGRect(origin: .zero, size: nb.canonicalSize)
        let source = library.pdfURL(nb).flatMap { PDFDocument(url: $0) }
        let url = exportURL(nb, suffix: only.map { pageSuffix(nb, $0) } ?? "", ext: "pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "OpenLeaf", kCGPDFContextTitle as String: nb.title]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        try? renderer.writePDF(to: url) { ctx in
            for page in only.map({ [$0] }) ?? nb.pages {
                ctx.beginPage()
                PageRenderer.draw(nb, page: page, drawing: library.drawing(nb.id, page.id), source: source,
                                  in: ctx.cgContext, exporting: true)
            }
        }
        return withExtendedLifetime(source) { url }
    }
}

extension PDFExporter {
    /// Dosya adı eki: " - Sayfa 3"
    static func pageSuffix(_ nb: Notebook, _ page: Page) -> String {
        guard nb.isPaged, let i = nb.pages.firstIndex(where: { $0.id == page.id }) else { return "" }
        return " - " + String(localized: "Sayfa \(i + 1)")
    }

    /// Tek sayfayı PNG resmi olarak yazar (kanonik boyutun 2 katı)
    @MainActor
    static func renderImage(_ nb: Notebook, page: Page, library: Library) -> URL {
        let bounds = CGRect(origin: .zero, size: nb.canonicalSize)
        let source = library.pdfURL(nb).flatMap { PDFDocument(url: $0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            PageRenderer.draw(nb, page: page, drawing: library.drawing(nb.id, page.id), source: source,
                              in: ctx.cgContext, exporting: true)
        }
        let url = exportURL(nb, suffix: pageSuffix(nb, page), ext: "png")
        try? image.pngData()?.write(to: url)
        return withExtendedLifetime(source) { url }
    }

    /// Sistem yazdırma penceresini açar
    @MainActor
    static func print(_ url: URL, title: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
    }
}
