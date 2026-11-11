// SPDX-License-Identifier: LGPL-3.0-only
// Run unchanged synchronous upstream catalog tests against the direct fork.
// The adapter supports Node 12 developer hosts without changing upstream files.
const fs = require('fs'), path = require('path'), vm = require('vm');
const base = path.resolve(__dirname, '..');
let passed = 0;
for (const filename of ['amazon_session.test.cjs', 'ytmusic_related_tracks.test.cjs']) {
  const testPath = path.join(base, 'upstream-mornye/tests', filename);
  const wrappedFS = Object.assign({}, fs, {readFileSync(file, options) {
    file = String(file);
    if (file.includes('/sources/amazon/')) file = file.replace('/upstream-mornye/sources/amazon/', '/amazon-direct/');
    if (file.includes('/sources/ytmusic-spotiflac/')) file = file.replace('/upstream-mornye/sources/ytmusic-spotiflac/', '/ytmusic-direct/');
    return fs.readFileSync(file, options);
  }});
  function localRequire(name) {
    if (name === 'node:test') return function (title, fn) {
      if (typeof fn !== 'function') throw Error('Unsupported upstream test signature');
      const result = fn();
      if (result && typeof result.then === 'function') throw Error('Async upstream test needs Node 22');
      console.log('ok ' + (++passed) + ' - ' + title);
    };
    if (name === 'node:assert/strict') return require('assert').strict;
    if (name === 'node:fs') return wrappedFS;
    return require(name.replace(/^node:/, ''));
  }
  const source = fs.readFileSync(testPath, 'utf8').replace(/ytmusic-spotiflac/g, 'ytmusic-direct');
  // Source path replacement above must also recognize the renamed provider in tests.
  const originalRead = wrappedFS.readFileSync;
  wrappedFS.readFileSync = (p, options) => originalRead(String(p).replace('/upstream-mornye/sources/ytmusic-direct/', '/ytmusic-direct/'), options);
  vm.runInNewContext(source, {require: localRequire, __dirname: path.dirname(testPath), URL, URLSearchParams, console, Buffer, setTimeout, clearTimeout}, {filename: testPath});
}
console.log('Passed ' + passed + ' inherited catalog regression tests');
