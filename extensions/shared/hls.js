// SPDX-License-Identifier: LGPL-3.0-only
// Finite audio HLS, including AES-128 keys supplied by the authorized stream.
var LibreMusicHls = (function () {
  "use strict";
  var C = LibreMusic;
  function attributes(line) {
    var output = {};
    var pattern = /([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)/g;
    var match;
    while ((match = pattern.exec(line))) output[match[1]] = match[2] === undefined ? match[3] : match[2];
    return output;
  }
  function parse(text, base, domains) {
    if (String(text).length > 1024 * 1024 || !/^#EXTM3U\s/.test(text)) C.fail("invalid_response", "Некорректный HLS-плейлист");
    var segments = [], variants = [], sequence = 0, key = null, pending = null, duration = 0;
    var ended = false, segmentDuration = null;
    String(text).split(/\r?\n/).forEach(function (raw) {
      var line = raw.trim();
      if (!line) return;
      if (line.indexOf("#EXT-X-STREAM-INF:") === 0) pending = attributes(line.slice(18));
      else if (line.indexOf("#EXT-X-MEDIA-SEQUENCE:") === 0) {
        var number = line.slice(22);
        if (!/^\d+$/.test(number) || !Number.isSafeInteger(Number(number))) C.fail("unsupported_stream", "Некорректная последовательность HLS");
        sequence = Number(number);
      } else if (line.indexOf("#EXT-X-KEY:") === 0) {
        var info = attributes(line.slice(11));
        if (info.METHOD === "NONE") key = null;
        else if (info.METHOD === "AES-128" && (!info.KEYFORMAT || info.KEYFORMAT === "identity") && info.URI) {
          if (info.IV && !/^0x[0-9a-fA-F]{1,32}$/.test(info.IV)) C.fail("unsupported_stream", "Некорректный IV HLS");
          key = {url: C.url(info.URI, domains, base).href, iv: info.IV ? info.IV.slice(2).padStart(32, "0") : null};
        } else C.fail("unsupported_stream", "Этот формат защиты HLS не поддерживается");
      } else if (/^#EXT-X-(MAP|BYTERANGE|DISCONTINUITY|SESSION-KEY)(:|$)/.test(line)) {
        C.fail("unsupported_stream", "Этот вариант HLS не поддерживается");
      } else if (line.indexOf("#EXTINF:") === 0) {
        var seconds = Number(line.slice(8).split(",")[0]);
        if (!Number.isFinite(seconds) || seconds <= 0) C.fail("invalid_response", "Некорректная длительность сегмента");
        if (segmentDuration !== null) C.fail("invalid_response", "Сегмент HLS не содержит адреса");
        segmentDuration = seconds;
        duration += seconds;
      } else if (line === "#EXT-X-ENDLIST") ended = true;
      else if (line[0] !== "#") {
        var url = C.url(line, domains, base).href;
        if (pending) { variants.push({url: url, bandwidth: Number(pending.BANDWIDTH) || 0}); pending = null; }
        else {
          if (segmentDuration === null || !Number.isSafeInteger(sequence + segments.length)) C.fail("invalid_response", "Некорректный сегмент HLS");
          segments.push({url: url, key: key, sequence: sequence + segments.length});
          segmentDuration = null;
        }
      }
    });
    if (pending || segmentDuration !== null) C.fail("invalid_response", "Неполный HLS-плейлист");
    if (variants.length && segments.length) C.fail("invalid_response", "Смешанный HLS-плейлист");
    if (variants.length) return {variants: variants.sort(function (a, b) { return b.bandwidth - a.bandwidth; })};
    if (!ended || !segments.length || segments.length > 2000 || duration <= 0) C.fail("unsupported_stream", "Нужен конечный HLS-трек до 2000 сегментов");
    return {segments: segments, duration: duration};
  }
  function download(url, output, domains, expectedMs, progress) {
    var playlist;
    for (var depth = 0; depth < 4; depth++) {
      url = C.url(url, domains).href;
      var response = http.get(url, {});
      if (!response.ok) C.fail("network_error", "Не удалось получить HLS-плейлист");
      playlist = parse(response.body, url, domains);
      if (!playlist.variants) break;
      url = playlist.variants[0].url;
    }
    if (playlist.variants) C.fail("unsupported_stream", "Слишком много уровней HLS");
    if (expectedMs > 0 && Math.abs(playlist.duration * 1000 - expectedMs) > 10000) {
      C.fail("unavailable", "Длительность потока не совпадает с треком; возможно, это превью");
    }
    var temporary = output + ".hls.ts";
    var segmentFile = output + ".hls.segment";
    var destination = output + ".m4a";
    var completed = false;
    try {
      if (!playlist.segments.some(function (s) { return s.key; })) {
        C.saved(file.downloadSegments(playlist.segments.map(function (s) { return s.url; }), temporary, {}));
      } else {
        C.saved(file.writeBytes(temporary, "", {encoding: "base64", truncate: true}));
        var keys = Object.create(null);
        playlist.segments.forEach(function (segment, index) {
          C.saved(file.download(segment.url, segmentFile, {}));
          var bytes = file.readBytes(segmentFile, {encoding: "base64"});
          C.saved(bytes);
          if (segment.key) {
            if (!keys[segment.key.url]) {
              var keyResponse = fetch(segment.key.url);
              if (!keyResponse.ok) C.fail("network_error", "Не удалось получить ключ HLS");
              var keyBytes = new Uint8Array(keyResponse.arrayBuffer());
              if (keyBytes.length !== 16) C.fail("invalid_response", "Неверная длина ключа HLS");
              keys[segment.key.url] = Array.from(keyBytes).map(function (b) { return b.toString(16).padStart(2, "0"); }).join("");
            }
            var decrypted = utils.decryptBlockCipher(bytes.data, {algorithm: "aes", mode: "cbc", padding: "pkcs7",
              inputEncoding: "base64", outputEncoding: "base64", keyEncoding: "hex", ivEncoding: "hex",
              key: keys[segment.key.url], iv: segment.key.iv || segment.sequence.toString(16).padStart(32, "0")});
            C.saved(decrypted);
            bytes = decrypted;
          }
          C.saved(file.writeBytes(temporary, bytes.data, {encoding: "base64", append: true}));
          if (typeof progress === "function") progress(Math.floor((index + 1) * 95 / playlist.segments.length));
        });
      }
      C.saved(ffmpeg.convert(temporary, destination, {codec: "copy"}));
      completed = true;
      return destination;
    } finally {
      file.delete(temporary);
      file.delete(segmentFile);
      if (!completed) file.delete(destination);
    }
  }
  return {parse: parse, download: download};
}());
