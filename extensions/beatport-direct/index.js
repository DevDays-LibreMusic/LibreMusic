// SPDX-License-Identifier: LGPL-3.0-only
(function () {
  "use strict";
  var C = LibreMusic, D = DirectMusic, ID = "beatport-direct", token = "";
  function api(path, params) { return D.json("https://api.beatport.com/v4/" + path + "?" + C.form(params || {}), {Authorization: "Bearer " + D.required(token)}); }
  function map(t, album) {
    album = album || t.release || {};
    return {id: D.id(t.id), provider_id: ID, name: (t.name || "") + (t.mix_name ? " (" + t.mix_name + ")" : ""),
      artists: (t.artists || []).map(function (a) { return a.name; }).join(", "),
      album_id: String(album.id || ""), album_name: album.name || "", duration_ms: Number(t.length_ms) || 0,
      cover_url: (album.image || {}).uri || "", isrc: t.isrc || "", explicit: !!t.is_explicit,
      release_date: t.publish_date || album.new_release_date || "", track_number: t.number || 0,
      genre: (t.genre || {}).name || "", external_urls: "https://www.beatport.com/track/track/" + t.id};
  }
  function getTrack(id) { id = D.id(id); var t = api("catalog/tracks/" + id + "/"); if (String(t.id) !== id) C.fail("not_found", "Трек не найден"); return map(t); }
  function collection(type, value) {
    var id = D.id(value), root = api("catalog/" + type + "/" + id + "/"), rows = [], total = D.size(root.track_count), pageNumber = 1;
    do {
      var page = api("catalog/" + type + "/" + id + "/tracks/", {page: pageNumber++, per_page: 100});
      if (D.size(page.count) !== total) C.fail("incomplete_playlist", "Размер коллекции изменился");
      rows = rows.concat(D.page(page.results, total, rows.length).map(function (t) { return map(type === "playlists" ? t.track : t, type === "releases" ? root : null); }));
    } while (rows.length < total);
    return {id: id, provider_id: ID, name: root.name || "", cover_url: (root.image || {}).uri || "", tracks: rows, total_tracks: total};
  }
  function download(value, quality, output, progress) {
    var id = D.id(value), expected = {lossless: ".flac", high: ".256k.aac.mp4", medium: ".128k.aac.mp4"}[quality];
    if (!expected) C.fail("unsupported_quality", "Выберите качество Beatport");
    var track = getTrack(id), data = api("catalog/tracks/" + id + "/download/", {quality: quality});
    if (!data.location || data.stream_quality !== expected) C.fail("unavailable", "Выбранное качество недоступно аккаунту Beatport");
    var ext = quality === "lossless" ? "flac" : "m4a";
    return D.save(track, data.location, ["*.beatport.com", "*.cloudfront.net"], output, ext, ext === "flac" ? "flac" : "aac", progress);
  }
  D.register(ID, {
    initialize: function (s) { token = C.secret((s || {}).token); return true; }, cleanup: function () { token = ""; },
    getTrack: getTrack, getAlbum: function (id) { return collection("releases", id); }, getPlaylist: function (id) { return collection("playlists", id); },
    searchTracks: function (q, limit) {
      q = String(q || "").trim(); if (!q) return {tracks: [], total: 0};
      var data = api("catalog/search/", {q: q, order_by: "-publish_date", is_available_for_streaming: true});
      var tracks = Array.isArray(data.tracks) ? data.tracks : (data.tracks || {}).results;
      if (!Array.isArray(tracks)) C.fail("invalid_response", "Некорректный результат поиска");
      return {tracks: tracks.slice(0, Math.max(1, Math.min(100, Number(limit) || 30))).map(function (t) { return map(t); }), total: tracks.length};
    },
    handleUrl: function (value) {
      var url = C.link(value, ["beatport.com", "www.beatport.com"]); if (!url) return null;
      var m = /^\/(track|release|playlist)\/(?:[^/]+\/)?(\d+)\/?$/.exec(url.pathname); if (!m) return null;
      return m[1] === "track" ? {type: "track", track: getTrack(m[2])} : C.collection(m[1] === "release" ? "album" : "playlist", collection(m[1] + "s", m[2]));
    }, download: download
  });
}());
