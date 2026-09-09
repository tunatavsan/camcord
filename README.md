# Camcord

Camcord, menü çubuğunda yaşayan native bir macOS ekran görüntüsü ve ekran kaydı
uygulamasıdır. Swift 6 ile yazılmıştır ve macOS 15.2 veya yenisini gerektirir.

## Özellikler

- **Ekran görüntüsü:** Bölge, pencere veya tüm ekranı PNG olarak panoya kopyalar.
  İstenirse ayrıca `~/Pictures/camcord/` veya seçilen başka bir klasöre kaydeder.
- **Donmuş seçim görüntüsü:** Bölge/pencere seçici açılmadan önce masaüstünün değişmez
  bir kopyası alınır. Tetikleme anında görünen hover durumu, tooltip ve menü pikselleri
  seçim sırasında kaybolsa bile sonuçta korunur. Ekran düzeni değişirse işlem iptal edilir.
- **Metin çıkarma:** Seçilen ekran alanındaki metni, QR kodunu ve barkodu panoya
  aktarır. Finder veya başka bir uygulamadaki mevcut görseller için de Servisler menüsü
  üzerinden çalışır.
- **Kaydırmalı çekim:** Elle kaydırırken ara kareleri sırayla toplar; birleştirme ve
  önizlemeyi günceller. Görünümün yaklaşık %40’ı kaydırılınca ve kaydırma durulunca
  yeni kare alır. Kopuklukta kısa bir ipucu gösterip yakalamaya devam eder.
  Önizlemedeki **Bitti** sonucu kopyalar; **İptal** veya `Esc`
  çekimden çıkar. HUD’daki otomatik kaydırma düğmesi sayfayı ilerletir (Erişilebilirlik izni gerekir).
- **Ekran kaydı:** Ekran veya pencereyi kaydeder; duraklatma/sürdürme, geri sayım,
  imleç, pencere göstergesi, düşük disk alanında güvenli durdurma ve isteğe bağlı süre
  sınırı sunar.
- **Ses:** Sistem sesi ve mikrofon için bağımsız canlı seviye göstergeleri ile kazanç
  kontrolleri vardır. Varsayılan olarak ikisi tek ses parçasında birleştirilir; kurgu
  için ayrı ses parçaları korunabilir. Mikrofon denemesi yalnızca kullanıcı düğmeye
  bastığında başlar ve dosya oluşturmaz.
- **Kamera:** İsteğe bağlı kamera görüntüsünü kaydın bir köşesine gömer; boyut, köşe
  ve aynalama ayarlanabilir. Ayarlardaki kamera provası yalnızca açıkça başlatıldığında
  kamerayı açar. Kamera sesi kayda eklenmez.
- **Native kontroller:** Sol tıklanan menü çubuğu simgesi her durumda paneli açar;
  kayıt sırasında buradan mikser, duraklatma ve durdurma kontrollerine ulaşılır. Video
  ve ekran görüntüsü klasörü düğmeleri, klasörler henüz boşken de görünür. Tamamlanan
  kayıt kartı hedefi, önizlemeyi ve Finder eylemlerini gösterir.

## Varsayılan çıktı

Ekran görüntüsü panoya gider; diske kopya yazma başlangıçta kapalıdır. Kayıtlar
`~/Movies/camcord/` altında oluşturulur; tamamlanınca önizleme kartından açılabilir,
yeniden adlandırılabilir veya Finder'da gösterilebilir. Kayıt almak panoyu değiştirmez.
Varsayılan kayıt profili 60 fps, native çözünürlük, SDR, HEVC 20 Mbps ve MP4'tür.
Sistem sesi ile mikrofon açıktır, tek ses parçasında birleştirilir; kamera kapalıdır.
ProRes profilleri MOV kullanır. Bunların tamamı Ayarlar'dan değiştirilebilir.

## Kısayollar ve kullanım

Camcord hazır klavye kısayolu atamaz. Ayarlar'dan bölge, pencere, tüm ekran, OCR,
kaydırmalı çekim, kayıt başlat/bitir ve kayıt duraklat/sürdür eylemlerine kısayol
atanabilir. `Kaydırmalı çekim` kısayolu da isteğe bağlıdır ve başlangıçta boştur.
Atanan kısayollar panelde ilgili eylemin yanında görünür.

Menü çubuğu kalabalıksa, çalışan Camcord'u Finder veya Spotlight'tan tekrar açmak
kontrolleri bağımsız bir macOS panelinde gösterir. Kayıt hazırlanırken ve başladığında
ekranda bildirim çıkar. Kayıt sayacı ve durdurma düğmesi, pencere çerçevesi kapalı
olsa veya kaydedilen pencere başka bir pencerenin altında kalsa da erişilebilir kalır.

Bölge seçiminde sürükleyerek alan seçilir, pencereye tıklayarak o pencere seçilir ve
`Esc` işlemi iptal eder. Menü çubuğu simgesine sağ tıklamak veya Control-tıklamak bağlam
menüsünü açar. Fare yan tuşları, orta tık ve çift Sağ Command gibi ek girişler Ayarlar'dan
atanabilir.

## Derleme ve çalıştırma

Xcode Command Line Tools ve geçerli, kalıcı bir codesign kimliği gerekir. Hazırlık
betiği ortamı denetler ve eksikse izlenecek adımları gösterir:

```bash
./scripts/dev-setup.sh
./scripts/build.sh
open dist/Camcord.app
```

Yerel `/Applications` kopyasını güncelleyip açmak için:

```bash
./scripts/build.sh --install
```

`--install`, çalışan Camcord'dan önce normal biçimde çıkmasını ister ve bekler. Kayıt
sonlandırması süre içinde bitmezse uygulamayı zorla kapatıp dosyayı riske atmak yerine
kurulumu durdurur. Bu komut yerel bir geliştirici kurulumu yapar; README herhangi bir
dağıtılmış veya yayınlanmış sürüm iddiasında bulunmaz.

Geliştirme sırasında hızlı kontroller:

```bash
swift build
swift test
```

## İzinler

Kullanılan özelliğe göre macOS Ekran Kaydı, Mikrofon, Kamera veya Erişilebilirlik izni
isteyebilir. Mikrofon ve kamera provaları izni yalnızca kullanıcı ilgili düğmeye
bastığında ister. Kalıcı imza kimliği, yeniden derlemelerde uygulamanın aynı code-signing
kimliğini taşımasını sağlar; macOS'un izin kararları yine Sistem Ayarları tarafından
yönetilir.

Bir izin kaydı sorunluysa Sistem Ayarları › Gizlilik ve Güvenlik bölümünü kontrol edin.
Geliştirici kurulumu için gerekirse ilgili kaydı sıfırlayabilirsiniz:

```bash
tccutil reset ScreenCapture dev.tavsan.camcord
tccutil reset Accessibility dev.tavsan.camcord
tccutil reset Microphone dev.tavsan.camcord
tccutil reset Camera dev.tavsan.camcord
```

## Bildirimleri susturma

macOS, Focus durumunu değiştirmek için genel bir API sunmadığından Camcord bunu isteğe
bağlı olarak Kısayollar uygulaması üzerinden yapar. Kısayollar'da Focus'u açan ve kapatan
iki kısayol hazırlayıp adlarını Ayarlar › Kayıt › Bildirimler bölümüne girin. Alanlar
boşsa bu adım atlanır.

## Teknik yapı ve doğrulama sınırı

Uygulama yaşam döngüsü, menü çubuğu ve overlay pencereleri AppKit; panel ve ayarlar
native SwiftUI/AppKit kontrolleri kullanır. Ekran yakalama ScreenCaptureKit, medya
yazımı ve kamera AVFoundation, OCR Vision ile çalışır. Paket Swift Package Manager ile
derlenir; Xcode projesi yoktur.

Birim ve medya testleri donmuş seçim geometrisini, kaydırmalı birleştirmeyi, zaman
damgalarını, ses işleme/miksajı ve kamera kompozisyonunu kapsar. Offscreen render'lar
yerleşim kontrolü içindir; gerçek masaüstü hover/tooltip yakalamasını, fiziksel kamera
ve mikrofon kalitesini, izin akışlarını veya uzun süreli termal performansı doğrulamaz.
