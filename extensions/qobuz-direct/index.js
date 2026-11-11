// SPDX-License-Identifier: LGPL-3.0-only
(function () {
  "use strict";
  var C = LibreMusic, D = DirectMusic, ID = "qobuz-direct";
  var token = "", app = "", secret = "";
  function api(path, params) {
    var headers = {"X-App-Id": D.required(app), "X-User-Auth-Token": D.required(token)};
    return D.json("https://www.qobuz.com/api.json/0.2/" + path + "?" + C.form(params || {}), headers);
  }
  function map(raw, album) {
    album = album || raw.album || {};
    return {id: D.id(raw.id), provider_id: ID, name: raw.title || "", artists: (raw.performer || raw.artist || {}).name || "",
      album_id: String(album.id || ""), album_name: album.title || "", album_artist: (album.artist || {}).name || "",
      duration_ms: (Number(raw.duration) || 0) * 1000, isrc: raw.isrc || "", cover_url: (album.image || {}).large || "",
      track_number: Number(raw.track_number) || 0, disc_number: Number(raw.media_number) || 0,
      release_date: album.release_date_original || "", explicit: !!raw.parental_warning,
      external_urls: "https://play.qobuz.com/track/" + raw.id};
  }
  function getTrack(id) { id = D.id(id); var raw = api("track/get", {track_id: id}); if (String(raw.id) !== id) C.fail("not_found", "Трек не найден"); return map(raw); }
  function collection(type, value) {
    var id = D.id(value, type === "album" ? /^[a-zA-Z0-9]+$/ : /^\d+$/);
    var params = {limit: 100, offset: 0, extra: "tracks"}; params[type + "_id"] = id;
    var first = api(type + "/get", params), current = first, rows = [], total = D.size((first.tracks || {}).total);
    if (String(first.id) !== id) C.fail("not_found", "Коллекция не найдена");
    do {
      if (D.size((current.tracks || {}).total) !== total) C.fail("incomplete_playlist", "Коллекция изменилась");
      rows = rows.concat(D.page((current.tracks || {}).items, total, rows.length));
      if (rows.length >= total) break;
      params.offset = rows.length; current = api(type + "/get", params);
    } while (rows.length < total);
    return {id: id, name: first.title || first.name || "", provider_id: ID, total_tracks: rows.length,
      cover_url: (first.image || {}).large || "", tracks: rows.map(function (t) { return map(t, type === "album" ? first : null); })};
  }
  function download(value, quality, output, progress) {
    var id = D.id(value), format = {"mp3-320": 5, flac: 6, "flac-96": 7, "flac-192": 27}[quality];
    if (!format) C.fail("unsupported_quality", "Выберите качество Qobuz");
    D.required(secret);
    var track = getTrack(id), ts = String(Math.floor(Date.now() / 1000));
    var signature = utils.md5("trackgetFileUrlformat_id" + format + "intentstreamtrack_id" + id + ts + secret);
    var data = api("track/getFileUrl", {track_id: id, format_id: format, intent: "stream", request_ts: ts, request_sig: signature});
    if (!data.url || Number(data.track_id) !== Number(id) || Number(data.format_id) !== format || data.sample === true) C.fail("unavailable", "Полный трек выбранного качества недоступен");
    var ext = format === 5 ? "mp3" : "flac";
    return D.save(track, data.url, ["*.qobuz.com", "*.qobuz.fr", "*.akamaized.net", "*.akamaihd.net"], output, ext, ext, progress);
  }
  D.register(ID, {
    initialize: function (s) { s = s || {}; token = C.secret(s.token); app = C.secret(s.appId); secret = C.secret(s.appSecret); return true; },
    cleanup: function () { token = app = secret = ""; }, getTrack: getTrack,
    searchTracks: function (q, limit) {
      q = String(q || "").trim(); if (!q) return {tracks: [], total: 0};
      var data = api("track/search", {query: q, limit: Math.max(1, Math.min(100, Number(limit) || 30)), offset: 0}).tracks;
      if (!data || !Array.isArray(data.items)) C.fail("invalid_response", "Некорректный результат поиска");
      return {tracks: data.items.map(function (t) { return map(t); }), total: Number(data.total) || data.items.length};
    },
    getAlbum: function (id) { return collection("album", id); }, getPlaylist: function (id) { return collection("playlist", id); },
    handleUrl: function (value) {
      var url = C.link(value, ["play.qobuz.com", "open.qobuz.com", "www.qobuz.com"]); if (!url) return null;
      var match = /^\/(?:[a-z]{2}-[a-z]{2}\/)?(track|album|playlist)\/(?:[^/]+\/)?([a-zA-Z0-9]+)\/?$/.exec(url.pathname);
      if (!match) return null;
      return match[1] === "track" ? {type: "track", track: getTrack(match[2])} : C.collection(match[1], collection(match[1], match[2]));
    }, download: download
  });
}());
