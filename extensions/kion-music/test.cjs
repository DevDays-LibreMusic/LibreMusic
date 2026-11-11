// SPDX-License-Identifier: LGPL-3.0-only
// Uses only Node built-ins, including on older development hosts.
const assert = require("assert");
const fs = require("fs");
const vm = require("vm");
const crypto = require("crypto");
const source = fs.readFileSync(__dirname + "/index.js", "utf8");
const manifest = JSON.parse(fs.readFileSync(__dirname + "/manifest.json", "utf8"));
const API = "https://api.music.yandex.net";
const raw = {id: 42, title: "Песня", version: "Live", durationMs: 180000,
  artists: [{id: 7, name: "Исполнитель"}], contentWarning: "explicit", isrc: "TEST00000001",
  albums: [{id: 9, title: "Альбом", year: 2024, trackPosition: {index: 3, volume: 2},
    coverUri: "avatars.yandex.net/get-music-content/example/%%"}]};
const clone = value => JSON.parse(JSON.stringify(value));
const ok = result => ({ok: true, statusCode: 200, body: JSON.stringify({result})});
let count = 0;
function test(name, body) {
  body(); count++; console.log("ok " + count + " - " + name);
}
function load(route, settings, fileSuccess) {
  let extension;
  const calls = [], downloads = [];
  function send(method, url, body, headers) {
    calls.push({method, url, body, headers: clone(headers)});
    return route({method, url, body, headers});
  }
  const context = {
    URL,
    http: {get: (url, headers) => send("GET", url, null, headers),
      post: (url, body, headers) => send("POST", url, body, headers)},
    file: {download: (url, path, options) => { downloads.push({url, path, options}); return {success: fileSuccess !== false}; }},
    utils: {md5: text => crypto.createHash("md5").update(text).digest("hex")},
    registerExtension: value => { extension = value; }
  };
  vm.runInNewContext(source, context, {timeout: 1000});
  extension.initialize(settings || {token: "fixture-token"});
  return {extension, calls, downloads};
}

test("manifest declares methods, secrets and bounded network permissions", () => {
  assert(manifest.type.includes("metadata_provider"));
  assert(manifest.type.includes("download_provider"));
  assert.strictEqual(manifest.settings[0].secret, true);
  assert(!manifest.permissions.network.includes("*"));
  const loaded = load(() => { throw Error("Unexpected network"); });
  ["initialize", "searchTracks", "customSearch", "getTrack", "getAlbum", "getPlaylist",
    "handleUrl", "checkAvailability", "download"].forEach(name => assert.strictEqual(typeof loaded.extension[name], "function"));
});
test("search encodes text, limits results and maps versions and metadata", () => {
  const h = load(req => {
    assert.strictEqual(req.url, API + "/search?type=track&page=0&text=" + encodeURIComponent("Песня & Live"));
    assert.strictEqual(req.headers.Authorization, "OAuth fixture-token");
    return ok({tracks: {total: 2, results: [raw, raw]}});
  });
  const result = h.extension.searchTracks("Песня & Live", 1);
  assert.strictEqual(result.total, 2);
  assert.strictEqual(result.tracks.length, 1);
  assert.strictEqual(result.tracks[0].name, "Песня (Live)");
  assert.strictEqual(result.tracks[0].cover_url, "https://avatars.yandex.net/get-music-content/example/1000x1000");
  assert.strictEqual(result.tracks[0].duration_ms, 180000);
  assert.strictEqual(result.tracks[0].disc_number, 2);
  assert.strictEqual(result.tracks[0].explicit, true);
});
test("empty search performs no request", () => {
  const h = load(() => { throw Error("Unexpected request"); });
  assert.strictEqual(h.extension.customSearch("  ").length, 0);
});
test("track lookup uses a form POST and verifies the returned ID", () => {
  const h = load(req => {
    assert.strictEqual(req.method, "POST");
    assert.strictEqual(req.url, API + "/tracks");
    assert.strictEqual(req.body, "track-ids=42%3A9&with-positions=true");
    return ok([raw]);
  });
  assert.strictEqual(h.extension.getTrack("42:9").id, "42");
  assert.throws(() => load(() => ok([{id: 43}])).extension.getTrack("42"), /не найден/);
});
test("album keeps disc numbering and release metadata", () => {
  const h = load(req => {
    assert.strictEqual(req.url, API + "/albums/9/with-tracks");
    return ok({id: 9, title: "Double", year: 2025, trackCount: 2, volumes: [[raw], [raw]]});
  });
  const result = h.extension.getAlbum("9");
  assert.strictEqual(result.tracks[1].disc_number, 2);
  assert.strictEqual(result.tracks[1].track_number, 1);
  assert.strictEqual(result.tracks[1].total_discs, 2);
  assert.strictEqual(result.tracks[0].album_name, "Double");
});
test("playlist hydrates short entries and preserves duplicates and order", () => {
  const h = load(req => {
    if (req.method === "POST") return ok([raw]);
    assert.strictEqual(req.url, API + "/users/person/playlists/12");
    return ok({title: "List", trackCount: 3, tracks: [{id: 42}, {track: Object.assign({}, raw, {id: 43})}, {id: 42}]});
  });
  assert.deepStrictEqual(clone(h.extension.getPlaylist("person:12").tracks.map(t => t.id)), ["42", "43", "42"]);
  assert.strictEqual(h.calls.length, 2);
});
test("UUID playlists use the modern endpoint", () => {
  const uuid = "11111111-2222-3333-4444-555555555555";
  const h = load(req => { assert.strictEqual(req.url, API + "/playlist/" + uuid); return ok({tracks: [], trackCount: 0}); });
  assert.strictEqual(h.extension.handleUrl("https://music.kion.ru/playlists/" + uuid).type, "playlist");
});
test("legacy playlist links support encoded usernames", () => {
  const h = load(req => {
    assert.strictEqual(req.url, API + "/users/" + encodeURIComponent("имя") + "/playlists/12");
    return ok({title: "List", tracks: [], trackCount: 0});
  });
  assert.strictEqual(h.extension.handleUrl("https://music.kion.ru/users/" + encodeURIComponent("имя") + "/playlists/12").type, "playlist");
});
test("large playlists hydrate in bounded batches", () => {
  const entries = Array.from({length: 101}, (_, id) => ({id: id + 1}));
  const sizes = [];
  const h = load(req => {
    if (req.method === "GET") return ok({tracks: entries, trackCount: entries.length});
    const ids = new URLSearchParams(req.body).get("track-ids").split(",");
    sizes.push(ids.length);
    return ok(ids.map(id => Object.assign({}, raw, {id})));
  });
  assert.strictEqual(h.extension.getPlaylist("person:12").tracks.length, 101);
  assert.deepStrictEqual(sizes, [50, 50, 1]);
});
test("incomplete playlists fail explicitly", () => {
  const h = load(() => ok({trackCount: 10, tracks: []}));
  assert.throws(() => h.extension.getPlaylist("person:1"), /неполный/);
});
test("links accept query strings and return UI-compatible collection shape", () => {
  const h = load(() => ok({id: 9, title: "Album", volumes: [[raw]]}));
  const result = h.extension.handleUrl("https://music.mts.ru/album/9?utm_source=share#x");
  assert.strictEqual(result.type, "album");
  assert.strictEqual(result.tracks[0].id, "42");
  assert.strictEqual(result.album.id, "9");
  const t = load(() => ok([raw]));
  assert.strictEqual(t.extension.handleUrl("https://music.kion.ru/album/9/track/42").track.id, "42");
});
test("foreign hosts, credentials, unsupported links and malformed IDs cause no request", () => {
  const h = load(() => { throw Error("Unexpected request"); });
  ["https://music.kion.ru.evil.test/track/42", "https://evil.test/track/42",
    "https://token@music.kion.ru/track/42", "https://music.kion.ru/artist/7", "garbage"]
    .forEach(url => assert.strictEqual(h.extension.handleUrl(url), null));
  assert.throws(() => h.extension.getTrack("../../account"), /ID/);
  assert.strictEqual(h.calls.length, 0);
});
test("missing and expired tokens, throttling, malformed JSON and API errors are explicit", () => {
  assert.throws(() => load(() => { throw Error("Network called"); }, {token: ""}).extension.getTrack("42"), /OAuth/);
  [401, 403, 429, 500].forEach(statusCode => {
    const h = load(() => ({ok: false, statusCode}));
    assert.throws(() => h.extension.getTrack("42"));
    assert.strictEqual(h.calls.length, 1);
  });
  ["not json", '{"error":{"message":"fixture-token"}}', "null"].forEach(body => {
    assert.throws(() => load(() => ({ok: true, body})).extension.getTrack("42"), error => !error.message.includes("fixture-token"));
  });
});
test("cross-service IDs are not treated as KION IDs; fallback requires exact ISRC", () => {
  const h = load(() => ok({tracks: {results: [raw]}}));
  assert.strictEqual(h.extension.checkAvailability("", "", "", {track: {id: "42", source: "deezer"}}).available, false);
  assert.strictEqual(h.calls.length, 0);
  assert.strictEqual(h.extension.checkAvailability("TEST00000001", "Песня", "Исполнитель", {}).track_id, "42");
  assert.strictEqual(h.extension.checkAvailability("OTHER", "Песня", "Исполнитель", {}).available, false);
  assert.strictEqual(h.extension.checkAvailability("", "", "", {track: {id: "42", provider_id: "kion-music"}}).track_id, "42");
});

function downloadHarness(variants, xml, fileSuccess) {
  const h = load(req => {
    if (req.url === API + "/tracks") return ok([raw]);
    if (req.url === API + "/tracks/42/download-info") return ok(variants);
    assert.strictEqual(req.url, "https://storage.mds.yandex.net/info.xml");
    assert.strictEqual(req.headers.Authorization, undefined);
    return {ok: true, body: xml};
  }, undefined, fileSuccess);
  return h;
}
const full = {codec: "mp3", preview: false, bitrateInKbps: 320, downloadInfoUrl: "https://storage.mds.yandex.net/info.xml"};
const xml = "<download-info><host>node.storage.yandex.net</host><path>/a/music.mp3</path><ts>123</ts><s>salt</s></download-info>";
test("download resolves signed MP3 and never forwards OAuth to CDN", () => {
  const h = downloadHarness([full], xml);
  let progress = 0;
  const result = h.extension.download("42", "mp3-320", "out.mp3", value => { progress = value; });
  assert.strictEqual(result.success, true);
  assert.strictEqual(result.file_path, "out.mp3");
  assert.strictEqual(result.title, "Песня (Live)");
  const sign = crypto.createHash("md5").update("XGRlBW9FXlekgbPrRHuSiA" + "a/music.mp3" + "salt").digest("hex");
  assert.strictEqual(h.downloads[0].url, "https://node.storage.yandex.net/get-mp3/" + sign + "/123/a/music.mp3");
  assert.deepStrictEqual(clone(h.downloads[0].options), {});
  assert.strictEqual(progress, 100);
});
test("preview-only, unknown preview status and invalid bitrate never download", () => {
  [Object.assign({}, full, {preview: true}), Object.assign({}, full, {preview: undefined}),
    Object.assign({}, full, {bitrateInKbps: 0}), Object.assign({}, full, {bitrateInKbps: "invalid"})].forEach(variant => {
    const h = downloadHarness([variant], xml);
    assert.strictEqual(h.extension.download("42", "mp3-320", "out.mp3").success, false);
    assert.strictEqual(h.downloads.length, 0);
    assert.strictEqual(h.calls.length, 2);
  });
});
test("best MP3 accepts real-world 192 kbps and hexadecimal ts without changing it", () => {
  const timestamp = "00065af012bcDE";
  const h = downloadHarness([Object.assign({}, full, {bitrateInKbps: 192})], xml.replace("123", timestamp));
  assert.strictEqual(h.extension.download("42", "mp3-320", "out.mp3").success, true);
  assert(h.downloads[0].url.includes("/" + timestamp + "/a/music.mp3"));
});
test("best MP3 prefers highest full bitrate, ignoring higher previews", () => {
  const low = Object.assign({}, full, {bitrateInKbps: 128, downloadInfoUrl: "https://wrong.storage.yandex.net/low"});
  const preview = Object.assign({}, full, {preview: true, downloadInfoUrl: "https://wrong.storage.yandex.net/preview"});
  const h = downloadHarness([low, preview, Object.assign({}, full, {bitrateInKbps: 192})], xml);
  assert.strictEqual(h.extension.download("42", "mp3-320", "out.mp3").success, true);
});
test("128 kbps mode remains exact", () => {
  const h = downloadHarness([full], xml);
  assert.strictEqual(h.extension.download("42", "mp3-128", "out.mp3").success, false);
  assert.strictEqual(h.downloads.length, 0);
});
test("MP3 128 uses its selected variant and file errors cannot report success", () => {
  const variants = [Object.assign({}, full, {bitrateInKbps: 128})];
  const low = downloadHarness(variants, xml);
  assert.strictEqual(low.extension.download("42", "mp3-128", "out.mp3").success, true);
  const failed = downloadHarness(variants, xml, false);
  const result = failed.extension.download("42", "mp3-128", "out.mp3");
  assert.strictEqual(result.success, false);
  assert.strictEqual(result.error_type, "download_failed");
});
test("malicious CDN, malformed XML and unsupported quality are rejected", () => {
  const h = downloadHarness([Object.assign({}, full, {downloadInfoUrl: "https://evil.test/info"})], xml);
  assert.strictEqual(h.extension.download("42", "mp3-320", "out.mp3").success, false);
  assert.strictEqual(h.calls.length, 2);
  ["broken", xml.replace("node.storage.yandex.net", "evil.test"), xml.replace("123", "not-hex"),
    xml.replace("123", "../123"), xml.replace("123", "")].forEach(body => {
    const fixture = downloadHarness([full], body);
    assert.strictEqual(fixture.extension.download("42", "mp3-320", "out.mp3").success, false);
    assert.strictEqual(fixture.downloads.length, 0);
  });
  assert.strictEqual(h.extension.download("42", "flac", "out.flac").error_type, "unsupported_quality");
});
test("cleanup removes the in-memory token", () => {
  const h = load(() => { throw Error("Unexpected request"); });
  h.extension.cleanup();
  assert.throws(() => h.extension.getTrack("42"), /OAuth/);
});
test("KION endpoint is explicit and credentials never fall back to another API", () => {
  const h = load(req => {
    assert.strictEqual(req.url, "https://music.mts.ru/ya_proxy_api/tracks");
    assert.strictEqual(req.headers.Authorization, "OAuth kion-only");
    return ok([raw]);
  }, {token: "kion-only", endpoint: "mts-proxy"});
  assert.strictEqual(h.extension.getTrack("42").provider_id, "kion-music");
  assert.strictEqual(h.extension.handleUrl("https://music.yandex.ru/track/42"), null);
  assert.throws(() => load(() => ok([raw]), {token: "fixture", endpoint: "https://evil.test"}), /API/);
  const failed = load(() => ({ok: false, statusCode: 401}), {token: "kion-only", endpoint: "mts-proxy"});
  assert.throws(() => failed.extension.getTrack("42"));
  assert.strictEqual(failed.calls.length, 1);
});
console.log("Passed " + count + " offline tests");
