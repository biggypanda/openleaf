# iPad iCloud eşitleme: uçtan uca deneme sonuçları

Bu senaryolar iki iPad simülatöründe, kullanıcının kendisinin aynı test Apple hesabıyla iCloud'a giriş yapmasını gerektirir (şifre girilmez). Uygulama iki simülatöre de kurulur. Giriş yapılmadığı için aşağıdaki senaryoların hiçbiri henüz çalıştırılmadı. Her senaryo çalıştırılınca durum GEÇTİ ya da KALDI olarak güncellenir ve Not satırına gözlem yazılır.

## A. İlk eşitleme
Yalnızca A'da eşitleme açık, kütüphanesi dolu; B'de aç. Beklenen: B'de A'nın defterleri görünür, B'nin kendi defterleri silinmez.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## B. Temel değişiklikler
A'da yeni defter, sayfa ekle/taşı/sil, PDF içe aktar, resim ekle. Beklenen: birkaç saniyede B'de görünür.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## C. Çakışma
İki simülatör uçak modunda (ağ kapalı); aynı sayfaya ikisinde yaz; ağı aç. Beklenen: sayfa ve "Çakışma" etiketli kopya, ikisinde de aynı. Aynısı bir beyaz tahtada: ayrı "(çakışma kopyası)" beyaz tahta.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## D. Silinen ama yazılan sayfa
A'da sayfa sil, B çevrimdışıyken aynı sayfaya yaz; bağlan. Beklenen: sayfa "Kurtarıldı" ile geri gelir, bildirim çıkar. Aynısı defter silme ile: yeni defterde yalnızca yazılan sayfalar.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## E. Yazarken gelen değişiklik
B'de sayfaya yazarken A'dan aynı sayfaya değişiklik gelir. Beklenen: çizgi bozulmaz, kalem kalkınca sayfa yenilenir, sayfa kaymaz.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## F. Hemen kapatma
Değişiklik yapıp uygulamayı hemen kapat; yeniden aç. Beklenen: değişiklik diğer simülatörde görünür.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## G. Çevrimdışı durum
Uçak modunda durum "Çevrimdışı…" olur; bağlanınca "Eşitlendi" olur.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## H. Kapat/aç
Eşitlemeyi kapat ve yeniden aç. Beklenen: arada silinenler geri gelmez.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## I. Eşitleme verisini silme
"iCloud'daki eşitleme verisini sil". Beklenen: diğer simülatörde eşitleme kapanır, notlar yerinde kalır.
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:

## J. Otomatik yedek
Mevcut otomatik yedek hâlâ çalışır (yedekleme menüsünden "Şimdi yedekle").
- Durum: ÇALIŞTIRILMADI (kullanıcı iCloud girişi bekleniyor)
- Not:
