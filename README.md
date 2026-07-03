# Camcord

Kişisel kullanım için ultra-hafif, native macOS ekran görüntüsü + ekran kaydı aracı.
Menü çubuğunda yaşar, login'de açılır, her şey kısayolla — sürtünmesiz.

- **Screenshot → sadece pano.** Bölge / pencere / tam ekran; PNG anında panoya düşer, dosya birikintisi yok.
- **Kayıt → `~/Movies/camcord/`.** Sistem sesi + mikrofon ayrı track'ler (HEVC `.mov`, H.264 fallback); bitince dosya URL'i panoya kopyalanır (Cmd+V ile Finder/Slack'e dosya olarak yapışır). Soft-pause/resume destekli.
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

## Varsayılan kısayollar (Settings… ⌘, ile değiştirilebilir)

| Aksiyon | Kısayol |
|---|---|
| Bölge seç → pano | `⌘⇧2` ve fare yan tuşu (Button 4) |
| Aktif pencere → pano | `⌘⇧1` |
| Tüm ekran → pano | `⌘⇧6` |
| Son bölgeyi tekrarla | `⌘⇧R` |
| Kayıt başlat/durdur | `⌘⇧9` |
| Kayıt duraklat/sürdür | `⌘⇧0` |
| Çift-tap Sağ ⌘ → bölge | Settings'ten açılır |

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
