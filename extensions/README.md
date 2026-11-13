# Расширения музыкальных сервисов

Отдельные пакеты `zvuk`, `vk-music`, `kion-music` для Mornye/LibreMusic.
Версия 0.1.0 экспериментальная: контракты проверяются офлайн, загрузки с
реальными аккаунтами этих трёх сервисов ещё не проверены. API неофициальные.

## Сборка и установка

```sh
node extensions/tests/run.cjs
node extensions/kion-music/test.cjs
python3 extensions/build.py
python3 extensions/build.py --check
```

Архивы появятся в `.tmp/extensions/`. Каждый содержит собственный `index.js`,
manifest, README и лицензии. Установите нужный `.sflx` через импорт локального
файла в разделе расширений приложения. Затем откройте настройки расширения,
заполните его учётные данные и включите расширение. Ищите треки через поиск
расширения или вставляйте ссылку на поддерживаемый сервис.

У каждого пакета своё имя и настройки. Обновление пакета с тем же именем
заменяет его предыдущую версию. Яндекс Музыка собирается своим прежним
скриптом `extensions/yandex-music/build.py`.

## Выполнение

JavaScript выполняется синхронно внутри Rust/QuickJS приложения. HTTP, файлы,
криптография и FFmpeg доступны через функции хоста. Node.js нужен только для
тестов, Python только для упаковки. Внешнего сервера или процесса расширения
нет. Flutter и Rust изменять для установки этих пакетов не требуется.

`shared/` включается в пакет при сборке и не требует отдельной установки.
КИОН использует самостоятельный адаптер совместимого API, основанный на
локальном расширении Яндекс Музыки. При изменении общего протокола следует
проверять обе реализации и оба набора регрессионных тестов.

## Ограничения

Токены вводятся в секретные настройки приложения, не в исходники или чат.
Доступ к полному треку определяется аккаунтом, подпиской и регионом.
Расширения не заменяют вход в сервис. Нет автоматического получения токенов,
фонового обновления сессий, рекомендаций, подкастов или синхронизации медиатеки.
Поиск возвращает первую страницу (до 100 записей). Звук и VK принимают
плейлисты до 2000 треков и явно сообщают о неполной выдаче.

Для проверки с аккаунтом: найти трек, импортировать его ссылку, альбом и
плейлист, скачать полный трек, проверить длительность и воспроизведение.
Проверить отмену загрузки и истёкший токен. Для VK отдельно проверить MP3,
HLS и наличие рабочего FFmpeg в сборке приложения. Офлайн-тесты этих проверок
на устройстве не заменяют.

Источники протоколов, закреплённые ревизии и MIT-уведомления находятся
в `THIRD_PARTY_NOTICES.txt` каждого расширения. Наш код: LGPL-3.0-only,
лицензии приложения включены в каждый пакет.

## Deezer Direct

`deezer-direct` работает через ARL собственного аккаунта Deezer, без внешнего
resolver. Это отдельный экспериментальный пакет, не замена сохранённого
upstream-расширения. Настройка, ограничения и порядок проверки описаны
в [deezer-direct/README.md](deezer-direct/README.md).

```sh
node extensions/deezer-direct/test.cjs
python3 extensions/build.py deezer-direct --output-dir build
python3 extensions/build.py deezer-direct --output-dir build --check
```

Общий скрипт `extensions/build.py` собирает девять пакетов по умолчанию.

## Остальные Direct-расширения

Все пять пакетов версии 0.1.0 не используют Zarz. Это экспериментальные
реализации; авторизация и загрузки с реальными аккаунтами не проверены.

| Пакет | Возможности и ограничения |
| --- | --- |
| [amazon-direct](amazon-direct/README.md) | Только каталог. Скачивание DRM-аудио не реализовано, нужен CDM вне текущего JS API. |
| [ytmusic-direct](ytmusic-direct/README.md) | Прямой InnerTube, Opus/AAC. Нет Cobalt, yt1d или внешнего PO Token сервера. |
| [qobuz-direct](qobuz-direct/README.md) | Свои user_auth_token, appId, appSecret; MP3/FLAC через API Qobuz. |
| [tidal-direct](tidal-direct/README.md) | Свой access token; AAC/FLAC в незашифрованном BTS. DASH/DRM не поддерживаются. |
| [beatport-direct](beatport-direct/README.md) | Свой access token с правами download; AAC/FLAC через API Beatport. |

```sh
node extensions/tests/direct-providers.cjs
node extensions/tests/direct-upstream-regression.cjs
python3 extensions/build.py amazon-direct ytmusic-direct qobuz-direct tidal-direct beatport-direct --output-dir build
python3 extensions/build.py amazon-direct ytmusic-direct qobuz-direct tidal-direct beatport-direct --output-dir build --check
```

`direct-upstream-regression.cjs` запускает неизменённые синхронные upstream-тесты
каталога на direct-форках через адаптер для Node 12+. Сохранённые исходники
в `upstream-mornye/` не меняются. Полного функционального равенства с upstream
по скачиванию нет: ограничения перечислены выше и в README пакетов.

Чтобы весь маршрут скачивания обходился без Zarz, установите Direct-пакеты
и отключите исходные расширения с Zarz в приоритетах загрузки и резервных
провайдерах. Одновременная установка сама по себе не отключает старые пакеты.

## Подключаемый каталог LibreMusic

Готовая папка [catalog/](catalog/README.md) содержит десять собственных
расширений, установочные `.sflx` и `registry.json` для подключения по HTTPS.
Сборка и проверка: `python3 extensions/build_catalog.py` и
`python3 extensions/build_catalog.py --check`. Инструкция подключения и
условие публикации адреса находятся в README каталога.
