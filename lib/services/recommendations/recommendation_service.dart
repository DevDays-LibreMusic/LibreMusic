import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show compute;
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';
import 'package:mornye/services/recommendations/recommendation_store.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/file_access.dart' show fileExists;
import 'package:mornye/utils/logger.dart';

class RecommendationCancelled implements Exception {}

class RecommendationResult {
  const RecommendationResult(
    this.picks, {
    required this.matched,
    this.requested = 20,
  });
  final List<RecommendationPick> picks;

  /// Matching metadata rows before sampling and file access checks.
  final int matched, requested;
}

class RecommendationService {
  RecommendationService({
    RecommendationStore? store,
    LibraryDatabase? library,
    Future<RecommendationHistory> Function()? loadHistory,
    this.exists = fileExists,
    Future<bool> Function(String)? serverAvailable,
  }) : store = store ?? RecommendationStore(),
       library = library ?? LibraryDatabase.instance,
       _loadHistory = loadHistory,
       _serverAvailable =
           serverAvailable ?? MusicServerClient.instance.canResolveSource;
  final RecommendationStore store;
  final LibraryDatabase library;
  final Future<RecommendationHistory> Function()? _loadHistory;
  final Future<bool> Function(String) exists;
  final Future<bool> Function(String) _serverAvailable;
  final _pending =
      <
        String,
        ({RecommendationProfile profile, RecommendationPick pick, DateTime at})
      >{};
  final _log = AppLogger('Recommendations');

  void remember(
    RecommendationProfile profile,
    Iterable<RecommendationPick> picks,
  ) {
    for (final pick in picks) {
      _pending.remove(pick.media.source);
      _pending[pick.media.source] = (
        profile: profile,
        pick: pick,
        at: DateTime.now(),
      );
    }
    while (_pending.length > 200) {
      _pending.remove(_pending.keys.first);
    }
  }

  PlayableMedia mediaFor(
    RecommendationProfile profile,
    RecommendationPick pick,
  ) => PlayableMedia.fromJson({
    ...pick.media.toJson(),
    'displayMetadata': {
      ...pick.media.displayMetadata,
      'recommendationProfileId': profile.id,
      'recommendationRevision': profile.revision,
    },
  })!;

  /// A manually selected copy of a queued suggestion is not its outcome.
  void begin(PlayableMedia media) {
    final pending = _pending[media.source];
    if (pending != null &&
        (media.displayMetadata['recommendationProfileId'] !=
                pending.profile.id ||
            media.displayMetadata['recommendationRevision'] !=
                pending.profile.revision)) {
      _pending.remove(media.source);
    }
  }

  void record(AutoplayFeedback feedback) {
    final entry = _pending.remove(feedback.track.source);
    if (entry == null || DateTime.now().difference(entry.at).inHours >= 24) {
      return;
    }
    unawaited(
      rate(
        entry.profile,
        entry.pick,
        feedback.reward,
        weight: feedback.weight,
      ).catchError((Object error) {
        _log.w('Could not store feedback: $error');
      }),
    );
  }

  Future<void> rate(
    RecommendationProfile profile,
    RecommendationPick pick,
    double reward, {
    double weight = 3,
  }) => store.record(
    profile,
    pick.parts,
    reward: reward,
    weight: weight,
    artist: normalizeLookupText(pick.media.artist),
  );

  Future<RecommendationProfile?> reset(String id) async {
    _pending.removeWhere((_, value) => value.profile.id == id);
    return store.reset(id);
  }

  Future<RecommendationHistory>
  _history() async => ListeningStatisticsStore.instance.read((db) async {
    final rows = await db.rawQuery(
      'SELECT title, artist, SUM(plays) AS plays, MAX(day) AS day FROM listening GROUP BY title, artist',
    );
    final plays = <String, int>{};
    final last = <String, DateTime>{};
    for (final row in rows) {
      final key = recommendationSongKey(
        row['artist'] as String,
        row['title'] as String,
      );
      plays[key] = (plays[key] ?? 0) + (row['plays'] as num).toInt();
      final date = DateTime.tryParse(row['day'] as String);
      if (date != null && (last[key] == null || date.isAfter(last[key]!))) {
        last[key] = date;
      }
    }
    return RecommendationHistory(plays: plays, lastPlayed: last);
  });

  Future<RecommendationResult> generate(
    RecommendationProfile profile, {
    bool includeLocal = true,
    int limit = 20,
    List<PlayableMedia> session = const [],
    Set<String> excludedSources = const {},
    Future<List<AutoplaySignal>> Function(List<PlayableMedia>)? loadSignals,
    bool Function()? cancelled,
  }) async {
    if (limit <= 0) {
      return const RecommendationResult([], matched: 0, requested: 0);
    }
    if (!profile.valid) throw const FormatException('Invalid profile');
    void check() {
      if (cancelled?.call() ?? false) throw RecommendationCancelled();
    }

    check();
    final history = await (_loadHistory?.call() ?? _history());
    final now = DateTime.now();
    final playlistSongs = <String>{};
    for (final id in profile.playlistIds) {
      final tracks = await LibraryCollectionsDatabase.instance
          .loadPlaylistTracks(id, limit: -1);
      for (final track in tracks) {
        playlistSongs.add(recommendationSongKey(track.artistName, track.name));
      }
      check();
    }
    final sessionKeys = {
      for (final song in session)
        recommendationSongKey(song.artist, song.title),
    };
    final random = Random();
    final candidates = <RecommendationCandidate>[];
    var matched = 0;
    for (final source in [
      'downloaded',
      if (includeLocal) ...['local', 'musicserver'],
    ]) {
      String? after;
      while (true) {
        check();
        final rows = await library.getRecommendationPage(
          source: source,
          limit: 256,
          afterId: after,
          minSeconds: profile.minSeconds,
          maxSeconds: profile.maxSeconds,
          minYear: profile.minYear,
          maxYear: profile.maxYear,
          excludeUnknown: profile.excludeUnknown,
          excludeMarkedExplicit: profile.excludeMarkedExplicit,
        );
        for (final row in rows) {
          final duration = row['duration'] as int?;
          final media = PlayableMedia(
            id: row['id'] as String,
            source: row['file_path'] as String,
            title: row['track_name'] as String? ?? '',
            artist: row['artist_name'] as String? ?? '',
            album: row['album_name'] as String? ?? '',
            genre: row['genre'] as String?,
            duration: duration == null || duration <= 0
                ? null
                : Duration(seconds: duration),
            // Recommendations must not fetch remote artwork while offline.
            artUri: null,
            explicit: row['explicit'] == 1,
            displayMetadata: {
              'recommendationCollectionId': row['collection_id'],
              'recommendationCollectionSource': row['collection_source'],
            },
          );
          if (excludedSources.contains(media.source)) continue;
          final date = row['release_date'] as String? ?? '';
          final candidate = RecommendationCandidate(
            media,
            year: int.tryParse(date.length >= 4 ? date.substring(0, 4) : date),
            markedExplicit: row['explicit'] == 1,
            streamable: source == 'musicserver',
          );
          if (sessionKeys.contains(candidate.key)) continue;
          if (!recommendationMatches(
            profile,
            candidate,
            history: history,
            now: now,
            playlistSongs: playlistSongs,
          )) {
            continue;
          }
          matched++;
          // Uniform reservoir after every filter, across all pages/sources.
          if (candidates.length < 500) {
            candidates.add(candidate);
          } else {
            final index = random.nextInt(matched);
            if (index < 500) candidates[index] = candidate;
          }
        }
        if (rows.length < 256) break;
        after = rows.last['id'] as String;
      }
    }
    check();
    candidates.shuffle(random);
    final learning = await store.learning(profile);
    final affinity = <String, double>{};
    // A cold profile can use existing local listening statistics immediately.
    for (final entry in history.plays.entries) {
      final artist = entry.key.split('|').first;
      affinity[artist] = (affinity[artist] ?? 0) + entry.value;
    }
    for (final artist in affinity.keys.toList()) {
      affinity[artist] = log(1 + affinity[artist]!) / 5;
    }
    for (final entry in learning.affinity.entries) {
      affinity[entry.key] = (affinity[entry.key] ?? 0) + entry.value;
    }
    final training = await compute(trainAutoplayRanker, learning.outcomes);
    check();
    final signals = profile.sound > 0 && loadSignals != null
        ? await loadSignals(candidates.map((c) => c.media).toList())
        : <AutoplaySignal>[];
    final ranked = await compute(
      rankRecommendations,
      RecommendationRanking(
        profile: profile,
        candidates: candidates,
        history: history,
        weights: training.weights,
        artistAffinity: affinity,
        session: session,
        signals: signals,
        limit: 500,
      ),
    );
    final picks = <RecommendationPick>[];
    for (final pick in ranked) {
      check();
      final available = MusicServerClient.owns(pick.media.source)
          ? await _serverAvailable(pick.media.source)
          : await exists(pick.media.source);
      if (available) picks.add(pick);
      if (picks.length >= limit) break;
    }
    check();
    return RecommendationResult(picks, matched: matched, requested: limit);
  }
}
