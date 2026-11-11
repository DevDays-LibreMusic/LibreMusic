// SPDX-License-Identifier: LGPL-3.0-only
// GraphQL field contracts and Tiny API researched with trudenboy/zvuk-music.
(function () {
  "use strict";
  var C = LibreMusic;
  var ID = "zvuk";
  var token = "";
  var MEDIA = ["*.zvuk.com", "*.zvooq.com", "*.zvuk.ru"];
  var ARTISTS = "artists { id title }";
  var RELEASE = "release { id title date image { src } " + ARTISTS + " }";
  var TRACK = "id title duration explicit " + ARTISTS + " " + RELEASE;
  function initialize(settings) { token = C.secret((settings || {}).token); return true; }
  function headers() {
    if (!token) C.fail("auth_required", "Укажите токен Звука в настройках расширения");
    return {"X-Auth-Token": token, "Content-Type": "application/json",
      Origin: "https://zvuk.com", Referer: "https://zvuk.com/"};
  }
  function gql(name, declaration, selection, variables) {
    var data = C.json(http.post("https://zvuk.com/api/v1/graphql", JSON.stringify({
      operationName: name, query: "query " + name + declaration + " { " + selection + " }", variables: variables
    }), headers()));
    // Partial GraphQL responses must not silently become incomplete playlists.
    if (!data || (data.errors && data.errors.length) || !data.data) {
      C.fail("api_error", "Ошибка API Звука. Проверьте токен и доступность записи");
    }
    return data.data;
  }
  function names(items) { return (items || []).map(function (a) { return a.title || ""; }).filter(Boolean).join(", "); }
  function map(raw, release) {
    release = release || raw.release || {};
    return {id: String(raw.id), provider_id: ID, name: raw.title || "", artists: names(raw.artists),
      album_name: release.title || "", album_id: String(release.id || ""), album_artist: names(release.artists),
      artist_id: String(((raw.artists || [])[0] || {}).id || ""),
      duration_ms: Math.round((Number(raw.duration) || 0) * 1000), explicit: !!raw.explicit,
      cover_url: (release.image || {}).src || "", release_date: String(release.date || "").slice(0, 10),
      external_urls: "https://zvuk.com/track/" + raw.id};
  }
  function tracks(ids) {
    var items = gql("getTracks", "($ids: [ID!]!)", "getTracks(ids: $ids) { " + TRACK + " hasFlac }",
      {ids: ids.map(C.numeric)}).getTracks;
    if (!Array.isArray(items)) C.fail("invalid_response", "Звук не вернул список треков");
    return items;
  }
  function getTrack(id) {
    id = C.numeric(id);
    var raw = tracks([id]).find(function (t) { return String(t.id) === id; });
    if (!raw) C.fail("not_found", "Трек не найден в Звуке");
    return map(raw);
  }
  function searchTracks(query, limit) {
    query = String(query || "").trim();
    if (!query) return {tracks: [], total: 0};
    limit = Math.max(1, Math.min(100, Number(limit) || 30));
    var data = gql("quickSearch", "($query: String, $limit: Int)",
      "quickSearch(query: $query, limit: $limit) { content { __typename ... on Track { " + TRACK + " } } }",
      {query: query, limit: limit});
    var items = ((data.quickSearch || {}).content || []).filter(function (i) { return i.__typename === "Track"; });
    return {tracks: items.slice(0, limit).map(function (i) { return map(i); }), total: items.length};
  }
  function getAlbum(id) {
    id = C.numeric(id);
    var items = gql("getReleases", "($ids: [ID!]!)",
      "getReleases(ids: $ids) { id title date image { src } " + ARTISTS + " tracks { " + TRACK + " } }",
      {ids: [id]}).getReleases || [];
    var release = items.find(function (r) { return String(r.id) === id; });
    if (!release || !Array.isArray(release.tracks)) C.fail("not_found", "Альбом не найден в Звуке");
    return {id: id, provider_id: ID, name: release.title || "", artists: names(release.artists),
      cover_url: (release.image || {}).src || "", total_tracks: release.tracks.length,
      tracks: release.tracks.map(function (r) { return map(r, release); })};
  }
  function getPlaylist(id) {
    // Zvuk playlist IDs can be UUIDs as well as decimal IDs.
    id = String(id || "");
    if (!/^[a-zA-Z0-9-]+$/.test(id)) C.fail("invalid_request", "Некорректный ID плейлиста");
    var lists = gql("getPlaylists", "($ids: [ID!]!)",
      "getPlaylists(ids: $ids) { id title isDeleted image { src } tracks { id } }", {ids: [id]}).getPlaylists || [];
    var playlist = lists.find(function (p) { return String(p.id) === id; });
    if (!playlist || playlist.isDeleted || !Array.isArray(playlist.tracks)) C.fail("not_found", "Плейлист недоступен");
    if (playlist.tracks.length > 2000) C.fail("playlist_too_large", "Плейлист содержит больше 2000 треков");
    var index = Object.create(null);
    var ids = playlist.tracks.map(function (t) { return C.numeric(t.id); });
    for (var offset = 0; offset < ids.length; offset += 50) {
      tracks(ids.slice(offset, offset + 50)).forEach(function (t) { index[String(t.id)] = t; });
    }
    return {id: id, provider_id: ID, name: playlist.title || "", cover_url: (playlist.image || {}).src || "",
      total_tracks: ids.length, tracks: ids.map(function (key) {
        if (!index[key]) C.fail("incomplete_playlist", "Звук не вернул один из треков плейлиста");
        return map(index[key]);
      })};
  }
  function handleUrl(value) {
    var parsed = C.link(value, ["zvuk.com", "www.zvuk.com"]);
    if (!parsed) return null;
    var match = /^\/(?:[a-z]{2}\/)?(track|release|playlist)\/([a-zA-Z0-9-]+)\/?$/.exec(parsed.pathname);
    if (!match) return null;
    if (match[1] === "track") return {type: "track", track: getTrack(match[2])};
    return match[1] === "release" ? C.collection("album", getAlbum(match[2])) : C.collection("playlist", getPlaylist(match[2]));
  }
  function download(id, quality, output, progress) {
    try {
      if (["mid", "high", "flac"].indexOf(quality) < 0) C.fail("unsupported_quality", "Неизвестное качество Звука");
      var metadata = getTrack(id);
      var data = C.json(http.get("https://zvuk.com/api/tiny/track/stream?id=" + C.numeric(id) + "&quality=" + quality, headers()));
      var payload = data && (data.result || data);
      if (!payload || data.error || !payload.stream || payload.preview === true) C.fail("unavailable", "Полный поток выбранного качества недоступен");
      var stream = C.url(payload.stream, MEDIA);
      if (/\.m3u8$/i.test(stream.pathname)) C.fail("unsupported_stream", "Звук вернул поток HLS вместо прямого аудиофайла");
      C.saved(file.download(stream.href, output, {}));
      if (typeof progress === "function") progress(100);
      return C.result(metadata, output, quality === "flac" ? "flac" : "mp3", quality === "flac" ? "flac" : "mp3");
    } catch (error) { return C.downloadError(error); }
  }
  registerExtension({initialize: initialize, cleanup: function () { token = ""; },
    searchTracks: searchTracks, customSearch: function (q, o) { return searchTracks(q, (o || {}).limit).tracks; },
    getTrack: getTrack, getAlbum: getAlbum, getPlaylist: getPlaylist, handleUrl: handleUrl,
    checkAvailability: function (isrc, title, artist, options) {
      var t = C.own(ID, options);
      return t ? {available: true, track_id: C.numeric(t.id)} : C.unavailable();
    }, download: download});
}());
