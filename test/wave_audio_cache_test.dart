import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/wave_audio_cache.dart';

Track track(String name) => Track(
  id: name,
  name: name,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 120,
);
void main() {
  test(
    'same-name recordings retain distinct cache files and lookup identity',
    () async {
      final root = await Directory.systemTemp.createTemp('wave-recordings');
      addTearDown(() => root.delete(recursive: true));
      final cache = WaveAudioCache(root);
      const a = Track(
        id: 'deezer:1',
        source: 'deezer',
        name: 'Song',
        artistName: 'Band',
        albumName: 'Studio',
        duration: 180,
      );
      const b = Track(
        id: 'deezer:2',
        source: 'deezer',
        name: 'Song',
        artistName: 'Band',
        albumName: 'Re-recording',
        duration: 180,
      );
      final file = File('${(await cache.directoryFor(a)).path}/audio.flac');
      await file.writeAsBytes([1, 2, 3]);
      await cache.remember(a, file.path);
      expect(await cache.lookup(a), file.path);
      expect(await cache.lookup(b), isNull);
      expect(
        (await cache.directoryFor(a)).path,
        isNot((await cache.directoryFor(b)).path),
      );
    },
  );

  test(
    'concurrent attempts have independent paths and startup pins protect resume',
    () async {
      final root = await Directory.systemTemp.createTemp('wave-attempts');
      addTearDown(() => root.delete(recursive: true));
      final cache = WaveAudioCache(root), item = track('Same');
      final a = await cache.directoryFor(item, attempt: '1'),
          b = await cache.directoryFor(item, attempt: '2');
      expect(a.path, isNot(b.path));
      final completed = File('${b.path}/audio.flac');
      await completed.writeAsBytes(List.filled(20, 1));
      await cache.remember(item, completed.path);
      final restored = WaveAudioCache(root)..limitBytes = 1;
      restored.protectedPaths.add(completed.path);
      await restored.load();
      expect(await restored.lookup(item), completed.path);
    },
  );
  test('cache evicts owned old audio and never touches saved music', () async {
    final parent = await Directory.systemTemp.createTemp('wave-test');
    addTearDown(() => parent.delete(recursive: true));
    final saved = File('${parent.path}/saved.flac');
    await saved.writeAsBytes(List.filled(20, 1));
    final cache = WaveAudioCache(Directory('${parent.path}/wave'))
      ..limitBytes = 30;
    final first = track('First'), second = track('Second');
    final firstFile = File(
      '${(await cache.directoryFor(first)).path}/audio.flac',
    );
    await firstFile.writeAsBytes(List.filled(20, 1));
    await cache.remember(first, firstFile.path);
    final secondFile = File(
      '${(await cache.directoryFor(second)).path}/audio.flac',
    );
    await secondFile.writeAsBytes(List.filled(20, 1));
    cache.protectedPaths.add(secondFile.path);
    await cache.remember(second, secondFile.path);
    expect(await firstFile.exists(), false);
    expect(await secondFile.exists(), true);
    expect(await saved.exists(), true);
    expect(cache.bytes, 20);
    await cache.trim(clear: true);
    expect(await secondFile.exists(), true);
    cache.protectedPaths.clear();
    await cache.trim(clear: true);
    expect(await secondFile.exists(), false);
    expect(await saved.exists(), true);
  });
  test(
    'restart restores completed cache and removes interrupted partials',
    () async {
      final root = await Directory.systemTemp.createTemp('wave-restore');
      addTearDown(() => root.delete(recursive: true));
      final item = track('Song'), cache = WaveAudioCache(root);
      final file = File('${(await cache.directoryFor(item)).path}/audio.flac');
      await file.writeAsBytes([1, 2, 3]);
      await cache.remember(item, file.path);
      final partial = File('${root.path}/interrupted.partial');
      await partial.writeAsBytes([0, 0]);
      final restored = WaveAudioCache(root);
      await restored.load();
      expect(await restored.lookup(item), file.path);
      expect(await partial.exists(), false);
    },
  );
  test('active download files are not removed by cache clearing', () async {
    final root = await Directory.systemTemp.createTemp('wave-active');
    addTearDown(() => root.delete(recursive: true));
    final cache = WaveAudioCache(root);
    final dir = await cache.directoryFor(track('Pending'));
    cache.activeDirectories.add(dir.path);
    final file = File('${dir.path}/audio.partial');
    await file.writeAsBytes([1, 2, 3]);
    await cache.trim(clear: true);
    expect(await file.exists(), true);
    cache.activeDirectories.clear();
    await cache.trim(clear: true);
    expect(await file.exists(), false);
  });
}
