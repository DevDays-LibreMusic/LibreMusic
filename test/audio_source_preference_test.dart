import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/audio_source_preference.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory work;
  late File a, b;
  late AudioSourcePreference service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    work = await Directory.systemTemp.createTemp('source-preference-test');
    a = await File('${work.path}/a').writeAsString('original audio');
    b = await File('${work.path}/b').writeAsString('fuller audio');
    service = AudioSourcePreference();
  });
  tearDown(() => work.delete(recursive: true));

  Future<bool> save(AudioSourcePair pair, AudioSourcePreferenceVerdict side) =>
      service.saveConfirmed(
        pair,
        side,
        directionModelSha256: AudioVersionDemucsRunner.modelSha256,
        contentModelSha256: AudioVersionLearnedRunner.modelSha256,
      );

  test('confirmed pair persists, swapped pair preserves direction', () async {
    final pair = (await service.capture(a.path, b.path))!;
    expect(await save(pair, AudioSourcePreferenceVerdict.b), isTrue);
    expect(await AudioSourcePreference().preferredSource(a.path), b.path);
    expect(await service.preferredSource(b.path), b.path);
    final swapped = (await service.capture(b.path, a.path))!;
    expect(await save(swapped, AudioSourcePreferenceVerdict.a), isTrue);
    expect(await service.preferredSource(a.path), b.path);
  });

  test('unknown does not erase a confirmed preference', () async {
    final pair = (await service.capture(a.path, b.path))!;
    await save(pair, AudioSourcePreferenceVerdict.b);
    expect(await save(pair, AudioSourcePreferenceVerdict.unknown), isFalse);
    expect(await service.preferredSource(a.path), b.path);
  });

  test('source byte replacement invalidates even with same size', () async {
    final pair = (await service.capture(a.path, b.path))!;
    await save(pair, AudioSourcePreferenceVerdict.b);
    await a.writeAsString('replaced audio');
    expect(await service.preferredSource(a.path), isNull);
    expect(await save(pair, AudioSourcePreferenceVerdict.b), isFalse);
  });

  test(
    'missing preferred file falls back and URL is never a file identity',
    () async {
      final pair = (await service.capture(a.path, b.path))!;
      await save(pair, AudioSourcePreferenceVerdict.b);
      await b.delete();
      expect(await service.preferredSource(a.path), isNull);
      expect(
        await service.capture(a.path, 'https://example.com/audio'),
        isNull,
      );
      expect(await service.preferredSource('${a.path}-other'), isNull);
    },
  );

  test(
    'provider binding is scoped to exact provider/item and retained bytes',
    () async {
      final pair = (await service.capture(a.path, b.path))!;
      await service.saveConfirmed(
        pair,
        AudioSourcePreferenceVerdict.b,
        directionModelSha256: AudioVersionDemucsRunner.modelSha256,
        contentModelSha256: AudioVersionLearnedRunner.modelSha256,
        providerA: AudioProviderSource(
          'one',
          '123',
          materializedDigest: pair.digestA,
        ),
        providerB: AudioProviderSource(
          'two',
          '456',
          materializedDigest: pair.digestB,
        ),
      );
      expect(await service.preferredProviderSource('one', '123'), b.path);
      expect(await service.preferredProviderSource('one', '456'), isNull);
      expect(await service.preferredProviderSource('other', '123'), isNull);
      await b.writeAsString('changed');
      expect(await service.preferredProviderSource('one', '123'), isNull);
    },
  );

  test(
    'playback resolver consumes provider preference before library/download lookup',
    () async {
      final pair = (await service.capture(a.path, b.path))!;
      await service.saveConfirmed(
        pair,
        AudioSourcePreferenceVerdict.b,
        directionModelSha256: AudioVersionDemucsRunner.modelSha256,
        contentModelSha256: AudioVersionLearnedRunner.modelSha256,
        providerA: AudioProviderSource(
          'one',
          '123',
          materializedDigest: pair.digestA,
        ),
        providerB: AudioProviderSource(
          'two',
          '456',
          materializedDigest: pair.digestB,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final paths = await container
          .read(playbackProvider.notifier)
          .resolveTrackFilePaths([
            const Track(
              id: '123',
              source: 'one',
              name: 'Same title',
              artistName: 'Artist',
              albumName: '',
              duration: 60,
            ),
          ]);
      expect(paths, [b.path]);
    },
  );

  test('unrecognized model cannot save evidence', () async {
    final pair = (await service.capture(a.path, b.path))!;
    expect(
      await service.saveConfirmed(
        pair,
        AudioSourcePreferenceVerdict.b,
        directionModelSha256: 'different model',
        contentModelSha256: AudioVersionLearnedRunner.modelSha256,
      ),
      isFalse,
    );
    expect(await service.preferredSource(a.path), isNull);
  });
}
