import Foundation

// İCloud eşitlemenin `Library` tarafı: anlık görüntü, değişiklik bildirimi, uzaktan uygulama.
// Saklanan durum `Library` içinde (Models.swift); mantık burada.
//
// Yansıma (echo) kuralı: uzaktan uygulanan her şey `lastSnapshot`'a da işlenir, böylece
// aynı değişiklik bir sonraki `save()` farkında geri gönderilmez. Her yerel değişiklik
// `save()` ile hemen farklandığı için `lastSnapshot` hep yerel durumun güncel kopyasıdır;
// uygulanan defterin dilimini yeniden almak bekleyen yerel bir değişikliği yutmaz.

extension Library {
    // MARK: Anlık görüntü

    /// Çöptekiler dahil tüm defterlerin, sayfaların, klasörlerin ve dosya özetlerinin görüntüsü
    func syncSnapshot() -> SyncSnapshot {
        var snap = SyncSnapshot(notebooks: [:], pages: [:], folders: [:], files: [:])
        for nb in notebooks { addSlice(of: nb, to: &snap) }
        for f in folders { snap.folders[f.id] = SyncFolderMeta(id: f.id, name: f.name, created: f.created) }
        return snap
    }

    func syncMeta(_ id: UUID) -> SyncNotebookMeta? {
        guard let nb = notebooks.first(where: { $0.id == id }) else { return nil }
        return meta(of: nb)
    }

    func syncPage(_ id: UUID) -> SyncPageMeta? {
        for nb in notebooks {
            if let p = nb.pages.first(where: { $0.id == id }) { return pageMeta(p, in: nb.id) }
        }
        return nil
    }

    func syncFolder(_ id: UUID) -> SyncFolderMeta? {
        folders.first { $0.id == id }.map { SyncFolderMeta(id: $0.id, name: $0.name, created: $0.created) }
    }

    private static let itemEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func meta(of nb: Notebook) -> SyncNotebookMeta {
        let pdfHash = nb.pdfFile.flatMap { fileHash(store.dir(nb.id).appendingPathComponent($0)) }
        return SyncNotebookMeta(
            id: nb.id, title: nb.title, subtitle: nb.subtitle,
            kind: nb.kind.rawValue, cover: nb.cover.rawValue, paper: nb.paper.rawValue, size: nb.size.rawValue,
            favorite: nb.favorite, trashed: nb.trashed, folder: nb.folder,
            created: nb.created, modified: nb.modified,
            pdfAspect: nb.pdfAspect, pdfFile: nb.pdfFile, pdfHash: pdfHash,
            pageOrder: nb.pages.map(\.id))
    }

    private func pageMeta(_ p: Page, in notebook: UUID) -> SyncPageMeta {
        SyncPageMeta(
            id: p.id, notebook: notebook, pdfPage: p.pdfPage, bookmarked: p.isBookmarked,
            mark: p.syncMark?.rawValue,
            notes: items(p.stickyNotes), images: items(p.pageImages), tapes: items(p.pageTapes),
            inkHash: inkHash(notebook, p.id))
    }

    private func items<T: Encodable & Identifiable>(_ list: [T]) -> [SyncItem] where T.ID == UUID {
        list.compactMap { item in
            (try? Self.itemEncoder.encode(item)).map { SyncItem(id: item.id, data: $0) }
        }
    }

    /// Mürekkep sürümü değişmediyse önbellekten; yoksa okuyup özetler
    private func inkHash(_ nb: UUID, _ page: UUID) -> String? {
        let k = key(nb, page)
        let v = drawingCache.version(k)
        if let c = inkHashCache[k], c.version == v { return c.hash }
        let h = SyncMerge.hash(drawing(nb, page))
        inkHashCache[k] = (v, h)
        return h
    }

    /// (yol, boyut, değişiklik tarihi) aynıysa önbellekten; dosya yoksa nil
    private func fileHash(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let date = attrs[.modificationDate] as? Date else { return nil }
        if let c = fileHashCache[url.path], c.size == size, c.date == date { return c.hash }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let h = SyncMerge.hash(data) else { return nil }
        fileHashCache[url.path] = (size, date, h)
        return h
    }

    /// Defterin üst verisini, sayfalarını ve dosya özetlerini görüntüye ekler
    private func addSlice(of nb: Notebook, to snap: inout SyncSnapshot) {
        snap.notebooks[nb.id] = meta(of: nb)
        for p in nb.pages {
            if let other = snap.pages[p.id], other.notebook != nb.id {
                // C1: aynı sayfa kimliği iki defterde; açılışta `reassignDuplicatePageIDs` düzeltir
                syncLog.error("Sayfa kimliği iki defterde birden: \(p.id.uuidString, privacy: .public)")
            }
            snap.pages[p.id] = pageMeta(p, in: nb.id)
        }
        let dir = store.dir(nb.id)
        var names = Set(nb.pages.flatMap { $0.pageImages.map(\.file) })
        if let pdf = nb.pdfFile { names.insert(pdf) }
        var flushed = false
        for name in names {
            let url = dir.appendingPathComponent(name)
            // Yeni eklenen dosya henüz kuyrukta yazılıyor olabilir; bir kez bekle ki kaçmasın
            if !flushed, !FileManager.default.fileExists(atPath: url.path) { store.flush(); flushed = true }
            if let h = fileHash(url) { snap.files[nb.id.uuidString + "/" + name] = h }
        }
    }

    // MARK: Yinelenen sayfa kimlikleri (C1)

    /// Eski sürümde çoğaltılan defterler sayfa kimliklerini paylaşıyordu; eşitleme sayfayı kimliğiyle tanıdığı
    /// için birinin (ör. boş yer tutucu) hâli ötekinin mürekkebini ezebilirdi. En eski defter dışındaki kopyalar
    /// kararlı yeni kimlik alır (her iPad aynı kimliği üretir); mürekkep yeni kimliğe yazılır.
    /// Eşitleme başlarken, ilk görüntüden önce çağrılır. Düzeltilen sayfa sayısını döndürür.
    @discardableResult
    func reassignDuplicatePageIDs() -> Int {
        let plan = SyncMerge.duplicatePageIDs(notebooks.map { (id: $0.id, created: $0.created, pages: $0.pages.map(\.id)) })
        guard !plan.isEmpty else { return 0 }
        store.flush()
        var touched = Set<UUID>()
        var done = 0
        for r in plan {
            guard let i = index(of: r.notebook), notebooks[i].pages.indices.contains(r.index),
                  notebooks[i].pages[r.index].id == r.old else { continue }
            let ink = drawing(r.notebook, r.old)
            notebooks[i].pages[r.index].id = r.new
            if !ink.isEmpty {
                drawingCache.set(key(r.notebook, r.new), ink)
                store.writeDrawing(r.notebook, r.new, ink)
            }
            // Eski dosyayı bu defterde başka sayfa kullanmıyorsa kaldır
            if !notebooks[i].pages.contains(where: { $0.id == r.old }) {
                drawingCache.set(key(r.notebook, r.old), nil)
                store.deleteDrawing(r.notebook, r.old)
            }
            touched.insert(r.notebook)
            done += 1
        }
        guard done > 0 else { return 0 }
        save()
        store.flush()
        touched.forEach { scheduleThumbnail($0) }
        return done
    }

    // MARK: Değişiklik bildirimi

    /// `save()` ve `saveFolders()` sonunda çağrılır; eşitleme kapalıysa hiçbir şey yapmaz
    func notifySync() {
        guard let handler = onSyncChanges else { return }
        let now = syncSnapshot()
        let changes = SyncMerge.diff(old: lastSnapshot ?? now, new: now)
        lastSnapshot = now
        if !changes.isEmpty { handler(changes) }
    }

    /// Eşitleme açılırken (`onSyncChanges` atandıktan sonra) farkın başlangıcını şimdiki durum yapar
    /// ve görüntüyü döndürür. Atama `lastSnapshot`'ı sıfırladığı için bu çağrılmazsa ilk kayıt boş fark verir.
    @discardableResult
    func seedSyncBaseline() -> SyncSnapshot {
        let now = syncSnapshot()
        lastSnapshot = now
        return now
    }

    /// Eşitleme açıkken ilk görüntü yoksa şimdiki durumu temel alır (sonraki değişiklik fark üretsin)
    private func ensureBaseline() {
        if onSyncChanges != nil, lastSnapshot == nil { lastSnapshot = syncSnapshot() }
    }

    /// Uygulanan defterin dilimini `lastSnapshot`'a işler (yansıma olmasın); defter yoksa dilimi siler
    private func patchSync(notebook id: UUID) {
        guard var snap = lastSnapshot else { return }
        snap.notebooks[id] = nil
        snap.pages = snap.pages.filter { $0.value.notebook != id }
        let prefix = id.uuidString + "/"
        snap.files = snap.files.filter { !$0.key.hasPrefix(prefix) }
        if let nb = notebooks.first(where: { $0.id == id }) { addSlice(of: nb, to: &snap) }
        lastSnapshot = snap
    }

    private func patchSync(folder id: UUID) {
        guard lastSnapshot != nil else { return }
        lastSnapshot?.folders[id] = syncFolder(id)
    }

    /// Uzaktan uygulanan değişikliği diske yazar; `save()` gibi fark üretmez
    private func persistRemote() {
        store.writeIndex(notebooks)
        onChange?()
    }

    // MARK: Uzaktan uygulama

    /// Sırada olup yerelde olmayan sayfalar için açılan boş yer tutucuların kimliklerini döndürür (içerikleri sonra gelir)
    @discardableResult
    func applyRemote(notebook m: SyncNotebookMeta) -> [UUID] {
        var keptLocal = false
        let placeholders: [UUID]
        if let i = index(of: m.id) {
            var nb = notebooks[i]
            fill(&nb, from: m)
            (keptLocal, placeholders) = reorderPages(&nb, order: m.pageOrder)
            notebooks[i] = nb
        } else {
            store.createDir(m.id)
            var nb = Notebook(id: m.id, title: m.title, cover: .ketenYesil, paper: .cizgili)
            fill(&nb, from: m)
            nb.pages = []
            placeholders = reorderPages(&nb, order: m.pageOrder).placeholders
            notebooks.append(nb)
        }
        persistRemote()
        patchSync(notebook: m.id)
        scheduleThumbnail(m.id)
        if keptLocal {
            // Sunucunun sırasında olmayan yerel sayfa korundu: defter üst verisi sunucudakinden farklı.
            // lastSnapshot'ta sunucunun sırasını bırakıp fark üretiriz ki sunucu sayfanın var olduğunu öğrensin.
            lastSnapshot?.notebooks[m.id]?.pageOrder = m.pageOrder
            notifySync()
        }
        return placeholders
    }

    /// `ink == nil` mürekkebe dokunmaz
    func applyRemote(page m: SyncPageMeta, ink: Data?) {
        guard let i = index(of: m.notebook) else { return }
        if let j = notebooks[i].pages.firstIndex(where: { $0.id == m.id }) {
            let old = notebooks[i].pages[j]
            let new = page(from: m, base: old)
            notebooks[i].pages[j] = new
            // I4: açık sayfa notları, resimleri ve bantları yeniden uygulasın
            if old.notes != new.notes || old.images != new.images || old.tapes != new.tapes {
                remoteItemsVersion[m.id, default: 0] += 1
            }
        } else {
            // Sıra bilgisi henüz gelmedi; sona eklenir, defter üst verisi sırayı düzeltir
            notebooks[i].pages.append(page(from: m, base: nil))
            remoteItemsVersion[m.id, default: 0] += 1
        }
        if let ink {
            let k = key(m.notebook, m.id)
            drawingCache.set(k, ink)
            store.writeDrawing(m.notebook, m.id, ink)
            remoteInkVersion[m.id, default: 0] += 1
        }
        persistRemote()
        patchSync(notebook: m.notebook)
        scheduleThumbnail(m.notebook)
    }

    func applyRemote(folder m: SyncFolderMeta) {
        if let i = folders.firstIndex(where: { $0.id == m.id }) {
            folders[i].name = m.name
            folders[i].created = m.created
        } else {
            folders.append(Folder(id: m.id, name: m.name, created: m.created))
        }
        store.writeFolders(folders)
        onChange?()
        patchSync(folder: m.id)
    }

    /// Resim ya da PDF dosyasını defter klasörüne yazar
    func applyRemote(file data: Data, notebook: UUID, name: String) {
        // Yalnızca beklenen dosya adları; yol atlatma olmasın
        let isImage = name.hasPrefix("img-") && name.hasSuffix(".jpg")
        guard !name.contains("/"), isImage || name == "source.pdf", index(of: notebook) != nil else { return }
        store.createDir(notebook)
        let url = store.dir(notebook).appendingPathComponent(name)
        store.writeFile(data, to: url)
        // Özet hemen doğru çıksın diye yazma bitsin
        store.flush()
        // Resmi kullanan açık sayfa dosya gelince yeniden çizsin (I4)
        if let i = index(of: notebook) {
            for p in notebooks[i].pages where p.pageImages.contains(where: { $0.file == name }) {
                remoteItemsVersion[p.id, default: 0] += 1
            }
        }
        if name == "source.pdf" {
            // Eski metin önbelleği yeni PDF'e ait değil; arama yeniden çıkarsın
            textCache[notebook] = nil
            try? FileManager.default.removeItem(at: store.textURL(notebook))
        }
        patchSync(notebook: notebook)
        scheduleThumbnail(notebook)
    }

    // MARK: Uzaktan silme (silinenler listesine eklenmez)

    func removeRemote(notebook id: UUID) {
        guard index(of: id) != nil else { return }
        notebooks.removeAll { $0.id == id }
        drawingCache.removeAll(prefix: id.uuidString)
        textCache[id] = nil
        store.deleteDir(id)
        persistRemote()
        patchSync(notebook: id)
    }

    func removeRemote(page id: UUID) {
        guard let i = notebooks.firstIndex(where: { $0.pages.contains { $0.id == id } }) else { return }
        let nbID = notebooks[i].id
        notebooks[i].pages.removeAll { $0.id == id }
        drawingCache.set(key(nbID, id), nil)
        store.deleteDrawing(nbID, id)
        patchSync(notebook: nbID)
        if notebooks[i].pages.isEmpty {
            // Defterde en az bir sayfa olmalı; yeni boş sayfa yerel değişikliktir ve bildirilir
            notebooks[i].pages = [Page()]
            save()
        } else {
            persistRemote()
        }
        scheduleThumbnail(nbID)
    }

    func removeRemote(folder id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        var touched: [UUID] = []
        for i in notebooks.indices where notebooks[i].folder == id {
            notebooks[i].folder = nil
            touched.append(notebooks[i].id)
        }
        store.writeFolders(folders)
        persistRemote()
        lastSnapshot?.folders[id] = nil
        for nb in touched { patchSync(notebook: nb) }
    }

    /// I4: tuval listeyi, sayfaya uzaktan gelen son not/resim/bant sürümünü uygulamadan önce ürettiyse (eski liste)
    /// uzaktan eklenen öğeler korunur; tuvaldeki öğeler kendi kimliklerinde kazanır. Böylece açık sayfadaki bir
    /// düzenleme, ekrana henüz gelmemiş uzak notu, resmi ya da bandı silmez.
    func keepingRemote<T: Identifiable>(_ list: [T], current: [T], page: UUID, seen: Int?) -> [T] where T.ID == UUID {
        guard let seen, seen != remoteItemsVersion[page] ?? 0 else { return list }
        let ids = Set(list.map(\.id))
        return list + current.filter { !ids.contains($0.id) }
    }

    // MARK: Çakışma ve kurtarma

    /// Sayfanın yerel hâlini (`ink` yerel mürekkep) yeni bir sayfaya kopyalar; beyaz tahtada yeni defter açar.
    /// Yeni sayfanın kimliğini döndürür. Sonuç `onSyncChanges`'e bildirilir.
    func insertConflictCopy(of page: UUID, ink: Data) -> UUID {
        ensureBaseline()
        guard let i = notebooks.firstIndex(where: { $0.pages.contains { $0.id == page } }),
              let src = notebooks[i].pages.first(where: { $0.id == page }) else { return page }
        let nb = notebooks[i]
        if nb.kind == .whiteboard {
            // Beyaz tahtada tek sayfa var; kopya aynı klasörde yeni bir tahta olur
            var copy = Notebook(id: UUID(), title: nb.title + String(localized: " (çakışma kopyası)"),
                                kind: .whiteboard, cover: nb.cover, paper: nb.paper, size: nb.size)
            copy.folder = nb.folder
            store.createDir(copy.id)
            let p = conflictPage(from: src, fromNotebook: nb.id, toNotebook: copy.id)
            copy.pages = [p]
            writeInk(ink, notebook: copy.id, page: p.id)
            notebooks.append(copy)
            save()
            scheduleThumbnail(copy.id)
            return p.id
        }
        let p = conflictPage(from: src, fromNotebook: nb.id, toNotebook: nb.id)
        writeInk(ink, notebook: nb.id, page: p.id)
        notebooks[i].pages.insert(p, at: (notebooks[i].pages.firstIndex { $0.id == page } ?? 0) + 1)
        notebooks[i].modified = Date()
        save()
        scheduleThumbnail(nb.id)
        return p.id
    }

    /// Başka cihazda silinen defterin yerelde değişmiş sayfalarını defterde tutar (yoksa defteri yeniden kurar)
    func rescue(pages: [SyncPageMeta], inks: [UUID: Data], into meta: SyncNotebookMeta) {
        guard !pages.isEmpty else { return }
        ensureBaseline()
        let existing = index(of: meta.id)
        if existing == nil {
            store.createDir(meta.id)
            var nb = Notebook(id: meta.id, title: meta.title, cover: .ketenYesil, paper: .cizgili)
            fill(&nb, from: meta)
            nb.pages = []
            notebooks.append(nb)
        }
        guard let i = index(of: meta.id) else { return }
        for m in pages where !notebooks[i].pages.contains(where: { $0.id == m.id }) {
            var p = page(from: m, base: nil)
            p.syncMark = .rescued
            p.bookmarked = true
            notebooks[i].pages.append(p)
            if let ink = inks[m.id] { writeInk(ink, notebook: meta.id, page: m.id) }
        }
        if notebooks[i].pages.isEmpty { notebooks[i].pages = [Page()] }
        notebooks[i].modified = Date()
        save()
        scheduleThumbnail(meta.id)
    }

    /// Başka cihazda silinen ama burada mürekkebi değişmiş sayfayı yerinde tutar: "Kurtarıldı" işareti
    /// ve yer imi konur. Değişiklik `onSyncChanges`'e bildirilir (sayfa yeniden gönderilir).
    func markRescued(page id: UUID) {
        ensureBaseline()
        guard let i = notebooks.firstIndex(where: { $0.pages.contains { $0.id == id } }),
              let j = notebooks[i].pages.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].pages[j].syncMark = .rescued
        notebooks[i].pages[j].bookmarked = true
        save()
    }

    // MARK: Yardımcılar

    private func writeInk(_ ink: Data, notebook: UUID, page: UUID) {
        guard !ink.isEmpty else { return }
        drawingCache.set(key(notebook, page), ink)
        store.writeDrawing(notebook, page, ink)
    }

    /// Çakışma kopyası sayfası: not, bant ve resimler yeni kimliklerle; resim dosyaları yeni adlarla kopyalanır
    private func conflictPage(from src: Page, fromNotebook: UUID, toNotebook: UUID) -> Page {
        var p = Page()
        p.pdfPage = src.pdfPage
        p.notes = src.notes?.map { n in var c = n; c.id = UUID(); return c }
        p.tapes = src.tapes?.map { t in var c = t; c.id = UUID(); return c }
        if let imgs = src.images {
            // Kuyruktaki yazmalar bitsin ki kopyalanacak dosya diskte olsun
            store.flush()
            let from = store.dir(fromNotebook), to = store.dir(toNotebook)
            p.images = imgs.compactMap { m in
                var c = m
                c.id = UUID()
                c.file = "img-\(UUID().uuidString).jpg"
                guard (try? FileManager.default.copyItem(at: from.appendingPathComponent(m.file),
                                                         to: to.appendingPathComponent(c.file))) != nil else { return nil }
                return c
            }
            if p.images?.isEmpty == true { p.images = nil }
        }
        p.bookmarked = true
        p.syncMark = .conflict
        return p
    }

    private func fill(_ nb: inout Notebook, from m: SyncNotebookMeta) {
        nb.title = m.title
        nb.subtitle = m.subtitle
        nb.kind = DocKind(rawValue: m.kind) ?? nb.kind
        nb.cover = CoverStyle(rawValue: m.cover) ?? nb.cover
        nb.paper = PaperStyle(rawValue: m.paper) ?? nb.paper
        nb.size = PaperSize(rawValue: m.size) ?? nb.size
        nb.favorite = m.favorite
        nb.trashed = m.trashed
        nb.folder = m.folder
        nb.created = m.created
        nb.modified = m.modified
        nb.pdfAspect = m.pdfAspect
        nb.pdfFile = m.pdfFile
    }

    /// Sayfaları verilen sıraya dizer; bilinmeyen kimlik boş sayfa olur (içeriği sonra gelir).
    /// Listede olmayan yerel sayfalar SİLİNMEZ: sona, mevcut göreli sırayla eklenir ve mürekkepleri dokunulmaz kalır.
    /// Gerçek silme yalnızca `removeRemote(page:)` ile olur. Böyle bir sayfa korunduysa `keptLocal` true olur;
    /// `placeholders` açılan boş yer tutucuların kimlikleridir.
    private func reorderPages(_ nb: inout Notebook, order: [UUID]) -> (keptLocal: Bool, placeholders: [UUID]) {
        let byID = Dictionary(nb.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var result: [Page] = []
        var created: [UUID] = []
        for id in order where seen.insert(id).inserted {
            if let p = byID[id] { result.append(p); continue }
            // C1: başka defterdeki bir sayfanın kimliği (eski sürümün çoğalttığı defter); boş yer tutucusu
            // açılmaz, yoksa o sayfa kimliğiyle gönderilen boş hâl öteki defterin mürekkebini ezebilirdi
            if notebooks.contains(where: { $0.id != nb.id && $0.pages.contains { $0.id == id } }) {
                syncLog.error("Sıradaki sayfa başka defterde; yer tutucu açılmadı: \(id.uuidString, privacy: .public)")
                continue
            }
            result.append(Page(id: id))
            created.append(id)
        }
        let kept = nb.pages.filter { !seen.contains($0.id) }
        result.append(contentsOf: kept)
        nb.pages = result.isEmpty ? [Page()] : result
        return (!kept.isEmpty, created)
    }

    private func page(from m: SyncPageMeta, base: Page?) -> Page {
        var p = base ?? Page(id: m.id)
        p.pdfPage = m.pdfPage
        p.notes = decode(m.notes, as: StickyNote.self)
        p.images = decode(m.images, as: PageImage.self)
        p.tapes = decode(m.tapes, as: Tape.self)
        p.bookmarked = m.bookmarked ? true : nil
        p.syncMark = m.mark.flatMap { SyncMark(rawValue: $0) }
        return p
    }

    /// Boş liste nil olur (yerel kayıtlardaki gibi); çözülemeyen öğe atlanır
    private func decode<T: Decodable>(_ list: [SyncItem], as: T.Type) -> [T]? {
        let out = list.compactMap { try? JSONDecoder().decode(T.self, from: $0.data) }
        return out.isEmpty ? nil : out
    }
}
