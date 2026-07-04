# Camcord

Kişisel kullanım için ultra-hafif, native macOS ekran görüntüsü + ekran kaydı aracı.
Menü çubuğunda yaşar, login'de açılır, her şey kısayolla — sürtünmesiz.

- **Screenshot → sadece pano.** Bölge / pencere / tam ekran; PNG anında panoya düşer, dosya birikintisi yok.
- **Kayıt → `~/Movies/camcord/`.** Kalite profilleri (En Optimize → En Kaliteli) veya Özel: H.264 / HEVC 10-bit / ProRes (Proxy…4444), ayarlanabilir bitrate, kapsayıcı (varsayılan `.mp4`, ProRes → `.mov`), 24–120 fps. Sistem sesi + mikrofon ayrı track'ler; bitince dosya URL'i panoya kopyalanır (Cmd+V ile Finder/Slack'e dosya olarak yapışır). Soft-pause/resume destekli.
- **Gelişmiş kısayollar.** Klavye (Carbon, izin gerektirmez) + fare yan tuşları / çift-tap Sağ ⌘ (CGEventTap, Accessibility izni ister).

## Kurulum

```bash
./scripts/dev-setup.sh    # imza kimliğini doğrular (tek seferlik)
./scripts/build.sh        # dist/Camcord.app üretir (imzalı)
./scripts/build.sh --install   # + /Applications'a kopyalar ve açar
```

İlk açılışta: login item otomatik kaydedilir; ilk çekimde **Screen Recording** izni,
mikrofonlu ilk kayıtta **Mikrofon** izni, fare kısayolu açılırsa **Accessibility**
izni istenir. İzinler sabit imza kimliği sayesinde rebuild'lerde bozulmaz.

## Kısayollar

**Varsayılan hiçbir kısayol yoktur** — hepsini Settings'ten sen atarsın (klavye kısayolları + fare yan tuşları). Atanabilir aksiyonlar: bölge / aktif pencere / tüm ekran çek, metin (OCR), kaydır (scrolling capture), kayıt başlat-bitir, kayıt duraklat-sürdür. Fare yan tuşları ve orta tık (yapıştır) da Settings'ten bağlanır.

Bölge seçiminde: sürükle = bölge, pencereye tek tık = o pencere, `Esc` = iptal.

## Sorun giderme

- **Çekim başarısız + bip:** Screen Recording izni düşmüş olabilir (macOS ~30 gün
  kullanılmayınca yeniden onay ister). App sizi otomatik olarak ilgili ayar
  bölmesine götürür. Gerekirse elle sıfırlayın:
  ```bash
  tccutil reset ScreenCapture dev.tavsan.camcord
  tccutil reset Accessibility dev.tavsan.camcord
  tccutil reset Microphone dev.tavsan.camcord
  ```
- **Fare kısayolu çalışmıyor:** Sistem Ayarları → Gizlilik ve Güvenlik →
  Erişilebilirlik'te Camcord açık mı? Menüdeki durum satırı eksikliği gösterir.
- **İkonu yeniden üretmek:** `swift scripts/make-icon.swift`

## Mimari (kısa)

Saf Swift 6 / AppKit (SwiftUI yalnızca Settings içeriği). ScreenCaptureKit:
screenshot'ta `SCScreenshotManager.captureImage(in:)` (çoklu ekran bölge desteği),
kayıtta manuel `SCStream` → `AVAssetWriter` (3 ayrı input: video + sistem sesi +
mikrofon; `SCRecordingOutput` pause API'si olmadığı için kullanılmadı; soft-pause
`PauseClock` CMTime retiming ile). `SCShareableContent` cache'lenir, asla
çekim-başına sorgulanmaz. Hotkey Tier 1 = KeyboardShortcuts (Carbon), Tier 2 =
`CGEventTap` (watchdog + wake/session yeniden-kurulum). Build: SPM + `scripts/build.sh`
(Xcode projesi yok); her build sabit Apple Development kimliğiyle imzalanır — asla
`codesign -s -` (TCC, Designated Requirement'a bakar; ad-hoc imza her rebuild'de
izinleri bozar).
