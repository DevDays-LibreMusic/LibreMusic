// SPDX-License-Identifier: LGPL-3.0-only
const assert = require('assert'), fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const root = __dirname + '/..';
const providers = ['qobuz-direct', 'tidal-direct', 'beatport-direct'];
let count = 0;
function test(name, run) { run(); console.log('ok ' + (++count) + ' - ' + name); }
const ok = value => ({ok: true, statusCode: 200, body: JSON.stringify(value)});
const raw = {
  'qobuz-direct': {id: 42, title: 'Track', duration: 180, performer: {name: 'Artist'}, album: {id: 'a9', title: 'Album'}},
  'tidal-direct': {id: 42, title: 'Track', duration: 180, artists: [{name: 'Artist'}], album: {id: 9, title: 'Album'}},
  'beatport-direct': {id: 42, name: 'Track', length_ms: 180000, artists: [{name: 'Artist'}], release: {id: 9, name: 'Album'}}
};
function response(provider, req) {
  const url = new URL(req.url);
  if (url.pathname.endsWith('/track/getFileUrl')) return ok({url: 'https://audio.qobuz.com/full', track_id: 42, format_id: Number(url.searchParams.get('format_id'))});
  if (url.pathname.endsWith('/playbackinfopostpaywall')) {
    const lossless = url.searchParams.get('audioquality') === 'LOSSLESS';
    return ok({trackId: 42, audioQuality: lossless ? 'LOSSLESS' : 'HIGH', assetPresentation: 'FULL', manifestMimeType: 'application/vnd.tidal.bts',
      manifest: Buffer.from(JSON.stringify({encryptionType: 'NONE', codecs: lossless ? 'flac' : 'mp4a.40.2', urls: ['https://audio.tidal.com/full']})).toString('base64')});
  }
  if (url.pathname.endsWith('/download/')) return ok({location: 'https://geo-downloads.beatport.com/full', stream_quality: url.searchParams.get('quality') === 'lossless' ? '.flac' : '.256k.aac.mp4'});
  return ok(raw[provider]);
}
function load(provider, route, settings) {
  let extension;
  const calls = [], downloads = [], deleted = [];
  const source = ['shared/provider.js', 'shared/direct.js', provider + '/index.js'].map(p => fs.readFileSync(root + '/' + p, 'utf8')).join('\n');
  const context = {
    URL, Date,
    http: {get: (url, headers) => { const req = {url, headers}; calls.push(req); return (route || (r => response(provider, r)))(req); }},
    file: {download: (url, path, options) => { downloads.push({url, path, options}); return {success: true}; }, delete: p => { deleted.push(p); return {success: true}; }},
    ffmpeg: {getInfo: () => ({success: true, codec: 'flac', duration: 180, bit_depth: 24, sample_rate: 96000})},
    utils: {md5: value => crypto.createHash('md5').update(value).digest('hex'), base64Decode: s => Buffer.from(s, 'base64').toString()},
    registerExtension: e => { extension = e; }
  };
  vm.runInNewContext(source, context, {timeout: 1500});
  extension.initialize(settings || {token: 'account-fixture', appId: '123', appSecret: 'secret-fixture', country: 'US'});
  return {extension, context, calls, downloads, deleted};
}
for (const provider of providers) {
  const quality = provider === 'beatport-direct' ? 'lossless' : 'flac';
  test(provider + ': fresh registration, no eager account requests', () => {
    const h = load(provider); assert.strictEqual(h.calls.length, 0);
    const m = JSON.parse(fs.readFileSync(root + '/' + provider + '/manifest.json'));
    assert.strictEqual(m.name, provider); assert(!m.signedSession); assert(!m.permissions.network.includes('*'));
    assert(m.settings.find(s => s.key === 'token').secret);
  });
  test(provider + ': search catalog mapping and stable provider identity', () => {
    const h = load(provider, req => {
      const u = new URL(req.url); assert.strictEqual(u.searchParams.get(provider === 'beatport-direct' ? 'q' : 'query'), 'A & B');
      if (provider === 'qobuz-direct') return ok({tracks: {items: [raw[provider]], total: 1}});
      if (provider === 'tidal-direct') return ok({items: [raw[provider]], totalNumberOfItems: 1});
      return ok({tracks: [raw[provider]]});
    });
    const t = h.extension.searchTracks('A & B', 10).tracks[0];
    assert.strictEqual(t.provider_id, provider); assert.strictEqual(t.duration_ms, 180000); assert.strictEqual(t.artists, 'Artist');
    assert.strictEqual(h.extension.searchTracks(' ').tracks.length, 0);
  });
  test(provider + ': missing credentials and cleanup require login', () => {
    const h = load(provider, () => { throw Error('No network allowed'); }, {});
    assert.throws(() => h.extension.getTrack('42'), e => e.kind === 'auth_required');
    h.extension.initialize({token: 'fixture', appId: '123', appSecret: 'fixture'}); h.extension.cleanup();
    assert.throws(() => h.extension.getTrack('42'), e => e.kind === 'auth_required');
    assert.strictEqual(h.calls.length, 0);
  });
  test(provider + ': account token stays on API, download metadata is measured', () => {
    const h = load(provider);
    const r = h.extension.download('42', quality, '/tmp/audio');
    assert.strictEqual(r.success, true); assert.strictEqual(r.audio_codec, 'flac'); assert.strictEqual(r.bit_depth, 24);
    assert.strictEqual(Object.keys(h.downloads[0].options).length, 0);
    h.calls.forEach(c => assert(!c.url.includes('account-fixture') && !c.url.includes('secret-fixture')));
    assert(h.calls.every(c => provider === 'qobuz-direct' ? c.headers['X-User-Auth-Token'] === 'account-fixture' : c.headers.Authorization === 'Bearer account-fixture'));
  });
  test(provider + ': rejects foreign IDs, HTTP, credential-bearing URLs', () => {
    const h = load(provider, () => { throw Error('Unexpected network'); });
    assert.throws(() => h.extension.getTrack('../../account'));
    assert.strictEqual(h.extension.checkAvailability('', '', '', {track: {id: '42', source: 'other'}}).available, false);
    for (const url of ['https://evil.test/track/42', 'https://token@www.qobuz.com/track/42', 'http://tidal.com/track/42']) assert.strictEqual(h.extension.handleUrl(url), null);
  });
  test(provider + ': API errors do not expose credential values', () => {
    for (const statusCode of [401, 403, 429, 500]) {
      const h = load(provider, () => ({ok: false, statusCode, body: 'account-fixture'}));
      const r = h.extension.download('42', quality, '/tmp/audio'); assert.strictEqual(r.success, false); assert(!r.error_message.includes('account-fixture')); assert.strictEqual(h.downloads.length, 0);
    }
  });
  test(provider + ': partial download and preview duration remove output', () => {
    for (const stage of ['cancel', 'preview', 'codec']) {
      const h = load(provider);
      if (stage === 'cancel') h.context.file.download = () => ({success: false, error_type: 'cancelled'});
      else h.context.ffmpeg.getInfo = () => ({success: true, codec: stage === 'codec' ? 'mp3' : 'flac', duration: 30});
      assert.strictEqual(h.extension.download('42', quality, '/tmp/audio').success, false);
      assert(h.deleted.includes('/tmp/audio.flac'));
    }
  });
}
test('Qobuz: exact signed getFileUrl request and refusal to lower quality', () => {
  const h = load('qobuz-direct', req => {
    const u = new URL(req.url);
    if (u.pathname.endsWith('getFileUrl')) {
      const expected = 'trackgetFileUrlformat_id27intentstreamtrack_id42' + u.searchParams.get('request_ts') + 'secret-fixture';
      assert.strictEqual(u.searchParams.get('request_sig'), crypto.createHash('md5').update(expected).digest('hex'));
      return ok({url: 'https://audio.qobuz.com/full', track_id: 42, format_id: 5});
    }
    return response('qobuz-direct', req);
  });
  assert.strictEqual(h.extension.download('42', 'flac-192', '/tmp/audio').error_type, 'unavailable'); assert.strictEqual(h.downloads.length, 0);
});
test('Tidal: encrypted, preview, wrong track and DASH manifests are rejected', () => {
  for (const change of ['encrypted', 'preview', 'track', 'dash', 'foreign']) {
    const h = load('tidal-direct', req => {
      const r = response('tidal-direct', req); if (!req.url.includes('playbackinfopostpaywall')) return r;
      const data = JSON.parse(r.body), m = JSON.parse(Buffer.from(data.manifest, 'base64'));
      if (change === 'encrypted') m.encryptionType = 'OLD_AES';
      if (change === 'preview') data.assetPresentation = 'PREVIEW';
      if (change === 'track') data.trackId = 43;
      if (change === 'dash') data.manifestMimeType = 'application/dash+xml';
      if (change === 'foreign') m.urls = ['https://evil.test/full'];
      data.manifest = Buffer.from(JSON.stringify(m)).toString('base64'); return ok(data);
    });
    assert.strictEqual(h.extension.download('42', 'flac', '/tmp/audio').success, false); assert.strictEqual(h.downloads.length, 0);
  }
});
test('Tidal: absent optional presentation uses FULL request and measured duration', () => {
  const h = load('tidal-direct', req => {
    const r = response('tidal-direct', req);
    if (!req.url.includes('playbackinfopostpaywall')) return r;
    assert.strictEqual(new URL(req.url).searchParams.get('assetpresentation'), 'FULL');
    const data = JSON.parse(r.body); delete data.assetPresentation; return ok(data);
  });
  assert.strictEqual(h.extension.download('42','flac','/tmp/audio').success, true);
  h.context.ffmpeg.getInfo = () => ({success: true, codec: 'flac', duration: 0});
  assert.strictEqual(h.extension.download('42','flac','/tmp/audio').error_type, 'invalid_audio');
});
test('Beatport: quality mismatch cannot use preview or report FLAC', () => {
  const h = load('beatport-direct', req => req.url.includes('/download/') ? ok({location: 'https://geo-samples.beatport.com/preview', stream_quality: '.128k.aac.mp4'}) : response('beatport-direct', req));
  assert.strictEqual(h.extension.download('42', 'lossless', '/tmp/audio').error_type, 'unavailable'); assert.strictEqual(h.downloads.length, 0);
});
test('collections paginate, retain duplicates, reject incomplete pages', () => {
  for (const p of providers) {
    let pages = 0;
    const h = load(p, req => {
      const u = new URL(req.url);
      if (p === 'qobuz-direct') return ok({id: 'a9', title: 'Album', tracks: {total: 2, items: [raw[p]]}});
      if (p === 'tidal-direct') return u.pathname.endsWith('/tracks') ? (++pages, ok({totalNumberOfItems: 2, items: [raw[p]]})) : ok({id: 9, title: 'Album', numberOfTracks: 2});
      return u.pathname.endsWith('/tracks/') ? (++pages, ok({count: 2, results: [raw[p]]})) : ok({id: 9, name: 'Album', track_count: 2});
    });
    const r = h.extension.getAlbum(p === 'qobuz-direct' ? 'a9' : '9'); assert.strictEqual(r.tracks.length, 2); assert.strictEqual(r.tracks[0].id, r.tracks[1].id);
    if (p !== 'qobuz-direct') assert.strictEqual(pages, 2);
  }
  const h = load('qobuz-direct', () => ok({id: 'a9', tracks: {total: 1, items: []}}));
  assert.throws(() => h.extension.getAlbum('a9'), e => e.kind === 'incomplete_playlist');
});
function fork(provider) {
  let extension; const calls = [], downloaded = [];
  const context = {URL, URLSearchParams, Map, Set, console,
    registerExtension: e => { extension = e; }, log: {info(){},debug(){},warn(){},error(){}},
    utils: {isDownloadCancelled: () => false, sleep(){}, randomUserAgent: () => 'fixture'},
    storage: {get(){},set(){}}, http: {clearCookies(){}},
    file: {download: (url, path) => { downloaded.push({url,path}); return {success: true, path}; }},
    fetch: (url, options) => { calls.push({url,options}); if (new URL(url).pathname === '/config.json') return {ok: true, status: 200, json: () => ({deviceId:'fixture',sessionId:'fixture',csrf:{token:'fixture',ts:'1',rnd:'2'}})}; throw Error('Unexpected network'); }
  };
  vm.runInNewContext(fs.readFileSync(root + '/' + provider + '/index.js', 'utf8'), context, {timeout: 2000});
  return {extension, context, calls, downloaded};
}
test('Amazon Direct exposes catalog only, initializes against Amazon, maps provider ID', () => {
  const h = fork('amazon-direct'); h.extension.initialize({});
  assert.strictEqual(h.extension.download, undefined); assert.strictEqual(h.extension.completeGrant, undefined);
  assert(h.calls.length > 0); assert(h.calls.every(c => new URL(c.url).hostname === 'music.amazon.com'));
  const t = h.context.formatAmazonTrackMetadata({id:'B012345678',title:'Track',artists:'Artist'}, null, 1);
  assert.strictEqual(t.provider_id, 'amazon-direct');
  const m = JSON.parse(fs.readFileSync(root + '/amazon-direct/manifest.json')); assert.deepStrictEqual(m.type, ['metadata_provider']); assert(!m.qualityOptions);
});
test('YouTube Direct succeeds through InnerTube, never invokes a resolver after failure', () => {
  const h = fork('ytmusic-direct'); h.extension.initialize({});
  h.context.getYouTubePageInfo = () => ({}); h.context.resolveDownloadCoverUrl = () => '';
  h.context.tryInnerTubeDownloadsLazily = () => ({success: true, file_path:'/tmp/song.opus',audio_codec:'opus'});
  assert.strictEqual(h.extension.download('abcdefghijk','best','/tmp/song').success, true);
  h.context.tryInnerTubeDownloadsLazily = () => null;
  assert.strictEqual(h.extension.download('abcdefghijk','best','/tmp/song').error_type, 'unavailable');
  assert.strictEqual(h.calls.length, 0);
  assert.strictEqual(h.context.requestCobaltAudioDownload, undefined); assert.strictEqual(h.context.requestYt1dAudioDownload, undefined);
});
test('YouTube Direct download guard rejects lookalike CDN and keeps manual PO token local', () => {
  const h = fork('ytmusic-direct'); h.extension.initialize({poTokenMode:'manual',manualGvsPoToken:'fixture-token'});
  assert.strictEqual(h.context.getGvsPoToken('abcdefghijk',{requiresGvsPoToken:true,name:'web'}), 'fixture-token');
  for (const url of ['https://googlevideo.com.evil.test/x','http://r.googlevideo.com/x','https://evilgooglevideo.com/x']) assert.throws(() => h.context.downloadAudioURL(url,'/tmp/song','.opus',{}));
  h.context.downloadAudioURL('https://r.googlevideo.com/x','/tmp/song','.opus',{}); assert.strictEqual(h.downloaded.length, 1);
  h.extension.cleanup(); assert.strictEqual(h.context.getGvsPoToken('abcdefghijk',{requiresGvsPoToken:true,name:'web'}), '');
});
test('all five direct manifests and executable sources contain no Zarz endpoints', () => {
  for (const p of providers.concat(['amazon-direct','ytmusic-direct'])) {
    const text = fs.readFileSync(root + '/' + p + '/index.js','utf8') + fs.readFileSync(root + '/' + p + '/manifest.json','utf8');
    assert(!/api\.zarz\.moe|signedFetch|X-Zarz|sessionGrant|signedSession/.test(text), p);
    const m = JSON.parse(fs.readFileSync(root + '/' + p + '/manifest.json'));
    assert.strictEqual(m.name, p); assert(!m.permissions.network.includes('*'));
  }
});
console.log('Passed ' + count + ' direct-provider tests');
