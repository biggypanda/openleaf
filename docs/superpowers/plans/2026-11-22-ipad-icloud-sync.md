# iPad'ler arası iCloud eşitleme: uygulama planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aynı Apple hesabındaki iPad'ler, kullanıcının özel CloudKit veritabanı üzerinden aynı kütüphaneyi görsün; hiçbir mürekkep sessizce kaybolmasın.

**Architecture:** Yerel depo (`Belgeler/OpenLeaf`) olduğu gibi kalır ve tek gerçek kaynaktır. `Library` her kayıtta önceki anlık görüntüyle farkı çıkarıp değişen kayıtları bir `SyncController`'a bildirir; o da `CKSyncEngine`'e verir. Gelen kayıtlar ve çakışmalar, son eşitlenen hâli ("taban") cihazda tutan üç yönlü birleştirme ile çözülür. Birleştirme ve fark mantığı saf Foundation kodudur ve Mac'te `swiftc` ile test edilir (mevcut `Tests/BackupEngineCheck` düzeni).

**Tech Stack:** Swift, SwiftUI, PencilKit, CloudKit (`CKSyncEngine`, iOS 17+), CryptoKit (SHA256), Foundation.

**Spec:** `docs/superpowers/specs/2026-11-22-ipad-icloud-sync-design.md`

## Global Constraints

- iPadOS 18 alt sınırı; üçüncü parti bağımlılık yok.
- Kapsayıcı: `iCloud.io.github.biggypanda.openleaf`; yalnızca **özel** veritabanı, tek özel bölge: `OpenLeaf`.
- Eşitleme varsayılan **kapalı**; anahtar yedekleme menüsünde: "iPad'ler arasında eşitle".
- `thumb.png` ve `text.txt` eşitlenmez.
- Başka cihazdan gelen kalıcı silme `DeletedNotebooks`'a **eklenmez**.
- Yeni her arayüz metni `Localizable.xcstrings`'e 7 dilde (de, en, es, fr, it, pt-BR, tr) girer; kaynak dil Türkçe.
- Mevcut yedekleme (`AutoBackup`, `BackupEngine`) davranışı değişmez.
- Hiçbir metinde gerçek ad geçmez. Commit yazarı `biggypanda`.
- Commit mesajları Türkçe, sonunda `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Çalışma dalı: `icloud-esitleme` (main'den).

## Review Focus

1. **Kullanıcı yazarken uzaktan aynı sayfaya değişiklik gelmesi:** Kalem kalkana kadar beklenmeli; çizgi bozulmamalı, sayfa kaymamalı. Test: Task 6 Step 4 (elle senaryo E).
2. **Eşitleme açıkken uygulamanın kapatılması (bekleyen değişiklikler):** Yeniden açılınca bekleyenler gönderilmeli. Test: Task 2 `stateRoundTrip` + Task 7 senaryo F.
3. **iCloud alanı dolu / ağ yok:** Yerel kayıt etkilenmemeli, durum satırı doğru olmalı, sonra yeniden denenmeli. Test: Task 5 `syncErrorMapping` denetimi + Task 7 senaryo G (uçak modu).
4. **Uzaktan gelen değişikliğin geri yankısı:** Uzaktan uygulanan kayıt tekrar "yerel değişiklik" olarak gönderilmemeli (sonsuz döngü). Test: Task 1 `diffIgnoresAppliedRemote`.
5. **Büyük PDF'li defter:** PDF bir kez yüklenmeli; meta veri değişikliğinde tekrar yüklenmemeli. Test: Task 1 `diffPdfOnlyWhenFileChanges`.

---

## Dosya yapısı

| Dosya | Sorumluluk |
|---|---|
| `OpenLeaf/SyncMerge.swift` (yeni) | Saf Foundation: anlık görüntü türleri, fark çıkarma, üç yönlü birleştirme, mürekkep çakışma kararı, kurtarma planı |
| `OpenLeaf/SyncState.swift` (yeni) | Saf Foundation: motor durumu, taban anlık görüntüleri ve kayıt sistem alanlarının cihazda saklanması |
| `OpenLeaf/SyncRecords.swift` (yeni) | CloudKit: anlık görüntü ↔ `CKRecord` dönüşümü, kayıt türü ve alan adları |
| `OpenLeaf/SyncController.swift` (yeni) | `CKSyncEngine` sahibi: açma/kapama, gönderme, alma, çakışma, hesap ve bölge olayları, durum |
| `OpenLeaf/SyncView.swift` (yeni) | Menüdeki anahtar, durum satırı, bulut verisini silme onayı, bildirimler |
| `OpenLeaf/Models.swift` | `Page.syncMark`, `Library` fark bildirimi ve uzaktan uygulama API'si |
| `OpenLeaf/LibraryView.swift`, `PageOverview.swift`, `DocumentView.swift`, `Canvas.swift` | Menü bağlantısı, etiketler, açık sayfanın yeniden yüklenmesi |
| `OpenLeaf/OpenLeafApp.swift` | `SyncController`'ın kurulması |
| `OpenLeaf.entitlements`, `OpenLeaf-Info.plist` | CloudKit servisi, `aps-environment`, `remote-notification` arka plan modu |
| `Tests/SyncCheck/main.swift` (yeni) | `SyncMerge` + `SyncState` denetimleri |

Test komutu (tüm görevlerde aynı):

```bash
swiftc OpenLeaf/SyncMerge.swift OpenLeaf/SyncState.swift Tests/SyncCheck/main.swift -o "$TMPDIR/esitleme-test" && "$TMPDIR/esitleme-test"
```

Harness `Tests/BackupEngineCheck/main.swift` ile aynı biçimde: her denetim adını yazıp `GEÇTİ`/`KALDI` basar; biri kalırsa çıkış kodu 1.

Derleme komutu:

```bash
xcodebuild -project OpenLeaf.xcodeproj -scheme OpenLeaf -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

---

### Task 1: Saf birleştirme mantığı (`SyncMerge.swift`)

**Files:**
- Create: `OpenLeaf/SyncMerge.swift`
- Test: `Tests/SyncCheck/main.swift`

**Interfaces:**
- Produces:
  - `struct SyncNotebookMeta: Codable, Equatable { var id: UUID; var title: String; var subtitle: String; var kind: String; var cover: String; var paper: String; var size: String; var favorite: Bool; var trashed: Bool; var folder: UUID?; var created: Date; var modified: Date; var pdfAspect: Double?; var pdfFile: String?; var pdfHash: String?; var pageOrder: [UUID] }`
  - `struct SyncPageMeta: Codable, Equatable { var id: UUID; var notebook: UUID; var pdfPage: Int?; var bookmarked: Bool; var mark: String?; var notes: [SyncItem]; var images: [SyncItem]; var tapes: [SyncItem]; var inkHash: String? }`
  - `struct SyncItem: Codable, Equatable, Identifiable { var id: UUID; var data: Data }` (yapışkan not/resim/bant öğesinin JSON kodlanmış hâli)
  - `struct SyncFolderMeta: Codable, Equatable { var id: UUID; var name: String; var created: Date }`
  - `struct SyncSnapshot: Equatable { var notebooks: [UUID: SyncNotebookMeta]; var pages: [UUID: SyncPageMeta]; var folders: [UUID: SyncFolderMeta]; var files: [String: String] }` (`files`: `"<defter>/<dosya>"` → SHA256; resimler ve `source.pdf`)
  - `enum SyncChange: Hashable { case notebook(UUID), page(UUID), folder(UUID), file(notebook: UUID, name: String), deleteNotebook(UUID), deletePage(UUID), deleteFolder(UUID), deleteFile(notebook: UUID, name: String) }`
  - `enum SyncMerge` (statik fonksiyonlar):
    - `static func hash(_ data: Data) -> String?` (boş veri → `nil`, değilse SHA256 hex)
    - `static func diff(old: SyncSnapshot, new: SyncSnapshot) -> Set<SyncChange>`
    - `static func mergeOrder(base: [UUID], local: [UUID], server: [UUID]) -> [UUID]`
    - `static func mergeItems(base: [SyncItem], local: [SyncItem], server: [SyncItem], localWins: Bool) -> [SyncItem]`
    - `static func mergeNotebook(base: SyncNotebookMeta?, local: SyncNotebookMeta, server: SyncNotebookMeta) -> SyncNotebookMeta`
    - `static func mergePage(base: SyncPageMeta?, local: SyncPageMeta, server: SyncPageMeta, localWins: Bool) -> SyncPageMeta` (mürekkep hariç alanlar)
    - `enum InkResolution: Equatable { case same, takeLocal, takeServer, keepBoth }`
    - `static func resolveInk(base: String?, local: String?, server: String?) -> InkResolution`
    - `enum DeleteResolution: Equatable { case delete, rescue }`
    - `static func resolveRemoteDelete(base: String?, local: String?) -> DeleteResolution`
    - `static func rescueNotebook(from deleted: SyncNotebookMeta, keeping pages: [UUID], newID: UUID, now: Date) -> SyncNotebookMeta`

- [ ] **Step 1: Dalı aç.** `git switch -c icloud-esitleme main`

- [ ] **Step 2: Başarısız testleri yaz** (`Tests/SyncCheck/main.swift`, BackupEngineCheck harness'ını kopyala). Denetimler ve beklenenler:
  - `hashEmptyIsNil`: `hash(Data()) == nil`; `hash(Data([1])) == hash(Data([1]))`; `hash(Data([1])) != hash(Data([2]))`.
  - `diffDetectsEachKind`: eski ve yeni anlık görüntüde bir defterin `title`'ı, bir sayfanın `bookmarked`'ı, bir sayfanın `inkHash`'i değişmiş, bir klasör eklenmiş, bir defter çıkarılmış, bir resim dosyası eklenmiş → sonuç tam olarak `{.notebook(a), .page(p1), .page(p2), .folder(f), .deleteNotebook(b), .file(notebook: a, name: "img-x.jpg")}`. Çıkarılan defterin sayfaları için ayrıca `.deletePage` **üretilmez** (defter silmesi yeter).
  - `diffIgnoresAppliedRemote`: `diff(old: s, new: s) == []`.
  - `diffPdfOnlyWhenFileChanges`: yalnızca `title` değişirse `.file(…"source.pdf")` yok; `files["a/source.pdf"]` hash'i değişirse var.
  - `orderKeepsServerAndInsertsLocal`: base `[A,B,C]`, local `[A,X,B,C]`, server `[C,A,B]` → `[C,A,X,B]`.
  - `orderDeletedStaysDeleted`: base `[A,B,C]`, local `[A,C]`, server `[A,B,C,D]` → `[A,C,D]`; base `[A,B]`, local `[A,B,E]`, server `[A]` → `[A,E]`.
  - `orderNoBase`: base `[]`, local `[A,B]`, server `[B,C]` → `[A,B,C]` (A'nın yerelde önceki komşusu yok → başa).
  - `itemsUnionAndLWW`: base `[n1]`, local `[n1', n2]`, server `[n1'', n3]`; `localWins: false` → `[n1'', n3, n2]` sırası fark etmeksizin içerik `{n1'', n2, n3}`; `localWins: true` → `{n1', n2, n3}`. base `[n1,n2]`, local `[n1]`, server `[n1,n2]` → `{n1}` (yerelde silinen silinmiş kalır).
  - `notebookFieldMerge`: base title "A" favorite false; local title "B" (modified t1); server favorite true (modified t2 > t1) → title "B", favorite true. İkisi de title değiştirmiş: local "B" t1, server "C" t2 → "C"; t1 > t2 → "B". base `nil` → daha yeni `modified` tarafının tüm alanları, `pageOrder` `mergeOrder(base: [], …)` ile.
  - `inkResolution`: `(h1,h1,h1) → .same`; `(h1,h2,h1) → .takeLocal`; `(h1,h1,h2) → .takeServer`; `(h1,h2,h2) → .same`; `(h1,h2,h3) → .keepBoth`; `(nil,h2,h3) → .keepBoth`; `(nil,h2,h2) → .same`; `(nil,nil,h1) → .takeServer`.
  - `remoteDelete`: `(h1,h1) → .delete`; `(h1,h2) → .rescue`; `(nil,nil) → .delete`; `(nil,h1) → .rescue`.
  - `rescuePlan`: silinen defter title "Biyoloji", pageOrder `[A,B,C]`, keeping `[C,A]` → yeni id, title "Biyoloji", aynı cover/paper/size/kind, `trashed == false`, `pageOrder == [A,C]` (özgün sırayla), `created == modified == now`.

- [ ] **Step 3: Kaldığını gör.** Test komutu. Expected: derleme hatası (`SyncMerge` yok).

- [ ] **Step 4: `SyncMerge.swift`'i yaz.** Yalnızca `Foundation` ve `CryptoKit`. Algoritmalar:
  - `mergeOrder`: `deleted = base − local ∪ base − server`; sonuç server sırasından `deleted` çıkarılarak başlar; local'de olup base'de ve server'da olmayan her öğe (local sırasıyla), local'de kendinden önce gelen öğeler arasında sonuçta bulunan en yakınının hemen arkasına; hiçbiri sonuçta yoksa başa eklenir.
  - `mergeNotebook`: her alan için `local != base` ve `server != base` ise (base yoksa ikisi farklıysa) daha yeni `modified` kazanır; yalnızca bir taraf değiştiyse o taraf. `pageOrder` her zaman `mergeOrder`. Sonucun `modified`'ı ikisinin büyüğü.
  - `mergeItems`: kimliğe göre; bir tarafta silinip öbüründe değişmemişse silinir; iki tarafta değişmişse `localWins`.

- [ ] **Step 5: Geçtiğini gör.** Test komutu. Expected: tüm satırlar `GEÇTİ`, çıkış kodu 0.

- [ ] **Step 6: Commit.** `git add OpenLeaf/SyncMerge.swift Tests/SyncCheck/main.swift` → `git commit -m "Eşitleme: saf birleştirme ve fark mantığı"`

---

### Task 2: Cihazdaki eşitleme durumu (`SyncState.swift`)

**Files:**
- Create: `OpenLeaf/SyncState.swift`
- Test: `Tests/SyncCheck/main.swift`

**Interfaces:**
- Consumes: `SyncNotebookMeta`, `SyncPageMeta`, `SyncFolderMeta` (Task 1)
- Produces: `final class SyncStateStore: @unchecked Sendable`:
  - `init(root: URL)` — varsayılan çağrı yerinde `Application Support/OpenLeaf-Esitleme/` (Belgeler'de değil: Dosyalar'da ve yedekte görünmesin)
  - `var engineState: Data?` (`CKSyncEngine.State.Serialization`'ın JSON'u; get/set dosyaya atomik)
  - `var enabled: Bool`, `var accountID: String?` (hesap değişimini tanımak için; `CKSyncEngine` hesap olayındaki kullanıcı kaydı kimliği)
  - `func base(notebook id: UUID) -> SyncNotebookMeta?`, `func setBase(_ m: SyncNotebookMeta)`; aynısı `page`, `folder` için
  - `func removeBase(_ id: UUID)`
  - `func systemFields(_ recordName: String) -> Data?`, `func setSystemFields(_ data: Data?, for recordName: String)`
  - `func reset()` — her şeyi siler, `enabled` hariç

- [ ] **Step 1: Başarısız testleri ekle:**
  - `stateRoundTrip`: geçici klasörde store; `engineState = Data([7])`, bir defter/sayfa/klasör tabanı ve bir sistem alanı yaz; **yeni** bir `SyncStateStore` aynı klasörden hepsini aynen okur.
  - `stateResetKeepsEnabled`: `enabled = true`, taban yaz, `reset()` → tabanlar `nil`, `engineState == nil`, `accountID == nil`, `enabled == true`.
  - `stateCorruptFileIsNil`: taban dosyasının yerine bozuk bayt yaz → `base(notebook:) == nil`, çökme yok.
- [ ] **Step 2: Kaldığını gör.** Test komutu. Expected: `SyncStateStore` yok.
- [ ] **Step 3: `SyncState.swift`'i yaz.** Tabanlar tür başına tek JSON sözlük dosyası (`notebooks.json`, `pages.json`, `folders.json`, `fields.json`) hâlinde, bellekte tutulur, yazmalar seri kuyrukta atomik. `enabled`/`accountID` `meta.json`'da.
- [ ] **Step 4: Geçtiğini gör.** Test komutu. Expected: tüm satırlar `GEÇTİ`.
- [ ] **Step 5: Commit.** `git commit -m "Eşitleme: cihazdaki durum deposu"`

---

### Task 3: Model ve `Library` bağlantısı

**Files:**
- Modify: `OpenLeaf/Models.swift` (`Page` CodingKeys ve init; `Library`)
- Test: `Tests/SyncCheck/main.swift` (yalnızca saf kısım), derleme

**Interfaces:**
- Consumes: `SyncSnapshot`, `SyncChange`, `SyncMerge.diff`, `SyncMerge.hash` (Task 1)
- Produces (hepsi `Library` üzerinde, `@MainActor`):
  - `Page.syncMark: SyncMark?`, `enum SyncMark: String, Codable { case conflict, rescued }` (Codable anahtarı `"syncMark"`; eski dosyalarda yoksa `nil`)
  - `var onSyncChanges: ((Set<SyncChange>) -> Void)?`
  - `func syncSnapshot() -> SyncSnapshot` (çöptekiler dahil tüm defterler; dosya hash'leri `img-*.jpg` ve `source.pdf` için, hash'ler `(dosya yolu, boyut, değişiklik tarihi)` anahtarlı bellek önbelleğinden)
  - `func syncMeta(_ id: UUID) -> SyncNotebookMeta?`, `func syncPage(_ id: UUID) -> SyncPageMeta?`, `func syncFolder(_ id: UUID) -> SyncFolderMeta?`
  - `func applyRemote(notebook: SyncNotebookMeta)`, `func applyRemote(page: SyncPageMeta, ink: Data?)` (`ink == nil` → mürekkebe dokunma), `func applyRemote(folder: SyncFolderMeta)`, `func applyRemote(file data: Data, notebook: UUID, name: String)`
  - `func removeRemote(notebook: UUID)`, `func removeRemote(page: UUID)`, `func removeRemote(folder: UUID)` — `DeletedNotebooks`'a **eklemez**
  - `func insertConflictCopy(of page: UUID, ink: Data) -> UUID` (yerel hâli sayfanın hemen arkasına, `syncMark = .conflict`, `bookmarked = true`, not/resim/bant kopyalı, resim dosyaları yeni adlarla kopyalanır). **Beyaz tahtada** (`kind == .whiteboard`) yeni sayfa yerine aynı klasörde `"<başlık> (çakışma kopyası)"` başlıklı yeni bir beyaz tahta defteri oluşturur ve onun tek sayfasının kimliğini döndürür; başlık eki 7 dilde çevrilir (en: `" (conflict copy)"`).
  - `func rescue(pages: [SyncPageMeta], inks: [UUID: Data], into meta: SyncNotebookMeta)` (`syncMark = .rescued`, `bookmarked = true`)
  - `var remoteInkVersion: [UUID: Int]` (gözlemlenir; uzaktan mürekkep gelince artar)

- [ ] **Step 1: `Page`'e `syncMark` ekle;** CodingKeys'e `syncMark` ekle, `init(from:)`'da `decodeIfPresent`.
- [ ] **Step 2: `syncSnapshot()` ve `syncMeta/syncPage/syncFolder`'ı yaz.** `SyncItem.data` = öğenin `JSONEncoder` (`.sortedKeys`) çıktısı; `inkHash` = `SyncMerge.hash(drawing(id, page))`.
- [ ] **Step 3: Fark bildirimi.** `Library`'de `@ObservationIgnored private var lastSnapshot: SyncSnapshot?`. `save()` ve `saveFolders()` sonunda `onSyncChanges` atanmışsa `let now = syncSnapshot(); let ch = SyncMerge.diff(old: lastSnapshot ?? now, new: now); lastSnapshot = now; if !ch.isEmpty { onSyncChanges?(ch) }`. `onSyncChanges` atanmamışsa anlık görüntü alınmaz (eşitleme kapalıyken maliyet yok).
- [ ] **Step 4: Uzaktan uygulama ve kurtarma API'si.** `applyRemote`/`removeRemote`/`insertConflictCopy`/`rescue` yerel depoya `NotebookStore` yoluyla yazar, ardından `lastSnapshot`'ı **uygulanan hâle göre günceller** ki aynı değişiklik geri gönderilmesin; yalnızca `insertConflictCopy` ve `rescue` sonuçlarını `onSyncChanges`'e bildirir (yeni sayfa/defter gönderilmeli). Küçük resim `scheduleThumbnail`, metin önbelleği PDF gelince temizlenir.
- [ ] **Step 5: Derle.** Derleme komutu. Expected: `BUILD SUCCEEDED`. Test komutu da hâlâ geçer.
- [ ] **Step 6: Commit.** `git commit -m "Eşitleme: Library fark bildirimi ve uzaktan uygulama"`

---

### Task 4: CloudKit kayıtları ve yetkiler

**Files:**
- Create: `OpenLeaf/SyncRecords.swift`
- Modify: `OpenLeaf.entitlements`, `OpenLeaf-Info.plist`

**Interfaces:**
- Consumes: Task 1 türleri, Task 2 `systemFields`
- Produces: `enum SyncRecords`:
  - `static let zoneID = CKRecordZone.ID(zoneName: "OpenLeaf")`
  - Kayıt türleri: `"Notebook"`, `"Page"`, `"Folder"`, `"File"`; kayıt adı = UUID string (dosya için `"<defter>/<dosya adı>"`)
  - `static func record(notebook: SyncNotebookMeta, pdf: URL?, fields: Data?) -> CKRecord` (meta JSON `meta` alanında `Data`; PDF varsa `pdf` `CKAsset`)
  - `static func record(page: SyncPageMeta, ink: URL?, fields: Data?) -> CKRecord` (meta JSON `meta`; `notebook` `CKRecord.Reference(action: .none)`; mürekkep `ink` `CKAsset`)
  - `static func record(folder:fields:)`, `static func record(file: URL, notebook: UUID, name: String, fields: Data?) -> CKRecord`
  - `static func notebook(_ r: CKRecord) -> (SyncNotebookMeta, pdf: URL?)?`, `page(_:) -> (SyncPageMeta, ink: URL?)?`, `folder(_:)`, `file(_:) -> (notebook: UUID, name: String, url: URL)?`
  - `static func encodeFields(_ r: CKRecord) -> Data` (`encodeSystemFields(with:)`)
  - Not: asset dosyaları gönderim için geçici kopyaya yazılır (yerel dosya gönderim sırasında değişebilir).

- [ ] **Step 1: Yetkiler.** Entitlement `com.apple.developer.icloud-services` dizisine `CloudKit` ekle (`CloudDocuments` kalır); `aps-environment` = `development` ekle. Info.plist `UIBackgroundModes` dizisine `remote-notification`.
- [ ] **Step 2: `SyncRecords.swift`'i yaz.**
- [ ] **Step 3: Derle.** Expected: `BUILD SUCCEEDED`. (Elle adım, kullanıcı: Xcode → Signing & Capabilities → iCloud → CloudKit işaretli ve kapsayıcı seçili olmalı; Push Notifications yeteneği eklenmiş olmalı.)
- [ ] **Step 4: Commit.** `git commit -m "Eşitleme: CloudKit kayıt dönüşümü ve yetkiler"`

---

### Task 5: `SyncController` (`CKSyncEngine`)

**Files:**
- Create: `OpenLeaf/SyncController.swift`
- Modify: `OpenLeaf/OpenLeafApp.swift`
- Test: `Tests/SyncCheck/main.swift` (saf durum eşlemesi), derleme

**Interfaces:**
- Consumes: Task 1–4
- Produces: `@MainActor @Observable final class SyncController`:
  - `init(library: Library, state: SyncStateStore)`
  - `private(set) var status: SyncStatus`; `enum SyncStatus: Equatable { case off, noAccount, syncing, upToDate(Date), offline, quotaFull, stopped(SyncStopReason) }`; `enum SyncStopReason: Equatable { case accountChanged, cloudDataDeleted }`
  - `private(set) var notice: SyncNotice?`; `enum SyncNotice: Identifiable, Equatable { case rescued(count: Int), stopped(SyncStopReason) }` (arayüz gösterip `clearNotice()` çağırır)
  - `func setEnabled(_ on: Bool)`, `func deleteCloudData() async throws`, `func clearNotice()`
  - Saf yardımcı (SyncMerge.swift'e eklenir, testli): `SyncMerge.statusKind(forErrorCode code: Int) -> SyncStatusKind` — `enum SyncStatusKind { case offline, quotaFull, retry, other }`; `CKError.Code` ham değerleri: `networkUnavailable(3)`, `networkFailure(4)` → `.offline`; `quotaExceeded(25)` → `.quotaFull`; `serviceUnavailable(6)`, `requestRateLimited(7)`, `zoneBusy(23)` → `.retry`; diğerleri `.other`.

Davranış (spec'teki kurallar):
- **Açma:** `state.enabled = true`, motoru `state.engineState` ile kur (`CKSyncEngine.Configuration(database: CKContainer(identifier:).privateCloudDatabase, stateSerialization:, delegate:)`), bölge yoksa `pendingDatabaseChanges`'e `.saveZone`. İlk açılışta (`engineState == nil`) yerel anlık görüntüdeki tüm kayıtları bekleyenlere ekle; gelen kayıtlar birleştirme kurallarıyla işlenir (taban yok → `resolveInk(base: nil, …)`).
- **Kapama:** motoru durdur, `state.enabled = false`; `engineState` ve tabanlar **silinmez**.
- **Gönderme:** `nextRecordZoneChangeBatch`'te bekleyen kayıt adlarından `SyncRecords.record(...)` üret; silinen kayıt artık yoksa atla.
- **Başarılı gönderim:** her kayıt için `setSystemFields` ve tabanı gönderilen hâl yap.
- **`serverRecordChanged`:** sunucu kaydını al; defter → `mergeNotebook`; sayfa → `mergePage` + `resolveInk`; `.keepBoth` → sunucunun mürekkebi sayfaya `applyRemote`, yerel mürekkep `insertConflictCopy`. Sonucu yerelde uygula, tabanı sunucu hâli yap, yeniden gönder.
- **Alınan değişiklikler:** her kayıt için aynı birleştirme (yerelde bekleyen değişiklik yoksa doğrudan `applyRemote`). Alınan silmelerde sayfa için `resolveRemoteDelete(base: taban.inkHash, local: yerel inkHash)`; `.rescue` sayfaları toplanır: defter hâlâ varsa sayfa geri eklenir (`syncMark = .rescued`) ve tekrar gönderilir; defter de silindiyse `rescueNotebook` + `library.rescue`. Kurtarma olduysa `notice = .rescued(count:)`.
- **`unknownItem` (gönderilen kayıt sunucuda silinmiş):** aynı silme kuralı.
- **Bölge silindi (`zoneDeleted` / `userDeletedZone`):** yerel veriye dokunma, motoru durdur, `state.enabled = false`, `status = .stopped(.cloudDataDeleted)`, `notice` ver. Bölgeyi yeniden oluşturma.
- **Hesap olayı:** `signOut` veya `switchAccounts` → yerel veri kalır, `state.reset()`, `enabled = false`, `.stopped(.accountChanged)`. `signIn` ve `state.accountID` farklıysa aynısı; eşitse devam.
- **Durum kaydı:** `stateUpdate` olayında `state.engineState`'i yaz.
- `deleteCloudData()`: `CKModifyRecordZonesOperation` ile bölgeyi sil, `state.reset()`, `enabled = false`.
- `OpenLeafApp`: `SyncController`'ı `Library`'den sonra kur, `.environment`'a ver; `state.enabled` ise başlat. `library.onSyncChanges`'i controller ayarlar (kapalıyken `nil`).

- [ ] **Step 1: Başarısız test ekle** `syncErrorMapping`: `3 → .offline`, `4 → .offline`, `25 → .quotaFull`, `7 → .retry`, `999 → .other`.
- [ ] **Step 2: Kaldığını gör.** Test komutu.
- [ ] **Step 3: `statusKind(forErrorCode:)`'u `SyncMerge.swift`'e ekle; geçtiğini gör.**
- [ ] **Step 4: `SyncController.swift`'i yaz ve `OpenLeafApp`'e bağla.**
- [ ] **Step 5: Derle.** Expected: `BUILD SUCCEEDED`; test komutu geçer.
- [ ] **Step 6: Commit.** `git commit -m "Eşitleme: CKSyncEngine denetleyicisi"`

---

### Task 6: Arayüz ve açık sayfa

**Files:**
- Create: `OpenLeaf/SyncView.swift`
- Modify: `OpenLeaf/LibraryView.swift` (yedekleme menüsü), `OpenLeaf/PageOverview.swift` (etiket), `OpenLeaf/DocumentView.swift` + `OpenLeaf/Canvas.swift` (yeniden yükleme), `OpenLeaf/Localizable.xcstrings`

**Interfaces:**
- Consumes: `SyncController.status/notice/setEnabled/deleteCloudData/clearNotice`, `Library.remoteInkVersion`, `Page.syncMark`

Metinler (kaynak Türkçe; 7 dile çevrilir):

| Anahtar | en |
|---|---|
| `iPad'ler arasında eşitle` | Sync Across iPads |
| `Eşitlendi` | Up to Date |
| `Eşitleniyor…` | Syncing… |
| `Çevrimdışı, bağlanınca gönderilecek` | Offline, will sync when connected |
| `iCloud dolu` | iCloud Storage Full |
| `iCloud oturumu yok` | Not Signed In to iCloud |
| `iCloud'daki eşitleme verisini sil…` | Delete Sync Data from iCloud… |
| `Eşitleme verisi iCloud'dan silinsin mi? Bu iPad'deki ve diğer iPad'lerdeki notlar silinmez; eşitleme her yerde kapanır.` | Delete sync data from iCloud? Notes on this iPad and your other iPads are not deleted; sync turns off everywhere. |
| `Çakışma` | Conflict |
| `Kurtarıldı` | Recovered |
| `%lld sayfa başka bir iPad'de silinmişti ama burada üzerine yazılmıştı. Bu sayfalar geri getirildi ve yer imiyle işaretlendi.` | %lld pages were deleted on another iPad but edited here. They've been brought back and bookmarked. |
| `iCloud hesabı değiştiği için eşitleme durdu. Bu iPad'deki notlar yerinde.` | Sync stopped because the iCloud account changed. Notes on this iPad are safe. |
| `iCloud'daki eşitleme verisi silindiği için eşitleme durdu. Bu iPad'deki notlar yerinde.` | Sync stopped because the sync data in iCloud was deleted. Notes on this iPad are safe. |

- [ ] **Step 1: `SyncView.swift`:** menüye konacak `SyncMenuSection` (anahtar + durum satırı + sil düğmesi, onay `confirmationDialog`); `.syncNotices(_ controller:)` görünüm değiştiricisi `notice`'u `alert` ile gösterir. `status == .noAccount` iken anahtar devre dışı.
- [ ] **Step 2: Menüye bağla.** `LibraryView` yedekleme menüsünde, kilit anahtarından önceki `Divider()`'ın üstüne `SyncMenuSection`; kök görünüme `.syncNotices`.
- [ ] **Step 3: Etiketler.** `PageOverview` küçük resminde `syncMark` varsa altta küçük etiket ("Çakışma" / "Kurtarıldı"), `Y` tema renkleri.
- [ ] **Step 4: Açık sayfanın yeniden yüklenmesi.** `Canvas` koordinatörü `canvasViewDidBeginUsingTool`/`canvasViewDidEndUsingTool` ile `isDrawing` tutar. Açık sayfanın `remoteInkVersion`'u artınca: `isDrawing` false ise `load(library.drawing(id, page))`; true ise kalem kalkınca bir kez yükle. Açık defter uzaktan silinirse kütüphaneye dön; açık sayfa silinirse mevcut `pinnedPage` mantığı devreye girer.
- [ ] **Step 5: Çeviriler.** 7 dil `Localizable.xcstrings`'e (Python `json` ile, `sort_keys=True, indent=2, separators=(',', ': ')`, sondaki yeni satır yok; önce dosyanın bu biçimle aynen geri yazıldığını doğrula).
- [ ] **Step 6: Derle ve simülatörde bak.** Derleme komutu `BUILD SUCCEEDED`; iPad simülatöründe menüde anahtarın ve durum satırının göründüğünü `xcrun simctl io <cihaz> screenshot` ile kontrol et.
- [ ] **Step 7: Commit.** `git commit -m "Eşitleme: menü, durum, bildirimler ve açık sayfa yenileme"`

---

### Task 7: Uçtan uca deneme ve yayın hazırlığı

**Files:**
- Modify: `PRIVACY.md` (eşitleme cümlesi), `README.md` (özellik satırı)
- Create: `docs/superpowers/plans/2026-11-22-ipad-icloud-sync-deneme.md` (senaryo sonuçları)

- [ ] **Step 1: Kullanıcı adımı.** İki iPad simülatöründe aynı test Apple hesabıyla iCloud'a kullanıcının kendisi giriş yapar (şifre girilmez). Uygulama iki simülatöre de kurulur.
- [ ] **Step 2: Senaryolar** (her biri sonuç dosyasına GEÇTİ/KALDI + not):
  - A. Yalnızca A'da eşitleme açık, kütüphanesi dolu; B'de aç → B'de A'nın defterleri, B'nin kendi defterleri silinmeden.
  - B. A'da yeni defter, sayfa ekle/taşı/sil, PDF içe aktar, resim ekle → birkaç saniyede B'de.
  - C. İki simülatör uçak modunda (ağ kapalı); aynı sayfaya ikisinde yaz; ağı aç → sayfa + "Çakışma" etiketli kopya, ikisinde de aynı. Aynısı bir beyaz tahtada → ayrı "(çakışma kopyası)" beyaz tahta.
  - D. A'da sayfa sil, B çevrimdışıyken aynı sayfaya yaz; bağlan → sayfa "Kurtarıldı" ile geri, bildirim çıktı. Aynısı defter silme ile → yeni defterde yalnızca yazılan sayfalar.
  - E. B'de sayfaya yazarken A'dan aynı sayfaya değişiklik → çizgi bozulmuyor, kalem kalkınca yenileniyor, sayfa kaymıyor.
  - F. Değişiklik yapıp uygulamayı hemen kapat; yeniden aç → değişiklik diğerinde görünüyor.
  - G. Uçak modunda durum "Çevrimdışı…"; bağlanınca "Eşitlendi".
  - H. Eşitlemeyi kapat/aç → arada silinenler geri gelmiyor.
  - I. "iCloud'daki eşitleme verisini sil" → diğer simülatörde eşitleme kapanıyor, notlar yerinde.
  - J. Mevcut otomatik yedek hâlâ çalışıyor (yedekleme menüsünden "Şimdi yedekle").
- [ ] **Step 3: Belgeler.** `PRIVACY.md`'ye: eşitleme açıksa notlar yalnızca kullanıcının kendi iCloud'undaki özel CloudKit veritabanına gider; geliştirici erişemez. README özellik listesine eşitleme satırı.
- [ ] **Step 4: Yayın öncesi elle adımlar listesi (kullanıcıya):** CloudKit Console'da `iCloud.io.github.biggypanda.openleaf` → Schema → "Deploy Schema Changes" ile Production'a gönder; App Store gizlilik etiketini gözden geçir (beklenen: değişiklik yok); sürüm 1.2.
- [ ] **Step 5: Commit.** `git commit -m "Eşitleme: deneme sonuçları ve belgeler"`
