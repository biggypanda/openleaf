# iPad'ler arası iCloud eşitleme: tasarım

Tarih: 22 Kasım 2026. Hedef sürüm: 1.2 (1.1.3 yalnızca puan isteme değişikliğiyle küçük kalır).

## Neden

Reddit'te bir kullanıcı "cihazlarım arasında eşitlemezse kullanmam" dedi. Eşitleme, ücretsiz not uygulamalarını bırakıp ücretli olanlara geçilmesinin en sık sebeplerinden biri. OpenLeaf'in sözü (veri cihazda kalır, hesap yok, sunucu yok, veri toplanmaz) bozulmadan, aynı Apple hesabıyla oturum açmış iPad'lerin aynı kütüphaneyi görmesi isteniyor.

## Hedefler

- Aynı Apple hesabındaki iki veya daha fazla iPad aynı kütüphaneyi görür: defterler, klasörler, sayfalar, mürekkep, yapışkan notlar, resimler, bantlar, yer imleri, PDF'ler.
- Bir iPad'deki değişiklik, iki cihaz da çevrimiçiyken birkaç saniye içinde diğerinde görünür.
- Uygulama çevrimdışı tam çalışır; değişiklikler bağlantı gelince gönderilir.
- **Hiçbir mürekkep sessizce kaybolmaz.** Aynı sayfa iki iPad'de, araya eşitleme girmeden değiştiyse iki hâli de saklanır (aşağıda "Çakışma").
- Veri yalnızca kullanıcının kendi iCloud'undaki **özel** CloudKit veritabanında durur. App Store gizlilik etiketi "Data Not Collected" olarak kalır.

## Hedef dışı (bu sürümde yok)

- iPhone ve Mac uygulaması. (Mac'te iPad uygulaması olarak çalışma ileride ucuza gelebilir; bu tasarım engel olmamalı.)
- Başka kişilerle paylaşma, ortak düzenleme.
- Aynı anda iki cihazda canlı, çizgi çizgi ortak yazma.
- İki çizimi otomatik birleştirme (silinen çizgileri geri getirdiği için bilerek seçilmedi).
- Eşitlenmiş geçmiş / sürüm geçmişi.

## Başarısızlık sayılacak durumlar (anti-hedefler)

- Bir sayfadaki mürekkebin, kullanıcı bir şey görmeden kaybolması.
- Eşitlemeyi açan kullanıcının mevcut yerel kütüphanesinin silinmesi ya da üstüne yazılması.
- Bir defterin ya da sayfanın iki kez görünmesi (çakışma kopyası dışında).
- Açık defterde yazarken uzaktan gelen değişikliğin o anki çizgiyi bozması ya da sayfayı kaydırması.
- Eşitleme yüzünden uygulamanın açılışının ya da yazmanın yavaşlaması.
- Mevcut yedekleme özelliğinin bozulması.

## Kısıtlar

- iPadOS 18 ve üzeri (mevcut alt sınır). SwiftUI + PencilKit + PDFKit, üçüncü parti bağımlılık yok.
- iCloud kapsayıcısı zaten var: `iCloud.io.github.biggypanda.openleaf` (şu an yalnızca `CloudDocuments` ile yedek için kullanılıyor). Entitlement'a `CloudKit` servisi eklenecek.
- Yerel depo yapısı (`Belgeler/OpenLeaf/`): `index.json` tüm defterlerin meta verisini ve sayfa listelerini tek dosyada tutuyor; her sayfanın mürekkebi `Defterler/<defter>/<sayfa>.drawing`; PDF `source.pdf`; resimler `img-<uuid>.jpg`; `text.txt` ve `thumb.png` türetilmiş dosyalar.
- `Library` (ana aktör, `@Observable`) her değişiklikte `save()` ile tüm dizini yazıyor; neyin değiştiğini ayrıca tutmuyor.
- 7 dil: tüm yeni arayüz metinleri `Localizable.xcstrings`'e 7 dilde girer.
- Gerçek ad hiçbir yerde geçmez.

## Yaklaşımlar

1. **Kütüphaneyi iCloud Drive kapsayıcısına taşımak** (`NSFileCoordinator`, `NSMetadataQuery`, `NSFileVersion`). Bugünkü dosya yapısına en yakın. Elendi: iCloud dosyaları cihazdan atabiliyor (açarken bekleme), değişikliklerin ne zaman geleceği belirsiz, çakışma bildirimi güvenilir değil.
2. **CloudKit + `CKSyncEngine`** (iOS 17+). Yerel depo aynen kalır; değişen kayıtlar kullanıcının özel veritabanına gönderilir, gelenler yerele yazılır. Çakışmada sunucu kaydı açıkça döner. **Seçilen yol.**
3. **Mevcut yedeklemeyi iki yönlü yapmak** (her iPad kendi yedek klasörünü yazar, diğerlerininkini okuyup birleştirir). Elendi: yavaş (yedek sıklığında), iCloud alanı cihaz sayısıyla katlanır, silme/birleştirme mantığının tamamı elle yazılır.

Kullanıcı 2'yi seçti. Gerekçe: hız, açık çakışma bilgisi, çevrimdışı tam çalışma.

## Kararlaştırılanlar

### Kullanıcının verdiği kararlar

- Kapsam: önce yalnızca iPad'ler arası.
- Yol: CloudKit + `CKSyncEngine`.
- Çakışma kuralı: **ikisini de sakla.** Aynı sayfanın mürekkebi iki cihazda bağımsız değiştiyse, sunucudaki hâl sayfada kalır, bu cihazın hâli hemen arkasına yeni bir sayfa olarak eklenir.
- **Silme ile yazma çakışırsa yazılan kazanır.** Bir iPad bir sayfayı (ya da defteri) kalıcı sildi, başka bir iPad araya eşitleme girmeden o sayfaya mürekkep ekledi ya da değiştirdiyse:
  - Yalnızca değiştirilmiş sayfalar geri gelir, "Kurtarıldı" etiketiyle ve yer imi konmuş olarak. Kullanıcıya kısa bir bildirim gösterilir.
  - Defter hâlâ duruyorsa sayfa eski yerine döner. Defter de silinmişse, kurtarılan sayfalar aynı başlık ve ayarlarla yeni bir deftere toplanır; değişmemiş sayfalar geri gelmez.
  - Değişiklik olmayan silmeler normal şekilde silinmiş kalır.
  - Silinen sayfa ya da defter diğer iPad'de o anda açıksa ve kullanıcı yazmıyorsa: açık defter kapanır (kütüphaneye dönülür) ya da sayfa bir öncekine kayar. Yazıyorsa yukarıdaki kural işler; yazdığı sayfa kurtarılır.

### Benim kararlarım (düzeltilebilir)

- **Açma/kapama:** Eşitleme varsayılan kapalı. Mevcut yedekleme menüsünde bir anahtar: "iPad'ler arasında eşitle". iCloud oturumu yoksa anahtar devre dışı ve sebebini söyler. Gerekçe: mevcut kullanıcılar habersiz veri göndermesin; "veri cihazda kalır" sözüyle uyumlu.
- **İlk açılış birleşmesi:** Eşitleme açılınca yerel kütüphane ile buluttaki birleştirilir (birleşim kümesi). Kimlikler UUID olduğu için iki iPad'deki farklı defterler çakışmaz; hiçbir yerel defter silinmez.
- **Kapatma:** Eşitleme kapatılınca yerel kütüphane olduğu gibi kalır, buluttaki veri silinmez. Ayrı ve onay isteyen bir "iCloud'daki eşitleme verisini sil" seçeneği olur.
- **Hesap değişimi / iCloud'dan çıkış:** Yerel veri korunur, eşitleme durur ve kullanıcıya bildirilir. Farklı bir hesapla tekrar açılırsa ilk açılış birleşmesi kuralı geçerlidir.
- **Mevcut yedekleme:** Değişmeden çalışmaya devam eder. Eşitleme yedeğin yerine geçmez.
- **Türetilmiş dosyalar eşitlenmez:** `thumb.png` ve `text.txt` alıcı cihazda yeniden üretilir.
- **Meta veri çakışmaları (mürekkep dışı):**
  - Defter başlığı, kapak, favori, klasör, çöp durumu gibi tekil alanlar: alan bazında son yazan kazanır (kayıttaki değişiklik zamanına göre).
  - Sayfa sırası: birleştirilir. Sunucudaki sıra temel alınır; yalnızca bu cihazda eklenmiş sayfalar bu cihazdaki komşularının yanına yerleştirilir; bir tarafta silinmiş sayfa silinmiş kalır.
  - Yapışkan not, resim ve bant listeleri: öğe kimliğine göre birleşim; aynı öğe iki tarafta değiştiyse son yazan kazanır.
- **Silme:** Bir cihazda kalıcı silinen defter/sayfa/klasör diğerlerinde de silinir (istisna: yukarıdaki "yazılan kazanır" kuralı). Çöp kutusu da eşitlenir (çöpe atma bir alan değişikliği).
- **Çakışma kopyası sayfası:** Yeni bir `Page`; yapışkan not/resim/bantlar da kopyalanır; yer imi konmuş olarak gelir ki kullanıcı kolay bulsun. Sayfa genel görünümünde küçük bir "Çakışma" etiketi taşır. Kullanıcı istemediğini normal sayfa silme ile siler.
- **Beyaz tahtada çakışma:** Beyaz tahta tek sayfalık olduğu için kopya yeni sayfa olamaz. Bu cihazın hâli, aynı klasörde "<başlık> (çakışma kopyası)" adlı ayrı bir beyaz tahta olarak eklenir.
- **Eşitleme kapatılıp aynı hesapla yeniden açılırsa:** Motor durumu (değişiklik belirteci, bekleyen liste, silinenler) kapalıyken de cihazda saklanır. Yeniden açılınca kaldığı yerden devam eder; arada başka cihazlarda yapılan silmeler geri gelmez. Durum yalnızca hesap değişince sıfırlanır (o zaman ilk açılış birleşmesi uygulanır).
- **"iCloud'daki eşitleme verisini sil" sonrası diğer iPad'ler:** Bölgenin silindiğini görünce yerel kütüphanelerini korur, eşitlemeyi kapatır ve kullanıcıya bildirir. Bölgeyi kendiliğinden yeniden oluşturup her şeyi tekrar yüklemez.
- **Uzaktan gelen silme ve yedek:** Başka bir iPad'den gelen kalıcı silme yerel kütüphaneden kaldırır ama `DeletedNotebooks`'a eklenmez; yani bu cihazın yedeğindeki kopya durur. Yedek, yanlışlıkla silmeye karşı güvenlik ağı olarak kalır. Silen cihaz kendi yedeğinden bugünkü gibi kaldırır.
- **İlk açılışta iki tarafta aynı kimlikli defter** (ör. aynı yedek iki iPad'e geri yüklenmişse): Sayfalar tek tek karşılaştırılır. Mürekkep verisi bayt bayt aynıysa çakışma yoktur. Farklıysa yalnızca o sayfa için çakışma kopyası üretilir. Meta veri için yukarıdaki alan kuralları geçerlidir.

### Veri modeli (CloudKit)

Özel veritabanında tek bir özel bölge (zone), ör. `OpenLeaf`. Kayıt kimlikleri yerel UUID'lerdir.

| Kayıt türü | İçerik |
|---|---|
| `Folder` | ad, oluşturma tarihi |
| `Notebook` | meta veri (başlık, alt başlık, tür, kapak, kâğıt, boyut, favori, çöp, klasör, tarihler, `pdfAspect`), **sayfa sırası** (sayfa kimlikleri listesi), PDF varsa `CKAsset` |
| `Page` | ait olduğu defter (referans), `pdfPage`, yer imi, yapışkan notlar/resim konumları/bantlar (kodlanmış), **mürekkep** (`CKAsset`) |
| `PageImage` dosyası | resim dosyası (`CKAsset`); `Page` kaydındaki resim listesi dosya adını gösterir |

Kesin alan adları ve kodlama biçimi kurucuya bırakılmıştır.

### Değişiklik takibi

- `Library` hangi defterin ve sayfanın değiştiğini bilecek şekilde genişletilir; değişen kayıtlar `CKSyncEngine`'in bekleyen değişiklik listesine eklenir. Bekleyen liste ve motor durumu (`stateSerialization`) cihazda kalıcı tutulur ki uygulama kapanınca kaybolmasın.
- Uzaktan gelen değişiklikler yerel depoya mevcut `NotebookStore` yolundan yazılır; `Library` ana iş parçacığında güncellenir.
- **Açık defter:** Açık sayfaya uzaktan değişiklik gelirse, kullanıcı o anda çizmiyorsa tuval yeniden yüklenir; çiziyorsa kalem kalkana kadar beklenir. Açık sayfa kimliğe göre sabit tutulur (mevcut `pinnedPage` mantığı), sayfa kaymaz.

### Arayüz

- Yedekleme menüsünde eşitleme anahtarı ve durum satırı: "Eşitlendi", "Eşitleniyor…", "Çevrimdışı, sonra gönderilecek", "iCloud dolu", "iCloud oturumu yok".
- Çakışma kopyası olan sayfada etiket (yukarıda).
- Yeni metinler 7 dilde.

### Senin yapman gereken elle adımlar

- Xcode'da iCloud yeteneğinde CloudKit'i işaretlemek (kapsayıcı aynı).
- Yayından önce CloudKit Console'da şemayı **Production**'a göndermek ("Deploy Schema Changes"). Bunu unutursak App Store sürümünde eşitleme çalışmaz.
- Gizlilik etiketini gözden geçirmek (beklenen: değişiklik yok).

### Test

- Birim testleri: meta veri birleştirme kuralları, sayfa sırası birleştirme, çakışma kopyası üretimi, ilk açılış birleşmesi (CloudKit olmadan, saf mantık olarak).
- Elle test: aynı Apple hesabıyla iki simülatör (ya da bir simülatör + gerçek iPad). Senaryolar: yeni defter, sayfa ekleme/silme/taşıma, aynı sayfaya iki tarafta çevrimdışı yazıp bağlanma, defter silme, eşitlemeyi kapatıp açma, hesap çıkışı.

## Kurucuya bırakılanlar

- `CKSyncEngine` entegrasyonunun kod yapısı (ayrı bir `SyncEngine` sınıfı vb.), dosya adları.
- CloudKit alan adları ve kodlama.
- Değişiklik takibinin `Library` içinde nasıl yapılacağı (anlık görüntü karşılaştırma ya da açık işaretleme).
- Toplu gönderim boyutları, yeniden deneme aralıkları.
- Durum satırının tam yerleşimi (menünün mevcut düzenine uygun).
