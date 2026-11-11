import 'dart:async';
import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/lastfm_wave_service.dart';
import 'package:mornye/services/music_player_service.dart';

class _Handler extends BaseAudioHandler implements MusicPlayerHandler {
  _Handler() {
    playbackState.add(
      PlaybackState(
        queueIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
      ),
    );
  }
  @override
  bool externalQueueActive = false;
  @override
  int playbackRequestGeneration = 0;
  @override
  Future<void> stop({bool keepResume = false}) async {}
  @override
  void Function(PlayableMedia)? onExplicitNext;
  @override
  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool? shuffle,
    bool externalQueue = false,
  }) async {
    playbackRequestGeneration++;
    externalQueueActive = externalQueue;
    queue.add(items.map((i) => i.toMediaItem()).toList());
    mediaItem.add(queue.value.first);
  }

  @override
  Future<void> replaceUpcoming(
    List<PlayableMedia> items, {
    String? waveSessionKey,
  }) async {
    queue.add([
      if (mediaItem.value != null) mediaItem.value!,
      ...items.map((i) => i.toMediaItem()),
    ]);
  }

  @override
  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    queue.add([...queue.value, ...items.map((i) => i.toMediaItem())]);
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> skipToNext() async {
    if (queue.value.length > 1) mediaItem.add(queue.value[1]);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Runtime implements MusicPlayerRuntime {
  _Runtime(this.handler);
  @override
  final MusicPlayerHandler handler;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Player extends MusicPlayerController {
  _Player(this.handler);
  final MusicPlayerHandler handler;
  @override
  Future<MusicPlayerHandler?> ensureInitialized() async => handler;
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

class _Wave extends WaveSessionController {
  _Wave({
    required super.service,
    required super.prepareAudio,
    required super.libraryLoader,
  }) : super(
         resolveCandidate: (candidate) async => Track(
           id: candidate.title,
           name: candidate.title,
           artistName: candidate.artist,
           albumName: 'Album',
           duration: 180,
         ),
       );
  @override
  Future<void> ensureLoaded() async {}
  @override
  WaveSessionState build() {
    return const WaveSessionState(loaded: true);
  }
}

PlayableMedia media(Track track) => PlayableMedia(
  id: track.id,
  source: '/cache/${track.id}.flac',
  title: track.name,
  artist: track.artistName,
  duration: const Duration(seconds: 180),
);
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => ['wifi'],
        );
  });
  Future<
    ({
      ProviderContainer container,
      _Handler handler,
      WaveSessionController wave,
    })
  >
  harness(
    Future<PlayableMedia?> Function(Track) prepare, {
    Future<List<PlayableMedia>> Function(PlayableMedia)? libraryLoader,
  }) async {
    final handler = _Handler();
    final service = LastfmWaveService(
      client: MockClient((request) async {
        final method = request.url.queryParameters['method'];
        return http.Response(
          jsonEncode(
            method == 'artist.getSimilar'
                ? {
                    'similarartists': {'artist': <Object>[]},
                  }
                : {
                    (method == 'track.getSimilar'
                        ? 'similartracks'
                        : method == 'tag.getTopTracks'
                        ? 'tracks'
                        : 'toptracks'): {
                      'track': [
                        for (var i = 0; i < 15; i++)
                          {
                            'name': 'Track $i',
                            'artist': {'name': 'Artist $i'},
                          },
                      ],
                    },
                  },
          ),
          200,
        );
      }),
    );
    final account = LastfmAccountController(
      service: LastfmAccountService(
        credentials: const LastfmAppCredentials(
          apiKey: 'key',
          sharedSecret: 'secret',
        ),
      ),
      storage: _Storage(),
    );
    await account.ready;
    final container = ProviderContainer(
      overrides: [
        musicPlayerRuntimeProvider.overrideWithValue(_Runtime(handler)),
        musicPlayerControllerProvider.overrideWithValue(_Player(handler)),
        lastfmAccountProvider.overrideWithValue(account),
        lastfmAppCredentialsProvider.overrideWithValue(
          const LastfmAppCredentials(apiKey: 'key', sharedSecret: 'secret'),
        ),
        waveSessionProvider.overrideWith(
          () => _Wave(
            service: service,
            prepareAudio: prepare,
            libraryLoader: libraryLoader ?? (_) async => [],
          ),
        ),
      ],
    );
    addTearDown(() async {
      await settle();
      container.dispose();
      service.dispose();
      account.dispose();
      await handler.queue.close();
      await handler.mediaItem.close();
      await handler.playbackState.close();
    });
    return (
      container: container,
      handler: handler,
      wave: container.read(waveSessionProvider.notifier),
    );
  }

  for (final kind in [
    WaveKind.track,
    WaveKind.artist,
    WaveKind.album,
    WaveKind.genre,
  ]) {
    test(
      '$kind failures keep current song without unrelated Library fallback',
      () async {
        var libraryCalls = 0;
        var prepareCalls = 0;
        final h = await harness(
          (_) async {
            prepareCalls++;
            return null;
          },
          libraryLoader: (_) async {
            libraryCalls++;
            return [
              const PlayableMedia(
                id: 'unrelated',
                source: '/manual/unrelated.flac',
                title: 'Unrelated',
                artist: 'Other',
              ),
            ];
          },
        );
        const seed = Track(
          id: 'seed',
          name: 'Duality',
          artistName: 'Slipknot',
          albumName: 'Album',
          duration: 180,
        );
        await h.handler.setQueueAndPlay([media(seed)]);
        await h.wave.start(
          WaveContext(
            kind: kind,
            title: 'Slipknot',
            artist: 'Slipknot',
            track: seed,
            albumTracks: [seed],
          ),
          preserveCurrent: true,
        );
        await settle();
        expect(prepareCalls, 8);
        expect(libraryCalls, 0);
        expect(h.handler.queue.value.map((item) => item.id), ['seed']);
        expect(h.handler.mediaItem.value?.id, 'seed');
        final state = h.container.read(waveSessionProvider);
        expect(state.context.kind, kind);
        expect(state.offline, isFalse);
        expect(state.error, isNotNull);
      },
    );
  }

  for (final offline in [false, true]) {
    test(
      'personal wave saved fallback reports actual connectivity (offline: $offline)',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('dev.fluttercommunity.plus/connectivity'),
              (_) async => [offline ? 'none' : 'wifi'],
            );
        final h = await harness(
          (_) async => null,
          libraryLoader: (_) async => [
            const PlayableMedia(
              id: 'saved',
              source: '/manual/saved.flac',
              title: 'Saved',
              artist: 'Artist',
            ),
          ],
        );
        const seed = Track(
          id: 'seed',
          name: 'Seed',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        );
        await h.handler.setQueueAndPlay([media(seed)]);
        await h.wave.start(const WaveContext(), preserveCurrent: true);
        await settle();
        expect(h.handler.queue.value.map((item) => item.id), contains('saved'));
        expect(h.container.read(waveSessionProvider).offline, offline);
      },
    );
  }

  test('new local queue wins over pending wave preparation', () async {
    final pending = Completer<PlayableMedia?>();
    final seed = Track(
      id: 'seed',
      name: 'Seed',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    );
    final h = await harness((_) => pending.future);
    final starting = h.wave.start(
      WaveContext(kind: WaveKind.track, title: 'Seed', track: seed),
    );
    await settle();
    expect(h.container.read(waveSessionProvider).busy, isTrue);
    await h.handler.setQueueAndPlay([
      const PlayableMedia(
        id: 'local-flow',
        source: '/local/flow.flac',
        title: 'Local flow',
        artist: 'Artist',
      ),
    ]);
    pending.complete(media(seed));
    await starting;
    await settle();
    expect(h.handler.queue.value.map((item) => item.title), ['Local flow']);
    expect(h.handler.externalQueueActive, isFalse);
    expect(h.container.read(waveSessionProvider).active, isFalse);
    expect(h.container.read(waveSessionProvider).busy, isFalse);
  });

  test(
    'excluding an in-flight candidate cannot enqueue it after completion',
    () async {
      final pending = Completer<PlayableMedia?>();
      Track? blocked;
      var count = 0;
      final h = await harness((track) async {
        count++;
        if (count == 2) {
          blocked = track;
          return pending.future;
        }
        return media(track);
      });
      await h.wave.start(
        const WaveContext(kind: WaveKind.artist, title: 'Seed'),
      );
      await settle();
      expect(blocked, isNotNull);
      await h.wave.excludeTrack(blocked!);
      await settle();
      pending.complete(media(blocked!));
      await settle();
      expect(h.handler.queue.value.any((i) => i.id == blocked!.id), false);
      expect(h.handler.queue.value.length, 2);
    },
  );

  test(
    'exclusion cancels delayed start without leaving busy or changing context',
    () async {
      final pending = Completer<PlayableMedia?>();
      var delay = false;
      final h = await harness(
        (track) async => delay ? pending.future : media(track),
      );
      await h.wave.start(
        const WaveContext(kind: WaveKind.artist, title: 'Original'),
      );
      await settle();
      final original = h.handler.mediaItem.value;
      delay = true;
      const selected = Track(
        id: 'selected',
        name: 'Selected',
        artistName: 'Other',
        albumName: '',
        duration: 180,
      );
      final starting = h.wave.start(
        const WaveContext(
          kind: WaveKind.track,
          title: 'Selected',
          track: selected,
        ),
      );
      await settle();
      expect(h.container.read(waveSessionProvider).busy, true);
      delay = false;
      await h.wave.excludeTrack(selected);
      expect(h.container.read(waveSessionProvider).busy, false);
      pending.complete(media(selected));
      await starting;
      expect(h.container.read(waveSessionProvider).context.title, 'Original');
      expect(h.handler.mediaItem.value, original);
      expect(
        h.handler.queue.value.any((item) => item.id == selected.id),
        false,
      );
    },
  );
  test(
    'excluding audible song pauses it while replacement is prepared',
    () async {
      final waiting = Completer<PlayableMedia?>();
      var hold = false;
      final h = await harness(
        (track) async => hold ? waiting.future : media(track),
      );
      await h.wave.start(
        const WaveContext(kind: WaveKind.artist, title: 'Original'),
      );
      await settle();
      final item = h.handler.mediaItem.value!;
      hold = true;
      final excluding = h.wave.excludeTrack(
        Track(
          id: item.id,
          name: item.title,
          artistName: item.artist!,
          albumName: '',
          duration: 180,
        ),
      );
      await settle();
      expect(h.handler.playbackState.value.playing, false);
      waiting.complete(null);
      await excluding;
      expect(h.handler.playbackState.value.playing, false);
      expect(h.container.read(waveSessionProvider).error, isNotNull);
    },
  );
  test(
    'starting another recording with the same title plays that exact recording',
    () async {
      final h = await harness((track) async => media(track));
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
      await h.wave.start(
        const WaveContext(kind: WaveKind.track, title: 'Song', track: a),
      );
      await settle();
      expect(h.handler.mediaItem.value!.id, a.id);
      await h.wave.start(
        const WaveContext(kind: WaveKind.track, title: 'Song', track: b),
      );
      expect(h.handler.mediaItem.value!.id, b.id);
    },
  );
  test(
    'current item action preserves paused local source and position without catalog tags',
    () async {
      final h = await harness((track) async => media(track));
      const item = MediaItem(
        id: '/library/song.flac',
        title: 'Song',
        artist: 'Band',
        duration: Duration(seconds: 180),
      );
      h.handler.queue.add([item]);
      h.handler.mediaItem.add(item);
      h.handler.playbackState.add(
        PlaybackState(
          queueIndex: 0,
          playing: false,
          updatePosition: const Duration(seconds: 80),
          processingState: AudioProcessingState.ready,
        ),
      );
      const selected = Track(
        id: 'deezer:1',
        source: 'deezer',
        name: 'Song',
        artistName: 'Band',
        albumName: 'Studio',
        duration: 180,
      );
      await h.wave.start(
        const WaveContext(kind: WaveKind.track, title: 'Song', track: selected),
        currentItemId: item.id,
      );
      expect(h.handler.mediaItem.value!.id, item.id);
      expect(h.handler.playbackState.value.playing, false);
      expect(
        h.handler.playbackState.value.updatePosition,
        const Duration(seconds: 80),
      );
    },
  );
  test(
    'failed first candidate keeps previous queue and wave ownership',
    () async {
      var succeed = true;
      final h = await harness((track) async => succeed ? media(track) : null);
      await h.wave.start(
        const WaveContext(kind: WaveKind.artist, title: 'Original'),
      );
      await settle();
      final before = h.handler.mediaItem.value;
      succeed = false;
      await h.wave.start(
        WaveContext(
          kind: WaveKind.track,
          title: 'Missing',
          track: const Track(
            id: 'missing',
            name: 'Missing',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
        ),
      );
      expect(h.handler.mediaItem.value, before);
      expect(h.container.read(waveSessionProvider).context.title, 'Original');
      expect(h.container.read(waveSessionProvider).seedUnavailable, true);
      expect(h.handler.externalQueueActive, true);
    },
  );
}
