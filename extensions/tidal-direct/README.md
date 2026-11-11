# Tidal Direct 0.1.0

Поиск, треки, альбомы, плейлисты через `api.tidal.com/v1`, аудио через
`tracks/{id}/playbackinfopostpaywall` и CDN, без Zarz и зеркал.

Импорт: `build/tidal-direct-0.1.0.sflx`. Укажите access token своего аккаунта
и двухбуквенный код страны аккаунта. Нужен пользовательский токен с доступом
к playback API; обычный client-credentials токен для публичного каталога
может не подойти. Получение OAuth-токена и обновление по refresh token
в расширении не реализованы. Истёкший токен меняется вручную.

Поддерживается **только незашифрованный BTS-манифест** с прямой ссылкой на
полное аудио: HIGH/AAC и LOSSLESS/FLAC. DASH/MPD, зашифрованные потоки,
Hi-Res и Atmos пока не поддерживаются. Если аккаунту выдаётся только такой
поток, скачивание завершится понятной ошибкой. Превью и автоматического
понижения качества нет. Длительность и кодек проверяются по файлу.

Ссылки: tidal.com/browse/track|album|playlist/ID и listen.tidal.com.
Поиск до 100 записей, коллекции до 2000; видеоплейлисты не поддерживаются.
Bearer token отправляется только API, не CDN.

Источники протокола:
https://github.com/tamland/python-tidal/blob/master/tidalapi/media.py
https://developer.tidal.com/documentation/api-sdk/api-sdk-authorization

Экспериментальная версия: проверены офлайн-контракты. Реальное скачивание
и совместимость конкретного токена с playback API не проверены.
