import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

// MARK: - PDF içe aktarma

extension Library {
    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Bu dosya açılamadı. Bozuk ya da parola korumalı bir PDF olabilir." }
    }

    /// PDF'i yeni defterin klasörüne kopyalar, her sayfası için bir not sayfası açar
    /// ve metnini aranabilir olsun diye `text.txt` olarak saklar.
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

        let text = PDFRender.text(of: doc)
        if !text.isEmpty, let data = text.data(using: .utf8) { store.writeFile(data, to: store.textURL(id)) }

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
    /// Bir sayfayı (PDF sayfası veya kâğıt deseni + mürekkep) kanonik boyutta `cg` bağlamına çizer.
    @MainActor
    static func draw(_ nb: Notebook, page: Page, drawing: Data, source: PDFDocument?, in cg: CGContext) {
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
            StickyRenderer.draw(page.stickyNotes, in: cg)
            UIGraphicsPopContext()
        }
    }

    /// Kütüphane için küçük resim (genişlik 360 piksel). Whiteboard'da çizimin bulunduğu bölge gösterilir.
    @MainActor
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
    /// Defteri (kâğıt deseni veya PDF sayfası + mürekkep) tek bir PDF dosyasına yazar.
    @MainActor
    static func render(_ nb: Notebook, library: Library) -> URL {
        let bounds = CGRect(origin: .zero, size: nb.canonicalSize)
        let source = library.pdfURL(nb).flatMap { PDFDocument(url: $0) }
        let safe = nb.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Yaprak" : safe) + ".pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Yaprak", kCGPDFContextTitle as String: nb.title]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        try? renderer.writePDF(to: url) { ctx in
            for page in nb.pages {
                ctx.beginPage()
                PageRenderer.draw(nb, page: page, drawing: library.drawing(nb.id, page.id), source: source, in: ctx.cgContext)
            }
        }
        return withExtendedLifetime(source) { url }
    }
}

/// Paylaş menüsüne verilen öğe: PDF, paylaşım seçildiği anda üretilir.
struct NotebookPDF: Transferable {
    let notebook: Notebook
    let library: Library

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            let url = await MainActor.run { PDFExporter.render(item.notebook, library: item.library) }
            return SentTransferredFile(url)
        }
    }
}
