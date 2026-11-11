// SPDX-License-Identifier: LGPL-3.0-only
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const crypto = require('crypto');
const source = fs.readFileSync(__dirname + '/../shared/provider.js', 'utf8') + '\n' + fs.readFileSync(__dirname + '/index.js', 'utf8');
const manifest = JSON.parse(fs.readFileSync(__dirname + '/manifest.json'));
const arl = 'a'.repeat(192);
const track = {id: 42, title: 'Track', duration: 180, artist: {id: 7, name: 'Artist'}, album: {id: 9, title: 'Album'}, isrc: 'TEST00000001'};
const clone = value => JSON.parse(JSON.stringify(value));
const ok = value => ({ok: true, statusCode: 200, body: JSON.stringify(value)});
let count = 0;
function test(name, run) { run(); console.log('ok ' + (++count) + ' - ' + name); }
function route(req) {
  const url = new URL(req.url);
  if (url.hostname === 'api.deezer.com') return ok(track);
  if (url.searchParams.get('method') === 'deezer.getUserData') return ok({error: [], results: {checkForm: 'csrf-fixture', USER: {USER_ID: 123, OPTIONS: {license_token: 'license-fixture'}}}});
  if (url.searchParams.get('method') === 'song.getData') return ok({error: {}, results: {SNG_ID: '42', TRACK_TOKEN: 'track-fixture'}});
  if (url.hostname === 'media.deezer.com') return ok({data: [{media: [{media_type: 'FULL', format: req.data.media[0].formats[0].format, cipher: {type: 'BF_CBC_STRIPE'}, sources: [{url: 'https://e-cdns-proxy-1.dzcdn.net/media/file'}]}]}]});
  throw Error('Unexpected URL');
}
function load(handler, settings) {
  let extension;
  const calls = [], downloads = [], transforms = [], removed = [];
  let clears = 0, codec = 'flac';
  function send(url, body, headers) {
    const req = {url, data: body === null ? null : JSON.parse(body), headers: headers || {}, clears};
    calls.push(req);
    return (handler || route)(req);
  }
  const context = {
    URL, http: {get: (url, headers) => send(url, null, headers), post: send, clearCookies: () => { clears++; }},
    utils: {md5: value => crypto.createHash('md5').update(value).digest('hex')},
    file: {
      download: (url, path, options) => { downloads.push({url, path, options}); return {success: true}; },
      transformPatternedBlocks: (input, output, options, progress) => { transforms.push({input, output, options}); progress(100, 100); return {success: true}; },
      delete: path => { removed.push(path); return {success: true}; }
    },
    ffmpeg: {getInfo: () => ({success: true, codec, duration: 180, bit_depth: 16, sample_rate: 44100})},
    registerExtension: e => { extension = e; }
  };
  vm.runInNewContext(source, context, {timeout: 1000});
  extension.initialize(settings || {arl});
  return {extension, context, calls, downloads, transforms, removed, setCodec: v => { codec = v; }};
}
test('standalone provider has only Deezer permissions, no signed-session dependency', () => {
  assert.strictEqual(manifest.name, 'deezer-direct');
  assert.deepStrictEqual(manifest.permissions.network, ['api.deezer.com', 'www.deezer.com', 'media.deezer.com', '*.dzcdn.net']);
  assert(!manifest.signedSession); assert(manifest.settings[0].secret);
  assert(!/zarz\.moe|signedFetch|sessionGrant|musicdl|resolverBaseURL/.test(source));
  const h = load(); assert.strictEqual(h.calls.length, 0);
});
test('ARL validation rejects full cookies and header injection; empty allows catalog', () => {
  for (const value of ['arl=' + arl, arl + '; sid=x', 'invalid', arl + '\r\nCookie: x']) assert.throws(() => load(null, {arl: value}));
  const h = load(null, {}); assert.strictEqual(h.extension.getTrack('42').id, '42');
  assert.strictEqual(h.extension.download('42', 'flac', '/tmp/file').error_type, 'auth_required');
});
test('catalog requests carry no account credentials; maps track metadata', () => {
  const h = load(req => { assert.strictEqual(Object.keys(req.headers).length, 0); return ok(track); });
  const t = h.extension.getTrack('42');
  assert.strictEqual(t.provider_id, 'deezer-direct'); assert.strictEqual(t.duration_ms, 180000);
  assert.strictEqual(t.artists, 'Artist'); assert.strictEqual(t.isrc, track.isrc);
});
test('search encodes text and caps results', () => {
  const h = load(req => { const u = new URL(req.url); assert.strictEqual(u.searchParams.get('q'), 'A & B'); assert.strictEqual(u.searchParams.get('limit'), '100'); return ok({data: [track], total: 200}); });
  assert.strictEqual(h.extension.searchTracks('A & B', 999).total, 200);
  assert.strictEqual(h.extension.searchTracks(' ').tracks.length, 0);
});
test('collection pagination preserves duplicates and refuses foreign or looping pages', () => {
  const h = load(req => new URL(req.url).pathname === '/album/9' ? ok({id: 9, title: 'Release', nb_tracks: 2, tracks: {data: [track], next: 'https://api.deezer.com/album/9/tracks?index=1'}}) : ok({data: [track]}));
  const r = h.extension.handleUrl('https://www.deezer.com/ru/album/9?utm=1');
  assert.strictEqual(r.tracks.length, 2); assert.strictEqual(r.tracks[0].album_name, 'Release');
  for (const next of ['https://evil.test/tracks', 'https://api.deezer.com/playlist/9/tracks']) {
    const bad = load(() => ok({id: 9, nb_tracks: 2, tracks: {data: [track], next}}));
    assert.throws(() => bad.extension.getAlbum('9'));
    assert.strictEqual(bad.calls.length, 1);
  }
  assert.throws(() => load(() => ok({id: 9, nb_tracks: 2, tracks: {data: [track]}})).extension.getPlaylist('9'), e => e.kind === 'incomplete_playlist');
});
test('foreign provider IDs, malformed IDs and unsupported URLs do not call API', () => {
  const h = load(() => { throw Error('Unexpected request'); });
  assert.strictEqual(h.extension.checkAvailability('', '', '', {track: {source: 'deezer', id: '42'}}).available, false);
  assert.strictEqual(h.extension.checkAvailability('', '', '', {track: {provider_id: 'deezer-direct', id: '42'}}).track_id, '42');
  assert.throws(() => h.extension.getTrack('../user'));
  for (const url of ['https://deezer.com.evil.test/track/42', 'https://arl@deezer.com/track/42', 'https://deezer.page.link/abc']) assert.strictEqual(h.extension.handleUrl(url), null);
  assert.strictEqual(h.calls.length, 0);
});
test('direct download uses own session, clears cookies before media and keeps CDN anonymous', () => {
  const h = load(req => {
    const host = new URL(req.url).hostname;
    if (host === 'www.deezer.com') assert.strictEqual(req.headers.Cookie, 'arl=' + arl);
    else assert.strictEqual(req.headers.Cookie, undefined);
    if (host === 'media.deezer.com') {
      assert.strictEqual(req.clears, 3);
      assert.strictEqual(req.data.license_token, 'license-fixture');
      assert.strictEqual(req.data.track_tokens[0], 'track-fixture');
      assert.strictEqual(req.data.media[0].type, 'FULL');
    }
    return route(req);
  });
  const r = h.extension.download('42', 'flac', '/tmp/song');
  assert.strictEqual(r.success, true); assert.strictEqual(r.file_path, '/tmp/song.flac');
  assert.strictEqual(r.bit_depth, 16); assert.strictEqual(r.sample_rate, 44100);
  assert.strictEqual(Object.keys(h.downloads[0].options).length, 0);
  assert(h.removed.includes('/tmp/song.deezer-encrypted'));
  const o = h.transforms[0].options;
  assert.strictEqual(o.algorithm, 'blowfish'); assert.strictEqual(o.segmentSize, 2048);
  assert.strictEqual(o.transformEvery, 3); assert.strictEqual(o.transformOffset, 0);
  assert.strictEqual(o.transformPartial, false); assert.strictEqual(o.iv, '0001020304050607');
  const hash = crypto.createHash('md5').update('42').digest('hex');
  const expected = Buffer.from(Array.from({length: 16}, (_, i) => hash.charCodeAt(i) ^ hash.charCodeAt(i + 16) ^ 'g4el58wc0zvf9na1'.charCodeAt(i)));
  assert.strictEqual(o.key, expected.toString('hex'));
});
test('requested MP3 quality is exact and not labelled as lossless', () => {
  for (const q of ['mp3-128', 'mp3-320']) {
    const h = load(req => { if (new URL(req.url).hostname === 'media.deezer.com') assert.strictEqual(req.data.media[0].formats[0].format, q === 'mp3-128' ? 'MP3_128' : 'MP3_320'); return route(req); });
    h.setCodec('mp3'); const r = h.extension.download('42', q, '/tmp/song.mp3');
    assert.strictEqual(r.success, true); assert.strictEqual(r.file_path, '/tmp/song.mp3');
    assert.strictEqual(r.actual_extension, 'mp3'); assert.strictEqual(r.bit_depth, undefined);
  }
});
test('anonymous or expired account, missing license or track token never downloads', () => {
  for (const mutation of ['anonymous', 'license', 'track', 'mismatch', 'gateway-error']) {
    const h = load(req => {
      const r = route(req), data = JSON.parse(r.body), method = new URL(req.url).searchParams.get('method');
      if (method === 'deezer.getUserData') {
        if (mutation === 'anonymous') data.results.USER.USER_ID = 0;
        if (mutation === 'license') delete data.results.USER.OPTIONS.license_token;
        if (mutation === 'gateway-error') data.error = {message: arl};
      }
      if (method === 'song.getData') {
        if (mutation === 'track') delete data.results.TRACK_TOKEN;
        if (mutation === 'mismatch') data.results.SNG_ID = '43';
      }
      return ok(data);
    });
    const r = h.extension.download('42', 'flac', '/tmp/song');
    assert.strictEqual(r.success, false); assert(!r.error_message.includes(arl)); assert.strictEqual(h.downloads.length, 0);
  }
});
test('preview, wrong quality/cipher, missing sources and foreign CDN are rejected', () => {
  for (const mutation of ['preview', 'format', 'cipher', 'source', 'errors']) {
    const h = load(req => {
      const r = route(req); if (new URL(req.url).hostname !== 'media.deezer.com') return r;
      const data = JSON.parse(r.body), m = data.data[0].media[0];
      if (mutation === 'preview') m.media_type = 'PREVIEW';
      if (mutation === 'format') m.format = 'MP3_128';
      if (mutation === 'cipher') m.cipher.type = 'UNKNOWN';
      if (mutation === 'source') m.sources[0].url = 'https://evil.test/audio';
      if (mutation === 'errors') data.data[0].errors = [{message: arl}];
      return ok(data);
    });
    const r = h.extension.download('42', 'flac', '/tmp/song');
    assert.strictEqual(r.success, false); assert.strictEqual(h.downloads.length, 0); assert(!r.error_message.includes(arl));
  }
});
test('download cancellation and transform failures clean partial files', () => {
  for (const stage of ['download', 'transformPatternedBlocks']) {
    const h = load(); h.context.file[stage] = () => ({success: false, error_type: 'cancelled', error: arl});
    const r = h.extension.download('42', 'flac', '/tmp/song');
    assert.strictEqual(r.error_type, 'cancelled'); assert(!r.error_message.includes(arl));
    assert(h.removed.includes('/tmp/song.deezer-encrypted')); assert(h.removed.includes('/tmp/song.flac'));
  }
});
test('corrupt audio, codec mismatch and preview duration fail after download', () => {
  for (const measured of [{success: false}, {success: true, codec: 'mp3'}, {success: true, codec: 'flac', duration: 30}]) {
    const h = load(); h.context.ffmpeg.getInfo = () => measured;
    assert.strictEqual(h.extension.download('42', 'flac', '/tmp/song').error_type, 'invalid_audio');
    assert(h.removed.includes('/tmp/song.flac'));
  }
});
test('cleanup removes ARL; subsequent download requires login', () => {
  const h = load(); h.extension.cleanup();
  assert.strictEqual(h.extension.download('42', 'flac', '/tmp/song').error_type, 'auth_required');
  assert.strictEqual(h.calls.length, 0);
});
test('HTTP failures and unexpected exceptions never expose session contents', () => {
  for (const statusCode of [401, 403, 429, 500]) {
    const r = load(() => ({ok: false, statusCode, body: arl})).extension.download('42', 'flac', '/tmp/song');
    assert.strictEqual(r.success, false); assert(!r.error_message.includes(arl));
  }
  const r = load(() => { throw Error(arl); }).extension.download('42', 'flac', '/tmp/song');
  assert.strictEqual(r.success, false); assert(!r.error_message.includes(arl));
});
console.log('Passed ' + count + ' offline Deezer Direct tests');
