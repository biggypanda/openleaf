# Toplu içe aktarma (issue #15) — tasarım

## Amaç

GoodNotes, Notability ya da başka bir not uygulamasından gelen kullanıcı tüm defterlerini tek seferde, dosyalarla uğraşmadan OpenLeaf'e taşısın. Hedef akış: diğer uygulamada "tümünü PDF olarak dışa aktar" → Paylaş → OpenLeaf → bitti.

## Hedefler

- Tek bir ZIP (GoodNotes'un klasör dışa aktarımı), birden çok PDF ya da bir klasör alınır.
- Her PDF dosya adıyla bir defter olur (mevcut `importPDF` ile aynı sonuç).
- ZIP ya da klasör içindeki alt klasörler OpenLeaf klasörü olur. OpenLeaf klasörleri düz: yalnız ilk seviye klasör adı kullanılır, daha derindeki PDF'ler o ilk seviye klasöre girer. Kökteki PDF'ler o an seçili klasöre (yoksa klasörsüz) girer.
- Aynı adlı klasör zaten varsa onu kullanır, yenisini açmaz.
- Bozuk / parolalı / PDF olmayan dosya işlemi durdurmaz; sonunda özet: "N defter aktarıldı, M dosya atlandı" ve atlananların adları.
- İki giriş yolu, aynı motor:
  1. Paylaş menüsü / "OpenLeaf'te aç" (`onOpenURL`): PDF ve ZIP kabul edilir. Notability çoklu paylaşımda her PDF ayrı `onOpenURL` olarak gelir; bunlar kısa bir süre içinde toplanıp tek özetle gösterilir.
  2. Kütüphanede "İçe aktar" düğmesi: çoklu seçim, PDF + ZIP + klasör.
- "Başka uygulamadan taşı" rehberi: GoodNotes ve Notability'den PDF dışa aktarma adımları kısaca, ve uyarı: eski el yazısı düzenlenebilir mürekkebe dönüşmez, üstüne yazılabilir; ses kayıtları gibi özellikler PDF'te gelmez.
- İlerleme: uzun aktarımda "12 / 42" gibi ilerleme ve iptal gösterilir; arayüz donmaz.

## Hedef dışı

- `.goodnotes`, `.note`, `.nbn` gibi yerel formatlar (kullanım şartları riski, belgesiz format).
- PDF'teki eski el yazısını / resimleri / metin kutularını düzenlenebilir nesneye çevirme.
- İç içe OpenLeaf klasörleri.

## Anti-hedefler

- Tek kötü dosya yüzünden tüm aktarımın çöpe gitmesi.
- Büyük ZIP'i belleğe alıp uygulamanın kapanması.
- Aktarım yarıda kesilince yarım defter / boş klasör kalması (bitmiş defterler kalır, yarımı silinir).

## Yaklaşımlar

1. **Kendi ZIP okuyucumuz (seçilen).** Apple `Compression` (`COMPRESSION_ZLIB` = ham DEFLATE) ile akış hâlinde diske açma; merkezi dizin okuma; stored (0) ve deflate (8) yöntemleri; ZIP64. Dış bağımlılık yok. Bedeli: kendi kodumuz, tuhaf ZIP'lerle test gerekir.
2. ZIPFoundation paketi: hazır ve olgun, ama ilk dış bağımlılık olurdu. Kullanıcı istemedi.
3. Yalnız çoklu PDF + klasör: ZIP'i kullanıcı Files'ta açmak zorunda kalır, "kolay taşıma" amacına ters.

## Kararlar

- ZIP okuyucu ayrı dosya `OpenLeaf/ZipReader.swift`, uygulamadan bağımsız (yalnız Foundation + Compression), komut satırı kontrolüyle test edilir (`Tests/` altındaki mevcut BackupEngineCheck gibi).
- Şifreli ZIP girdileri, desteklenmeyen sıkıştırma yöntemleri ve CRC tutmayan girdiler "atlandı" sayılır.
- Yol güvenliği: `..` ya da mutlak yol içeren girdi adları reddedilir (zip-slip); `__MACOSX/` ve `._` ile başlayan gizli dosyalar sessizce yok sayılır.
- ZIP geçici klasöre açılır, PDF'ler tek tek `importPDF` ile içe aktarılır, geçici klasör her durumda silinir.
- `Info.plist` belge türlerine `public.zip-archive` eklenir (Alternate rank).
- Yeni metinler `Localizable.xcstrings`'e 7 dilde eklenir.

## Kurucuya kalanlar

- İlerleme arayüzünün görünümü (sheet ya da kart), rehberin tam metni, toplama süresi (çoklu `onOpenURL` için ~1 sn).
