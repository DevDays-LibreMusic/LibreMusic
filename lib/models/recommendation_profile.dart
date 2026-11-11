/// Versioned, device-local recommendation settings. Empty lists mean any.
class RecommendationProfile {
  const RecommendationProfile({
    required this.id,
    required this.name,
    this.revision = 1,
    this.genres = const [],
    this.moods = const [],
    this.excludedGenres = const [],
    this.artists = const [],
    this.excludedArtists = const [],
    this.folders = const [],
    this.playlistIds = const [],
    this.excludedTracks = const [],
    this.minSeconds,
    this.maxSeconds,
    this.minYear,
    this.maxYear,
    this.excludeMarkedExplicit = false,
    this.excludeUnknown = true,
    this.repeatDays = 0,
    this.discovery = 0.5,
    this.diversity = 0.5,
    this.history = 0.5,
    this.sound = 0,
    this.learning = true,
  });

  final String id, name;
  final int revision;
  final List<String> genres, excludedGenres, artists, excludedArtists;
  final List<String> moods;
  final List<String> folders, playlistIds, excludedTracks;
  final int? minSeconds, maxSeconds, minYear, maxYear;
  final bool excludeMarkedExplicit, excludeUnknown, learning;
  final int repeatDays;
  final double discovery, diversity, history, sound;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'revision': revision,
    'genres': genres,
    'moods': moods,
    'excludedGenres': excludedGenres,
    'artists': artists,
    'excludedArtists': excludedArtists,
    'folders': folders,
    'playlistIds': playlistIds,
    'excludedTracks': excludedTracks,
    'minSeconds': minSeconds,
    'maxSeconds': maxSeconds,
    'minYear': minYear,
    'maxYear': maxYear,
    'excludeMarkedExplicit': excludeMarkedExplicit,
    'excludeUnknown': excludeUnknown,
    'repeatDays': repeatDays,
    'discovery': discovery,
    'diversity': diversity,
    'history': history,
    'sound': sound,
    'learning': learning,
  };

  factory RecommendationProfile.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('Profile version');
    List<String> list(String key) => List.unmodifiable(
      (json[key] as List? ?? const [])
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet(),
    );
    int? number(String key) => (json[key] as num?)?.toInt();
    double weight(String key, double fallback) {
      final value = (json[key] as num?)?.toDouble();
      return value != null && value.isFinite ? value.clamp(0, 1) : fallback;
    }

    return RecommendationProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      revision: (number('revision') ?? 1).clamp(1, 1 << 30),
      genres: list('genres'),
      moods: list('moods'),
      excludedGenres: list('excludedGenres'),
      artists: list('artists'),
      excludedArtists: list('excludedArtists'),
      folders: list('folders'),
      playlistIds: list('playlistIds'),
      excludedTracks: list('excludedTracks'),
      minSeconds: number('minSeconds'),
      maxSeconds: number('maxSeconds'),
      minYear: number('minYear'),
      maxYear: number('maxYear'),
      excludeMarkedExplicit: json['excludeMarkedExplicit'] == true,
      excludeUnknown: json['excludeUnknown'] != false,
      repeatDays: (number('repeatDays') ?? 0).clamp(0, 3650),
      discovery: weight('discovery', .5),
      diversity: weight('diversity', .5),
      history: weight('history', .5),
      sound: weight('sound', 0),
      learning: json['learning'] != false,
    );
  }

  RecommendationProfile update(Map<String, dynamic> changes) =>
      RecommendationProfile.fromJson({...toJson(), ...changes});

  bool get valid =>
      name.trim().isNotEmpty &&
      (minSeconds == null || minSeconds! >= 0) &&
      (maxSeconds == null || maxSeconds! > 0) &&
      (minSeconds == null ||
          maxSeconds == null ||
          minSeconds! <= maxSeconds!) &&
      (minYear == null || minYear! > 0) &&
      (maxYear == null || maxYear! > 0) &&
      (minYear == null || maxYear == null || minYear! <= maxYear!);
}
