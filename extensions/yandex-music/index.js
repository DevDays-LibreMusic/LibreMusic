// SPDX-License-Identifier: LGPL-3.0-only
// Synchronous Mornye host API; no Node.js or browser runtime dependencies.
(function () {
  "use strict";
  var API = "https://api.music.yandex.net";
  var PROVIDER = "yandex-music";
  var token = "";

  function failure(type, message) {
    var error = new Error(message);
    error.kind = type;
    return error;
  }

  function initialize(settings) {
    token = String((settings || {}).token || "").trim().replace(/^OAuth\s+/i, "");
    if (/[\r\n]/.test(token)) throw failure("auth_required", "Некорректный OAuth-токен");
    return true;
  }

  function request(path, body) {
    if (!token) throw failure("auth_required", "Укажите OAuth-токен в настройках расширения");
    var headers = {Authorization: "OAuth " + token};
    var response;
    if (body === undefined) response = http.get(API + path, headers);
    else {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      response = http.post(API + path, body, headers);
    }
    var status = Number(response.statusCode);
    if (status === 401) throw failure("auth_required", "Яндекс отклонил OAuth-токен");
    if (status === 403) throw failure("subscription_required", "Аккаунту недоступен этот ресурс Яндекс Музыки");
    if (status === 429) throw failure("rate_limited", "Лимит запросов Яндекса. Повторите позднее");
    if (!response.ok) throw failure("network_error", "Ошибка запроса Яндекс Музыки (HTTP " + (status || 0) + ")");
    var data;
    try { data = JSON.parse(response.body); }
    catch (_) { throw failure("invalid_response", "Яндекс вернул некорректный JSON"); }
    if (!data || data.error || data.result === undefined || data.result === null) {
      throw failure("invalid_response", "Яндекс не вернул ожидаемые данные");
    }
    return data.result;
  }

  function numericId(value) {
    var id = String(value || "");
    if (!/^\d+(?::\d+)?$/.test(id)) throw failure("invalid_request", "Некорректный ID трека или альбома");
    return id;
  }

  function names(artists) {
    return (artists || []).map(function (artist) { return artist.name || ""; }).filter(Boolean).join(", ");
  }

  function cover(uri) {
    if (!uri) return "";
    return "https://" + String(uri).replace(/^https?:\/\//, "").replace(/^\/\//, "").replace(/%%/g, "1000x1000");
  }

  function track(raw, album) {
    album = album || (raw.albums || [])[0] || {};
    var position = album.trackPosition || {};
    return {
      id: String(raw.id), provider_id: PROVIDER,
      name: (raw.title || "") + (raw.version ? " (" + raw.version + ")" : ""),
      artists: names(raw.artists), album_name: album.title || "",
      album_artist: names(album.artists), album_id: String(album.id || ""),
      artist_id: String(((raw.artists || [])[0] || {}).id || ""),
      duration_ms: Number(raw.durationMs) || 0,
      cover_url: cover(raw.coverUri || album.coverUri),
      release_date: String(album.releaseDate || album.year || "").slice(0, 10),
      track_number: Number(position.index) || 0, disc_number: Number(position.volume) || 0,
      total_tracks: Number(album.trackCount) || 0,
      genre: album.genre || "", isrc: raw.isrc || "",
      explicit: raw.contentWarning === "explicit",
      external_urls: "https://music.yandex.ru/" + (album.id ? "album/" + album.id + "/" : "") + "track/" + raw.id
    };
  }

  function rawTracks(ids) {
    if (!ids.length) return [];
    var result = request("/tracks", "track-ids=" + encodeURIComponent(ids.map(numericId).join(",")) + "&with-positions=true");
    if (!Array.isArray(result)) throw failure("invalid_response", "Некорректный список треков");
    return result;
  }

  function getTrack(id) {
    id = numericId(id);
    var raw = rawTracks([id]).find(function (item) { return String(item.id) === id.split(":")[0]; });
    if (!raw) throw failure("not_found", "Трек не найден");
    return track(raw);
  }

  function searchTracks(query, limit) {
    query = String(query || "").trim();
    if (!query) return {tracks: [], total: 0};
    limit = Math.max(1, Math.min(100, Number(limit) || 30));
    var result = request("/search?type=track&page=0&text=" + encodeURIComponent(query));
    var section = result.tracks || {};
    return {
      tracks: (section.results || []).slice(0, limit).map(function (raw) { return track(raw); }),
      total: Number(section.total) || 0
    };
  }

  function customSearch(query, options) {
    return searchTracks(query, (options || {}).limit).tracks;
  }

  function getAlbum(id) {
    id = numericId(id);
    var raw = request("/albums/" + encodeURIComponent(id) + "/with-tracks");
    var tracks = [];
    (raw.volumes || []).forEach(function (volume, disc) {
      volume.forEach(function (item, index) {
        var mapped = track(item, raw);
        mapped.disc_number = disc + 1;
        mapped.track_number = index + 1;
        mapped.total_discs = raw.volumes.length;
        tracks.push(mapped);
      });
    });
    return {id: String(raw.id || id), name: raw.title || "", artists: names(raw.artists),
      cover_url: cover(raw.coverUri), release_date: String(raw.releaseDate || raw.year || "").slice(0, 10),
      total_tracks: Number(raw.trackCount) || tracks.length, tracks: tracks, provider_id: PROVIDER};
  }

  function getPlaylist(id) {
    id = String(id || "");
    var match = /^([^/:]+):(\d+)$/.exec(id);
    var path;
    if (match) path = "/users/" + encodeURIComponent(match[1]) + "/playlists/" + match[2];
    else if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) path = "/playlist/" + id;
    else throw failure("invalid_request", "Некорректный ID плейлиста");
    var raw = request(path);
    var entries = raw.tracks || [];
    if (Number(raw.trackCount) > entries.length) {
      throw failure("incomplete_playlist", "Яндекс вернул неполный список треков плейлиста");
    }
    var missing = entries.filter(function (entry) { return !entry.track && entry.id; });
    var hydrated = Object.create(null);
    for (var offset = 0; offset < missing.length; offset += 50) {
      rawTracks(missing.slice(offset, offset + 50).map(function (entry) { return String(entry.id); }))
        .forEach(function (item) { hydrated[String(item.id)] = item; });
    }
    var tracks = entries.map(function (entry) {
      var item = entry.track || hydrated[String(entry.id)];
      if (!item) throw failure("incomplete_playlist", "Не удалось получить один из треков плейлиста");
      return track(item);
    });
    return {id: id, name: raw.title || "", artists: (raw.owner || {}).name || "",
      cover_url: cover((raw.cover || {}).uri), total_tracks: tracks.length,
      tracks: tracks, provider_id: PROVIDER};
  }

  function handleUrl(value) {
    var url;
    try { url = new URL(String(value)); } catch (_) { return null; }
    if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.port ||
        !/^music\.yandex\.(ru|com|by|kz|uz)$/.test(url.hostname)) return null;
    var path = url.pathname.replace(/\/$/, "");
    var match = /^\/(?:album\/\d+\/)?track\/(\d+)$/.exec(path);
    if (match) return {type: "track", track: getTrack(match[1])};
    var collection;
    var type;
    if ((match = /^\/album\/(\d+)$/.exec(path))) {
      collection = getAlbum(match[1]); type = "album";
    } else if ((match = /^\/users\/([^/]+)\/playlists\/(\d+)$/.exec(path))) {
      collection = getPlaylist(decodeURIComponent(match[1]) + ":" + match[2]); type = "playlist";
    } else if ((match = /^\/playlists\/([0-9a-f-]+)$/i.exec(path))) {
      collection = getPlaylist(match[1]); type = "playlist";
    } else return null;
    return {type: type, id: collection.id, name: collection.name, cover_url: collection.cover_url,
      tracks: collection.tracks, album: collection};
  }

  function checkAvailability(isrc, title, artist, options) {
    // Do not interpret another service's numeric ID as a Yandex track ID.
    var original = (options || {}).track || {};
    if (original.provider_id === PROVIDER || original.source === PROVIDER) {
      return {available: true, track_id: numericId(original.id)};
    }
    // Cross-service fallback requires an exact recording identifier.
    if (!isrc) return {available: false, reason: "Для сопоставления с другим сервисом нужен ISRC"};
    var found = searchTracks(String(title || "") + " " + String(artist || ""), 30).tracks.filter(function (item) {
      return item.isrc && item.isrc.toUpperCase() === String(isrc).toUpperCase();
    });
    return found.length ? {available: true, track_id: found[0].id} : {available: false, reason: "Совпадение ISRC не найдено"};
  }

  function cdnUrl(value) {
    var url;
    try { url = new URL(String(value)); } catch (_) { throw failure("invalid_response", "Некорректный адрес аудио"); }
    if (url.protocol !== "https:" || url.username || url.password || url.port ||
        !/^[a-z0-9.-]+\.(?:storage|music|mds)\.yandex\.net$/.test(url.hostname)) {
      throw failure("invalid_response", "Неожиданный адрес сервера аудио");
    }
    return url.href;
  }

  function xmlField(xml, name) {
    var match = new RegExp("<" + name + ">([^<]*)</" + name + ">").exec(xml);
    if (!match) throw failure("invalid_response", "Неполный ответ сервера аудио");
    return match[1].replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
  }

  function download(id, quality, outputPath, progress) {
    try {
      id = numericId(id);
      var bitrate = {"mp3-320": 320, "mp3-128": 128}[quality];
      if (!bitrate) throw failure("unsupported_quality", "Выберите лучшее качество MP3 или MP3 128");
      var metadata = getTrack(id);
      var variants = request("/tracks/" + encodeURIComponent(id) + "/download-info");
      if (!Array.isArray(variants)) throw failure("invalid_response", "Некорректный список форматов");
      var variant = variants.filter(function (item) {
        var availableBitrate = Number(item.bitrateInKbps);
        return item.codec === "mp3" && item.preview === false && availableBitrate > 0 &&
          (quality === "mp3-320" ? availableBitrate <= bitrate : availableBitrate === bitrate);
      }).sort(function (a, b) { return Number(b.bitrateInKbps) - Number(a.bitrateInKbps); })[0];
      if (!variant) throw failure("unavailable", "Полный MP3 выбранного качества недоступен аккаунту");
      // No OAuth header is sent to CDN hosts, including the XML manifest request.
      var response = http.get(cdnUrl(variant.downloadInfoUrl), {});
      if (!response.ok) throw failure("network_error", "Не удалось получить адрес аудиофайла");
      var host = xmlField(response.body, "host");
      var path = xmlField(response.body, "path");
      var timestamp = xmlField(response.body, "ts");
      var salt = xmlField(response.body, "s");
      // Yandex's ts is a hexadecimal string. Preserve it verbatim in the URL.
      if (!/^[a-z0-9.-]+$/.test(host) || !/^[0-9a-fA-F]+$/.test(timestamp) || !/^\/[a-zA-Z0-9/_.%-]+$/.test(path)) {
        throw failure("invalid_response", "Некорректный ответ сервера аудио");
      }
      var signature = utils.md5("XGRlBW9FXlekgbPrRHuSiA" + path.slice(1) + salt);
      var stream = cdnUrl("https://" + host + "/get-mp3/" + signature + "/" + timestamp + path);
      var result = file.download(stream, outputPath, {});
      if (!result.success) throw failure("download_failed", "Не удалось сохранить аудиофайл");
      if (typeof progress === "function") progress(100);
      return {success: true, file_path: outputPath, actual_extension: "mp3", actual_container: "mp3",
        audio_codec: "mp3", title: metadata.name, artist: metadata.artists, album: metadata.album_name,
        album_artist: metadata.album_artist, duration_ms: metadata.duration_ms, isrc: metadata.isrc,
        cover_url: metadata.cover_url, track_number: metadata.track_number, disc_number: metadata.disc_number,
        release_date: metadata.release_date, genre: metadata.genre, explicit: metadata.explicit};
    } catch (error) {
      return {success: false, error_type: error.kind || "provider_error",
        error_message: error.kind ? error.message : "Ошибка расширения Яндекс Музыки"};
    }
  }

  registerExtension({initialize: initialize, cleanup: function () { token = ""; },
    searchTracks: searchTracks, customSearch: customSearch, getTrack: getTrack,
    getAlbum: getAlbum, getPlaylist: getPlaylist, handleUrl: handleUrl,
    checkAvailability: checkAvailability, download: download});
}());
