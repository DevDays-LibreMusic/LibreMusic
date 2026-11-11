# Локальная копия расширений Mornye

Источник: https://github.com/mornyeapp/Mornye-Extension
Ветка: main
Коммит: `12530ceda46dc78a10f9258b7d65a71452dfcf50`
Дата копирования: 2026-11-10

## Содержимое

- `sources/`: исходники всех 14 расширений JavaScript из `registry.json`.
- `tests/`, `scripts/`, `icons/`, `.github/`: оригинальные вспомогательные файлы.
- `package-sources/utilities-python/`: код из `extensions/utilities.sflx`,
  предназначенный только для Mornye-Python.
- `package-sources/spotify-web-legacy/` и `package-sources/ytmusic-spotiflac-legacy/`:
  содержимое двух старых `.spotiflac-ext`, также присутствующих в репозитории.
- `LICENSE`, `COPYING`, `NOTICE`: неизменённые лицензии и авторские уведомления.
- `LOCAL_SOURCE_HASHES.json`: SHA-256 всех скопированных файлов (кроме этого
  описания и самого списка хешей).

Оригинальные файлы сохранены без изменений. Вложенная история `.git` и готовые
архивы не копировались. Все 15 актуальных пакетов перед извлечением проверены
по SHA-256 из оригинальных реестров. Оригинальные файлы сверены побайтово,
распакованные файлы включены в локальный список хешей.

Это копия для изучения и разработки, расширения автоматически не установлены.
Тесты и скрипты upstream не запускались. Для тестов upstream нужен Node.js 22+.
Скрипт upstream по умолчанию создаёт пакеты внутри `extensions/` этой копии;
результаты сборки следует хранить в игнорируемом корневом `build/` LibreMusic.

## Расширения JavaScript

- `amazon`
- `apple-music`
- `beatport`
- `bugs-music`
- `deezer`
- `genie-music`
- `jellyfin`
- `jiosaavn`
- `melon-music`
- `qobuz-web`
- `soundcloud`
- `spotify-web`
- `tidal-web`
- `ytmusic-spotiflac`
