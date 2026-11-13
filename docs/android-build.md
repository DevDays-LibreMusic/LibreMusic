# Self-contained Android: подготовка и проверка

Все команды выполняются из корня репозитория. Общая подготовка FVM, Rust,
Android SDK и описание release-сборки находятся в [README](../README.md#android).
Закреплены Flutter 3.47.8, Rust 1.99.1, Temurin 25.0.5, Android API 37,
Build Tools 37.0.0, NDK 30.0.16248370 и Android CMake 4.1.2.
Используйте свои `JAVA_HOME` и `ANDROID_HOME`, не пути другого разработчика.
Для анализа нужны `ffmpeg` и `ffprobe` в `PATH`.

## Подготовка моделей разработчиком

Этот шаг нужен сборщику APK. Пользователь приложения не импортирует модели:
оба экспорта попадают в APK, а приложение подготавливает их автоматически при
первом сравнении. Обычный запуск и волна не запускают этот анализ.

[Манифест пинов](../scripts/audio_version_model_pins.json) задаёт точные размеры
и SHA-256 двух файлов:

```text
wavlm/wavlm-layer6-fp32.onnx
demucs/htdemucs-trunk-fp32.onnx
```

Не добавляйте веса или staged-ссылки в Git. Сохраните проверенные экспорты вне
репозитория и укажите общий корень:

```bash
export LIBREMUSIC_MODEL_ROOT="$HOME/.cache/libremusic/mobile-models"
python3 scripts/bootstrap_audio_version_models.py \
  --model-root "$LIBREMUSIC_MODEL_ROOT" --require-existing
```

Команда проверяет файлы и создаёт ссылки в игнорируемом
`android/app/.bundled-model-assets/`, без второй копии весов. Исходные файлы
должны оставаться доступны и неизменны до конца сборки.

Если экспортов ещё нет, bootstrap без `--require-existing` скачивает официальные
входы Hugging Face, проверяет закреплённые ревизии и хеши, затем запускает
экспорт. Используйте отдельное окружение **Python 3.12**, `ffmpeg` и зависимости
из [requirements.txt](../scripts/mobile_model_export/requirements.txt):

```bash
python3.12 -m venv "$HOME/.cache/libremusic/model-export-venv"
"$HOME/.cache/libremusic/model-export-venv/bin/python" -m pip install -r scripts/mobile_model_export/requirements.txt
"$HOME/.cache/libremusic/model-export-venv/bin/python" scripts/bootstrap_audio_version_models.py \
  --model-root "$LIBREMUSIC_MODEL_ROOT"
```

Точное восстановление этих пинов проверено локально на macOS ARM64.
На Linux экспорт HTDemucs в CI пока даёт несовпадение ожидаемого SHA-256;
путь восстановления с нуля на Linux **не подтверждён**. Не меняйте пины ради
прохождения проверки. Проверка уже готовых точных экспортов через
`--require-existing` не запускает скачивание или PyTorch.
Частичный или повреждённый cache завершается ошибкой, а не подменяет модель.

[Протокол экспорта](../scripts/mobile_model_export/README.md) и
[CI action](../.github/actions/audio-version-models/action.yml) содержат
закреплённые входы и окружение. Наличие action не означает, что весь CI зелёный.

## ARM64 Lite debug APK

Сначала закоммитьте исходники: helper запрещает доставку из грязного дерева.
После общей подготовки toolchain запустите:

```bash
export MORNYE_RUST_ANDROID_ABIS=arm64-v8a
python3 scripts/deliver_android_debug.py \
  --model-root "$LIBREMUSIC_MODEL_ROOT" \
  --check-area build
```

Helper сам проверяет и stage-ит модели, проверяет закреплённый Flutter и патч SDK,
восстанавливает зависимости, последовательно выполняет выбранные проверки,
обновляет конфигурацию и собирает ARM64 Lite debug APK. Lite отключает мобильный
Discord status и не требует закрытого Discord SDK. Пакет debug-варианта —
`com.zarz.mornye.debug`; APK и JSON-манифест сохраняются в `~/Downloads`
(можно задать `--output-dir`). Для обновления существующей установки добавьте
`--expected-certificate` с SHA-256 её сертификата.

Выбирайте дополнительные области проверок по изменению:
`python3 scripts/check_local_changes.py --list build` показывает команды без
их запуска. Не запускайте Flutter-тесты одновременно с Android-сборкой.

## Проверка содержимого и подписи

Для любого доставляемого APK выполните, подставив его путь:

```bash
python3 scripts/audit_audio_version_models.py /path/to/app.apk
"$ANDROID_HOME/build-tools/37.0.0/apksigner" verify --verbose --print-certs /path/to/app.apk
shasum -a 256 /path/to/app.apk
```

Аудит читает реальные ZIP-потоки и требует ровно обе закреплённые модели,
проверяет размер и SHA-256 и отклоняет посторонние ONNX/tensor payloads.
Release-скрипт дополнительно проверяет нативный backend и ABI; debug helper
записывает эти проверки, подпись, commit и APK hash в манифест доставки.
Для release требуйте APK Signature Scheme v2. Без `android/key.properties`
локальный release подписывается debug-ключом; для распространения настройте
собственную подпись. Не используйте чужой приватный ключ.

Храните APK вместе с его манифестом. Эти проверки подтверждают состав сборки,
но воспроизведение, доступность сервисов, память и скорость сравнения необходимо
отдельно проверять на целевом телефоне.
