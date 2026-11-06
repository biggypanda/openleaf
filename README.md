# Yaprak

Öğrenciler için ücretsiz ve açık kaynak, Apple Pencil ile el yazısı not alma uygulaması (iPad öncelikli).
Reklam yok, abonelik yok, uygulama içi satın alma yok; notlar cihazda kalır.

## Özellikler

- Kütüphane: malzemeli defter kapakları (keten, deri, kraft…), favoriler, çöp, arama, sıralama
- Yeni defter: 8 kapak, 4 şablon (çizgili, kareli, noktalı, boş), A4 / A5 / Mektup
- Not alma (PencilKit): dolma, tükenmez ve fırça kalem; vurgulayıcı, silgi, kement; 5 renk; geri al ve yinele
- Sayfa ekleme, silme (onaylı) ve sayfa çevirme; odak modu; harici klavye kısayolları
- PDF: içe aktarma, sayfaların üstüne yazma, "Şununla Aç → Yaprak" ile başka uygulamalardan açma
- Her defteri PDF olarak dışa aktarma (Mail, AirDrop, Dosyalar)
- Açık ve koyu tema; Türkçe arayüz

## Gereksinimler

- Xcode 26 veya üstü
- iPadOS / iOS 18 veya üstü (Liquid Glass görünümü iPadOS 26 ve üstünde)

## Çalıştırma

1. `Yaprak.xcodeproj` dosyasını Xcode'da açın.
2. Bir iPad simülatörü veya cihaz seçin.
3. Çalıştır'a (⌘R) basın.

Komut satırından simülatör için derleme:

```bash
xcodebuild -project Yaprak.xcodeproj -scheme Yaprak -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Proje yapısı

| Dosya | İçerik |
| --- | --- |
| `Yaprak/YaprakApp.swift` | Uygulama girişi |
| `Yaprak/Theme.swift` | Tasarım tokenları (renk, köşe, hareket, cam) |
| `Yaprak/Models.swift` | Defter ve sayfa modeli, kütüphane (arayüz durumu) |
| `Yaprak/Storage.swift` | Yerel dosya deposu ve eski kayıtların taşınması |
| `Yaprak/LibraryView.swift` | Kütüphane ekranı |
| `Yaprak/NewNotebookSheet.swift` | Yeni defter penceresi |
| `Yaprak/DocumentView.swift` | Not alma ekranı ve araç çubuğu |
| `Yaprak/Canvas.swift` | PencilKit tuvali ve kâğıt desenleri |
| `Yaprak/CoverView.swift` | Kapaklar ve logo |
| `Yaprak/PDFSupport.swift` | PDF içe aktarma, sayfa çizimi, küçük resim, dışa aktarma |
| `Yaprak-Info.plist` | PDF belge türü kaydı |

## Veri nasıl saklanır

Her şey cihazda, uygulamanın Belgeler klasöründe durur; sunucu yoktur.

```
Yaprak/
  index.json                kütüphane dizini (defter bilgileri, sayfa listeleri)
  Defterler/<defter-id>/
    <sayfa-id>.drawing      her sayfanın mürekkebi (PencilKit)
    source.pdf              içe aktarılan PDF
    text.txt                PDF'in aranabilir metni
    thumb.png               mürekkepli küçük resim
```

Bir çizgi çizildiğinde yalnızca o sayfanın dosyası yazılır. Yazmalar tek sıralı kuyrukta ve atomik
yapılır; uygulama arka plana geçerken bekleyen kayıtlar tamamlanır. İlk sürümün tek dosyalık kaydı
(`yaprak-kutuphane.json`) ilk açılışta otomatik taşınır ve `yaprak-kutuphane.eski.json` olarak saklanır.

## Lisans

Henüz seçilmedi.
