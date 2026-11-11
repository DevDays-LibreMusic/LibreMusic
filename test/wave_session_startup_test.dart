import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/wave_audio_cache.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Storage implements LastfmAccountStorage {
  @override
  Future<String?> readData() async => null;
  @override
  Future<String?> readSession() async => null;
  @override
  Future<void> writeData(String value) async {}
  @override
  Future<void> writeSession(String? value) async {}
}

class _Handler extends BaseAudioHandler implements MusicPlayerHandler {
  _Handler() {
    playbackState.add(
      PlaybackState(
        playing: false,
        queueIndex: 0,
        processingState: AudioProcessingState.ready,
      ),
    );
  }
  @override
  bool externalQueueActive = false;
  @override
  Future<void> stop({bool keepResume = false}) async {}
  void restore(PlayableMedia current) {
    externalQueueActive = current.waveSessionKey != null;
    queue.add([
      current.toMediaItem(),
      const MediaItem(
        id: 'next',
        title: 'Next',
        extras: {'source': '/library/next.flac'},
      ),
    ]);
    mediaItem.add(queue.value.first);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Runtime implements MusicPlayerRuntime {
  @override
  String get unknownTitle => 'Unknown title';
  @override
  String get unknownArtist => 'Unknown artist';
  @override
  MusicPlayerHandler? get handler {
    reads++;
    return _handler;
  }

  MusicPlayerHandler? _handler;
  set handler(MusicPlayerHandler? value) => _handler = value;
  int reads = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Media extends LocalMediaItemNotifier {
  _Media(this.handler);
  final _Handler handler;
  @override
  Stream<MediaItem?> build() => handler.mediaItem.stream;
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const context = WaveContext(
    kind: WaveKind.artist,
    title: 'Slipknot',
    artist: 'Slipknot',
  );
  const track = Track(
    id: 'deezer:1',
    name: 'Duality',
    artistName: 'Slipknot',
    albumName: 'Vol. 3',
    duration: 240,
    source: 'deezer',
  );
  const oldTrack = Track(
    id: 'deezer:2',
    name: 'Old',
    artistName: 'Slipknot',
    albumName: 'Vol. 3',
    duration: 240,
    source: 'deezer',
  );

  for (final handlerFirst in [false, true]) {
    for (final scenario in [
      'wave',
      'stale-inactive-wave',
      'ordinary',
      'different-wave',
    ]) {
      test(
        'real controller startup handlerFirst=$handlerFirst $scenario',
        () async {
          final dir = await Directory.systemTemp.createTemp('wave-startup-');
          addTearDown(() => dir.delete(recursive: true));
          final oldPaths = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _Paths(dir.path);
          addTearDown(() => PathProviderPlatform.instance = oldPaths);
          final cache = WaveAudioCache(Directory('${dir.path}/wave-audio'));
          final file = File(
            '${(await cache.directoryFor(track)).path}/audio.flac',
          );
          await file.writeAsBytes(List.filled(20, 1));
          await cache.remember(track, file.path);
          final old = File(
            '${(await cache.directoryFor(oldTrack)).path}/audio.flac',
          );
          await old.writeAsBytes(List.filled(20, 2));
          await cache.remember(oldTrack, old.path);
          SharedPreferences.setMockInitialValues({
            'wave_session': jsonEncode({
              'context': context.toJson(),
              'active': scenario != 'stale-inactive-wave',
              'mode': 'balanced',
              'cacheLimitBytes': 1,
              'cachePins': [file.path],
            }),
          });
          var media = playableFromTrack(track, file.path);
          if (scenario != 'ordinary') {
            media = media.withWaveSession(
              scenario == 'different-wave' ? 'artist:Other:Other' : context.key,
              track: track,
            );
          }
          final handler = _Handler();
          final runtime = _Runtime();
          if (handlerFirst) {
            runtime.handler = handler;
            handler.restore(media);
          }
          final account = LastfmAccountController(
            service: LastfmAccountService(
              credentials: const LastfmAppCredentials(
                apiKey: '',
                sharedSecret: '',
              ),
            ),
            storage: _Storage(),
            retryInterval: Duration.zero,
          );
          await account.ready;
          final container = ProviderContainer(
            overrides: [
              musicPlayerRuntimeProvider.overrideWithValue(runtime),
              localMediaItemProvider.overrideWith(() => _Media(handler)),
              localPlaybackStateProvider.overrideWith(
                (ref) => handler.playbackState.stream,
              ),
              libraryCollectionsProvider.overrideWith(_Collections.new),
              lastfmAccountProvider.overrideWithValue(account),
            ],
          );
          addTearDown(() async {
            container.dispose();
            account.dispose();
            await handler.queue.close();
            await handler.mediaItem.close();
            await handler.playbackState.close();
          });
          container.listen(waveSessionProvider, (_, _) {});
          final controller = container.read(waveSessionProvider.notifier);
          await controller.ensureLoaded();
          expect(container.read(waveSessionProvider).loaded, isTrue);
          expect(
            await file.exists(),
            isTrue,
            reason: 'Resume pin must be applied before startup cache trim',
          );
          expect(
            await old.exists(),
            isFalse,
            reason: 'Startup must actually enforce the cache limit',
          );
          if (!handlerFirst) {
            runtime.handler = handler;
            handler.restore(media);
          }
          await settle();
          expect(
            container.read(localMediaItemProvider).value?.id,
            media.id,
            reason:
                'The restored handler event must reach the real controller dependency',
          );
          final state = container.read(waveSessionProvider);
          final owned = scenario == 'wave' || scenario == 'stale-inactive-wave';
          expect(
            state.active,
            owned,
            reason:
                'Current persisted media marker is authoritative, independent of startup order',
          );
          expect(handler.externalQueueActive, owned);
          expect(state.context.key, context.key);
          expect(handler.mediaItem.value!.extras?['source'], file.path);
          expect(handler.playbackState.value.playing, isFalse);
          expect(await file.exists(), isTrue);
        },
      );
    }
  }
  test('dispose cancels timer and detaches playback listeners', () async {
    final dir = await Directory.systemTemp.createTemp('wave-dispose-');
    addTearDown(() => dir.delete(recursive: true));
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() => PathProviderPlatform.instance = oldPaths);
    SharedPreferences.setMockInitialValues({});
    final handler = _Handler();
    final runtime = _Runtime()..handler = handler;
    final account = LastfmAccountController(
      service: LastfmAccountService(
        credentials: const LastfmAppCredentials(apiKey: '', sharedSecret: ''),
      ),
      storage: _Storage(),
      retryInterval: Duration.zero,
    );
    await account.ready;
    final timers = <Timer>[];
    late ProviderContainer container;
    await runZoned(
      () async {
        container = ProviderContainer(
          overrides: [
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            localMediaItemProvider.overrideWith(() => _Media(handler)),
            localPlaybackStateProvider.overrideWith(
              (ref) => handler.playbackState.stream,
            ),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            lastfmAccountProvider.overrideWithValue(account),
          ],
        );
        container.listen(waveSessionProvider, (_, _) {});
        await container.read(waveSessionProvider.notifier).ensureLoaded();
        await settle();
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(timers.where((timer) => timer.isActive), isNotEmpty);
    container.dispose();
    final readsAtDispose = runtime.reads;
    expect(timers.every((timer) => !timer.isActive), isTrue);
    handler.restore(playableFromTrack(track, '/library/duality.flac'));
    handler.playbackState.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        queueIndex: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await settle();
    expect(
      runtime.reads,
      readsAtDispose,
      reason: 'Disposed listeners and timer must not observe later playback',
    );
    account.dispose();
    await handler.queue.close();
    await handler.mediaItem.close();
    await handler.playbackState.close();
  });
}
