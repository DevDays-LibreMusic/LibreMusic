// SPDX-License-Identifier: LGPL-3.0-only
// API protocol researched using MuXolotl/MusiMuX documentation.
(function () {
  "use strict";
  var C = LibreMusic;
  var ID = "vk-music";
  var token = "", device = "", userAgent = "";
  var MEDIA = ["*.vkuseraudio.net", "*.vkuseraudio.com", "*.useraudio.com", "*.userapi.com", "*.vk-cdn.net", "*.vkcdn.ru"];
  var LINKS = ["vk.com", "vk.ru", "m.vk.com", "m.vk.ru", "music.vk.com", "music.vk.ru"];
  function initialize(settings) {
    settings = settings || {};
    token = C.secret(settings.token);
    device = C.secret(settings.deviceId);
    userAgent = C.secret(settings.userAgent || "VKAndroidApp/8.154 (Android 13; SDK 33; arm64-v8a; Google Pixel 7; ru; 1080x2400)");
    return true;
  }
  function api(method, parameters) {
    if (!token || !device) C.fail("auth_required", "Укажите музыкальный токен VK и device_id его сессии");
    var form = Object.assign({}, parameters, {access_token: token, device_id: device, v: "8.154", lang: "ru"});
    var data = C.json(http.post("https://api.vk.ru/method/" + method, C.form(form), {
      "Content-Type": "application/x-www-form-urlencoded", "User-Agent": userAgent,
      "X-VK-Android-Client": "new", Origin: "https://id.vk.ru", Referer: "https://id.vk.ru"
    }));
    if (!data || data.error) {
      var code = Number(((data || {}).error || {}).error_code) || 0;
      if ([5, 1114, 1117].indexOf(code) >= 0) C.fail("auth_required", "Сессия VK недействительна или истекла");
      if (code === 6 || code === 29) C.fail("rate_limited", "VK ограничил запросы. Повторите позднее");
      if (code === 14 || code === 17) C.fail("verification_required", "Подтвердите вход в официальном клиенте VK");
      C.fail("api_error", "Ошибка музыкального API VK (код " + code + ")");
    }
    if (data.response === undefined || data.response === null) C.fail("invalid_response", "VK не вернул данные");
    return data.response;
  }
  function identifier(value) {
    var match = /^(-?\d+)_(-?\d+)(?:_([a-zA-Z0-9-]+))?$/.exec(String(value || ""));
    if (!match) C.fail("invalid_request", "Нужен ID VK вида owner_id_audio_id");
    return {owner: match[1], id: match[2], key: match[3] || "", full: match[0]};
  }
  function identity(raw) {
    return String(raw.owner_id) + "_" + String(raw.id) + (raw.access_key ? "_" + raw.access_key : "");
  }
  function image(raw) {
    raw = raw || {};
    return raw.photo_1200 || raw.photo_600 || raw.photo_300 || raw.photo_270 || raw.photo_135 || raw.photo_68 || "";
  }
  function map(raw) {
    var album = raw.album || {};
    var albumId = album.id !== undefined && album.owner_id !== undefined ? identity(album) : "";
    return {id: identity(raw), provider_id: ID, name: (raw.title || "") + (raw.subtitle ? " (" + raw.subtitle + ")" : ""),
      artists: raw.artist || "", album_name: album.title || "", album_id: albumId,
      duration_ms: (Number(raw.duration) || 0) * 1000, explicit: !!raw.is_explicit,
      cover_url: image(raw.thumb || album.thumb),
      external_urls: "https://vk.com/audio" + raw.owner_id + "_" + raw.id};
  }
  function rawTrack(id) {
    var wanted = identifier(id);
    var rows = api("audio.getById", {audios: wanted.full});
    if (!Array.isArray(rows)) C.fail("invalid_response", "Некорректный ответ VK о треке");
    var raw = rows.find(function (r) { return String(r.owner_id) === wanted.owner && String(r.id) === wanted.id; });
    if (!raw) C.fail("not_found", "Трек не найден в VK");
    if (!raw.access_key && wanted.key) raw.access_key = wanted.key;
    return raw;
  }
  function getTrack(id) { return map(rawTrack(id)); }
  function searchTracks(query, limit) {
    query = String(query || "").trim();
    if (!query) return {tracks: [], total: 0};
    var data = api("audio.search", {q: query, count: Math.max(1, Math.min(100, Number(limit) || 30)), offset: 0, extended: 1, sort: 0});
    if (!Array.isArray(data.items)) C.fail("invalid_response", "VK не вернул результаты поиска");
    return {tracks: data.items.map(map), total: Number(data.count) || data.items.length};
  }
  function getPlaylist(id) {
    var parsed = identifier(id);
    var parameters = {owner_id: parsed.owner, playlist_id: parsed.id, extended: 1};
    if (parsed.key) parameters.access_key = parsed.key;
    var playlist = api("audio.getPlaylistById", parameters);
    var tracks = [], expected = null;
    while (tracks.length < 2000) {
      var data = api("audio.get", Object.assign({}, parameters, {count: 200, offset: tracks.length}));
      if (!Array.isArray(data.items) || !Number.isInteger(Number(data.count)) || Number(data.count) < 0) C.fail("invalid_response", "Некорректная страница плейлиста VK");
      if (expected === null) expected = Number(data.count);
      if (expected > 2000) C.fail("playlist_too_large", "Плейлист содержит больше 2000 треков");
      if (Number(data.count) !== expected) C.fail("incomplete_playlist", "Плейлист изменился во время загрузки");
      tracks = tracks.concat(data.items.map(map));
      if (tracks.length === expected) break;
      if (!data.items.length || tracks.length > expected) C.fail("incomplete_playlist", "VK вернул неполный плейлист");
    }
    return {id: parsed.full, provider_id: ID, name: playlist.title || "", tracks: tracks, total_tracks: tracks.length,
      cover_url: image(playlist.photo || (playlist.thumbs || [])[0])};
  }
  function handleUrl(value) {
    var url = C.link(value, LINKS);
    if (!url) return null;
    var path = url.pathname;
    // Web links may embed the canonical audio/playlist path in z=.
    var embedded = url.searchParams.get("z");
    if (embedded && /^(audio|audio_playlist|playlist)/.test(embedded)) path = "/" + embedded.split("/")[0];
    var match = /^\/(?:music\/)?audio(-?\d+_\d+(?:_[a-zA-Z0-9-]+)?)\/?$/.exec(path);
    if (match) return {type: "track", track: getTrack(match[1])};
    match = /^\/(?:music\/)?(?:album|playlist|audio_playlist)\/?(-?\d+_-?\d+(?:_[a-zA-Z0-9-]+)?)\/?$/.exec(path);
    if (!match) return null;
    return C.collection(path.indexOf("album") >= 0 ? "album" : "playlist", getPlaylist(match[1]));
  }
  function download(id, quality, output, progress) {
    try {
      if (quality !== "original") C.fail("unsupported_quality", "Выберите исходное качество VK");
      var raw = rawTrack(id);
      if (raw.content_restricted || raw.is_preview || raw.preview || !raw.url) C.fail("unavailable", "Полное аудио недоступно этой сессии VK");
      var metadata = map(raw);
      var stream = C.url(raw.url, MEDIA);
      var destination, ext;
      if (/\.m3u8$/i.test(stream.pathname)) {
        destination = LibreMusicHls.download(stream.href, output, MEDIA, metadata.duration_ms, progress);
        ext = "m4a";
      } else {
        if (!/\.mp3$/i.test(stream.pathname)) C.fail("unsupported_stream", "VK вернул неизвестный формат аудио");
        destination = output;
        ext = "mp3";
        C.saved(file.download(stream.href, destination, {}));
      }
      if (typeof progress === "function") progress(100);
      return C.result(metadata, destination, ext, ext === "mp3" ? "mp3" : "");
    } catch (error) { return C.downloadError(error); }
  }
  registerExtension({initialize: initialize, cleanup: function () { token = ""; device = ""; },
    searchTracks: searchTracks, customSearch: function (q, o) { return searchTracks(q, (o || {}).limit).tracks; },
    getTrack: getTrack, getPlaylist: getPlaylist, getAlbum: getPlaylist, handleUrl: handleUrl,
    checkAvailability: function (isrc, title, artist, options) {
      var t = C.own(ID, options);
      return t ? {available: true, track_id: identifier(t.id).full} : C.unavailable();
    }, download: download});
}());
