import 'dart:math' as math;

import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';

/// One independent ranking. Related services share a family so that publishing
/// several charts cannot give one company multiple votes for the same recording.
class DiscoveryRanking {
  final String sourceId;
  final String family;
  final DiscoveryFeed feed;
  const DiscoveryRanking({
    required this.sourceId,
    required this.family,
    required this.feed,
  });
}

String canonicalDiscoveryGenre(String value) {
  final key = value.trim().toLowerCase().replaceAll(RegExp(r'[\s_/&-]+'), '');
  return switch (key) {
    'hiphop' || 'hiphoprap' || 'rap' => 'Hip-Hop/Rap',
    'rnb' || 'rbsoul' || 'randb' || 'rnbandsoul' => 'R&B/Soul',
    'electronic' || 'electronica' => 'Electronic',
    'pop' => 'Pop',
    'rock' => 'Rock',
    'dance' => 'Dance',
    'alternative' => 'Alternative',
    'jazz' => 'Jazz',
    'classical' => 'Classical',
    'country' => 'Country',
    'metal' => 'Metal',
    'indie' => 'Indie',
    _ => value.trim(),
  };
}

String _text(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp('[’‘`]'), "'")
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();
String _isrc(Track track) =>
    (track.isrc ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
String _version(Track track) {
  // Keep the complete title for fallback matching. These flags also protect
  // against a provider attaching the original ISRC to a different recording.
  final name = _text(track.name);
  final flags = RegExp(
    r'\b(live|remix|remaster(?:ed)?|acoustic|instrumental|karaoke|sped up|slowed|radio edit|mono|stereo|demo)\b',
  ).allMatches(name).map((m) => m.group(0)!).toSet().toList()..sort();
  return flags.join('|');
}

bool sameDiscoveryRecording(Track a, Track b) {
  if (a.isAlbumItem != b.isAlbumItem) return false;
  if (a.source == b.source && a.id == b.id) return true;
  if (a.explicit != null && b.explicit != null && a.explicit != b.explicit) {
    return false;
  }
  if (_version(a) != _version(b)) return false;
  if (_version(a).isNotEmpty && _text(a.name) != _text(b.name)) return false;
  if (a.duration > 0 && b.duration > 0 && (a.duration - b.duration).abs() > 4) {
    return false;
  }
  final ai = _isrc(a), bi = _isrc(b);
  if (!a.isAlbumItem && ai.isNotEmpty && bi.isNotEmpty) return ai == bi;
  if (a.isAlbumItem && a.upc?.isNotEmpty == true && b.upc?.isNotEmpty == true) {
    return a.upc == b.upc;
  }
  // Conservative fallback: punctuation/case only; never strip remix titles,
  // featured artists or accents to force a match.
  return _text(a.name).isNotEmpty &&
      _text(a.name) == _text(b.name) &&
      _text(a.artistName).isNotEmpty &&
      _text(a.artistName) == _text(b.artistName) &&
      (!a.isAlbumItem ||
          a.totalTracks == null ||
          b.totalTracks == null ||
          a.totalTracks == b.totalTracks);
}

DateTime? discoveryReleaseDay(String? value) {
  if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}(?:$|T)').hasMatch(value)) {
    return null;
  }
  final day = value.substring(0, 10);
  final parsed = DateTime.tryParse(day);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != day) {
    return null;
  }
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

class _Candidate {
  Track track;
  final List<Track> recordings;
  final Set<String> genres = {};
  final List<DiscoveryOrigin> origins = [];
  final Map<String, double> votes = {};
  _Candidate(this.track) : recordings = [track];
  double get score => votes.values.fold(0, (a, b) => a + b);
}

/// Reciprocal rank fusion: each independent family contributes at most
/// 61/(60+rank), without rewarding longer source lists. New releases receive a
/// bounded 0.7–1.0 freshness multiplier. Consensus adds independent votes.
List<DiscoveryEntry> aggregateDiscovery(
  List<DiscoveryRanking> rankings,
  DiscoveryKind kind, {
  required DateTime now,
}) {
  final candidates = <_Candidate>[];
  final today = DateTime.utc(now.year, now.month, now.day);
  for (final ranking in rankings) {
    final seen = <String>{};
    for (var index = 0; index < ranking.feed.entries.length; index++) {
      final entry = ranking.feed.entries[index];
      final track = entry.track;
      if (!seen.add('${track.itemType}:${track.id}')) continue;
      final date = discoveryReleaseDay(track.releaseDate);
      if (kind == DiscoveryKind.newReleases &&
          (date == null ||
              date.isAfter(today) ||
              today.difference(date).inDays > 30)) {
        continue;
      }
      _Candidate? candidate;
      for (final existing in candidates) {
        // Pairwise agreement prevents unknown metadata bridging conflicting
        // explicit/clean or differing-duration versions into the same group.
        if (existing.recordings.every(
          (item) => sameDiscoveryRecording(item, track),
        )) {
          candidate = existing;
          break;
        }
      }
      if (candidate == null) {
        candidate = _Candidate(track);
        candidates.add(candidate);
      } else {
        candidate.recordings.add(track);
        if (_completeness(track) > _completeness(candidate.track)) {
          candidate.track = track;
        }
      }
      candidate.genres.addAll(
        entry.genres.map(canonicalDiscoveryGenre).where((g) => g.isNotEmpty),
      );
      final rank = entry.position != null && entry.position! > 0
          ? entry.position!
          : index + 1;
      var vote = 61 / (60 + rank);
      if (kind == DiscoveryKind.newReleases) {
        vote *= 1 - 0.3 * today.difference(date!).inDays / 30;
      }
      if (ranking.feed.isStale) vote *= 0.85;
      candidate.votes[ranking.family] = math.max(
        candidate.votes[ranking.family] ?? 0,
        vote,
      );
      candidate.origins.add(
        DiscoveryOrigin(
          sourceId: ranking.sourceId,
          sourceName: ranking.feed.sourceName,
          region: ranking.feed.region,
          nativeId: track.id,
          sourceUrl: _sourceUrl(track),
          nativeTrack: track,
          position: entry.position,
        ),
      );
    }
  }
  candidates.sort((a, b) {
    final score = b.score.compareTo(a.score);
    return score != 0
        ? score
        : '${_text(a.track.artistName)}:${_text(a.track.name)}:${a.track.source}:${a.track.id}'
              .compareTo(
                '${_text(b.track.artistName)}:${_text(b.track.name)}:${b.track.source}:${b.track.id}',
              );
  });
  final ordered = <_Candidate>[];
  // At most two entries by the same credited artist in the last five when
  // another artist is available. In releases, also surface both songs and
  // albums: no more than two consecutive entries of one type while the other
  // is available. Keep scores intact and never discard valid discoveries.
  while (candidates.isNotEmpty) {
    final needsOtherType =
        kind == DiscoveryKind.newReleases &&
        ordered.length >= 2 &&
        ordered.last.track.isAlbumItem ==
            ordered[ordered.length - 2].track.isAlbumItem;
    bool matchesType(_Candidate candidate) =>
        !needsOtherType ||
        candidate.track.isAlbumItem != ordered.last.track.isAlbumItem;
    bool addsArtistVariety(_Candidate candidate) =>
        ordered
            .skip(math.max(0, ordered.length - 5))
            .where(
              (recent) =>
                  _text(recent.track.artistName) ==
                  _text(candidate.track.artistName),
            )
            .length <
        2;
    var next = candidates.indexWhere(
      (candidate) => matchesType(candidate) && addsArtistVariety(candidate),
    );
    if (next < 0 && needsOtherType) next = candidates.indexWhere(matchesType);
    if (next < 0) next = candidates.indexWhere(addsArtistVariety);
    if (next < 0) next = 0;
    ordered.add(candidates.removeAt(next));
  }
  return [
    for (var i = 0; i < ordered.length; i++)
      DiscoveryEntry(
        track: _mergedTrack(ordered[i]),
        position: i + 1,
        rankScore: ordered[i].score,
        genres: ordered[i].genres.toList()..sort(),
        origins: ordered[i].origins,
      ),
  ];
}

int _completeness(Track t) =>
    (t.isrc?.isNotEmpty == true ? 4 : 0) +
    (t.duration > 0 ? 2 : 0) +
    (t.explicit != null ? 1 : 0) +
    (t.coverUrl?.isNotEmpty == true ? 1 : 0) +
    (t.albumName.isNotEmpty ? 1 : 0);

String? _sourceUrl(Track track) {
  final id = Uri.encodeComponent(track.id);
  final kind = track.isAlbumItem ? 'album' : 'track';
  return switch (track.source) {
    'deezer' => 'https://www.deezer.com/$kind/$id',
    'lastfm' =>
      'https://www.last.fm/music/${Uri.encodeComponent(track.artistName)}/_/${Uri.encodeComponent(track.name)}',
    'yandex-music' =>
      track.isAlbumItem
          ? 'https://music.yandex.ru/album/$id'
          : (track.albumId?.isNotEmpty == true
                ? 'https://music.yandex.ru/album/${Uri.encodeComponent(track.albumId!)}/track/$id'
                : null),
    'apple-music' || 'itunes' =>
      track.isAlbumItem
          ? 'https://music.apple.com/us/album/$id'
          : 'https://music.apple.com/us/song/$id',
    _ => null,
  };
}

Track _mergedTrack(_Candidate candidate) {
  final selected = candidate.track;
  final tracks = candidate.recordings;
  final deezer = tracks
      .where((t) => t.source == 'deezer' && !t.isAlbumItem)
      .firstOrNull;
  return selected.copyWith(
    deezerId: selected.deezerId ?? deezer?.id,
    isrc:
        selected.isrc ??
        tracks.where((t) => t.isrc?.isNotEmpty == true).firstOrNull?.isrc,
    explicit:
        selected.explicit ??
        tracks.where((t) => t.explicit != null).firstOrNull?.explicit,
    genre: candidate.genres.isEmpty
        ? selected.genre
        : (candidate.genres.toList()..sort()).join(', '),
    duration: selected.duration > 0
        ? selected.duration
        : tracks.where((t) => t.duration > 0).firstOrNull?.duration,
    releaseDate:
        selected.releaseDate ??
        tracks
            .where((t) => discoveryReleaseDay(t.releaseDate) != null)
            .firstOrNull
            ?.releaseDate,
  );
}
