import 'package:mornye/models/track.dart';
import 'package:mornye/models/track_censorship.dart';
import 'package:mornye/services/track_search_ranking.dart';
import 'package:mornye/services/lastfm_wave_service.dart';

/// Keep version labels: a live/remix result must never replace a studio track.
String waveMatchKey(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[’‘]'), "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _artistMatchKey(String value) {
  final normalized = waveMatchKey(value);
  // Deezer uses the band's stylized name; this is a specific catalogue alias,
  // not a general Cyrillic transliteration or fuzzy artist match.
  return normalized == 'koяn' ? 'korn' : normalized;
}

Track? matchWaveTrack(
  LastfmWaveTrack recommendation,
  Iterable<Track> results, {
  bool preferExplicit = true,
}) {
  final matches = results.where(
    (track) =>
        !track.isCollection &&
        track.id.isNotEmpty &&
        waveMatchKey(withoutCensorshipMarker(track.name)) ==
            waveMatchKey(withoutCensorshipMarker(recommendation.title)) &&
        _artistMatchKey(track.artistName) ==
            _artistMatchKey(recommendation.artist),
  );
  if (matches.isEmpty) return null;
  return matches.reduce(
    (best, next) =>
        compareTrackVersions(best, next, preferExplicit: preferExplicit) <= 0
        ? best
        : next,
  );
}

typedef WaveTrackSearch = Future<List<Track>> Function(LastfmWaveTrack track);

/// A failed lookup must not discard recordings found by earlier lookups.
Future<({List<Track> tracks, int failures})> resolveWaveBatch(
  Iterable<LastfmWaveTrack> candidates,
  WaveTrackSearch search,
) async {
  final tracks = <Track>[];
  var failures = 0;
  for (final candidate in candidates.take(5)) {
    try {
      final match = matchWaveTrack(candidate, await search(candidate));
      if (match != null) tracks.add(match);
    } on Exception {
      failures++;
    }
  }
  return (tracks: tracks, failures: failures);
}

/// Some catalogues omit the exact recording for an artist+title query while
/// returning it for title alone. A non-explicit match also gets this one bounded
/// chance to find an uncensored version; other version labels remain significant.
Future<List<Track>> searchWaveCandidates(
  LastfmWaveTrack requested,
  Future<List<Track>> Function(String query) search, {
  bool preferExplicit = true,
  void Function(String phase, int count, bool matched)? onResult,
}) async {
  final title = withoutCensorshipMarker(requested.title);
  final queries = ['${requested.artist} $title', title];
  Track? best;
  for (var index = 0; index < queries.length; index++) {
    late final List<Track> results;
    try {
      results = await search(queries[index]);
    } on Exception {
      if (best case final existing?) return [existing];
      rethrow;
    }
    final match = matchWaveTrack(
      requested,
      results,
      preferExplicit: preferExplicit,
    );
    onResult?.call(
      index == 0 ? 'primary' : 'title_fallback',
      results.length,
      match != null,
    );
    if (match != null) {
      if (best == null ||
          compareTrackVersions(match, best, preferExplicit: preferExplicit) <
              0) {
        best = match;
      }
      if (!preferExplicit || best.censorship != TrackCensorship.clean) {
        return [best];
      }
    }
  }
  return [?best];
}
