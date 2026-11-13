# LibreMusic

LibreMusic — музыкальный плеер с открытым исходным кодом на Flutter и Rust,
развиваемый на основе Mornye. Он объединяет локальную медиатеку, сетевые
источники и расширения музыкальных сервисов.

- Воспроизведение музыки, очередь, плейлисты, тексты и эквалайзер.
- Локальная библиотека и подключение SMB, WebDAV, HTTP(S), Subsonic/OpenSubsonic.
- Поиск и работа с музыкальными сервисами через устанавливаемые расширения.
- История прослушиваний, резервные копии и интеграция с Last.fm.

Проект находится в разработке; первый релиз этого форка ещё не выпущен.
Исходники и задачи: [DevDays-LibreMusic/LibreMusic](https://github.com/DevDays-LibreMusic/LibreMusic).
В именах пакетов, скриптов и выходных файлов пока сохраняется `Mornye`.

## Расширения

В разделе репозиториев расширений приложения добавьте полный адрес каталога:

```text
https://raw.githubusercontent.com/DevDays-LibreMusic/LibreMusic/main/extensions/catalog/registry.json
```

Состав, ограничения сервисов и пересборка пакетов описаны в
[инструкции каталога](extensions/catalog/README.md).

## Подготовка к сборке

Все команды выполняются из корня репозитория. Установите Git, Python 3,
[FVM](https://fvm.app/) и Rust через rustup. Для Unix-скриптов нужен Bash.
Используйте закреплённые версии: Flutter **3.47.8** из [.fvmrc](.fvmrc)
и Rust **1.99.1** из [rust-toolchain.toml](rust_backend/rust-toolchain.toml).
Dart поставляется вместе с Flutter.

```bash
git clone https://github.com/DevDays-LibreMusic/LibreMusic.git
cd LibreMusic
fvm install
fvm dart scripts/prepare_flutter_sdk.dart
fvm flutter pub get --enforce-lockfile
```

Скрипт подготовки применяет необходимый проекту патч Flutter SDK; запускайте
его для каждой новой установки SDK. Активируйте Rust командой `rustup show`
из папки `rust_backend`, затем вернитесь в корень. Нативные инструменты для
выбранной платформы перечислены ниже; проверьте окружение через `fvm flutter doctor -v`.

Примеры мобильных сборок ниже используют **Lite**: музыка и расширения работают
без Discord SDK, отключён только мобильный статус «Слушает…» в Discord.
Полная интеграция требует отдельно подготовленного SDK — см.
[Discord build setup](third_party/mornye_discord/README.md#build-setup).
Обычный CI без ключа также использует Lite; релизный workflow и `--production`
по-прежнему требуют SDK. Для Last.fm нужны собственные API-ключи:
[настройка Last.fm](CONTRIBUTING.md#lastfm-integration).

## Android

Сборка через Bash на Linux/macOS. Нужны JDK **25**, Gradle **9.8.2**,
Android command-line tools, SDK Platform **37.0**, Build Tools **37.0.0**,
NDK **30.0.16248370**, Android CMake **4.1.2** и Clang/libclang. Укажите `JAVA_HOME`, добавьте Java,
Gradle и `sdkmanager` в `PATH`; `ANDROID_HOME` должен указывать на ваш Android SDK.
Версии соответствуют [CI](.github/workflows/ci.yml).

```bash
sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0" "ndk;30.0.16248370" "cmake;4.1.2"
sdkmanager --licenses
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/30.0.16248370"
export MORNYE_RUST_ANDROID_ABIS=arm64-v8a
fvm flutter build apk --config-only
bash scripts/build_android.sh --lite
```

Gradle соберёт Rust автоматически. APK: `build/app/outputs/flutter-apk/`,
включая `app-arm64-v8a-release.apk`. Для ARM64 и ARMv7 задайте
`MORNYE_RUST_ANDROID_ABIS=arm64-v8a,armeabi-v7a`.
Без `android/key.properties` локальная release-сборка подписывается debug-ключом;
для распространения настройте собственную подпись. Сохраняйте соответствующие
символы из `build/symbols/android/` вместе с APK.

## iOS

Нужны macOS, Xcode с iOS SDK, command-line tools и CocoaPods. Применяйте Xcode,
совместимый с закреплённым Flutter; окружение мобильного CI указано в
[ci.yml](.github/workflows/ci.yml).

```bash
export MORNYE_DISCORD_SDK=0
bash scripts/build_ios.sh
(cd ios && pod install)
fvm flutter build ios --release --no-codesign
```

Результат: `build/ios/iphoneos/Runner.app` без подписи. Для установки на устройство
откройте `ios/Runner.xcworkspace`, настройте Team/Signing для приложения и его
расширений и выполните Archive/Export в Xcode. После смены режима Discord
повторите `pod install` с тем же значением `MORNYE_DISCORD_SDK`.

## Linux

Собирайте на Linux той же архитектуры, что и целевой пакет (x64 или ARM64).
Для Ubuntu 22.04 зависимости совпадают с [desktop CI](.github/workflows/desktop.yml):

```bash
sudo apt-get update
sudo apt-get install -y libunwind-dev clang cmake ninja-build pkg-config zip \
  curl xz-utils libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev \
  libjson-glib-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libasound2-dev libclang-dev libmpv-dev
bash scripts/build_rust_backend.sh desktop
bash scripts/fetch_desktop_ffmpeg.sh
fvm flutter build linux --release --dart-define="GIT_COMMIT=$(git rev-parse --short=8 HEAD)"
```

Результат: `build/linux/x64/release/bundle/` (на ARM64 — `arm64` вместо `x64`).
Передавайте всю папку, включая `lib/` и `data/`; системные библиотеки GTK,
GStreamer, libsecret и libmpv нужны и на целевом компьютере.
Для Linux ARM64 способ установки закреплённого SDK из Git приведён в desktop CI,
если ваша установка FVM не предоставляет SDK для этой архитектуры.

## macOS

Нужны Xcode, command-line tools, CocoaPods, CMake и pkg-config.
Desktop CI использует Xcode **26.1.1**. Сборка Rust и FFmpeg ниже создаёт
универсальные библиотеки для Apple Silicon и Intel.

```bash
bash scripts/build_rust_backend.sh desktop
bash scripts/fetch_desktop_ffmpeg.sh macos-universal
MORNYE_SKIP_RUST_BUILD=1 MORNYE_REQUIRE_FFMPEG=1 \
  fvm flutter build macos --release --dart-define="GIT_COMMIT=$(git rev-parse --short=8 HEAD)"
```

Результат: `build/macos/Build/Products/Release/Mornye.app`.
Для публичного распространения отдельно настройте подпись и notarization Apple.

## Windows

Сборка x64: Windows, Visual Studio с workload **Desktop development with C++**
и Windows SDK, Rust MSVC, PowerShell и Git for Windows (Git Bash в `PATH`).
После общей подготовки выполните в PowerShell:

```powershell
./scripts/build_rust_backend_windows.ps1 -Target x86_64-pc-windows-msvc
bash scripts/fetch_desktop_ffmpeg.sh windows-x64
$commit = git rev-parse --short=8 HEAD
fvm flutter build windows --release --dart-define="GIT_COMMIT=$commit"
./scripts/check_windows_bundle.ps1 -BundleDir build/windows/x64/runner/Release -Arch x64
```

Результат: вся папка `build/windows/x64/runner/Release/`, а не только `.exe`.
Windows пока экспериментален: его CI допускает ошибки. ARM64-сборка на нативном
Windows ARM64 описана в [desktop CI](.github/workflows/desktop.yml), включая
подготовку SDK скриптом `scripts/setup_flutter_windows_arm64.ps1`.

## Проверки и документация

```bash
fvm flutter analyze
fvm flutter test
bash scripts/check_rust_backend.sh
python3 extensions/build_catalog.py --check
```

Аудиотестам нужны `ffmpeg` и `ffprobe` в `PATH`; старые версии FFmpeg могут
не поддерживать используемые фильтры. Не запускайте Flutter-тесты параллельно
с Android-сборкой: они меняют генерируемую конфигурацию.

Подробности: [руководство разработчика](CONTRIBUTING.md),
[Rust backend](rust_backend/README.md), [расширения](extensions/README.md),
[политика подписи Windows](.github/signpath/README.md#code-signing-policy).
Браузерная сборка не предусмотрена: приложение использует нативный Rust backend.

