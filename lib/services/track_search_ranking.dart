import 'package:mornye/models/track.dart';
import 'package:mornye/models/track_censorship.dart';

int _censorshipRank(Track track) => switch (track.censorship) {
  TrackCensorship.clean => 0,
  TrackCensorship.unknown => 1,
  TrackCensorship.explicit => 2,
};

int _qualityRank(Track track) {
  final quality = track.audioQuality?.trim().toUpperCase() ?? '';
  if (quality.contains('HI_RES') || quality.contains('HI-RES')) return 400000;
  if (quality.contains('LOSSLESS') || quality.contains('FLAC')) return 300000;
  final bitrate = RegExp(r'(\d+)\s*(?:KBPS|K)?\b').firstMatch(quality);
  if (bitrate != null) return int.parse(bitrate.group(1)!);
  if (quality == 'HIGH') return 320;
  if (quality == 'LOW') return 96;
  return 0;
}

int compareTrackVersions(
  Track first,
  Track second, {
  bool preferExplicit = true,
}) {
  final firstCensorship = _censorshipRank(first);
  final secondCensorship = _censorshipRank(second);
  final firstQuality = _qualityRank(first);
  final secondQuality = _qualityRank(second);
  final primary = preferExplicit
      ? secondCensorship.compareTo(firstCensorship)
      : secondQuality.compareTo(firstQuality);
  if (primary != 0) return primary;
  return preferExplicit
      ? secondQuality.compareTo(firstQuality)
      : secondCensorship.compareTo(firstCensorship);
}

String? _versionKey(Track track) {
  if (track.isCollection) return null;
  final title = withoutCensorshipMarker(track.name).toLowerCase();
  final artist = track.artistName.trim().toLowerCase();
  if (title.isEmpty || artist.isEmpty) return null;
  return '$artist\u0000$title';
}

List<Track> rankTrackSearchResults(
  Iterable<Track> tracks, {
  bool preferExplicit = true,
}) {
  final input = tracks.toList();
  final groups = <String, List<Track>>{};
  for (final track in input) {
    final key = _versionKey(track);
    if (key != null) groups.putIfAbsent(key, () => []).add(track);
  }
  for (final versions in groups.values) {
    final original = versions.indexed.toList();
    original.sort((first, second) {
      final compared = compareTrackVersions(
        first.$2,
        second.$2,
        preferExplicit: preferExplicit,
      );
      return compared != 0 ? compared : first.$1.compareTo(second.$1);
    });
    versions.setAll(0, original.map((entry) => entry.$2));
  }
  final positions = <String, int>{};
  // Replace only a recording's original slots, preserving provider relevance
  // positions of other songs and collection results.
  return input.map((track) {
    final key = _versionKey(track);
    if (key == null) return track;
    final index = positions.update(
      key,
      (value) => value + 1,
      ifAbsent: () => 0,
    );
    return groups[key]![index];
  }).toList();
}
