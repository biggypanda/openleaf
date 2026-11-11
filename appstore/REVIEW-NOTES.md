# App Review cevabı (Guideline 2.1 - Information Needed)

Aşağıdaki İngilizce metni App Store Connect → sürüm sayfası → App Review Information → **Notes**
alanına yapıştır (eski kısa notun yerine). Ekran kaydını **Attachment** alanına yükle.

---

```
Thank you for reviewing OpenLeaf Notes. Answers to your questions:

1. SCREEN RECORDING
A screen recording captured on a physical iPad running the latest iPadOS is attached to this submission (Attachment field). It starts with launching the app and shows the typical flow: opening the library, creating and opening a notebook, writing with Apple Pencil, changing pens and colors, adding a sticky note, adding a page, creating a new notebook and importing a PDF.
The app has no account registration or login, no user-generated content shared with other users, and no paid content or in-app purchases.

2. PURPOSE AND TARGET AUDIENCE
OpenLeaf is a free, open-source handwritten note-taking app for iPad, made mainly for students. It lets them take class notes with Apple Pencil in digital notebooks, write on top of lecture PDFs and slides, and organize notes in folders. Many note apps require a subscription or an account; OpenLeaf is completely free, has no ads and keeps all notes on the device. Source code: https://github.com/biggypanda/openleaf

3. SETUP AND MAIN FEATURES
No setup or login is needed. On first launch the library is empty and shows two buttons: "Create notebook" and "Import PDF".
- Tap "Create notebook", pick a cover and paper, then write with Apple Pencil (a finger also works for scrolling).
- Use the bottom toolbar for pens, highlighter, eraser, lasso, sticky notes, images and colors. Tap the selected pen again to change pen type and thickness.
- Use the top bar to see all pages, add a page, share/export as PDF, or go full screen.
- In the library, tap "+" to create a notebook, quick note, whiteboard or folder, or to import a PDF from Files.
- Long-press a notebook to favorite, duplicate, move to a folder, share as PDF or delete it. Deleted notebooks go to Trash and can be restored.
No sample files are required; any PDF from the Files app can be imported.

4. EXTERNAL SERVICES
None. The app makes no network requests and uses no third-party SDKs, analytics, authentication, payment or AI services. It only uses Apple frameworks (SwiftUI, PencilKit, PDFKit, PhotosUI/camera, Files). All data is stored locally on the device. Backups are saved by the user to Files or iCloud Drive through the standard system file picker.

5. REGIONAL DIFFERENCES
None. The app works the same in all regions. The interface is available in English, Turkish and German and follows the device language.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. The app does not operate in a regulated industry and contains no protected third-party material.
```

---

## Ekran kaydı (gerçek iPad'de, 1–2 dakika)

1. iPad'i en son iPadOS'a güncelle. TestFlight'tan en yeni build'i (build 3) kur.
2. Denetim Merkezi'ni aç (sağ üstten aşağı kaydır) → **Ekran Kaydı** düğmesi.
   Yoksa: Ayarlar → Denetim Merkezi → "Ekran Kaydı"nı ekle.
3. Kayıt başlayınca ana ekrandan **OpenLeaf'i aç** (kayıt uygulamanın açılışıyla başlamalı).
4. Sırayla göster:
   - Kütüphane → "Yeni defter oluştur" → defteri aç
   - Apple Pencil'la birkaç kelime yaz, rengi değiştir
   - Kaleme tekrar dokun → kalem türü/kalınlık menüsü
   - Fosforlu kalem, silgi
   - Yapışkan not ekle, içine yaz
   - Üstten sayfa ekle, sayfalar görünümünü aç
   - "+" → PDF içe aktar → Dosyalar'dan bir PDF seç, üstüne yaz
5. Denetim Merkezi'nden kaydı durdur. Video **Fotoğraflar**'a kaydedilir.
6. Videoyu Mac'e al (AirDrop) ve App Store Connect'te **Attachment** alanına yükle.
