// SPDX-License-Identifier: LGPL-3.0-only
// Bundled into each package; no runtime dependency on another extension.
var LibreMusic = (function () {
  "use strict";
  function fail(kind, message) {
    var error = new Error(message);
    error.kind = kind;
    throw error;
  }
  function secret(value) {
    value = String(value || "").trim();
    if (/[\r\n]/.test(value)) fail("auth_required", "Некорректное значение токена");
    return value;
  }
  function json(response) {
    if (!response || !response.ok) {
      var code = Number((response || {}).statusCode) || 0;
      if (code === 401 || code === 403) fail("auth_required", "Проверьте токен, подписку и доступ аккаунта");
      if (code === 429) fail("rate_limited", "Сервис ограничил запросы. Повторите позднее");
      fail("network_error", "Ошибка сервиса (HTTP " + code + ")");
    }
    try { return JSON.parse(response.body); }
    catch (_) { fail("invalid_response", "Сервис вернул некорректный JSON"); }
  }
  function url(value, domains, base) {
    var parsed;
    try { parsed = base ? new URL(String(value), base) : new URL(String(value)); }
    catch (_) { fail("invalid_response", "Некорректная ссылка сервиса"); }
    if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.port ||
        !domains.some(function (domain) {
          return domain.slice(0, 2) === "*." ?
            String(parsed.hostname).endsWith(domain.slice(1)) : parsed.hostname === domain;
        })) fail("invalid_response", "Адрес не относится к разрешённым серверам сервиса");
    return parsed;
  }
  function link(value, domains) {
    try { return url(value, domains); } catch (_) { return null; }
  }
  function numeric(value) {
    var id = String(value || "");
    if (!/^\d+$/.test(id)) fail("invalid_request", "Некорректный идентификатор");
    return id;
  }
  function form(values) {
    return Object.keys(values).map(function (key) {
      return encodeURIComponent(key) + "=" + encodeURIComponent(String(values[key]));
    }).join("&");
  }
  function own(provider, options) {
    var track = (options || {}).track || {};
    return track.provider_id === provider || track.source === provider ? track : null;
  }
  function unavailable() {
    return {available: false, reason: "Выберите трек из каталога этого расширения"};
  }
  function result(track, path, extension, codec) {
    return {success: true, file_path: path, actual_extension: extension, audio_codec: codec,
      title: track.name, artist: track.artists, album: track.album_name,
      album_artist: track.album_artist, duration_ms: track.duration_ms,
      cover_url: track.cover_url, release_date: track.release_date,
      track_number: track.track_number, disc_number: track.disc_number,
      total_tracks: track.total_tracks, genre: track.genre, explicit: track.explicit};
  }
  function downloadError(error) {
    return {success: false, error_type: error.kind || "provider_error",
      error_message: error.kind ? error.message : "Ошибка расширения; проверьте доступность трека"};
  }
  function saved(result) {
    if (!result || !result.success) {
      var type = (result || {}).error_type;
      fail(type === "cancelled" ? "cancelled" : "download_failed",
        type === "cancelled" ? "Загрузка отменена" : "Не удалось сохранить аудиофайл");
    }
  }
  function collection(type, value) {
    return {type: type, id: value.id, name: value.name, cover_url: value.cover_url,
      tracks: value.tracks, album: value};
  }
  return {fail: fail, secret: secret, json: json, url: url, link: link, numeric: numeric,
    form: form, own: own, unavailable: unavailable, result: result, saved: saved,
    downloadError: downloadError, collection: collection};
}());
