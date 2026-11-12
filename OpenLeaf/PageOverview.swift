import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Defterin tüm sayfalarını küçük resim ızgarasında gösterir.
/// Dokun: o sayfaya git. Basılı tutup sürükle: sırasını değiştir. Uzun basma menüsü: ekle, çoğalt, sil.
struct PageOverview: View {
    let notebook: Notebook
    let current: Int
    let pdf: PDFDocument?
    var onOpen: (Int) -> Void
    var onClose: () -> Void

    @Environment(Library.self) private var library
    @State private var dragging: UUID?
    @State private var confirmDelete: Page?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { i, page in
                            cell(page, index: i)
                                .id(page.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .animation(Y.spring, value: notebook.pages.map(\.id))
                }
                .onAppear {
                    if notebook.pages.indices.contains(current) {
                        proxy.scrollTo(notebook.pages[current].id, anchor: .center)
                    }
                }
            }
        }
        .background(Y.bg.ignoresSafeArea())
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Sayfayı sil", role: .destructive) {
                if let p = confirmDelete { delete(p) }
                confirmDelete = nil
            }
            Button("Vazgeç", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Bu sayfadaki notlar kalıcı olarak silinir.")
        }
    }

    private var deleteTitle: String {
        guard let p = confirmDelete, let i = notebook.pages.firstIndex(where: { $0.id == p.id }) else { return "" }
        return String(localized: "Sayfa \(i + 1) silinsin mi?")
    }

    // MARK: Üst kısım

    private var header: some View {
        HStack {
            Button {
                library.insertPage(notebook.id, at: notebook.pages.count)
            } label: {
                Label("Sayfa ekle", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Y.accent)

            Spacer()
            VStack(spacing: 1) {
                Text("Sayfalar").font(.system(size: 17, weight: .semibold, design: .serif))
                Text("\(notebook.pages.count) sayfa · sıralamak için basılı tutup sürükleyin")
                    .font(.caption).foregroundStyle(Y.ink3)
            }
            Spacer()

            Button("Bitti", action: onClose)
                .fontWeight(.semibold)
                .buttonStyle(.plain)
                .foregroundStyle(Y.accent)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(Y.line2).frame(height: 1) }
    }

    // MARK: Hücre

    private func cell(_ page: Page, index i: Int) -> some View {
        let isCurrent = i == current
        return VStack(spacing: 8) {
            PageThumbnail(notebook: notebook, page: page, pdf: pdf)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isCurrent ? Y.accent : Y.line, lineWidth: isCurrent ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(i) }
                // Basılı tutup sürükleyince sırası değişir
                .onDrag {
                    dragging = page.id
                    return NSItemProvider(object: page.id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], delegate: PageDrop(target: page.id, notebookID: notebook.id,
                                                               library: library, dragging: $dragging))
                .accessibilityLabel(isCurrent ? String(localized: "Sayfa \(i + 1), açık sayfa") : String(localized: "Sayfa \(i + 1)"))
                .accessibilityAddTraits(.isButton)
                .overlay(alignment: .topTrailing) { actions(page, index: i) }
            Text("\(i + 1)")
                .font(.footnote.weight(isCurrent ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isCurrent ? Y.accent : Y.ink2)
                .accessibilityHidden(true)
        }
    }

    /// Sayfa işlemleri: köşedeki ••• düğmesi (basılı tutma sürüklemeye ayrıldı)
    private func actions(_ page: Page, index i: Int) -> some View {
        Menu {
            Button { library.insertPage(notebook.id, at: i + 1) } label: {
                Label("Sonrasına sayfa ekle", systemImage: "doc.badge.plus")
            }
            Button { library.duplicatePage(notebook.id, at: i) } label: {
                Label("Çoğalt", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) { confirmDelete = page } label: {
                Label("Sayfayı sil", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Y.ink2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Y.surface.opacity(0.92)))
                .overlay(Circle().strokeBorder(Y.line, lineWidth: 1))
                .padding(6)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sayfa \(i + 1) seçenekleri")
    }

    private func delete(_ p: Page) {
        withAnimation(Y.quick) { library.deletePage(notebook.id, p.id) }
    }
}

/// Sürüklenen sayfa başka bir sayfanın üstüne gelince yer değiştirir
private struct PageDrop: DropDelegate {
    let target: UUID
    let notebookID: UUID
    let library: Library
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let nb = library.notebooks.first(where: { $0.id == notebookID }),
              let from = nb.pages.firstIndex(where: { $0.id == d }),
              let to = nb.pages.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(Y.spring) { library.movePage(notebookID, from: from, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Tek bir sayfanın mürekkepli küçük resmi
struct PageThumbnail: View {
    let notebook: Notebook
    let page: Page
    let pdf: PDFDocument?

    @Environment(Library.self) private var library
    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        let size = notebook.canonicalSize
        let data = library.drawing(notebook.id, page.id)
        let notesHash = (try? JSONEncoder().encode(page.stickyNotes))?.hashValue ?? 0
            ^ ((try? JSONEncoder().encode(page.pageImages))?.hashValue ?? 0)
            ^ ((try? JSONEncoder().encode(page.pageTapes))?.hashValue ?? 0)
        let key = "\(page.id)-\(data.hashValue)-\(notesHash)-\(notebook.paper.rawValue)" as NSString
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(uiColor: Y.paperUI))
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: key) {
            if let cached = Self.cache.object(forKey: key) { image = cached; return }
            // Izgara açılırken arayüz takılmasın: sırayla, kısa aralarla çiz
            await Task.yield()
            let img = Self.render(notebook, page: page, drawing: data, pdf: pdf)
            Self.cache.setObject(img, forKey: key)
            image = img
        }
    }

    @MainActor
    static func render(_ nb: Notebook, page: Page, drawing: Data, pdf: PDFDocument?) -> UIImage {
        let canonical = nb.canonicalSize
        let width: CGFloat = 260
        let size = CGSize(width: width, height: width * canonical.height / canonical.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let s = width / canonical.width
            ctx.cgContext.scaleBy(x: s, y: s)
            PageRenderer.draw(nb, page: page, drawing: drawing, source: pdf, in: ctx.cgContext)
        }
    }
}
