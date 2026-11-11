// SPDX-License-Identifier: LGPL-3.0-only
var DirectMusic = (function () {
  "use strict";
  var C = LibreMusic;
  function id(value, pattern) {
    value = String(value || "");
    if (!(pattern || /^\d+$/).test(value)) C.fail("invalid_request", "Некорректный идентификатор сервиса");
    return value;
  }
  function required(value) {
    value = C.secret(value);
    if (!value) C.fail("auth_required", "Заполните настройки своего аккаунта и приложения");
    return value;
  }
  function json(url, headers) {
    var value = C.json(http.get(url, headers || {}));
    if (!value || value.error || value.status === "error") C.fail("api_error", "Сервис отклонил запрос");
    return value;
  }
  function size(total) {
    total = Number(total);
    if (!Number.isInteger(total) || total < 0 || total > 2000) C.fail("collection_limit", "Поддерживаются коллекции до 2000 треков с известным размером");
    return total;
  }
  function page(items, total, collected) {
    if (!Array.isArray(items) || (!items.length && collected < total) || collected + items.length > total) C.fail("incomplete_playlist", "Сервис вернул неполную или изменившуюся коллекцию");
    return items;
  }
  function save(track, url, domains, output, ext, codec, progress) {
    url = C.url(url, domains).href;
    var path = output.endsWith("." + ext) ? output : output + "." + ext;
    var complete = false;
    try {
      C.saved(file.download(url, path, {}));
      var info = ffmpeg.getInfo(path);
      if (!info || !info.success || String(info.codec).toLowerCase() !== codec) C.fail("invalid_audio", "Формат полученного файла не соответствует выбранному качеству");
      var duration = Number(info.duration);
      if (!(duration > 0) || !Number.isFinite(duration)) C.fail("invalid_audio", "Не удалось проверить длительность аудио");
      if (track.duration_ms > 0 && Math.abs(duration * 1000 - track.duration_ms) > 10000) C.fail("invalid_audio", "Получено превью или неполный трек");
      var result = C.result(track, path, ext, codec);
      result.isrc = track.isrc || ""; result.actual_container = ext;
      if (codec === "flac") { result.bit_depth = info.bit_depth; result.sample_rate = info.sample_rate; }
      if (typeof progress === "function") progress(100);
      complete = true;
      return result;
    } finally { if (!complete) { try { file.delete(path); } catch (_) {} } }
  }
  function register(provider, methods) {
    methods.customSearch = function (query, options) { return methods.searchTracks(query, (options || {}).limit).tracks; };
    methods.checkAvailability = function (isrc, title, artist, options) {
      var original = C.own(provider, options);
      return original ? {available: true, track_id: original.id} : C.unavailable();
    };
    var download = methods.download;
    methods.download = function (track, quality, path, progress) {
      try { return download(track, quality, path, progress); } catch (e) { return C.downloadError(e); }
    };
    registerExtension(methods);
  }
  return {id: id, required: required, json: json, size: size, page: page, save: save, register: register};
}());
