import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

// MARK: - PDF dosyaları

extension Library {
    /// İçe aktarılan PDF'ler uygulamanın Belgeler/PDF klasöründe tutulur.
    static var pdfDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pdfURL(_ file: String) -> URL { pdfDirectory.appendingPathComponent(file) }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Bu dosya açılamadı. Bozuk ya da parola korumalı bir PDF olabilir." }
    }

    /// PDF'i uygulama klasörüne kopyalar ve her sayfası için bir not sayfası açar.
    func importPDF(from source: URL) throws -> UUID {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let file = UUID().uuidString + ".pdf"
        let dest = Library.pdfURL(file)
        try FileManager.default.copyItem(at: source, to: dest)

        guard let doc = PDFDocument(url: dest), !doc.isLocked, doc.pageCount > 0, let first = doc.page(at: 0) else {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.unreadable
        }
        let size = PDFRender.displaySize(of: first)
        let nb = Notebook(
            title: source.deletingPathExtension().lastPathComponent,
            subtitle: "PDF",
            kind: .pdf,
            cover: .kagit,
            paper: .bos,
            pages: (0..<doc.pageCount).map { Page(pdfPage: $0) },
            pdfFile: file,
            pdfAspect: Double(size.height / size.width)
        )
        return create(nb)
    }

    /// Defteri çoğaltır; PDF'li belgelerde PDF dosyası da kopyalanır (silinince diğeri bozulmasın).
    func duplicate(_ nb: Notebook) {
        var copy = nb
        copy.id = UUID()
        copy.title += " (kopya)"
        copy.favorite = false
        copy.modified = Date()
        copy.pages = nb.pages.map { Page(data: $0.data, pdfPage: $0.pdfPage) }
        if let file = nb.pdfFile {
            let newFile = UUID().uuidString + ".pdf"
            if (try? FileManager.default.copyItem(at: Library.pdfURL(file), to: Library.pdfURL(newFile))) != nil {
                copy.pdfFile = newFile
            }
        }
        create(copy)
    }
}

// MARK: - Çizim yardımcıları

enum PDFRender {
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

// MARK: - Kütüphane küçük resmi

final class PDFThumbCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct PDFThumb: View {
    var file: String
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(Y.ink3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text("PDF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Y.accentInk)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Y.accent, in: Capsule())
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Y.line, lineWidth: 1))
            .aspectRatio(3 / 4, contentMode: .fit)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .task(id: file) { image = await Self.load(file) }
    }

    static func load(_ file: String) async -> UIImage? {
        if let cached = PDFThumbCache.shared.object(forKey: file as NSString) { return cached }
        let img: UIImage? = await Task.detached(priority: .utility) {
            // Belge, sayfa çizilene kadar bellekte kalmalı; yoksa küçük resim boş çıkar
            guard let doc = PDFDocument(url: Library.pdfURL(file)), let page = doc.page(at: 0) else { return nil }
            return withExtendedLifetime(doc) { page.thumbnail(of: CGSize(width: 360, height: 480), for: .mediaBox) }
        }.value
        if let img { PDFThumbCache.shared.setObject(img, forKey: file as NSString) }
        return img
    }
}

// MARK: - PDF olarak dışa aktarma

enum PDFExporter {
    /// Defteri (kâğıt deseni veya PDF sayfası + mürekkep) tek bir PDF dosyasına yazar.
    @MainActor
    static func render(_ nb: Notebook) -> URL {
        let size = nb.canonicalSize
        let bounds = CGRect(origin: .zero, size: size)
        let source = nb.pdfFile.flatMap { PDFDocument(url: Library.pdfURL($0)) }
        let safe = nb.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Yaprak" : safe) + ".pdf")

        let meta = [kCGPDFContextCreator as String: "Yaprak", kCGPDFContextTitle as String: nb.title]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = meta
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let light = UITraitCollection(userInterfaceStyle: .light)

        try? renderer.writePDF(to: url) { ctx in
            light.performAsCurrent {
                for page in nb.pages {
                    ctx.beginPage()
                    let cg = ctx.cgContext
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
                    if let drawing = try? PKDrawing(data: page.data), !drawing.strokes.isEmpty {
                        drawing.image(from: bounds, scale: 2).draw(in: bounds)
                    }
                }
            }
        }
        return url
    }
}

/// Paylaş menüsüne verilen öğe: PDF, paylaşım seçildiği anda üretilir.
struct NotebookPDF: Transferable {
    let notebook: Notebook

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            let url = await MainActor.run { PDFExporter.render(item.notebook) }
            return SentTransferredFile(url)
        }
    }
}
