# iCloud otomatik yedek: tasarım

Tarih: 2026-11-13. Hedef sürüm: 1.0.3'ten sonraki sürüm.

## Amaç

iPad bozulursa, kaybolursa ya da uygulama silinirse notlar yok olmasın. Bugün tek koruma elle alınan
yedek dosyası; almayı unutan kişinin notları gider. Yedek, kullanıcı hiçbir şey yapmadan kendi
iCloud'una alınmalı ve yeni kurulumda geri gelmeli.

Koşul: kullanıcıdan veri toplanmayacak. Notlar yalnızca kullanıcının kendi iCloud hesabına gider;
geliştirici o veriye erişemez. App Store gizlilik etiketi "Veri toplanmıyor" olarak kalır.

## Hedefler

- Açıkken yedek kendiliğinden alınır; kullanıcı bir şeye basmaz.
- Yalnızca değişen dosyalar yüklenir (bir sayfaya yazınca o sayfanın dosyası).
- Boş bir kurulumda iCloud'da yedek varsa geri yükleme teklif edilir.
- Kullanıcı yedeğin durumunu görür: açık mı, en son ne zaman alındı, bir sorun var mı.
- Yedek kapalıyken ya da iCloud yokken uygulama bugünkü gibi çalışır.

## Kapsam dışı

- Cihazlar arası eşitleme (aynı defterin iki cihazda güncel kalması).
- Eski sürümlere dönme (yedek geçmişi).
- iPhone desteği.
- Elle yedek dosyasının (`makeBackup`) bellek kullanımını düzeltmek. Elle yedek aynen kalır.

## Asla olmaması gerekenler

- Yedekleme kodunun yerel notları değiştirmesi ya da silmesi. Yedekleme yerel depoyu yalnızca okur.
- Boş ya da bozuk bir yerel kütüphanenin iCloud'daki yedeği silmesi.
- Verinin kullanıcının iCloud'u dışında bir yere gitmesi.
- Kullanıcıya sorulmadan açılması (bugüne kadar "notların cihazında kalır" dedik).

## Yaklaşımlar

1. **Uygulamanın iCloud klasörüne dosya dosya kopya (seçilen).** Yerel depo zaten sayfa başına bir
   dosya tutuyor; aynı yapı iCloud'daki uygulama klasörüne aynalanır. Yalnızca değişen dosya yüklenir,
   bellek kullanımı düşük kalır, kod küçük. Eksisi: yükleme durumunu iOS yönetir, ayrıntılı ilerleme
   göstermek zor.
2. **Mevcut tek dosyalık yedeği iCloud'a otomatik kaydetmek.** En az kod. Ama her seferinde bütün
   kütüphane yeniden yüklenir (63 MB'lık kütüphanede her yedek 63 MB) ve bütün kütüphane belleğe
   alınır (ölçülen: 97 MB); büyük kütüphanede arka planda uygulama öldürülebilir. Elendi.
3. **CloudKit (Apple'ın veritabanı).** Hata ve durum bilgisi daha iyi. Ama çok daha fazla kod, test
   etmesi zor ve kullanıcıya 1. yolun vermediği bir şey vermiyor. Elendi.
4. **Kütüphanenin kendisini iCloud'da tutmak.** Dosyalar cihazdan boşaltılabilir, yarım inmiş dosya
   okunabilir, çakışma çıkar. Notları riske atar. Elendi.

Seçim gerekçesi: amaç kayıp önlemek; 1. yol bunu en az riskle ve en az kodla yapıyor. Yaklaşım seçimi
geliştiriciye bırakıldı ("otomatik yedek lazım" dendi, nasıl yapılacağı söylenmedi).

## Nasıl çalışır

### Yer

iCloud kapsayıcısı: `iCloud.io.github.biggypanda.openleaf`. Kapsayıcının köküne yazılır, `Documents`
altına değil; böylece Dosyalar uygulamasında görünmez ve kullanıcı içini yanlışlıkla bozamaz.
Kullanıcı kapladığı yeri Ayarlar → iCloud → Saklama Alanı'nda görür ve oradan silebilir.

```
Yedekler/<cihaz-kimliği>/
  cihaz.json          cihaz adı, model, son yedek tarihi, defter sayısı, uygulama sürümü, biçim sürümü
  index.json          yerel index.json'ın kopyası
  folders.json        yerel folders.json'ın kopyası
  Defterler/<defter-id>/
    <sayfa-id>.drawing, source.pdf, text.txt, img-<id>.jpg     (thumb.png alınmaz)
```

Her cihazın kendi klasörü var: aynı Apple hesabındaki iki iPad birbirinin yedeğini ezmez. Cihaz
kimliği ilk açılışta üretilen bir UUID'dir ve `UserDefaults`'ta (`yedek.cihazKimligi`) durur.
Uygulama silinip yeniden kurulursa yeni kimlik üretilir; eski klasör geri yüklenebilir bir yedek
olarak kalır.

### Yedekleme

- Tetikleyiciler: uygulama açılınca, arka plana geçince (`beginBackgroundTask` ile süre alınarak) ve
  kullanım sırasında son değişiklikten 60 saniye sonra. İstekler birleştirilir; aynı anda tek yedek
  çalışır, kendi sıralı kuyruğunda.
- Önce `library.flush()` ile bekleyen yazmalar bitirilir.
- Her yerel dosya için boyut ve değişiklik tarihi, cihazda tutulan bir durum dosyasıyla
  (`Application Support/yedek-durum.json`: yol → boyut + tarih) karşılaştırılır. Değişen ya da
  yedekte olmayan dosya kopyalanır. Kopya `NSFileCoordinator` ile, önce geçici dosyaya yazılıp
  sonra yer değiştirilerek yapılır.
- Sıra: önce defter dosyaları, sonra `folders.json` ve `index.json`, en son `cihaz.json`. Böylece
  dizin hiçbir zaman yedekte olmayan bir sayfayı göstermez (yarıda kesilirse en kötü ihtimalle bir
  sayfanın eski hali kalır, sonraki yedek düzeltir).
- Silme kuralları:
  - Yerel dizinde olan bir defterin klasöründe artık bulunmayan dosya yedekten silinir (sayfa silinmiş).
  - Bir defter yedekten yalnızca kullanıcı onu çöp kutusundan kalıcı olarak sildiyse silinir. Kalıcı
    silme, kimliği bir "silinenler" listesine (`yedek.silinenler`) yazar; yedek bu listeye göre siler.
  - Bunun dışında yedekte olup yerelde olmayan hiçbir şeye dokunulmaz. Yani yerel kütüphane boş ya da
    okunamaz gelirse yedek olduğu gibi kalır.
- iCloud yoksa (oturum kapalı, iCloud Drive kapalı) ya da yer dolduysa durum ekranında yazar; yerel
  kayıt etkilenmez, sonraki tetikleyicide yeniden denenir.

### Geri yükleme

- Kütüphane boşken iCloud'da yedek bulunursa bir pencere açılır: cihaz adı, defter sayısı, son yedek
  tarihi; "Geri yükle" ve "Şimdi değil". Yeni kurulumda iCloud dosya listesi gecikmeli gelebildiği
  için yedekler `NSMetadataQuery` ile aranır ve bulunduğu anda teklif edilir.
- Yedekleme menüsünde "iCloud yedeği" her zaman durur; geri yükleme oradan da başlatılabilir.
  Birden fazla cihaz yedeği varsa liste gösterilir.
- Geri yükleme bugünkü elle geri yüklemeyle aynı kuralı izler: bu iPad'de olmayan defterler eklenir,
  var olanlara dokunulmaz, hiçbir şey silinmez. Dosya adları bugünkü gibi doğrulanır (klasör dışına
  yazılmaz).
- Dosyalar cihaza inmemiş olabilir; her dosya `NSFileCoordinator` ile okunur (inmesini bekler).
  İlerleme gösterilir, iptal edilebilir. Yarıda kalan bir defter kütüphaneye eklenmez.
- Geri yükleme bitince bu cihaz kendi klasörüne yedeklemeye başlar. Eski cihaz klasörü silinmez;
  kullanıcı isterse listeden onay vererek siler.

### Arayüz

- Güncellemeden sonraki ilk açılışta bir kez sorulur: "Notların iCloud'una otomatik yedeklensin mi?"
  "Aç" / "Şimdi değil". Sessizce açılmaz. iCloud yoksa sorulmaz.
- Kütüphanedeki Yedekleme menüsüne "iCloud yedeği…" satırı eklenir. Açılan pencerede: aç/kapa,
  durum ("Son yedek: bugün 14:32", "Yedekleniyor…", "iCloud'da oturum açık değil", "iCloud dolu"),
  "Şimdi yedekle", bulunan yedekler ve geri yükleme.
- Durumda "yedeklendi" yalnızca dosyalar kapsayıcıya kopyalandıysa yazılır; iCloud'a yükleme sürüyorsa
  (`ubiquitousItemIsUploaded` yanlışsa) "iCloud'a yükleniyor" denir.
- Tüm yeni metinler Türkçe, İngilizce ve Almanca.

### Proje ayarları

- Yeni `OpenLeaf/OpenLeaf.entitlements`: iCloud Documents hizmeti ve yukarıdaki kapsayıcı.
  `CODE_SIGN_ENTITLEMENTS` proje dosyasına eklenir.
- `Info.plist`'e `NSUbiquitousContainers` eklenmez (Dosyalar'da görünmesin diye).
- Yeni dosya: `OpenLeaf/CloudBackup.swift` (yedekleme motoru, durum, geri yükleme). Motor hedef kök
  klasörü dışarıdan alır; böylece iCloud olmadan, geçici bir klasöre karşı denenebilir.

### Metinler

`PRIVACY.md`, `README.md` ve mağaza açıklamaları (TR/EN/DE) güncellenir: notlar cihazda kalır;
kullanıcı açarsa ayrıca kendi iCloud'una yedeklenir; geliştirici notları göremez.

## Doğrulama

- Motor, geçici bir klasör hedef verilerek simülatörde denenir: ilk yedek, tek sayfa değişince
  yalnızca o dosyanın kopyalanması, sayfa silme, kalıcı defter silme, boş kütüphaneyle yedeğin
  korunması, yarıda kesilen yedek, geri yükleme sonrası dosyaların bayt bayt aynı olması.
- Gerçek iCloud yalnızca gerçek cihazda denenebilir: aç, Ayarlar → iCloud'da yerin dolduğunu gör,
  uygulamayı sil, yeniden kur, geri yükleme teklifinin geldiğini ve notların döndüğünü gör. Bu adımı
  uygulama sahibi kendi iPad'inde yapar.

## Bilinen riskler ve açık noktalar

- iCloud yeteneğinin ve kapsayıcının Apple geliştirici hesabında açılması gerekir. Otomatik imzalama
  bunu kendisi yapabilir; yapamazsa hesap sahibinin Xcode'da ya da geliştirici sitesinde bir kez
  onay vermesi gerekir.
- iCloud'un ücretsiz alanı 5 GB. Büyük PDF'li kütüphaneler bunu doldurabilir; bu durumda yedek durur
  ve kullanıcıya söylenir.
- iPad'in kendi iCloud Yedeklemesi açıksa ve cihaz o yedekten kurulursa notlar bugün de geri gelir.
  Bu özellik onun kapalı olduğu, dolduğu ya da yalnızca uygulamanın silindiği durumları kapatır.

## Yedek klasörünü seçmek (aynı işe alındı)

Karar (2026-11-13): önce "iCloud'dan sonra ayrı aşama" denmişti; uygulama sahibi Google Drive, OneDrive ve
Dropbox'ın da gelmesini isteyince aynı işe alındı. Uygulama bu hizmetlere kendisi bağlanmaz: kullanıcı Dosyalar
penceresinden bir klasör seçer, otomatik yedek oraya yazılır. Giriş ekranı ve üçüncü taraf kodu yoktur.

- Aynı anda tek yedek yeri vardır: iCloud ya da seçilen klasör. Pencerede "Yedek yeri" altında seçilir.
- Seçilen klasöre kalıcı erişim bir yer imiyle (`UserDefaults` `yedek.klasor.imi`) saklanır; her işte açılıp kapatılır.
- Yapı: `<klasör>/OpenLeaf Yedekleri/<cihaz-kimliği>/…` (iCloud'daki yapının aynısı).
- Her yerin kendi durum dosyası vardır; yer değişince yeni yere her şey baştan kopyalanır, eski yerdeki yedek silinmez.
- Bir kerelik soru yalnızca iCloud için sorulur; klasör penceresinden seçilir.
- Sağlayıcıların (Google Drive, Dropbox, OneDrive) klasör seçmeye izin verip vermediği ve arka planda yazmanın
  güvenilirliği gerçek cihazda denenmedi. Simülatörde yalnızca "iPad'imde" klasörüyle denendi.

SSH/SFTP için doğrudan destek yazılmayacak (karar: 2026-11-13).

## Uygulayana bırakılanlar

Pencere yerleşimi ve metinlerin son hali, durum dosyasının biçimi, yeniden deneme aralıkları,
ilerleme göstergesinin ayrıntısı.
