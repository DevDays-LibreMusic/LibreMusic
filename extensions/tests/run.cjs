// SPDX-License-Identifier: LGPL-3.0-only
// Contract and download tests, Node built-ins only. No accounts or network.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const crypto = require('crypto');
const root = __dirname + '/..';
let count = 0;
function test(name, run) { run(); console.log('ok ' + (++count) + ' - ' + name); }
function ok(value) { return {ok: true, statusCode: 200, body: JSON.stringify(value)}; }
function load(provider, route, settings, overrides) {
  let extension;
  const calls = [], downloads = [], removed = [], files = new Map();
  function request(method, url, body, headers) {
    const call = {method, url, body, headers}; calls.push(call); return route(call);
  }
  const context = {
    URL, Uint8Array,
    http: {get: (u, h) => request('GET', u, null, h), post: (u, b, h) => request('POST', u, b, h)},
    file: {
      download: (url, path, options) => { downloads.push({url, path, options}); files.set(path, Buffer.from('audio')); return {success: true}; },
      downloadSegments: (urls, path) => { downloads.push({urls, path}); files.set(path, Buffer.from('segments')); return {success: true}; },
      writeBytes: (path, data, options) => { const value = Buffer.from(data, 'base64'); files.set(path, options.append ? Buffer.concat([files.get(path) || Buffer.alloc(0), value]) : value); return {success: true}; },
      readBytes: path => ({success: true, data: files.get(path).toString('base64')}),
      delete: path => { removed.push(path); files.delete(path); return {success: true}; }
    },
    ffmpeg: {convert: (input, output, options) => { assert.strictEqual(options.codec, 'copy'); files.set(output, files.get(input)); return {success: true}; }},
    utils: {decryptBlockCipher: (data, options) => {
      assert.strictEqual(options.algorithm, 'aes'); assert.strictEqual(options.mode, 'cbc');
      assert.strictEqual(options.padding, 'pkcs7');
      const cipher = crypto.createDecipheriv('aes-128-cbc', Buffer.from(options.key, 'hex'), Buffer.from(options.iv, 'hex'));
      return {success: true, data: Buffer.concat([cipher.update(Buffer.from(data, 'base64')), cipher.final()]).toString('base64')};
    }},
    registerExtension: value => { extension = value; }
  };
  Object.assign(context, overrides);
  const sources = ['shared/provider.js', 'shared/hls.js', provider + '/index.js'];
  vm.runInNewContext(sources.map(p => fs.readFileSync(root + '/' + p, 'utf8')).join('\n'), context, {timeout: 2000});
  extension.initialize(settings || {token: 'fixture-secret', deviceId: 'fixture-device'});
  return {extension, context, calls, downloads, removed, files};
}
const ztrack = {id: '42', title: 'Track', duration: 180, artists: [{id: '7', title: 'Artist'}],
  release: {id: '9', title: 'Album', image: {src: 'https://image.test/x'}}};
const vtrack = {owner_id: -7, id: 42, artist: 'Artist', title: 'Track', duration: 180,
  album: {owner_id: -7, id: 9, title: 'Album'}, url: 'https://ps.vkuseraudio.net/a.mp3'};
function zvukRoute(request) {
  if (request.method === 'POST') return ok({data: {getTracks: [ztrack]}});
  return ok({result: {stream: 'https://cdn.zvuk.com/file.mp3'}});
}
const vkRoute = () => ok({response: [vtrack]});
for (const provider of ['zvuk', 'vk-music']) {
  test(provider + ': manifest and registration agree, no initialization request', () => {
    const m = JSON.parse(fs.readFileSync(root + '/' + provider + '/manifest.json'));
    const h = load(provider, () => { throw Error('Unexpected network'); });
    assert.strictEqual(m.name, provider); assert(m.permissions.file);
    assert(m.settings.filter(s => s.required).every(s => s.secret));
    assert(!m.permissions.network.includes('*'));
    ['getTrack', 'getAlbum', 'getPlaylist', 'handleUrl', 'searchTracks', 'download', 'cleanup'].forEach(method => assert.strictEqual(typeof h.extension[method], 'function'));
    assert.strictEqual(h.extension.searchTracks(' ').tracks.length, 0);
  });
  test(provider + ': authentication required, cleanup clears session', () => {
    const id = provider === 'zvuk' ? '42' : '-7_42';
    const h = load(provider, () => { throw Error('Unexpected network'); }, {});
    assert.throws(() => h.extension.getTrack(id), e => e.kind === 'auth_required');
    h.extension.initialize({token: 'fixture', deviceId: 'device'}); h.extension.cleanup();
    assert.throws(() => h.extension.getTrack(id), e => e.kind === 'auth_required');
  });
  test(provider + ': foreign sources and hosts never trigger requests', () => {
    const h = load(provider, () => { throw Error('Unexpected network'); });
    assert.strictEqual(h.extension.checkAvailability('', '', '', {track: {id: '42', source: 'other'}}).available, false);
    ['https://evil.test/track/42', 'http://zvuk.com/track/42', 'https://vk.com.evil.test/audio-7_42', 'https://token@vk.com/audio-7_42'].forEach(u => assert.strictEqual(h.extension.handleUrl(u), null));
    assert.throws(() => h.extension.getTrack('../../account'));
    assert.strictEqual(h.calls.length, 0);
  });
  test(provider + ': HTTP errors and invalid JSON never expose response secrets', () => {
    const id = provider === 'zvuk' ? '42' : '-7_42';
    const quality = provider === 'zvuk' ? 'high' : 'original';
    for (const statusCode of [401, 403, 429, 500]) {
      const h = load(provider, () => ({ok: false, statusCode, body: 'fixture-secret'}));
      const r = h.extension.download(id, quality, '/tmp/audio');
      assert.strictEqual(r.success, false); assert(!r.error_message.includes('fixture-secret'));
    }
    assert.throws(() => load(provider, () => ({ok: true, body: 'fixture-secret'})).extension.getTrack(id));
  });
}
test('Zvuk: GraphQL search filters polymorphic records and maps seconds', () => {
  const h = load('zvuk', req => {
    assert.strictEqual(req.url, 'https://zvuk.com/api/v1/graphql');
    assert.strictEqual(req.headers['X-Auth-Token'], 'fixture-secret');
    const body = JSON.parse(req.body); assert.strictEqual(body.variables.query, 'A & B');
    assert.strictEqual(body.operationName, 'quickSearch');
    return ok({data: {quickSearch: {content: [Object.assign({__typename: 'Track'}, ztrack), {__typename: 'Artist'}]}}});
  });
  const r = h.extension.searchTracks('A & B', 10);
  assert.strictEqual(r.tracks.length, 1); assert.strictEqual(r.tracks[0].duration_ms, 180000);
  assert.strictEqual(r.tracks[0].artists, 'Artist');
});
test('Zvuk: albums and playlist hydration preserve duplicates and order', () => {
  const h = load('zvuk', req => {
    const op = JSON.parse(req.body).operationName;
    if (op === 'getPlaylists') return ok({data: {getPlaylists: [{id: 'abc-123', title: 'List', tracks: [{id: 42}, {id: 43}, {id: 42}]}]}});
    if (op === 'getReleases') return ok({data: {getReleases: [{id: 9, title: 'Release', tracks: [ztrack]}]}});
    return ok({data: {getTracks: [Object.assign({}, ztrack, {id: 43}), ztrack]}});
  });
  const list = h.extension.handleUrl('https://zvuk.com/playlist/abc-123?utm=1');
  assert.strictEqual(list.tracks.map(t => t.id).join(','), '42,43,42');
  assert.strictEqual(h.extension.handleUrl('https://zvuk.com/release/9').tracks[0].album_name, 'Release');
  assert.strictEqual(h.extension.handleUrl('https://zvuk.com/track/42').track.id, '42');
});
test('Zvuk: missing playlist tracks and partial GraphQL data fail explicitly', () => {
  const h = load('zvuk', req => JSON.parse(req.body).operationName === 'getPlaylists' ?
    ok({data: {getPlaylists: [{id: '1', tracks: [{id: 42}]}]}}) : ok({data: {getTracks: []}}));
  assert.throws(() => h.extension.getPlaylist('1'), e => e.kind === 'incomplete_playlist');
  assert.throws(() => load('zvuk', () => ok({data: {getTracks: [ztrack]}, errors: [{message: 'fixture-secret'}]})).extension.getTrack('42'), e => !e.message.includes('fixture-secret'));
});
test('Zvuk: each quality requests Tiny API; CDN gets no token', () => {
  for (const quality of ['mid', 'high', 'flac']) {
    const h = load('zvuk', req => {
      if (req.method === 'GET') assert(req.url.endsWith('id=42&quality=' + quality));
      return zvukRoute(req);
    });
    const r = h.extension.download('42', quality, '/tmp/audio');
    assert.strictEqual(r.success, true); assert.strictEqual(r.actual_extension, quality === 'flac' ? 'flac' : 'mp3');
    assert.strictEqual(Object.keys(h.downloads[0].options).length, 0);
  }
});
test('Zvuk: preview, foreign CDN and unsupported streams are rejected', () => {
  for (const payload of [{stream: 'https://evil.test/a'}, {stream: 'https://cdn.zvuk.com/a', preview: true}, {stream: 'https://cdn.zvuk.com/a.m3u8'}, {}]) {
    const h = load('zvuk', req => req.method === 'POST' ? zvukRoute(req) : ok(payload));
    assert.strictEqual(h.extension.download('42', 'high', '/tmp/audio').success, false);
    assert.strictEqual(h.downloads.length, 0);
  }
});
test('VK: music session POST parameters, owner ID and access key', () => {
  const h = load('vk-music', req => {
    assert.strictEqual(req.url, 'https://api.vk.ru/method/audio.getById');
    const params = new URLSearchParams(req.body);
    assert.strictEqual(params.get('audios'), '-7_42_key'); assert.strictEqual(params.get('v'), '8.154');
    assert.strictEqual(params.get('device_id'), 'fixture-device');
    assert.strictEqual(params.get('access_token'), 'fixture-secret');
    return ok({response: [Object.assign({}, vtrack)]});
  });
  assert.strictEqual(h.extension.getTrack('-7_42_key').id, '-7_42_key');
});
test('VK: search maps titles and clamps limit', () => {
  const h = load('vk-music', req => {
    const params = new URLSearchParams(req.body); assert.strictEqual(params.get('count'), '100');
    assert.strictEqual(params.get('q'), 'A & B');
    return ok({response: {count: 1000, items: [Object.assign({}, vtrack, {subtitle: 'Live'})]}});
  });
  const r = h.extension.searchTracks('A & B', 1000);
  assert.strictEqual(r.total, 1000); assert.strictEqual(r.tracks[0].name, 'Track (Live)');
});
test('VK: paginated private playlists preserve session access key', () => {
  const offsets = [];
  const h = load('vk-music', req => {
    const p = new URLSearchParams(req.body);
    assert.strictEqual(p.get('access_key'), 'private');
    if (req.url.endsWith('audio.getPlaylistById')) return ok({response: {title: 'Private'}});
    offsets.push(Number(p.get('offset')));
    return ok({response: {count: 201, items: Array.from({length: p.get('offset') === '0' ? 200 : 1}, () => vtrack)}});
  });
  const r = h.extension.handleUrl('https://vk.ru/music/album/-7_9_private');
  assert.strictEqual(r.type, 'album'); assert.strictEqual(r.tracks.length, 201);
  assert.deepStrictEqual(offsets, [0, 200]);
});
test('VK: canonical and embedded track links', () => {
  for (const link of ['https://vk.com/audio-7_42', 'https://music.vk.ru/audio-7_42', 'https://vk.com/music?z=audio-7_42']) {
    assert.strictEqual(load('vk-music', vkRoute).extension.handleUrl(link).track.id, '-7_42');
  }
});
test('VK: partial playlists and expired sessions produce useful errors', () => {
  const h = load('vk-music', req => ok({response: req.url.endsWith('audio.getPlaylistById') ? {} : {count: 2, items: []}}));
  assert.throws(() => h.extension.getPlaylist('-7_9'), e => e.kind === 'incomplete_playlist');
  for (const error_code of [5, 1114, 1117, 6, 29, 14, 17]) {
    const r = load('vk-music', () => ok({error: {error_code, error_msg: 'fixture-secret'}})).extension.download('-7_42', 'original', '/tmp/audio');
    assert.strictEqual(r.success, false); assert(!r.error_message.includes('fixture-secret'));
  }
});
test('VK: direct MP3 download never sends session to CDN', () => {
  const h = load('vk-music', vkRoute);
  const r = h.extension.download('-7_42', 'original', '/tmp/audio');
  assert.strictEqual(r.success, true); assert.strictEqual(r.actual_extension, 'mp3');
  assert.strictEqual(Object.keys(h.downloads[0].options).length, 0);
});
test('VK: inaccessible, preview and foreign streams cannot report success', () => {
  for (const extra of [{is_preview: true}, {content_restricted: true}, {url: ''}, {url: 'https://evil.test/a.mp3'}]) {
    const h = load('vk-music', () => ok({response: [Object.assign({}, vtrack, extra)]}));
    assert.strictEqual(h.extension.download('-7_42', 'original', '/tmp/audio').success, false);
    assert.strictEqual(h.downloads.length, 0);
  }
});
const CDN = 'https://ps.vkuseraudio.net/dir/list.m3u8';
const media = '#EXTM3U\n#EXTINF:90,\na.ts\n#EXTINF:90,\nb.ts\n#EXT-X-ENDLIST\n';
function hlsRoute(req) {
  if (req.method === 'POST') return ok({response: [Object.assign({}, vtrack, {url: CDN})]});
  assert.strictEqual(Object.keys(req.headers).length, 0);
  return {ok: true, body: media};
}
test('HLS: relative segments assembled and remuxed with cleanup', () => {
  const h = load('vk-music', hlsRoute);
  const r = h.extension.download('-7_42', 'original', '/tmp/audio');
  assert.strictEqual(r.success, true); assert.strictEqual(r.file_path, '/tmp/audio.m4a');
  assert.strictEqual(h.downloads[0].urls.join(','), 'https://ps.vkuseraudio.net/dir/a.ts,https://ps.vkuseraudio.net/dir/b.ts');
  assert(h.removed.includes('/tmp/audio.hls.ts')); assert(h.files.has('/tmp/audio.m4a'));
});
test('HLS: master chooses highest bandwidth; rejects live, preview and foreign key', () => {
  const parse = load('vk-music', vkRoute).context.LibreMusicHls.parse;
  const domains = ['*.vkuseraudio.net'];
  const m = parse('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nb.m3u8\n', CDN, domains);
  assert(m.variants[0].url.endsWith('/b.m3u8'));
  for (const text of [media.replace('#EXT-X-ENDLIST', ''), media.replace('a.ts', 'https://evil.test/a.ts'),
    media.replace('#EXTINF:90,', '#EXT-X-KEY:METHOD=AES-128,URI="https://evil.test/key"\n#EXTINF:90,'),
    media.replace('#EXTINF:90,', '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:90,')]) assert.throws(() => parse(text, CDN, domains));
  const h = load('vk-music', req => req.method === 'POST' ? hlsRoute(req) : {ok: true, body: media.replace(/90/g, '15')});
  assert.strictEqual(h.extension.download('-7_42', 'original', '/tmp/audio').error_type, 'unavailable');
  assert.strictEqual(h.downloads.length, 0);
});
test('HLS: AES-128 uses sequence IV and explicit IV, rotates keys, appends clear audio', () => {
  const key1 = Buffer.alloc(16, 7), key2 = Buffer.alloc(16, 8), plain = Buffer.from('real cryptographic roundtrip fixture');
  const list = '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:42\n#EXT-X-KEY:METHOD=AES-128,URI="key1"\n#EXTINF:90,\na.ts\n#EXT-X-KEY:METHOD=AES-128,URI="key2",IV=0x2b\n#EXTINF:90,\nb.ts\n#EXT-X-ENDLIST\n';
  const h = load('vk-music', req => req.method === 'POST' ? hlsRoute(req) : {ok: true, body: list});
  h.context.fetch = url => ({ok: true, arrayBuffer: () => new Uint8Array(url.endsWith('key1') ? key1 : key2).buffer});
  h.context.file.download = (url, path, options) => {
    assert.strictEqual(Object.keys(options).length, 0);
    const iv = Buffer.alloc(16); iv[15] = url.endsWith('a.ts') ? 42 : 43;
    const cipher = crypto.createCipheriv('aes-128-cbc', url.endsWith('a.ts') ? key1 : key2, iv);
    h.files.set(path, Buffer.concat([cipher.update(plain), cipher.final()])); return {success: true};
  };
  const r = h.extension.download('-7_42', 'original', '/tmp/audio');
  assert.strictEqual(r.success, true); assert.deepStrictEqual(h.files.get(r.file_path), Buffer.concat([plain, plain]));
});
test('HLS: failed FFmpeg conversion removes temporary and partial output', () => {
  const h = load('vk-music', hlsRoute);
  h.context.ffmpeg.convert = () => ({success: false});
  assert.strictEqual(h.extension.download('-7_42', 'original', '/tmp/audio').success, false);
  assert(h.removed.includes('/tmp/audio.m4a')); assert(h.removed.includes('/tmp/audio.hls.ts'));
});
console.log('Passed ' + count + ' offline provider/HLS tests');
