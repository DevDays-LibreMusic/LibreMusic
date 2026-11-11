// SPDX-License-Identifier: LGPL-3.0-only
(function () {
  "use strict";
  var C = LibreMusic, D = DirectMusic, ID = "tidal-direct", token = "", country = "US";
  function api(path, params) {
    params = Object.assign({}, params || {}, {countryCode: country});
    return D.json("https://api.tidal.com/v1/" + path + "?" + C.form(params), {Authorization: "Bearer " + D.required(token)});
  }
  function cover(value) { return value ? "https://resources.tidal.com/images/" + String(value).replace(/-/g, "/") + "/1280x1280.jpg" : ""; }
  function map(t, album) {
    album = album || t.album || {};
    return {id: D.id(t.id), provider_id: ID, name: (t.title || "") + (t.version ? " (" + t.version + ")" : ""),
      artists: (t.artists || (t.artist ? [t.artist] : [])).map(function (a) { return a.name; }).join(", "),
      album_id: String(album.id || ""), album_name: album.title || "", duration_ms: (Number(t.duration) || 0) * 1000,
      cover_url: cover(album.cover), isrc: t.isrc || "", explicit: !!t.explicit, track_number: t.trackNumber || 0,
      disc_number: t.volumeNumber || 0, release_date: album.releaseDate || "", external_urls: "https://tidal.com/browse/track/" + t.id};
  }
  function getTrack(id) { id = D.id(id); var t = api("tracks/" + id); if (String(t.id) !== id) C.fail("not_found", "Трек не найден"); return map(t); }
  function collection(type, value) {
    var id = D.id(value, type === "playlists" ? /^[0-9a-fA-F-]{36}$/ : /^\d+$/);
    var root = api(type + "/" + id), rows = [], total = D.size(root.numberOfTracks);
    do {
      var page = api(type + "/" + id + (type === "albums" ? "/tracks" : "/items"), {offset: rows.length, limit: 100});
      if (D.size(page.totalNumberOfItems) !== total) C.fail("incomplete_playlist", "Размер коллекции изменился");
      var items = D.page(page.items, total, rows.length);
      rows = rows.concat(items.map(function (item) {
        if (type === "playlists") { if (item.type !== "track") C.fail("unsupported_collection", "Плейлист содержит видео"); item = item.item; }
        return map(item, type === "albums" ? root : null);
      }));
    } while (rows.length < total);
    return {id: id, provider_id: ID, name: root.title || "", cover_url: cover(root.cover || root.squareImage), tracks: rows, total_tracks: total};
  }
  function download(value, quality, output, progress) {
    var id = D.id(value), level = {aac: "HIGH", flac: "LOSSLESS"}[quality];
    if (!level) C.fail("unsupported_quality", "Выберите AAC или FLAC");
    var track = getTrack(id), response = api("tracks/" + id + "/playbackinfopostpaywall", {audioquality: level, playbackmode: "STREAM", assetpresentation: "FULL"});
    if (String(response.trackId) !== id || (response.assetPresentation !== undefined && response.assetPresentation !== "FULL") || response.audioQuality !== level) C.fail("unavailable", "Полный поток выбранного качества недоступен");
    if (response.manifestMimeType !== "application/vnd.tidal.bts") C.fail("unsupported_stream", "Поддерживается прямой BTS-поток; DASH/DRM пока не поддерживаются");
    var manifest;
    try { manifest = JSON.parse(utils.base64Decode(response.manifest)); } catch (_) { C.fail("invalid_response", "Некорректный манифест Tidal"); }
    if (manifest.encryptionType !== "NONE" || manifest.keyId || !Array.isArray(manifest.urls) || !manifest.urls.length) C.fail("unsupported_stream", "Поток зашифрован или не содержит прямой ссылки");
    var codec = String(manifest.codecs || "").toLowerCase();
    if (quality === "flac" ? codec !== "flac" : !/^(mp4a|aac)/.test(codec)) C.fail("unsupported_stream", "Неожиданный кодек Tidal");
    return D.save(track, manifest.urls[0], ["*.tidal.com", "*.tidalhifi.com", "*.akamaized.net", "*.akamaihd.net", "*.cloudfront.net"], output,
      quality === "flac" ? "flac" : "m4a", quality === "flac" ? "flac" : "aac", progress);
  }
  D.register(ID, {
    initialize: function (s) { s = s || {}; token = C.secret(s.token); country = String(s.country || "US").toUpperCase(); if (!/^[A-Z]{2}$/.test(country)) C.fail("invalid_request", "Нужен код страны из двух букв"); return true; },
    cleanup: function () { token = ""; }, getTrack: getTrack,
    searchTracks: function (q, limit) {
      q = String(q || "").trim(); if (!q) return {tracks: [], total: 0};
      var data = api("search/tracks", {query: q, limit: Math.max(1, Math.min(100, Number(limit) || 30)), offset: 0});
      if (!Array.isArray(data.items)) C.fail("invalid_response", "Некорректный результат поиска");
      return {tracks: data.items.map(function (t) { return map(t); }), total: Number(data.totalNumberOfItems) || data.items.length};
    },
    getAlbum: function (id) { return collection("albums", id); }, getPlaylist: function (id) { return collection("playlists", id); },
    handleUrl: function (value) {
      var url = C.link(value, ["tidal.com", "www.tidal.com", "listen.tidal.com"]); if (!url) return null;
      var m = /^\/(?:browse\/)?(track|album|playlist)\/([a-zA-Z0-9-]+)\/?$/.exec(url.pathname); if (!m) return null;
      return m[1] === "track" ? {type: "track", track: getTrack(m[2])} : C.collection(m[1], collection(m[1] + "s", m[2]));
    }, download: download
  });
}());
