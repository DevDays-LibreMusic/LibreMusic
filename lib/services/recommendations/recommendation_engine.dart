import 'dart:math';
import 'package:mornye/utils/windows_path_identity.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/utils/artist_utils.dart' show splitArtistTagValues;

String recommendationSongKey(String artist, String title) =>
    '${normalizeLookupText(artist)}|${normalizeLookupText(title)}';
Set<String> recommendationGenres(String? value) => (value ?? '')
    .split(RegExp(r'[,;/|&]'))
    .map(normalizeLookupText)
    .where((s) => s.isNotEmpty)
    .toSet();

/// Deliberately coarse, offline mood presets inferred from genre metadata.
/// Unknown genres never count as a mood match.
const recommendationMoodGenres = <String, Set<String>>{
  'calm': {
    'ambient',
    'ambientgenre',
    'newage',
    'new age',
    'classical',
    'modern',
    'chillout',
    'lounge',
  },
  'energetic': {
    'rock',
    'rusrock',
    'punk',
    'metal',
    'classicmetal',
    'epicmetal',
    'breakbeatgenre',
    'dance',
    'techno',
    'house',
    'electronics',
    'hip-hop',
    'rusrap',
  },
  'bright': {'pop', 'ruspop', 'disco', 'funk', 'reggae', 'ska', 'dance'},
  'melancholic': {
    'blues',
    'soul',
    'vocaljazz',
    'triphopgenre',
    'trip-hop',
    'alternative',
    'local-indie',
  },
};

/// Compare directory boundaries, not arbitrary string prefixes. SAF document
/// identifiers are decoded once; their provider authority stays part of identity.
bool recommendationFolderContains(String folder, String source) {
  final folderUri = Uri.tryParse(folder), sourceUri = Uri.tryParse(source);
  String? document(Uri uri) {
    final segments = uri.pathSegments;
    var index = segments.lastIndexOf('document');
    if (index < 0) index = segments.lastIndexOf('tree');
    return index >= 0 && index + 1 < segments.length
        ? segments[index + 1]
        : null;
  }

  if (folderUri?.scheme == 'content' || sourceUri?.scheme == 'content') {
    if (folderUri?.scheme != 'content' ||
        sourceUri?.scheme != 'content' ||
        folderUri!.authority != sourceUri!.authority) {
      return false;
    }
    final base = document(folderUri), file = document(sourceUri);
    return base != null &&
        file != null &&
        file.startsWith('${base.replaceAll(RegExp(r'/+$'), '')}/');
  }
  final windowsFolder = windowsPathIdentity(folder),
      windowsSource = windowsPathIdentity(source);
  final base = (windowsFolder?.toLowerCase() ?? folder).replaceAll(
    RegExp(r'/+$'),
    '',
  );
  final file = windowsSource?.toLowerCase() ?? source;
  return file.startsWith('$base/');
}

class RecommendationCandidate {
  const RecommendationCandidate(
    this.media, {
    this.year,
    this.markedExplicit = false,
    this.streamable = false,
  });
  final PlayableMedia media;
  final int? year;
  final bool markedExplicit;
  final bool streamable;
  String get key => recommendationSongKey(media.artist, media.title);
}

class RecommendationHistory {
  const RecommendationHistory({
    this.plays = const {},
    this.lastPlayed = const {},
  });
  final Map<String, int> plays;
  final Map<String, DateTime> lastPlayed;
}

/// The same predicate protects discovery and the final result. Missing data
/// never masquerades as a known value. Explicit legacy tags only mark positives.
bool recommendationMatches(
  RecommendationProfile profile,
  RecommendationCandidate candidate, {
  required RecommendationHistory history,
  required DateTime now,
  Set<String>? playlistSongs,
}) {
  final media = candidate.media;
  final serverStream =
      candidate.streamable &&
      Uri.tryParse(media.source)?.scheme == 'musicserver';
  if ((media.isNetwork && !serverStream) || media.source.isEmpty) {
    return false;
  }
  if (profile.excludedTracks.contains(candidate.key)) return false;
  if (profile.excludeMarkedExplicit && candidate.markedExplicit) return false;
  final genres = recommendationGenres(media.genre);
  if (profile.moods.isNotEmpty &&
      !profile.moods.any(
        (mood) => recommendationMoodGenres[mood]?.any(genres.contains) ?? false,
      )) {
    return false;
  }
  final artists = splitArtistTagValues(
    media.artist,
  ).map(normalizeLookupText).where((s) => s.isNotEmpty).toSet();
  bool tags(Set<String> actual, List<String> include, List<String> exclude) {
    if (include.isEmpty && exclude.isEmpty) return true;
    if (actual.isEmpty) return !profile.excludeUnknown;
    if (exclude.map(normalizeLookupText).any(actual.contains)) return false;
    return include.isEmpty ||
        include.map(normalizeLookupText).any(actual.contains);
  }

  bool range(int? value, int? lower, int? upper) {
    if (lower == null && upper == null) return true;
    if (value == null || value <= 0) return !profile.excludeUnknown;
    return (lower == null || value >= lower) &&
        (upper == null || value <= upper);
  }

  if (!tags(genres, profile.genres, profile.excludedGenres) ||
      !tags(artists, profile.artists, profile.excludedArtists) ||
      !range(
        media.duration?.inSeconds,
        profile.minSeconds,
        profile.maxSeconds,
      ) ||
      !range(candidate.year, profile.minYear, profile.maxYear)) {
    return false;
  }
  if (profile.folders.isNotEmpty &&
      !profile.folders.any(
        (folder) => recommendationFolderContains(folder, media.source),
      )) {
    return false;
  }
  if (profile.playlistIds.isNotEmpty &&
      !(playlistSongs?.contains(candidate.key) ?? false)) {
    return false;
  }
  final last = history.lastPlayed[candidate.key];
  return profile.repeatDays == 0 ||
      last == null ||
      now.difference(last).inDays >= profile.repeatDays;
}

class RecommendationPick {
  const RecommendationPick(this.candidate, this.parts);
  final RecommendationCandidate candidate;
  final Map<String, double> parts;
  PlayableMedia get media => candidate.media;
}

/// Plain data work request, safe to send to an isolate.
class RecommendationRanking {
  const RecommendationRanking({
    required this.profile,
    required this.candidates,
    required this.history,
    this.weights = const {},
    this.artistAffinity = const {},
    this.signals = const [],
    this.session = const [],
    this.limit = 20,
  });
  final RecommendationProfile profile;
  final List<RecommendationCandidate> candidates;
  final RecommendationHistory history;
  final Map<String, double> weights, artistAffinity;
  final List<AutoplaySignal> signals;
  final List<PlayableMedia> session;
  final int limit;
}

List<RecommendationPick> rankRecommendations(RecommendationRanking input) {
  final p = input.profile;
  for (final signal in input.signals) {
    signal.prepare(
      input.session,
      input.candidates.map((c) => c.media).toList(),
    );
  }
  final scored = input.candidates.map((c) {
    final plays = input.history.plays[c.key] ?? 0;
    final parts = <String, double>{
      'discovery': p.discovery * (plays == 0 ? 2 : 1 / (1 + plays)),
      'familiar': (1 - p.discovery) * min(2, log(1 + plays)),
      'history':
          p.history *
          (input.artistAffinity[normalizeLookupText(c.media.artist)] ?? 0)
              .clamp(-2, 2),
      if (input.session.isNotEmpty)
        'similarity':
            p.history *
            ((recommendationGenres(c.media.genre)
                        .intersection(
                          recommendationGenres(input.session.last.genre),
                        )
                        .isNotEmpty
                    ? 1
                    : 0) +
                (c.media.artist.trim().isNotEmpty &&
                        normalizeLookupText(c.media.artist) ==
                            normalizeLookupText(input.session.last.artist)
                    ? 1
                    : 0)),
      if (p.sound > 0)
        'sound':
            p.sound *
            input.signals
                .fold<double>(0, (sum, s) => sum + s.score(c.media))
                .clamp(-2, 2),
    };
    return RecommendationPick(c, parts);
  }).toList();
  double score(RecommendationPick pick) => pick.parts.entries.fold<double>(
    0,
    (sum, e) =>
        sum +
        e.value * (p.learning ? (input.weights[e.key] ?? 1).clamp(.5, 1.5) : 1),
  );
  final result = <RecommendationPick>[];
  final artists = <String, int>{};
  final seen = <String>{};
  while (scored.isNotEmpty && result.length < input.limit) {
    double adjusted(RecommendationPick pick) =>
        score(pick) -
        p.diversity *
            2 *
            (artists[normalizeLookupText(pick.media.artist)] ?? 0);
    var best = 0;
    for (var i = 1; i < scored.length; i++) {
      if (adjusted(scored[i]) > adjusted(scored[best])) best = i;
    }
    final pick = scored.removeAt(best);
    if (!seen.add(pick.candidate.key)) continue;
    result.add(pick);
    final artist = normalizeLookupText(pick.media.artist);
    artists[artist] = (artists[artist] ?? 0) + 1;
  }
  return result;
}
