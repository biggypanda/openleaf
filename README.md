# OpenLeaf

Öğrenciler için ücretsiz ve açık kaynak, Apple Pencil ile el yazısı not alma uygulaması (iPad öncelikli).
Reklam yok, abonelik yok, uygulama içi satın alma yok; notlar cihazda kalır. Türkçe, İngilizce ve Almanca.

<a href="https://apps.apple.com/app/id6832556915"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/tr-tr" alt="App Store'dan indirin" height="50"></a>

## Özellikler

- **Kütüphane:** malzemeli defter kapakları (keten, deri, kraft…), klasörler, favoriler, çöp, arama, sıralama
- **Yeni defter:** 8 kapak, 4 şablon (çizgili, kareli, noktalı, boş), A4 / A5 / Mektup
- **Yazma (PencilKit):** tükenmez, dolma, kurşun ve fırça kalem; ayarlanabilir kalınlık; vurgulayıcı; kement
- **Silgi:** dairenin değdiği yeri silen kısmi silgi (boyutu ayarlanabilir) ya da bütün çizgi
- **Apple Pencil:** iki kez dokununca silgiye geç; Pencil Pro'yu sıkınca dairesel hızlı menü
- **Yalnızca Pencil yazar:** parmak sayfayı kaydırır, tek ya da iki parmakla sayfa çevirir
- **İki parmakla yakınlaştırma** (4 kata kadar, kâğıt ve PDF her yakınlıkta net)
- **Yapışkan notlar:** klavyeyle ya da kalemle yazılır, taşınır, köşeden boyutlandırılır, renk değiştirir
- **Fotoğraf/resim:** kamerayla çek ya da arşivden seç; taşı, boyutlandır, üstüne yaz
- **Sayfalar:** kitap gibi kıvrılarak çevirme, genel görünüm (küçük resim ızgarası), sürükleyerek sıralama, çoğaltma
- **PDF:** içe aktarma, sayfaların üstüne yazma, "Şununla Aç → OpenLeaf", her defteri PDF olarak dışa aktarma
- **Yedekleme:** tüm kütüphane tek dosya olarak Dosyalar'a / iCloud Drive'a; yedekten geri yükleme
- Açık ve koyu tema; Türkçe, İngilizce ve Almanca arayüz; reklam, abonelik, hesap yok

## Gereksinimler

- Xcode 26 veya üstü
- iPadOS / iOS 18 veya üstü (Liquid Glass görünümü iPadOS 26 ve üstünde)

## Çalıştırma

1. `OpenLeaf.xcodeproj` dosyasını Xcode'da açın.
2. Bir iPad simülatörü veya cihaz seçin.
3. Çalıştır'a (⌘R) basın.

Komut satırından simülatör için derleme:

```bash
xcodebuild -project OpenLeaf.xcodeproj -scheme OpenLeaf -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Proje yapısı

| Dosya | İçerik |
| --- | --- |
| `OpenLeaf/OpenLeafApp.swift` | Uygulama girişi |
| `OpenLeaf/Theme.swift` | Tasarım tokenları (renk, köşe, hareket, cam) |
| `OpenLeaf/Models.swift` | Defter ve sayfa modeli, kütüphane (arayüz durumu) |
| `OpenLeaf/Storage.swift` | Yerel dosya deposu ve eski kayıtların taşınması |
| `OpenLeaf/LibraryView.swift` | Kütüphane ekranı |
| `OpenLeaf/NewNotebookSheet.swift` | Yeni defter penceresi |
| `OpenLeaf/DocumentView.swift` | Not alma ekranı ve araç çubuğu |
| `OpenLeaf/Canvas.swift` | PencilKit tuvali ve kâğıt desenleri |
| `OpenLeaf/CoverView.swift` | Kapaklar ve logo |
| `OpenLeaf/PDFSupport.swift` | PDF içe aktarma, sayfa çizimi, küçük resim, dışa aktarma |
| `OpenLeaf/StickyNotes.swift` | Yapışkan notlar (yazı ve kalem katmanı) |
| `OpenLeaf/PageImages.swift` | Sayfadaki resimler, seçim, kamera |
| `OpenLeaf/PageOverview.swift` | Sayfa genel görünümü ve sıralama |
| `OpenLeaf/QuickPalette.swift` | Pencil Pro sıkma menüsü |
| `OpenLeaf/Backup.swift` | Yedekleme ve geri yükleme |
| `OpenLeaf-Info.plist` | PDF belge türü kaydı |

## Veri nasıl saklanır

Her şey cihazda, uygulamanın Belgeler klasöründe durur; sunucu yoktur.

```
OpenLeaf/
  index.json                kütüphane dizini (defter bilgileri, sayfa listeleri, notlar, resim yerleri)
  folders.json              klasörler
  Defterler/<defter-id>/
    <sayfa-id>.drawing      her sayfanın mürekkebi (PencilKit)
    source.pdf              içe aktarılan PDF
    text.txt                PDF'in aranabilir metni
    img-<id>.jpg            sayfalara eklenen resimler
    thumb.png               mürekkepli küçük resim
```

Bir çizgi çizildiğinde yalnızca o sayfanın dosyası yazılır. Yazmalar tek sıralı kuyrukta ve atomik
yapılır; uygulama arka plana geçerken bekleyen kayıtlar tamamlanır. İlk sürümün tek dosyalık kaydı
(`yaprak-kutuphane.json`) ilk açılışta otomatik taşınır ve `yaprak-kutuphane.eski.json` olarak saklanır.

## Lisans

OpenLeaf, [GNU Genel Kamu Lisansı sürüm 3](LICENSE) (GPL-3.0) ile yayınlanan özgür yazılımdır.

Kodu kullanabilir, değiştirebilir ve paylaşabilirsiniz. Değiştirilmiş bir sürümü dağıtırsanız
onun kaynak kodunu da aynı lisansla açmanız gerekir; böylece OpenLeaf'ten türeyen uygulamalar da
öğrenciler için özgür kalır.

Copyright (C) 2026 biggypanda

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. This program is distributed in the hope that it
will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
