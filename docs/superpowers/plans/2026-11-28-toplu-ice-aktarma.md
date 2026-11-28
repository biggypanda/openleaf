# Toplu İçe Aktarma Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GoodNotes/Notability kullanıcısı tüm defterlerini tek ZIP, klasör ya da çoklu PDF olarak paylaş menüsünden veya "İçe aktar" düğmesinden OpenLeaf'e taşıyabilsin.

**Architecture:** Bağımsız `ZipReader` (Foundation + Compression) ZIP'i akış hâlinde diske açar. Saf `ImportPlan` bir kök klasördeki PDF'leri bulup her birine OpenLeaf klasör adı eşler. `Library.importBatch` ikisini birleştirip mevcut `importPDF`'i tek tek çağırır, ilerleme bildirir, özet döner. Arayüz (LibraryView) ilerleme kartı, özet uyarısı ve taşıma rehberi ekler.

**Tech Stack:** Swift 6 / SwiftUI, PDFKit, Apple Compression (`OutputFilter`, `.zlib` = ham DEFLATE), komut satırı denetimleri (`swiftc` ile Mac'te).

**Spec:** `docs/superpowers/specs/2026-11-28-toplu-ice-aktarma-design.md`

**Branch:** `toplu-ice-aktarma`, `puan-isteme`'den (1.1.3) kesilir.

## Global Constraints

- Dış bağımlılık yok; ZIP okuyucu yalnız Foundation + Compression kullanır.
- Desteklenen ZIP yöntemleri: 0 (stored) ve 8 (deflate). ZIP64 desteklenir. Şifreli girdi, başka yöntem, CRC uyuşmazlığı → atlandı.
- Zip-slip: `..` bileşeni ya da `/` ile başlayan girdi reddedilir (atlandı). `__MACOSX/` altı ve adı `._` ile başlayanlar sessizce yok sayılır (atlandı sayılmaz).
- Klasör eşleme: yalnız ilk seviye klasör adı; kökteki PDF'ler o an seçili klasöre (yoksa klasörsüz). Aynı adlı (büyük/küçük harf duyarsız) mevcut klasör yeniden kullanılır. Klasör yalnız içine en az bir defter girerse açılır.
- Kötü dosya aktarımı durdurmaz; özet: aktarılan sayı + atlanan dosya adları.
- Geçici açma klasörü her durumda silinir. İptalde biten defterler kalır.
- Tek PDF (paylaş menüsü ya da düğme) eski davranışı korur: defter hemen açılır.
- Tüm yeni kullanıcı metinleri `OpenLeaf/Localizable.xcstrings`'e 7 dilde: en, tr, de, es, fr, it, pt-BR. Kaynak dil en; anahtarlar Türkçe metin (mevcut düzen).
- Kod yorumları Türkçe, mevcut üslupta.

## Review Focus

- Binlerce girdili / 1 GB üstü ZIP: bellek sabit kalmalı (akış), arayüz donmamalı.
- Aynı ZIP iki kez aktarılırsa: klasör tekrar açılmaz, defterler ikinci kez eklenir (kabul edilen davranış, özet doğru sayar).
- PDF uzantısı büyük harf (`.PDF`) ya da Türkçe/emoji dosya adı: bulunmalı, başlık doğru olmalı.
- Notability çoklu paylaşım: art arda gelen `onOpenURL`'ler tek özet verir, Inbox kopyaları silinir.
- İptal ortada basılırsa geçici klasör silinir, boş klasör kalmaz.

---

### Task 1: ZipReader

**Files:**
- Create: `OpenLeaf/ZipReader.swift`
- Create: `Tests/ZipReaderCheck/main.swift`

**Interfaces:**
- Produces:
  - `struct ZipEntry { let path: String; let method: UInt16; let crc32: UInt32; let compressedSize: UInt64; let uncompressedSize: UInt64; let localHeaderOffset: UInt64; let isEncrypted: Bool; var isDirectory: Bool }`
  - `enum ZipError: Error { case notZip, corrupt, unsupported, encrypted, crcMismatch, unsafePath }`
  - `final class ZipReader { init(url: URL) throws; let entries: [ZipEntry]; func extract(_ e: ZipEntry, to dest: URL) throws }`
  - `static func ZipReader.safeRelativePath(_ name: String) -> String?` — güvensizse nil.
  - `static func ZipReader.isJunk(_ path: String) -> Bool` — `__MACOSX/` ya da son bileşen `._` ile başlar.
  - `static func ZipReader.extractAll(_ zip: URL, to dir: URL) -> (files: [URL], failed: [String])` — junk'ı sessizce atlar, diğer hataları `failed`'a ad olarak yazar.

- [ ] **Step 1: Denetimleri yaz** (`Tests/ZipReaderCheck/main.swift`, BackupEngineCheck ile aynı `check`/`expect` düzeni). Örnek arşivler `Process` ile `/usr/bin/zip` ve `python3 -I -c` ile geçici klasörde üretilir:
  - `stored`: `zip -0` ile 2 dosya → `entries.count == 2`, içerik bayt bayt aynı.
  - `deflate`: `zip -9` ile 300 KB tekrarlı metin + alt klasör → içerik aynı, `path == "Ders/a.txt"`.
  - `zip64`: `zip -fz` → okunur, içerik aynı.
  - `encrypted`: `zip -P x` → `extract` `ZipError.encrypted` atar.
  - `crc`: deflate arşivinde veri baytı bozulur → `crcMismatch` ya da `corrupt`.
  - `slip`: python `zipfile` ile `../kotu.pdf` ve `/abs.pdf` → `extractAll` hedef klasör dışına yazmaz, ikisi `failed`'da.
  - `junk`: `__MACOSX/._a.pdf` ve `._b.pdf` → `files`'ta yok, `failed`'da yok.
  - `notZip`: rastgele baytlar → `init` `ZipError.notZip` atar.
  - `unicode`: `Türkçe ğüş 📓.pdf` adı (UTF-8 bayrağı) → `path` aynen.

- [ ] **Step 2: Çalıştır, kaldığını gör**

Run: `swiftc OpenLeaf/ZipReader.swift Tests/ZipReaderCheck/main.swift -o /tmp/zip-check && /tmp/zip-check`
Expected: derleme hatası (ZipReader yok).

- [ ] **Step 3: `ZipReader`'ı yaz.** End-of-central-directory'yi dosya sonundan en çok 65 557 bayt geri tarayarak bul; ZIP64 EOCD locator (`0x07064b50`) varsa ZIP64 kaydından sayı/ofset al; merkezi dizin girdilerinde ZIP64 ekstra alanı (`0x0001`) ile 0xFFFFFFFF değerleri değiştir. Ad: bit 11 açıksa UTF-8, değilse CP437 yerine `.isoLatin1` ile çöz (yeterli). `extract`: yerel başlığın ad+ekstra uzunluğunu atla; stored için 64 KB parçalarla kopyala; deflate için `OutputFilter(.decompress, using: .zlib)` ile 64 KB parçalar yaz; CRC32'yi yazarken tablo tabanlı kendi fonksiyonunla hesapla. Hedef klasörleri `createDirectory(withIntermediateDirectories:)` ile aç.

- [ ] **Step 4: Çalıştır, geçtiğini gör**

Run: aynı komut. Expected: tüm satırlar `GEÇTİ`, çıkış kodu 0.

- [ ] **Step 5: Commit**

```bash
git add OpenLeaf/ZipReader.swift Tests/ZipReaderCheck/main.swift
git commit -m "ZIP okuyucu: akışla açma, ZIP64, zip-slip koruması"
```

### Task 2: ImportPlan + Library.importBatch

**Files:**
- Create: `OpenLeaf/BulkImport.swift`
- Create: `Tests/ImportPlanCheck/main.swift`

**Interfaces:**
- Consumes: `ZipReader.extractAll`, `ZipReader.isJunk`, mevcut `Library.importPDF(from:) throws -> UUID`, `Library.createFolder(_:) -> UUID`, `Library.move(_:toFolder:)`, `Library.folders`.
- Produces:
  - `struct ImportItem: Equatable { let pdf: URL; let folderName: String? }`
  - `enum ImportPlan { static func items(in root: URL) -> [ImportItem] }` — özyinelemeli; `.pdf` uzantısı büyük/küçük harf duyarsız; junk atlanır; ad sırasına göre (`localizedStandardCompare`), klasör adı = kökten sonraki ilk bileşen, kökteyse nil.
  - `struct ImportSummary { var imported: [UUID]; var skipped: [String] }`
  - `extension Library { func importBatch(_ sources: [URL], into folder: UUID?, progress: @escaping (Int, Int) -> Void) async -> ImportSummary }` — `@MainActor`.

- [ ] **Step 1: Denetimleri yaz** (`Tests/ImportPlanCheck/main.swift`, yalnız `ImportPlan` — `BulkImport.swift`'teki `Library` uzantısı `#if canImport(UIKit)` ile sarılır ki Mac'te derlensin):
  - kök `a.pdf`, `Matematik/b.PDF`, `Matematik/Ünite 1/c.pdf`, `Fizik/not.txt`, `__MACOSX/._a.pdf`, `._x.pdf` → tam olarak `[a.pdf nil, b.PDF "Matematik", c.pdf "Matematik"]`.
  - boş klasör → `[]`.
  - `Türkçe 📓.pdf` → bulunur.

- [ ] **Step 2: Çalıştır, kaldığını gör**

Run: `swiftc OpenLeaf/ZipReader.swift OpenLeaf/BulkImport.swift Tests/ImportPlanCheck/main.swift -o /tmp/plan-check && /tmp/plan-check`
Expected: derleme hatası.

- [ ] **Step 3: `ImportPlan` ve `importBatch`'i yaz.** `importBatch`: her kaynak için security-scoped erişim aç; klasörse `ImportPlan.items(in:)`; `.zip` ise `FileManager.temporaryDirectory/ice-aktar-<UUID>`'ye `Task.detached` içinde `extractAll` (failed'ları `skipped`'a ekle) sonra `items(in:)`; `.pdf` ise `ImportItem(pdf:, folderName: nil)`; diğerleri `skipped`. Toplam öğe sayısı belli olunca her PDF'ten önce `Task.isCancelled` kontrolü, `importPDF`, hata → `skipped` (dosya adı), klasör adı varsa büyük/küçük harf duyarsız mevcut klasörü bul ya da ilk başarılı defterde `createFolder` (sonuç sözlükte saklanır), yoksa `folder` parametresine `move`; her adımdan sonra `progress(done, total)` ve `await Task.yield()`. Geçici klasörler `defer` ile silinir.

- [ ] **Step 4: Çalıştır, geçtiğini gör.** Ayrıca uygulama derlenir:

Run: aynı komut; sonra `xcodebuild -project OpenLeaf.xcodeproj -scheme OpenLeaf -destination 'generic/platform=iOS Simulator' build -quiet`
Expected: `GEÇTİ` satırları; `** BUILD SUCCEEDED **` (ya da -quiet ile hatasız çıkış).

- [ ] **Step 5: Commit**

```bash
git add OpenLeaf/BulkImport.swift Tests/ImportPlanCheck/main.swift
git commit -m "Toplu içe aktarma motoru: ZIP, klasör ve çoklu PDF"
```

### Task 3: Kütüphane arayüzü ve paylaş menüsü

**Files:**
- Modify: `OpenLeaf/LibraryView.swift` (fileImporter ~92, `openIncoming` ~575, "Yeni" menüsü ~472, boş durum ~502)
- Modify: `OpenLeaf-Info.plist` (CFBundleDocumentTypes)
- Modify: `OpenLeaf/Localizable.xcstrings`

**Interfaces:**
- Consumes: `Library.importBatch`, `ImportSummary`.

- [ ] **Step 1: Info.plist'e ikinci belge türü:** `CFBundleTypeName` "ZIP arşivi", `Viewer`, `LSHandlerRank` `Alternate`, `LSItemContentTypes` `public.zip-archive`.
- [ ] **Step 2: `fileImporter`'ı çoklu yap:** `allowedContentTypes: [.pdf, .zip, .folder]`, `allowsMultipleSelection: true`. Tek URL ve `.pdf` ise eski yol (aç). Değilse `runBatch(urls)`.
- [ ] **Step 3: `openIncoming`:** URL'leri `pendingIncoming` dizisine ekle; 1 sn'lik bir `Task` (yeni gelen her URL'de iptal edilip yeniden kurulur) dolunca: tek PDF ise eski davranış; değilse `runBatch`. Inbox kopyaları batch bittikten sonra silinir.
- [ ] **Step 4: `runBatch(_ urls: [URL])`:** `@State importProgress: (done: Int, total: Int)?` ve `importTask: Task<Void, Never>?`. Aktarım sürerken alt ortada kart: `ProgressView(value:)`, "İçe aktarılıyor… %lld / %lld", "İptal" düğmesi (`importTask?.cancel()`). Bitince `@State importSummary: ImportSummary?` ile uyarı: başlık "%lld defter aktarıldı"; `skipped` boş değilse mesaj "Atlanan dosyalar: …" (en çok 10 ad, fazlası "ve %lld dosya daha"). Hiç defter aktarılmadıysa başlık "Hiçbir defter aktarılamadı". Bölüm seçimi `.belgeler` değilse ve seçili klasör yoksa `selection = .section(.belgeler)`.
- [ ] **Step 5: Menü metni** "PDF içe aktar" → "İçe aktar" (iki yerde). Yeni metinleri 7 dilde ekle.
- [ ] **Step 6: Derle**

Run: `xcodebuild -project OpenLeaf.xcodeproj -scheme OpenLeaf -destination 'generic/platform=iOS Simulator' build -quiet`
Expected: hatasız.

- [ ] **Step 7: Commit**

```bash
git add OpenLeaf/LibraryView.swift OpenLeaf-Info.plist OpenLeaf/Localizable.xcstrings
git commit -m "Kütüphane: çoklu içe aktarma, ilerleme ve özet; paylaş menüsünden ZIP"
```

### Task 4: Taşıma rehberi ve belgeler

**Files:**
- Create: `OpenLeaf/MigrationGuide.swift`
- Modify: `OpenLeaf/LibraryView.swift` (menüye "Başka uygulamadan taşı", sheet)
- Modify: `OpenLeaf/Localizable.xcstrings`, `README.md`

**Interfaces:**
- Produces: `struct MigrationGuide: View { var onPick: () -> Void }` — "Dosyaları seç" düğmesi sheet'i kapatıp `showImporter = true` yapar.

- [ ] **Step 1: `MigrationGuide`'ı yaz.** `NavigationStack` + `List`, üç bölüm:
  - "GoodNotes": "Belgeler'de Seç'e dokunun ve tüm defterleri ya da klasörleri seçin." / "Paylaş > Dışa aktar'a dokunun, biçim olarak PDF'i seçin." / "Paylaşım menüsünden OpenLeaf'i seçin. Klasörleriniz korunur."
  - "Notability": "Notları seçin, Paylaş'a dokunun ve PDF'i seçin." / "Paylaşım menüsünden OpenLeaf'i seçin."
  - "Bilmeniz gerekenler": "Sayfalar olduğu gibi gelir; üstüne yeni mürekkeple yazabilirsiniz." / "Eski el yazısı ve resimler düzenlenebilir nesneye dönüşmez." / "Ses kayıtları gibi özellikler PDF'e aktarılmaz."
  - Alt kısımda "Dosyaları seç" (borderedProminent) ve araç çubuğunda "Kapat".
- [ ] **Step 2: Bağla.** "Yeni" menüsüne "İçe aktar"ın altına `Button("Başka uygulamadan taşı", systemImage: "arrow.right.doc.on.clipboard")`; boş durum ekranına da aynı düğme. `.sheet(isPresented: $showGuide)`.
- [ ] **Step 3: Metinleri 7 dilde ekle; README özellik listesine madde + `Tests/ZipReaderCheck` ve `Tests/ImportPlanCheck` komutları ve yapı tablosu satırları.**
- [ ] **Step 4: Derle ve denetimleri çalıştır**

Run: `xcodebuild -project OpenLeaf.xcodeproj -scheme OpenLeaf -destination 'generic/platform=iOS Simulator' build -quiet && /tmp/zip-check && /tmp/plan-check`
Expected: hatasız, tüm `GEÇTİ`.

- [ ] **Step 5: Commit**

```bash
git add OpenLeaf/MigrationGuide.swift OpenLeaf/LibraryView.swift OpenLeaf/Localizable.xcstrings README.md
git commit -m "Başka uygulamadan taşıma rehberi (closes #15)"
```
