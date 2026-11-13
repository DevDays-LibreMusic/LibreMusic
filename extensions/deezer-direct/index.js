// SPDX-License-Identifier: LGPL-3.0-only
// Independent direct Deezer adapter. Patterned decryption adapted from
// mornyeapp/Mornye-Extension, Copyright 2026 zarzet (see THIRD_PARTY_NOTICES.txt).
(function () {
  "use strict";
  var C = LibreMusic, ID = "deezer-direct";
  var API = "https://api.deezer.com";
  var GATEWAY = "https://www.deezer.com/ajax/gw-light.php";
  var MEDIA = "https://media.deezer.com/v1/get_url";
  var arl = "";
  var agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
  function clearCookies() { if (typeof http.clearCookies === "function") http.clearCookies(); }
  function initialize(settings) {
    arl = "";
    clearCookies();
    var value = C.secret((settings || {}).arl);
    if (value && !/^[a-f0-9]{192}$/i.test(value)) C.fail("auth_required", "Введите только значение cookie arl (192 шестнадцатеричных символа)");
    arl = value;
    return true;
  }
  function api(path) {
    var address = C.url(API + path, ["api.deezer.com"]);
    var value = C.json(http.get(address.href, {}));
    if (!value || value.error) C.fail("api_error", "Deezer не вернул данные каталога");
    return value;
  }
  function explicitFlag(raw) {
    if (raw.explicit_lyrics === true || raw.explicit_content_lyrics === 1) return true;
    if (raw.explicit_content_lyrics === 0 ||
        (raw.explicit_lyrics === false && raw.explicit_content_lyrics == null)) return false;
    return null;
  }
  function map(raw, album) {
    album = album || raw.album || {};
    var artists = (raw.contributors || []).map(function (a) { return a.name; }).filter(Boolean);
    return {id: C.numeric(raw.id), provider_id: ID, name: raw.title || "",
      artists: artists.length ? artists.join(", ") : (raw.artist || {}).name || "",
      album_name: album.title || "", album_id: String(album.id || ""),
      album_artist: (album.artist || {}).name || "", artist_id: String((raw.artist || {}).id || ""),
      duration_ms: (Number(raw.duration) || 0) * 1000, isrc: raw.isrc || "",
      cover_url: album.cover_xl || album.cover_big || album.cover_medium || "",
      track_number: Number(raw.track_position) || 0, disc_number: Number(raw.disk_number) || 0,
      total_tracks: Number(album.nb_tracks) || 0, release_date: raw.release_date || album.release_date || "",
      explicit: explicitFlag(raw), external_urls: "https://www.deezer.com/track/" + raw.id};
  }
  function getTrack(id) {
    id = C.numeric(id);
    var raw = api("/track/" + id);
    if (String(raw.id) !== id) C.fail("not_found", "Deezer вернул другой трек");
    return map(raw);
  }
  function searchTracks(query, limit) {
    query = String(query || "").trim();
    if (!query) return {tracks: [], total: 0};
    var count = Math.max(1, Math.min(100, Math.floor(Number(limit) || 30)));
    var response = api("/search/track?q=" + encodeURIComponent(query) + "&limit=" + count);
    if (!Array.isArray(response.data)) C.fail("invalid_response", "Некорректный ответ поиска Deezer");
    return {tracks: response.data.slice(0, count).map(function (t) { return map(t); }), total: Number(response.total) || 0};
  }
  function collection(kind, id) {
    id = C.numeric(id);
    var raw = api("/" + kind + "/" + id);
    if (String(raw.id) !== id) C.fail("not_found", "Коллекция Deezer не найдена");
    var page = raw.tracks, rows = [], visited = Object.create(null);
    var expected = Number(kind === "album" ? raw.nb_tracks : raw.nb_tracks !== undefined ? raw.nb_tracks : (page || {}).total);
    if (!Number.isInteger(expected) || expected < 0 || expected > 2000) C.fail("playlist_too_large", "Нужна коллекция до 2000 треков с известным размером");
    while (page) {
      if (!Array.isArray(page.data)) C.fail("invalid_response", "Deezer не вернул список треков");
      rows = rows.concat(page.data);
      if (rows.length > 2000) C.fail("playlist_too_large", "Коллекция содержит больше 2000 треков");
      if (!page.next) break;
      var next = C.url(page.next, ["api.deezer.com"]);
      if (next.pathname !== "/" + kind + "/" + id + "/tracks" || visited[next.href] || !page.data.length) C.fail("incomplete_playlist", "Некорректная пагинация Deezer");
      visited[next.href] = true;
      page = api(next.pathname + next.search);
    }
    if (rows.length !== expected) C.fail("incomplete_playlist", "Deezer вернул неполную коллекцию");
    return {id: id, provider_id: ID, name: raw.title || "", cover_url: raw.cover_xl || raw.picture_xl || "",
      total_tracks: rows.length, tracks: rows.map(function (t) { return map(t, kind === "album" ? raw : null); })};
  }
  function handleUrl(value) {
    var url = C.link(value, ["www.deezer.com", "deezer.com"]);
    if (!url) return null;
    var match = /^\/(?:[a-z]{2}\/)?(track|album|playlist)\/(\d+)\/?$/.exec(url.pathname);
    if (!match) return null;
    if (match[1] === "track") return {type: "track", track: getTrack(match[2])};
    return C.collection(match[1], collection(match[1], match[2]));
  }
  function gateway(method, csrf, payload) {
    var response = C.json(http.post(GATEWAY + "?method=" + method + "&input=3&api_version=1.0&api_token=" + encodeURIComponent(csrf || "null"), JSON.stringify(payload), {
      Cookie: "arl=" + arl, "Content-Type": "application/json", "User-Agent": agent,
      Origin: "https://www.deezer.com", Referer: "https://www.deezer.com/"
    }));
    var error = response && response.error;
    if (!response || (error && (typeof error !== "object" || Object.keys(error).length)) || !response.results) {
      C.fail("auth_required", "Deezer отклонил запрос сессии; обновите ARL или повторите позднее");
    }
    return response.results;
  }
  function descriptor(id, format) {
    if (!arl) C.fail("auth_required", "Укажите ARL своего аккаунта Deezer в настройках расширения");
    var license, song;
    // Refresh the session and track token for every download. Never cache account data.
    clearCookies();
    try {
      var user = gateway("deezer.getUserData", "", {});
      var account = user.USER || {}, options = account.OPTIONS || {};
      if (!(Number(account.USER_ID) > 0) || !user.checkForm) C.fail("auth_required", "ARL недействителен или сессия Deezer истекла");
      license = options.license_token;
      if (!license) C.fail("subscription_required", "Аккаунт не получил лицензию на полное аудио");
      song = gateway("song.getData", user.checkForm, {sng_id: id});
      if (String(song.SNG_ID) !== id) C.fail("unavailable", "Deezer вернул другую запись трека");
      if (!song.TRACK_TOKEN) C.fail("unavailable", "Deezer не выдал токен полного трека");
    } finally {
      // Do not forward session cookies to the media API or retain them between accounts.
      clearCookies();
    }
    var response = C.json(http.post(MEDIA, JSON.stringify({license_token: license,
      media: [{type: "FULL", formats: [{cipher: "BF_CBC_STRIPE", format: format}]}],
      track_tokens: [song.TRACK_TOKEN]}), {"Content-Type": "application/json", "User-Agent": agent,
      Origin: "https://www.deezer.com", Referer: "https://www.deezer.com/"}));
    var row = response && Array.isArray(response.data) && response.data[0];
    if (!row || (row.errors && row.errors.length) || !Array.isArray(row.media)) C.fail("unavailable", "Полный трек выбранного качества недоступен аккаунту");
    var selected = row.media.find(function (m) { return m.media_type === "FULL" && m.format === format; });
    if (!selected || !selected.cipher || selected.cipher.type !== "BF_CBC_STRIPE" || !Array.isArray(selected.sources)) C.fail("unsupported_stream", "Deezer не вернул ожидаемый полный формат аудио");
    var address = null;
    selected.sources.some(function (s) {
      try { address = C.url(s.url, ["*.dzcdn.net"]).href; return true; } catch (_) { return false; }
    });
    if (!address) C.fail("invalid_response", "Deezer не вернул допустимый адрес CDN");
    return {url: address, song: song};
  }
  function key(id) {
    var hash = utils.md5(id), secret = "g4el58wc0zvf9na1", result = "";
    for (var i = 0; i < 16; i++) result += (hash.charCodeAt(i) ^ hash.charCodeAt(i + 16) ^ secret.charCodeAt(i)).toString(16).padStart(2, "0");
    return result;
  }
  function download(id, quality, output, progress) {
    var temp = output + ".deezer-encrypted", destination = "", started = false, complete = false;
    try {
      id = C.numeric(id);
      var format = {"mp3-128": "MP3_128", "mp3-320": "MP3_320", flac: "FLAC"}[quality];
      if (!format) C.fail("unsupported_quality", "Выберите MP3 128, MP3 320 или FLAC");
      if (!arl) C.fail("auth_required", "Укажите ARL своего аккаунта Deezer");
      var track = getTrack(id);
      var stream = descriptor(id, format);
      var ext = format === "FLAC" ? "flac" : "mp3";
      destination = output.endsWith("." + ext) ? output : output + "." + ext;
      started = true;
      C.saved(file.download(stream.url, temp, {}));
      C.saved(file.transformPatternedBlocks(temp, destination, {operation: "decrypt", algorithm: "blowfish",
        mode: "cbc", key: key(id), keyEncoding: "hex", iv: "0001020304050607", ivEncoding: "hex",
        padding: "none", segmentSize: 2048, transformEvery: 3, transformOffset: 0,
        bufferSize: 1048576, transformPartial: false}, function (processed, total) {
        if (typeof progress === "function" && total > 0) progress(Math.floor(processed * 95 / total));
      }));
      // Inspect the saved file, not the requested quality label.
      var measured = ffmpeg.getInfo(destination);
      if (!measured || !measured.success || String(measured.codec).toLowerCase() !== ext) C.fail("invalid_audio", "Скачанный файл не соответствует выбранному формату аудио");
      var duration = Number(measured.duration);
      if (duration > 0 && track.duration_ms > 0 && Math.abs(duration * 1000 - track.duration_ms) > 10000) C.fail("invalid_audio", "Длительность файла не совпадает с треком");
      var result = C.result(track, destination, ext, ext);
      result.isrc = track.isrc;
      result.actual_container = ext;
      if (ext === "flac") { result.bit_depth = Number(measured.bit_depth) || 0; result.sample_rate = Number(measured.sample_rate) || 0; }
      complete = true;
      if (typeof progress === "function") progress(100);
      return result;
    } catch (error) { return C.downloadError(error); }
    finally {
      if (started) {
        try { file.delete(temp); } catch (_) {}
        if (!complete && destination) { try { file.delete(destination); } catch (_) {} }
      }
    }
  }
  registerExtension({initialize: initialize, cleanup: function () { arl = ""; clearCookies(); },
    searchTracks: searchTracks, customSearch: function (q, o) { return searchTracks(q, (o || {}).limit).tracks; },
    getTrack: getTrack, getAlbum: function (id) { return collection("album", id); },
    getPlaylist: function (id) { return collection("playlist", id); }, handleUrl: handleUrl,
    checkAvailability: function (isrc, title, artist, options) {
      var original = C.own(ID, options);
      return original ? {available: true, track_id: C.numeric(original.id)} : C.unavailable();
    }, download: download});
}());
