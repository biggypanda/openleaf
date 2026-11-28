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
    @State private var onlyBookmarks = false

    private var hasBookmarks: Bool { notebook.pages.contains(where: \.isBookmarked) }
    /// Gösterilen sayfalar, gerçek sıra numaralarıyla (filtrede numara değişmesin)
    private var shown: [(index: Int, page: Page)] {
        notebook.pages.enumerated()
            .filter { !(onlyBookmarks && hasBookmarks) || $0.element.isBookmarked }
            .map { ($0.offset, $0.element) }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(shown, id: \.page.id) { item in
                            cell(item.page, index: item.index)
                                .id(item.page.id)
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
                Text("Sayfalar").font(.system(.headline, design: .serif, weight: .semibold))
                Text("\(notebook.pages.count) sayfa · sıralamak için basılı tutup sürükleyin")
                    .font(.caption).foregroundStyle(Y.ink3)
            }
            Spacer()

            if hasBookmarks {
                Button {
                    withAnimation(Y.spring) { onlyBookmarks.toggle() }
                } label: {
                    Label("Yer imleri", systemImage: onlyBookmarks ? "bookmark.fill" : "bookmark")
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(Capsule().fill(onlyBookmarks ? Y.accent.opacity(0.14) : Color.clear))
                        .overlay(Capsule().strokeBorder(onlyBookmarks ? Y.accent : Y.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(onlyBookmarks ? Y.accent : Y.ink2)
                .accessibilityAddTraits(onlyBookmarks ? .isSelected : [])
                .accessibilityHint("Yalnızca yer imi konmuş sayfaları gösterir")
                .padding(.trailing, 14)
            }

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
                .accessibilityLabel((isCurrent ? String(localized: "Sayfa \(i + 1), açık sayfa") : String(localized: "Sayfa \(i + 1)"))
                                    + (page.isBookmarked ? ", " + String(localized: "yer imi var") : ""))
                .accessibilityAddTraits(.isButton)
                .overlay(alignment: .topTrailing) { actions(page, index: i) }
                .overlay(alignment: .topLeading) {
                    if page.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Y.accent)
                            .padding(.leading, 10)
                            .offset(y: -2)
                            .accessibilityHidden(true)
                    }
                }
                // Eşitleme işareti: çakışma kopyası ya da başka iPad'de silinip burada kurtarılan sayfa
                .overlay(alignment: .bottom) {
                    if let mark = page.syncMark {
                        let color = mark == .conflict ? Y.danger : Y.accent
                        Text(mark == .conflict ? "Çakışma" : "Kurtarıldı")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Y.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
                            .padding(.bottom, 8)
                    }
                }
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
            Button { library.toggleBookmark(notebook.id, page.id) } label: {
                page.isBookmarked ? Label("Yer imini kaldır", systemImage: "bookmark.slash")
                                  : Label("Yer imi koy", systemImage: "bookmark")
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
        let pdfURL = pdf?.documentURL
        // Ucuz anahtar: mürekkebin sürüm sayacı + notlar/resimler/bantlar (küçük listeler)
        let version = library.drawingVersion(notebook.id, page.id)
        let extras = (try? JSONEncoder().encode(Extras(notes: page.stickyNotes, images: page.pageImages, tapes: page.pageTapes)))?.hashValue ?? 0
        let key = "\(page.id)-\(version)-\(extras)-\(page.pdfPage ?? -1)-\(notebook.paper.rawValue)-\(pdfURL?.path ?? "")" as NSString
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
            // Çizim arka plan kuyruğunda: ızgara açılırken ve kaydırırken arayüz takılmaz
            let data = library.drawing(notebook.id, page.id)
            let img = await PageThumbRenderer.shared.render(notebook, page: page, drawing: data, pdfURL: pdfURL, width: 260)
            Self.cache.setObject(img, forKey: key)
            image = img
        }
    }

    private struct Extras: Encodable {
        let notes: [StickyNote]
        let images: [PageImage]
        let tapes: [Tape]
    }
}
