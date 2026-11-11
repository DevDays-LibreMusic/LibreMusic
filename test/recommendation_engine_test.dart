import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';

RecommendationCandidate song(
  String title, {
  String artist = 'Artist',
  String? genre = 'Jazz',
  int? year = 2020,
  int? seconds = 180,
  String? path,
  bool explicit = false,
  bool streamable = false,
}) => RecommendationCandidate(
  PlayableMedia(
    id: title,
    source: path ?? '/music/$title.flac',
    title: title,
    artist: artist,
    genre: genre,
    duration: seconds == null ? null : Duration(seconds: seconds),
  ),
  year: year,
  markedExplicit: explicit,
  streamable: streamable,
);

void main() {
  final now = DateTime(2026, 11, 10);
  const profile = RecommendationProfile(id: 'work', name: 'Work');
  bool matches(
    RecommendationProfile p,
    RecommendationCandidate c, {
    RecommendationHistory history = const RecommendationHistory(),
    Set<String>? playlist,
  }) => recommendationMatches(
    p,
    c,
    history: history,
    now: now,
    playlistSongs: playlist,
  );

  test('moods combine with genres and survive profile serialization', () {
    final calm = profile.update({
      'moods': ['calm'],
      'genres': ['Classical'],
    });
    expect(matches(calm, song('piano', genre: 'Classical')), isTrue);
    expect(matches(calm, song('ambient', genre: 'ambientgenre')), isFalse);
    expect(matches(calm, song('metal', genre: 'classicmetal')), isFalse);
    expect(
      matches(
        calm.update({'excludeUnknown': false}),
        song('unknown', genre: null),
      ),
      isFalse,
    );
    expect(RecommendationProfile.fromJson(calm.toJson()).moods, ['calm']);
    final legacy = profile.toJson()..remove('moods');
    expect(RecommendationProfile.fromJson(legacy).moods, isEmpty);
    final either = profile.update({
      'moods': ['calm', 'energetic'],
    });
    expect(matches(either, song('ambient', genre: 'ambientgenre')), isTrue);
    expect(matches(either, song('metal', genre: 'classicmetal')), isTrue);
    expect(matches(either, song('blues', genre: 'blues')), isFalse);
  });

  test('old settings retain default autoplay and new setting round trips', () {
    expect(AppSettings.fromJson({}).recommendationProfileId, '');
    final settings = const AppSettings().copyWith(
      recommendationProfileId: 'work',
    );
    expect(
      AppSettings.fromJson(settings.toJson()).recommendationProfileId,
      'work',
    );
  });
  test('profile round trip and finite bounded preferences', () {
    final p = profile.update({
      'genres': [' Jazz ', 'Rock'],
      'discovery': 9,
      'sound': double.nan,
    });
    expect(RecommendationProfile.fromJson(p.toJson()).genres, ['Jazz', 'Rock']);
    expect(p.discovery, 1);
    expect(p.sound, 0);
    expect(
      () => RecommendationProfile.fromJson({'version': 2}),
      throwsFormatException,
    );
    expect(profile.update({'minSeconds': 200, 'maxSeconds': 100}).valid, false);
  });
  test('OR within tags, AND across filters, exclusion wins', () {
    final p = profile.update({
      'genres': ['jazz', 'rock'],
      'excludedGenres': ['metal'],
      'artists': ['Artist'],
      'minYear': 2010,
    });
    expect(matches(p, song('yes', genre: 'Jazz; Fusion')), true);
    expect(matches(p, song('no', genre: 'Rock; Metal')), false);
    expect(matches(p, song('no', artist: 'Else')), false);
    expect(matches(p, song('no', year: 2000)), false);
    expect(matches(p, song('no', genre: 'Jazz fusion')), false);
  });
  test('unknown tags only pass when explicitly allowed, ranges inclusive', () {
    final p = profile.update({
      'genres': ['Jazz'],
      'minSeconds': 180,
      'maxYear': 2020,
    });
    expect(matches(p, song('yes')), true);
    expect(matches(p, song('unknown', genre: null)), false);
    expect(matches(p, song('unknown', seconds: null)), false);
    expect(
      matches(
        p.update({'excludeUnknown': false}),
        song('unknown', genre: null, seconds: null, year: null),
      ),
      true,
    );
    expect(
      matches(
        p.update({'excludeUnknown': false}),
        song('known wrong', year: 2021),
      ),
      false,
    );
  });
  test('folder boundaries, playlist membership and network exclusions', () {
    final p = profile.update({
      'folders': ['/music'],
      'playlistIds': ['p'],
    });
    final candidate = song('yes');
    expect(matches(p, candidate, playlist: {candidate.key}), true);
    expect(matches(p, candidate, playlist: {}), false);
    expect(
      matches(
        p,
        song('yes', path: '/music-other/yes.flac'),
        playlist: {candidate.key},
      ),
      false,
    );
    for (final path in [
      'network://host/song',
      'https://host/song',
      'musicserver://song',
    ]) {
      expect(matches(profile, song('remote', path: path)), false);
    }
  });
  test('only approved server identities may pass the network boundary', () {
    expect(
      matches(
        profile,
        song(
          'server',
          path: 'musicserver://account/${'a' * 64}',
          streamable: true,
        ),
      ),
      isTrue,
    );
    expect(
      matches(
        profile,
        song('server', path: 'musicserver://account/${'a' * 64}'),
      ),
      isFalse,
    );
    expect(
      matches(
        profile,
        song('web', path: 'https://example.org/song', streamable: true),
      ),
      isFalse,
    );
  });
  test('folder matching preserves platform directory boundaries', () {
    expect(
      recommendationFolderContains(r'C:\Music', r'c:\music\song.flac'),
      true,
    );
    expect(recommendationFolderContains('/Music', '/music/song.flac'), false);
    expect(
      recommendationFolderContains(
        'content://provider/tree/primary%3AMusic',
        'content://provider/document/primary%3AMusic%2FAlbum%2Fsong.flac',
      ),
      true,
    );
    expect(
      recommendationFolderContains(
        'content://provider/tree/primary%3AMusic',
        'content://other/document/primary%3AMusic%2Fsong.flac',
      ),
      false,
    );
    expect(
      recommendationFolderContains(
        'content://provider/tree/primary%3AMusic',
        'content://provider/document/primary%3AMusicOther%2Fsong.flac',
      ),
      false,
    );
  });

  test('repeat window and explicit markings remain hard filters', () {
    final candidate = song('yes');
    final p = profile.update({'repeatDays': 7, 'excludeMarkedExplicit': true});
    expect(
      matches(
        p,
        candidate,
        history: RecommendationHistory(
          lastPlayed: {candidate.key: now.subtract(const Duration(days: 6))},
        ),
      ),
      false,
    );
    expect(
      matches(
        p,
        candidate,
        history: RecommendationHistory(
          lastPlayed: {candidate.key: now.subtract(const Duration(days: 7))},
        ),
      ),
      true,
    );
    expect(matches(p, song('explicit', explicit: true)), false);
    expect(
      matches(
        profile.update({
          'excludedTracks': [candidate.key],
        }),
        candidate,
      ),
      false,
    );
  });
  test('discovery and familiarity settings reverse rankings', () {
    final old = song('old'), fresh = song('fresh');
    final history = RecommendationHistory(plays: {old.key: 20});
    List<String> rank(double discovery) => rankRecommendations(
      RecommendationRanking(
        profile: profile.update({'discovery': discovery}),
        candidates: [old, fresh],
        history: history,
      ),
    ).map((p) => p.media.title).toList();
    expect(rank(1).first, 'fresh');
    expect(rank(0).first, 'old');
  });
  test('diversity spreads artists and duplicate recordings do not repeat', () {
    final picks = rankRecommendations(
      RecommendationRanking(
        profile: profile.update({'diversity': 1}),
        candidates: [
          song('a'),
          song('b'),
          song('c', artist: 'Other'),
          song('a', path: '/copy/a.flac'),
        ],
        history: const RecommendationHistory(),
      ),
    );
    expect(picks.map((p) => p.media.title), ['a', 'c', 'b']);
  });
  test('missing artist and genre do not count as reference similarity', () {
    final unknown = song('unknown', artist: '', genre: null);
    final picks = rankRecommendations(
      RecommendationRanking(
        profile: profile,
        candidates: [unknown],
        history: const RecommendationHistory(),
        session: [song('reference', artist: '', genre: null).media],
      ),
    );
    expect(picks.single.parts['similarity'], 0);
  });

  test('disabled preference cannot be revived by learned weights', () {
    final picks = rankRecommendations(
      RecommendationRanking(
        profile: profile.update({'history': 0}),
        candidates: [song('a')],
        history: const RecommendationHistory(),
        artistAffinity: {'artist': 2},
        weights: {'history': 999},
      ),
    );
    expect(picks.single.parts['history'], 0);
  });
}
