import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/home_search_logic.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/models/wave_session.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart' show playbackProvider;
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/services/lastfm_wave_service.dart';
import 'package:mornye/services/lastfm_wave_resolver.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/wave_audio_cache.dart';
import 'package:mornye/services/wave_listening_observer.dart';
import 'package:mornye/utils/logger.dart';
export 'package:mornye/models/wave_session.dart';

final waveSessionProvider =
    NotifierProvider<WaveSessionController, WaveSessionState>(
      WaveSessionController.new,
    );

class WaveSessionController extends Notifier<WaveSessionState> {
  WaveSessionController({
    LastfmWaveService? service,
    Future<Track?> Function(LastfmWaveTrack)? resolveCandidate,
    Future<PlayableMedia?> Function(Track)? prepareAudio,
    Future<List<PlayableMedia>> Function(PlayableMedia)? libraryLoader,
  }) : _service = service ?? LastfmWaveService(),
       _resolveCandidate = resolveCandidate,
       _prepareAudio = prepareAudio,
       _libraryLoader = libraryLoader;
  final LastfmWaveService _service;
  final Future<Track?> Function(LastfmWaveTrack)? _resolveCandidate;
  final Future<PlayableMedia?> Function(Track)? _prepareAudio;
  final Future<List<PlayableMedia>> Function(PlayableMedia)? _libraryLoader;
  final _random = Random();
  final _pool = <LastfmWaveTrack>[];
  final _recent = <String>[];
  final _heard = <String, Track>{};
  final _likes = <String>{};
  final _skips = <String, int>{};
  final _resolved = <String, Track>{};
  final _modes = <String, WaveMode>{};
  final _metadataCache =
      <String, ({DateTime at, List<LastfmWaveTrack> tracks})>{};

  WaveAudioCache? _cache;
  late Future<void> _ready;
  Future<void> ensureLoaded() => _ready;
  int _generation = 0, _page = 0;
  WaveContext? _failedSeedContext;
  WaveSessionState? _startingState;
  bool _startingOwnership = false;
  final _pendingDownloads = <String>{};
  bool _disposed = false;
  int? _fillingGeneration;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  final _listening = WaveListeningObserver();
  bool _samplePending = false;
  Future<void> _persistTail = Future.value();
  MusicPlayerHandler? get _handler =>
      ref.read(musicPlayerRuntimeProvider).handler;
  String get _apiKey => ref.read(lastfmAppCredentialsProvider).apiKey;

  @override
  WaveSessionState build() {
    _ready = _load();
    ref.listen(libraryCollectionsProvider, (previous, next) {
      if (previous?.isLoaded != true || !next.isLoaded) return;
      final old = {for (final e in previous!.loved) e.key: e.track};
      final fresh = {for (final e in next.loved) e.key: e.track};
      for (final key in fresh.keys.where((k) => !old.containsKey(k))) {
        unawaited(_recordLove(fresh[key]!, true));
      }
      for (final key in old.keys.where((k) => !fresh.containsKey(k))) {
        unawaited(_recordLove(old[key]!, false));
      }
    });
    ref.listen(localMediaItemProvider, (_, next) {
      _onMedia(next.value);
    });
    ref.listen(localPlaybackStateProvider, (_, next) {
      _onPlayback(next.value);
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tick();
    });
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
      _service.dispose();
    });
    return const WaveSessionState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('wave_session');
      var cachePins = <String>[];
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        cachePins = (data['cachePins'] as List? ?? []).cast<String>();
        for (final t in data['heard'] as List? ?? []) {
          final track = Track.fromJson(Map<String, dynamic>.from(t as Map));
          _heard[waveTrackKey(track.artistName, track.name)] = track;
        }
        _recent.addAll((data['recent'] as List? ?? []).cast<String>());
        _likes.addAll((data['likes'] as List? ?? []).cast<String>());
        for (final e in (data['modes'] as Map? ?? {}).entries) {
          _modes[e.key as String] = WaveMode.values.byName(e.value as String);
        }
        if (_disposed) return;
        state = state.copyWith(
          context: data['context'] is Map
              ? WaveContext.fromJson(
                  Map<String, dynamic>.from(data['context'] as Map),
                )
              : null,
          mode: WaveMode.values.byName(data['mode'] as String? ?? 'balanced'),
          active: data['active'] == true,
          seedArtists: (data['seedArtists'] as List? ?? []).cast<String>(),
          recentContexts: (data['contexts'] as List? ?? [])
              .map(
                (e) =>
                    WaveContext.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList(),
          blockedTracks: Map<String, String>.from(
            data['blockedTracks'] as Map? ?? {},
          ),
          blockedArtists: (data['blockedArtists'] as List? ?? [])
              .cast<String>()
              .toSet(),
          cacheLimitBytes: data['cacheLimitBytes'] as int?,
          backgroundMobile: data['backgroundMobile'] as bool?,
        );
      }
      final support = await getApplicationSupportDirectory();
      _cache = WaveAudioCache(Directory('${support.path}/wave-audio'))
        ..limitBytes = state.cacheLimitBytes;
      _cache!.protectedPaths.addAll(cachePins);
      await _cache!.load();
      if (_disposed) return;
      state = state.copyWith(loaded: true, cacheBytes: _cache!.bytes);
      final restored = _handler?.mediaItem.value;
      if (restored != null) {
        final owned = restored.extras?['waveSessionKey'] == state.context.key;
        state = state.copyWith(active: owned);
        _handler?.externalQueueActive = owned;
      }
    } on Object {
      if (!_disposed) {
        state = state.copyWith(
          loaded: true,
          error: 'Не удалось загрузить настройки волны. Попробуйте ещё раз.',
        );
      }
    }
  }

  Future<void> _persist() {
    final data = {
      'cachePins': _cache?.protectedPaths.toList() ?? <String>[],
      'context': state.context.toJson(),
      'mode': state.mode.name,
      'active': state.active,
      'seedArtists': state.seedArtists,
      'contexts': state.recentContexts.map((c) => c.toJson()).toList(),
      'blockedTracks': state.blockedTracks,
      'blockedArtists': state.blockedArtists.toList(),
      'heard': _heard.values
          .toList()
          .reversed
          .take(500)
          .map((t) => t.toJson())
          .toList()
          .reversed
          .toList(),
      'recent': _recent,
      'likes': _likes.toList(),
      'modes': _modes.map((k, v) => MapEntry(k, v.name)),
      'cacheLimitBytes': state.cacheLimitBytes,
      'backgroundMobile': state.backgroundMobile,
    };
    final pending = _persistTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wave_session', jsonEncode(data));
    });
    _persistTail = pending.catchError((Object _) {
      AppLogger('Wave').w('state_write_failed');
    });
    return _persistTail;
  }

  Future<List<String>> searchArtists(String query) async {
    if (query.trim().length < 2) return [];
    return _service.searchArtists(_apiKey, query.trim());
  }

  Future<void> setSeedArtists(List<String> artists) async {
    await ensureLoaded();
    state = state.copyWith(
      needsSeeds: false,
      seedArtists: artists
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .take(20)
          .toList(),
    );
    _pool.clear();
    await _persist();
  }

  Future<void> setCacheLimit(int bytes) async {
    await ensureLoaded();
    state = state.copyWith(
      cacheLimitBytes: bytes.clamp(128 * 1024 * 1024, 8 * 1024 * 1024 * 1024),
    );
    _cache?.limitBytes = state.cacheLimitBytes;
    await _cache?.trim();
    state = state.copyWith(cacheBytes: _cache?.bytes ?? 0);
    await _persist();
  }

  Future<void> setBackgroundMobile(bool enabled) async {
    state = state.copyWith(backgroundMobile: enabled);
    await _persist();
  }

  Future<void> clearCache() async {
    await ensureLoaded();
    await _cache?.trim(clear: true);
    state = state.copyWith(cacheBytes: _cache?.bytes ?? 0);
  }

  Future<void> setLoved(Track track, bool loved) async {
    if (ref.read(libraryCollectionsProvider).isLoved(track) != loved) {
      await ref.read(libraryCollectionsProvider.notifier).toggleLoved(track);
    }
    await _recordLove(track, loved);
  }

  Future<void> _recordLove(Track track, bool loved) async {
    final key = waveTrackKey(track.artistName, track.name);
    if (loved) {
      _likes.add(key);
      _heard[key] = track;
    } else {
      _likes.remove(key);
    }
    // Keep the audible and prepared songs while refreshing later suggestions.
    _pool.clear();
    _metadataCache.removeWhere((key, _) => key.startsWith('profile:'));
    _page = 0;
    await _persist();
    await ref
        .read(lastfmAccountProvider)
        .setLoved(_listeningTrack(track), loved);
  }

  Future<void> saveTrack(Track track) async {
    final service = resolveEffectiveDownloadService(
      ref.read(settingsProvider).defaultService,
      ref.read(extensionProvider),
    );
    ref.read(downloadQueueProvider.notifier).addMultipleToQueue([
      track,
    ], service);
  }

  Future<void> excludeTrack(Track track) async {
    final key = waveTrackKey(track.artistName, track.name);
    state = state.copyWith(
      blockedTracks: {
        ...state.blockedTracks,
        key: '${track.artistName} — ${track.name}',
      },
    );
    await _excludeCurrent();
  }

  Future<void> excludeArtist(String artist) async {
    state = state.copyWith(
      blockedArtists: {...state.blockedArtists, waveArtistKey(artist)},
    );
    await _excludeCurrent();
  }

  Future<void> unblockTrack(String key) async {
    final map = {...state.blockedTracks}..remove(key);
    state = state.copyWith(blockedTracks: map);
    await _persist();
  }

  Future<void> unblockArtist(String artist) async {
    state = state.copyWith(
      blockedArtists: {...state.blockedArtists}..remove(waveArtistKey(artist)),
    );
    await _persist();
  }

  Future<void> _excludeCurrent() async {
    _generation++;
    final starting = _startingState;
    _startingState = null;
    if (starting != null) {
      state = state.copyWith(
        context: starting.context,
        mode: starting.mode,
        active: starting.active,
        recentContexts: starting.recentContexts,
        busy: false,
      );
      _handler?.externalQueueActive = _startingOwnership;
    } else {
      state = state.copyWith(busy: false);
    }
    for (final id in _pendingDownloads.toList()) {
      unawaited(PlatformBridge.cancelDownload(id));
    }
    await _persist();
    if (!state.active) return;
    final handler = _handler;
    if (handler == null) return;
    final current = handler.mediaItem.value;
    final currentBlocked =
        current != null && _blocked(current.artist ?? '', current.title);
    if (currentBlocked) await handler.pause();
    await handler.replaceUpcoming([]);
    _pool.removeWhere((t) => _blocked(t.artist, t.title));
    await _fill(force: true);
    if (currentBlocked) {
      if (handler.queue.value.length >
          (handler.playbackState.value.queueIndex ?? 0) + 1) {
        await handler.skipToNext();
        await handler.play();
      } else {
        state = state.copyWith(
          error:
              state.error ??
              'Не удалось продолжить волну. Проверьте подключение или откройте библиотеку.',
        );
      }
    }
  }

  bool _blocked(String artist, String title) =>
      state.blockedArtists.contains(waveArtistKey(artist)) ||
      state.blockedTracks.containsKey(waveTrackKey(artist, title));

  Future<void> setMode(WaveMode mode) async {
    state = state.copyWith(mode: mode);
    _modes[state.context.key] = mode;
    await _persist();
    if (state.active) await start(state.context, preserveCurrent: true);
  }

  Future<void> returnToPersonal() =>
      start(const WaveContext(), preserveCurrent: true);
  Future<void> retry() =>
      start(state.context, preserveCurrent: _handler?.mediaItem.value != null);
  Future<void> toggle() async {
    await ensureLoaded();
    final handler = _handler;
    if (state.active && handler?.mediaItem.value != null) {
      if (handler!.playbackState.value.playing) {
        await handler.pause();
      } else {
        await handler.play();
        await _fill(force: true);
      }
      return;
    }
    await start(state.context);
  }

  Future<void> playSimilar() async {
    final context = _failedSeedContext;
    if (context != null) {
      if (context.track case final t?) {
        _recent.add(waveTrackKey(t.artistName, t.name));
      }
      await start(context, skipSeed: true);
    }
  }

  Future<void> start(
    WaveContext context, {
    bool preserveCurrent = false,
    bool skipSeed = false,
    String? currentItemId,
  }) async {
    await ensureLoaded();
    if (state.busy) return;
    if (_apiKey.isEmpty) {
      state = state.copyWith(
        error:
            'В этой сборке не настроен Last.fm. Установите настроенную сборку приложения.',
      );
      return;
    }
    final previousState = state;
    final previousOwnership = _handler?.externalQueueActive ?? false;
    var committed = false;
    _startingState = previousState;
    _startingOwnership = previousOwnership;
    state = state.copyWith(
      busy: true,
      clearError: true,
      seedUnavailable: false,
    );
    final generation = ++_generation;
    for (final id in _pendingDownloads.toList()) {
      unawaited(PlatformBridge.cancelDownload(id));
    }
    MusicPlayerHandler? preparingHandler;
    int? preparingGeneration;
    bool current() {
      if (_disposed || generation != _generation) return false;
      if (!committed &&
          preparingGeneration != null &&
          preparingHandler!.playbackRequestGeneration != preparingGeneration) {
        // A newer player action owns the queue, including local Flow playback.
        _generation++;
        _startingState = null;
        state = state.copyWith(busy: false, active: false);
        unawaited(_persist());
        return false;
      }
      return true;
    }

    final handler = await ref
        .read(musicPlayerControllerProvider)
        .ensureInitialized();
    if (!current()) return;
    if (handler == null) {
      _startingState = null;
      state = state.copyWith(
        busy: false,
        error: 'Не удалось запустить встроенный плеер.',
      );
      return;
    }
    preparingHandler = handler;
    preparingGeneration = handler.playbackRequestGeneration;
    final selected = context.track;
    final playing = handler.mediaItem.value;
    Track? playingTrack;
    final storedTrack = playing?.extras?['catalogTrack'];
    if (storedTrack is String) {
      try {
        playingTrack = Track.fromJson(
          Map<String, dynamic>.from(jsonDecode(storedTrack) as Map),
        );
      } on Object {
        AppLogger('Wave').w('current_metadata_invalid');
      }
    }
    final same =
        selected != null &&
        playing != null &&
        (playingTrack != null
            ? waveRecordingKey(selected) == waveRecordingKey(playingTrack)
            : selected.id == playing.id);
    preserveCurrent =
        preserveCurrent ||
        same ||
        (currentItemId != null && playing?.id == currentItemId);
    state = state.copyWith(
      busy: true,
      clearError: true,
      seedUnavailable: false,
    );
    try {
      PlayableMedia? first;
      if (!skipSeed &&
          !preserveCurrent &&
          selected != null &&
          context.kind == WaveKind.track) {
        first = await _prepareTrack(selected, foreground: true);
        if (!current()) return;
        if (first == null) {
          _failedSeedContext = context;
          state = state.copyWith(seedUnavailable: true);
          throw StateError(
            'Выбранная композиция недоступна. Попробуйте снова или включите похожее.',
          );
        }
      }
      if (!current()) return;
      state = state.copyWith(
        context: context,
        mode: _modes[context.key] ?? state.mode,
        active: true,
        recentContexts: [
          context,
          ...state.recentContexts.where((c) => c.key != context.key),
        ].take(12).toList(),
      );
      _pool.clear();
      _page = 0;
      handler.externalQueueActive = true;
      handler.onExplicitNext = (media) {
        final listened = _listening.current?.listened ?? Duration.zero;
        if (state.active &&
            listened > Duration.zero &&
            listened < const Duration(seconds: 30)) {
          final artist = waveArtistKey(media.artist);
          _skips[artist] = min(4, (_skips[artist] ?? 0) + 1);
          _pool.sort(
            (a, b) => (_skips[waveArtistKey(a.artist)] ?? 0).compareTo(
              _skips[waveArtistKey(b.artist)] ?? 0,
            ),
          );
        }
      };
      if (preserveCurrent && playing != null) {
        await handler.replaceUpcoming([], waveSessionKey: state.context.key);
        committed = true;
        _startingState = null;
      } else {
        first ??= await _nextPlayable(foreground: true);
        if (!current()) return;
        if (first == null) {
          throw StateError(
            state.error ??
                'Не удалось продолжить волну. Проверьте сеть или откройте сохранённую музыку.',
          );
        }
        committed = true;
        _startingState = null;
        await handler.setQueueAndPlay(
          [
            first.withWaveSession(
              state.context.key,
              track:
                  selected ??
                  _resolved[waveTrackKey(first.artist, first.title)],
            ),
          ],
          shuffle: false,
          externalQueue: true,
        );
      }
      await _persist();
      if (current()) state = state.copyWith(busy: false, clearError: true);
      unawaited(_fill());
    } on Object catch (error) {
      if (current() && !committed) {
        final unavailable = state.seedUnavailable;
        state = previousState.copyWith(
          seedUnavailable: unavailable,
          needsSeeds: state.needsSeeds,
          busy: false,
        );
        handler.externalQueueActive = previousOwnership;
      }
      if (current()) {
        state = state.copyWith(
          busy: false,
          error: error is WaveSourceUnavailable
              ? error.message
              : error is WaveVerificationRequired
              ? 'Источник требует проверки доступа. Нажмите «Повторить», чтобы открыть проверку.'
              : error is StateError
              ? error.message.toString()
              : 'Не удалось запустить волну. Проверьте сеть и источник музыки.',
        );
      }
    } finally {
      if (current()) {
        _startingState = null;
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<List<LastfmWaveTrack>> _cached(
    String key,
    Future<List<LastfmWaveTrack>> Function() fetch,
  ) async {
    final entry = _metadataCache[key];
    if (entry != null &&
        DateTime.now().difference(entry.at) < const Duration(hours: 6)) {
      return entry.tracks;
    }
    final tracks = await fetch();
    if (_metadataCache.length >= 200) {
      _metadataCache.remove(_metadataCache.keys.first);
    }
    _metadataCache[key] = (at: DateTime.now(), tracks: tracks);
    return tracks;
  }

  Future<void> _populate() async {
    final generation = _generation, page = _page;
    bool current() => !_disposed && generation == _generation;
    final context = state.context;
    final candidates = <LastfmWaveTrack>[];
    final familiar = <LastfmWaveTrack>[
      for (final t in _heard.values)
        LastfmWaveTrack(
          title: t.name,
          artist: t.artistName,
          artworkUrl: t.coverUrl,
        ),
    ];
    var profileFailed = false;
    final account = ref.read(lastfmAccountProvider);
    await account.ready;
    if (context.kind == WaveKind.personal && account.state.connected) {
      try {
        familiar.addAll(
          await _cached(
            'profile:${account.state.username}',
            () => _service.profileTracks(_apiKey, account.state.username ?? ''),
          ),
        );
      } on Object {
        profileFailed = true;
        AppLogger('Wave').w('profile_unavailable');
      }
    }
    familiar.sort(
      (a, b) => (_likes.contains(b.key) ? 1 : 0).compareTo(
        _likes.contains(a.key) ? 1 : 0,
      ),
    );
    Future<void> artist(String name) async {
      candidates.addAll(
        await _cached(
          'artist:$name',
          () => _service.artistTracks(_apiKey, name),
        ),
      );
      final similar = await _service.similarArtists(_apiKey, name);
      if (similar.isNotEmpty) {
        final other = similar[page % similar.length];
        candidates.addAll(
          await _cached(
            'artist:$other',
            () => _service.artistTracks(_apiKey, other),
          ),
        );
      }
    }

    try {
      if (context.kind == WaveKind.genre) {
        candidates.addAll(
          await _cached(
            'genre:${context.title}:${page + 1}',
            () => _service.genreTracks(_apiKey, context.title, page: page + 1),
          ),
        );
      } else if (context.kind == WaveKind.artist) {
        await artist(context.artist.isEmpty ? context.title : context.artist);
      } else {
        final seeds = context.kind == WaveKind.track && context.track != null
            ? [
                LastfmWaveTrack(
                  title: context.track!.name,
                  artist: context.track!.artistName,
                ),
              ]
            : context.kind == WaveKind.album
            ? context.albumTracks
                  .map(
                    (t) => LastfmWaveTrack(title: t.name, artist: t.artistName),
                  )
                  .toList()
            : familiar;
        if (seeds.isNotEmpty) {
          for (var i = 0; i < min(3, seeds.length); i++) {
            if (!current()) return;
            final seed = seeds[(page * 3 + i) % seeds.length];
            try {
              candidates.addAll(
                await _cached(
                  'similar:${seed.key}',
                  () => _service.similarTracks(_apiKey, seed),
                ),
              );
            } on LastfmWaveException catch (e) {
              if (e.kind != LastfmWaveErrorKind.notFound) rethrow;
            }
          }
          if (context.kind == WaveKind.personal) candidates.addAll(familiar);
        }
        if (candidates.isEmpty ||
            context.kind == WaveKind.personal && state.seedArtists.isNotEmpty) {
          final artists = context.kind == WaveKind.album
              ? [context.artist]
              : context.kind == WaveKind.track
              ? [context.track!.artistName]
              : state.seedArtists;
          if (artists.isNotEmpty) await artist(artists[page % artists.length]);
        }
      }
    } on Object {
      AppLogger('Wave').w('recommendations_unavailable');
    }
    if (!current()) return;
    if (context.kind == WaveKind.personal &&
        familiar.isEmpty &&
        !profileFailed &&
        state.seedArtists.isEmpty) {
      state = state.copyWith(needsSeeds: true);
    }
    if (!current()) return;
    _page = page + 1;
    final known = {..._heard.keys, ...familiar.map((t) => t.key)};
    final unique = <String, LastfmWaveTrack>{
      for (final c in candidates)
        if (!_blocked(c.artist, c.title) && !_recent.contains(c.key)) c.key: c,
    };
    final ranked = unique.values.toList()..shuffle(_random);
    double score(LastfmWaveTrack t) {
      final familiar = known.contains(t.key);
      return (state.mode == WaveMode.familiar
              ? (familiar ? 10 : 0)
              : state.mode == WaveMode.discovery
              ? (familiar ? -10 : 10)
              : 0) +
          (_likes.contains(t.key) ? 2 : 0) -
          (_skips[waveArtistKey(t.artist)] ?? 0) * 2;
    }

    ranked.sort((a, b) => score(b).compareTo(score(a)));
    _pool.addAll(ranked);
  }

  Future<PlayableMedia?> _nextPlayable({required bool foreground}) async {
    final generation = _generation;
    bool current() => !_disposed && generation == _generation;
    final offline = (await Connectivity().checkConnectivity()).contains(
      ConnectivityResult.none,
    );
    if (!current()) return null;
    state = state.copyWith(offline: offline);
    if (!offline && _pool.isEmpty) await _populate();
    if (!current()) return null;
    var attempts = 0;
    while (!offline && _pool.isNotEmpty && attempts++ < 8) {
      if (!current()) return null;
      var index = 0;
      final recentArtists = _recent.reversed
          .take(3)
          .map((s) => s.split('\u0000').first)
          .toSet();
      final diverse = _pool.indexWhere(
        (t) => !recentArtists.contains(waveArtistKey(t.artist)),
      );
      if (diverse >= 0) index = diverse;
      final candidate = _pool.removeAt(index);
      if (_blocked(candidate.artist, candidate.title) ||
          _recent.contains(candidate.key)) {
        continue;
      }
      try {
        final track = await _resolve(candidate, foreground: foreground);
        if (!current()) return null;
        if (track == null) continue;
        final media = await _prepareTrack(track, foreground: foreground);
        if (!current()) return null;
        if (media == null || _blocked(candidate.artist, candidate.title)) {
          continue;
        }
        _recent.add(candidate.key);
        if (_recent.length > 100) _recent.removeAt(0);
        return media;
      } on WaveVerificationRequired {
        state = state.copyWith(
          error:
              'Источник требует проверки доступа. Нажмите «Повторить», чтобы открыть проверку.',
        );
        return null;
      } on WaveSourceUnavailable catch (error) {
        state = state.copyWith(error: error.message);
        break;
      } on Object {
        AppLogger('Wave').w('candidate_unavailable');
      }
    }
    if (!current()) return null;
    if (state.context.kind != WaveKind.personal) {
      state = state.copyWith(
        error:
            state.error ??
            (offline
                ? 'Нет сети для продолжения этой волны. Подключитесь и нажмите «Повторить» или откройте библиотеку.'
                : 'Не удалось найти доступные композиции для этой волны. Нажмите «Повторить» или выберите другую волну.'),
      );
      return null;
    }
    final cached = _cache?.tracks ?? [];
    for (final track in cached.reversed) {
      final key = waveTrackKey(track.artistName, track.name);
      if (_blocked(track.artistName, track.name) || _recent.contains(key)) {
        continue;
      }
      final path = await _cache!.lookup(track);
      if (path == null) continue;
      _recent.add(key);
      if (_recent.length > 100) _recent.removeAt(0);
      state = state.copyWith(offline: offline);
      _resolved[key] = track;
      return playableFromTrack(track, path);
    }
    final handler = _handler;
    final item = handler?.mediaItem.value;
    if (item != null) {
      final seed = PlayableMedia(
        id: item.id,
        source: item.extras?['source']?.toString() ?? '',
        title: item.title,
        artist: item.artist ?? '',
      );
      final local = _libraryLoader != null
          ? await _libraryLoader(seed)
          : await loadAutoplayLibrary(
              seed,
              ref.read(musicPlayerRuntimeProvider),
            );
      if (!current()) return null;
      for (final media in local) {
        final key = waveTrackKey(media.artist, media.title);
        if (_recent.contains(key) || _blocked(media.artist, media.title)) {
          continue;
        }
        _recent.add(key);
        if (_recent.length > 100) _recent.removeAt(0);
        state = state.copyWith(offline: offline);
        return media;
      }
    }
    return null;
  }

  Future<Track?> _resolve(
    LastfmWaveTrack candidate, {
    required bool foreground,
  }) async {
    if (_resolveCandidate != null) return _resolveCandidate(candidate);
    if (_resolved[candidate.key] case final known?) return known;
    final local = _heard[candidate.key];
    if (local != null &&
        (await ref.read(playbackProvider.notifier).resolveTrackFilePaths([
              local,
            ], strictRecording: true)).single !=
            null) {
      return local;
    }
    final settings = ref.read(settingsProvider);
    final extensions = ref.read(extensionProvider).extensions;
    final source = HomeSearchProviderPolicy.resolveProvider(
      settings.searchProvider,
      extensions,
    );
    if (source == null || source.isEmpty) return null;
    final found = await searchWaveCandidates(candidate, (query) async {
      Future<List<Map<String, dynamic>>> request() =>
          PlatformBridge.customSearchWithExtension(
            source,
            query,
            options: {'filter': 'track'},
          ).timeout(const Duration(seconds: 15));
      List<Map<String, dynamic>> rows;
      try {
        rows = await request();
      } catch (error) {
        if (!isExtensionVerificationRequired(error)) rethrow;
        if (!foreground) throw const WaveVerificationRequired();
        if (!await openVerificationAndAwaitGrant(
          source,
          browserMode: settings.extensionVerificationBrowserMode,
        )) {
          throw const WaveVerificationRequired();
        }
        rows = await request();
      }
      return rows.map((r) => Track.fromBackendMap(r, source: source)).toList();
    });
    final match = matchWaveTrack(candidate, found);
    if (match != null) _resolved[candidate.key] = match;
    return match;
  }

  Future<PlayableMedia?> _prepareTrack(
    Track track, {
    required bool foreground,
  }) async {
    if (_prepareAudio != null) return _prepareAudio(track);
    final cache = _cache;
    if (cache == null) return null;
    final existing =
        (await ref.read(playbackProvider.notifier).resolveTrackFilePaths([
          track,
        ], strictRecording: true)).single ??
        await cache.lookup(track);
    if (existing != null) {
      _resolved[waveTrackKey(track.artistName, track.name)] = track;
      cache.protectedPaths.add(existing);
      return playableFromTrack(track, existing);
    }
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return null;
    if (!foreground &&
        !state.backgroundMobile &&
        !connectivity.any(
          (v) =>
              v == ConnectivityResult.wifi || v == ConnectivityResult.ethernet,
        )) {
      return null;
    }
    final generation = _generation;
    final dir = await cache.directoryFor(
      track,
      attempt: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    final settings = ref.read(settingsProvider);
    final service = resolveEffectiveDownloadService(
      settings.defaultService,
      ref.read(extensionProvider),
    );
    if (service.isEmpty) return null;
    final itemId = 'wave-${DateTime.now().microsecondsSinceEpoch}';
    final providerId = track.id.replaceFirst(
      RegExp('^${RegExp.escape(service)}:', caseSensitive: false),
      '',
    );
    final payload = DownloadRequestPayload(
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      outputDir: dir.path,
      filenameFormat: 'audio',
      quality: 'LOSSLESS',
      embedMetadata: false,
      embedLyrics: false,
      service: service,
      downloadProvider: service,
      providerTrackId:
          (track.source ?? '').toLowerCase() == service.toLowerCase()
          ? providerId
          : '',
      spotifyId: track.id,
      isrc: track.isrc ?? '',
      source: track.source ?? '',
      deezerId: track.deezerId ?? '',
      itemId: itemId,
      durationMs: track.duration * 1000,
      useExtensions: true,
      useFallback: true,
      storageMode: 'app',
      outputExt: '.flac',
    );
    cache.activeDirectories.add(dir.path);
    _pendingDownloads.add(itemId);
    try {
      Future<Map<String, dynamic>> download() =>
          PlatformBridge.downloadByStrategy(
            payload: payload,
            useExtensions: true,
            useFallback: true,
          );
      var response = DownloadResult.fromMap(
        await download().timeout(
          const Duration(seconds: 75),
          onTimeout: () {
            unawaited(PlatformBridge.cancelDownload(itemId));
            throw TimeoutException('Wave audio unavailable');
          },
        ),
      );
      if (!response.success &&
          response['error_type'] == 'verification_required') {
        if (!foreground) throw const WaveVerificationRequired();
        if (!await openVerificationAndAwaitGrant(
          service,
          browserMode: settings.extensionVerificationBrowserMode,
        )) {
          throw const WaveVerificationRequired();
        }
        response = DownloadResult.fromMap(
          await download().timeout(
            const Duration(seconds: 75),
            onTimeout: () {
              unawaited(PlatformBridge.cancelDownload(itemId));
              throw TimeoutException('Wave audio unavailable');
            },
          ),
        );
      }
      if (!response.success) {
        final reason = switch (response['error_type']) {
          'rate_limit' =>
            'Источник временно ограничил запросы. Попробуйте позже.',
          'network' =>
            'Не удалось связаться с источником. Проверьте подключение.',
          'permission' =>
            'Нет доступа к файлу. Проверьте разрешения приложения.',
          'authentication_error' ||
          'provider_auth_failed' ||
          'request_auth_invalid' ||
          'provider_reauth_required' =>
            'Источник требует входа. Проверьте его настройки в разделе расширений.',
          _ => null,
        };
        if (reason != null) throw WaveSourceUnavailable(reason);
        return null;
      }
      var path = response.filePath;
      if (path == null) return null;
      if (response.decryption case final descriptor?) {
        path = await FFmpegDecryption.decrypt(
          inputPath: path,
          descriptor: descriptor,
        );
        if (path == null) return null;
      }
      if (response.requiresContainerConversion) {
        path = await FFmpegConversion.convertM4aToFlac(path);
        if (path == null) return null;
      }
      if (generation == _generation) cache.protectedPaths.add(path);
      await cache.remember(track, path);
      if (generation != _generation || _disposed) return null;
      if (!_disposed) {
        state = state.copyWith(cacheBytes: cache.bytes, offline: false);
      }
      _resolved[waveTrackKey(track.artistName, track.name)] = track;
      return playableFromTrack(track, path);
    } finally {
      _pendingDownloads.remove(itemId);
      cache.activeDirectories.remove(dir.path);
      unawaited(
        PlatformBridge.clearItemProgress(itemId).catchError((Object _) {}),
      );
    }
  }

  Future<void> _fill({bool force = false}) async {
    if (_disposed ||
        !state.active ||
        state.busy ||
        _fillingGeneration == _generation) {
      return;
    }
    final handler = _handler;
    if (handler == null) return;
    final index = handler.playbackState.value.queueIndex ?? -1;
    if (index < 0 || handler.queue.value.length - index > 1) return;
    final generation = _generation;
    _fillingGeneration = generation;
    try {
      final media = await _nextPlayable(
        foreground:
            force ||
            handler.playbackState.value.playing ||
            handler.playbackState.value.processingState ==
                AudioProcessingState.completed,
      );
      if (_disposed || generation != _generation || !state.active) return;
      if (media != null && !_blocked(media.artist, media.title)) {
        await handler.enqueueAll([
          media.withWaveSession(
            state.context.key,
            track: _resolved[waveTrackKey(media.artist, media.title)],
          ),
        ]);
        if (handler.playbackState.value.processingState ==
            AudioProcessingState.completed) {
          await handler.skipToNext();
        }
        state = state.copyWith(clearError: true);
        await _persist();
      } else if (handler.playbackState.value.processingState ==
          AudioProcessingState.completed) {
        state = state.copyWith(
          error:
              state.error ??
              'Не удалось продолжить волну. Проверьте подключение или откройте библиотеку.',
        );
      }
    } finally {
      if (_fillingGeneration == generation) _fillingGeneration = null;
    }
  }

  void _onMedia(MediaItem? item) {
    _scheduleSample();
    if (item != null && state.loaded && !state.busy) {
      final owned = item.extras?['waveSessionKey'] == state.context.key;
      _handler?.externalQueueActive = owned;
      if (state.active != owned) {
        state = state.copyWith(active: owned);
        if (!owned) _generation++;
        unawaited(_persist());
      }
    }
    if (item != null) {
      if (!state.loaded) return;
      final queue = _handler?.queue.value ?? [];
      final index = _handler?.playbackState.value.queueIndex ?? 0;
      final protected = _cache?.protectedPaths;
      if (protected != null) {
        protected.clear();
        protected.addAll(
          queue
              .skip(max(0, index - 1))
              .take(3)
              .map((i) => i.extras?['source']?.toString() ?? ''),
        );
      }
    }
    unawaited(_fill());
  }

  void _onPlayback(PlaybackState? playback) => _scheduleSample();

  void _scheduleSample() {
    if (_samplePending) return;
    _samplePending = true;
    scheduleMicrotask(() {
      _samplePending = false;
      if (!_disposed) _tick();
    });
  }

  void _tick() {
    if (_disposed) return;
    final handler = _handler;
    final account = ref.read(lastfmAccountProvider);
    final accountIdentity = account.state.connected
        ? account.state.username
        : null;
    final update = _listening.observe(
      handler?.mediaItem.value,
      handler?.playbackState.value,
      _clock.elapsed,
      chosenByUser: !state.active,
      owner: accountIdentity,
      nowPlayingEnabled: account.state.nowPlayingEnabled,
      enabled: !account.state.connected || account.state.scrobblingEnabled,
      unknownTitle: ref.read(musicPlayerRuntimeProvider).unknownTitle,
      unknownArtist: ref.read(musicPlayerRuntimeProvider).unknownArtist,
    );
    if (update.nowPlaying case final occurrence?) {
      unawaited(account.nowPlaying(occurrence.track));
    }
    for (final occurrence in update.scrobbles) {
      unawaited(
        account.recordListening(
          playId: occurrence.playId,
          track: occurrence.track,
          startedAt: occurrence.startedAt,
          listened: occurrence.listened,
          chosenByUser: occurrence.chosenByUser,
        ),
      );
    }
    final current = update.current;
    if (current?.qualifies == true) {
      unawaited(
        account.recordListening(
          playId: current!.playId,
          track: current.track,
          startedAt: current.startedAt,
          listened: current.listened,
          chosenByUser: current.chosenByUser,
        ),
      );
    }
    if (current != null && current.listened >= const Duration(seconds: 1)) {
      final key = waveTrackKey(current.track.artist, current.track.title);
      final track = _resolved[key];
      if (track != null && !_heard.containsKey(key)) {
        _heard[key] = track;
        unawaited(_persist());
      }
    }
    if (state.active && _clock.elapsed.inSeconds % 10 == 0) unawaited(_fill());
  }

  LastfmListeningTrack _listeningTrack(Track track) => LastfmListeningTrack(
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    duration: Duration(seconds: track.duration),
  );
}

class WaveVerificationRequired implements Exception {
  const WaveVerificationRequired();
}

class WaveSourceUnavailable implements Exception {
  const WaveSourceUnavailable(this.message);
  final String message;
}
