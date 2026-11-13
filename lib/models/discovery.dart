import 'package:mornye/models/track.dart';

enum DiscoveryKind { newReleases, trends }

class DiscoveryGenre {
  final String id;
  final String name;
  const DiscoveryGenre({required this.id, required this.name});
  factory DiscoveryGenre.fromJson(Map<String, dynamic> json) =>
      DiscoveryGenre(id: json['id'] as String, name: json['name'] as String);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class DiscoveryQuery {
  final DiscoveryKind kind;
  final String genreId;
  final String region;
  const DiscoveryQuery({
    required this.kind,
    this.genreId = '0',
    this.region = 'us',
  });
  String get cacheKey => '$region:${kind.name}:$genreId';
  @override
  bool operator ==(Object other) =>
      other is DiscoveryQuery &&
      other.kind == kind &&
      other.genreId == genreId &&
      other.region == region;
  @override
  int get hashCode => Object.hash(kind, genreId, region);
}

class DiscoveryOrigin {
  final String sourceId;
  final String sourceName;
  final String region;
  final String nativeId;
  final String? sourceUrl;
  final Track? nativeTrack;
  final int? position;
  const DiscoveryOrigin({
    required this.sourceId,
    required this.sourceName,
    required this.region,
    required this.nativeId,
    this.sourceUrl,
    this.nativeTrack,
    this.position,
  });
  factory DiscoveryOrigin.fromJson(Map<String, dynamic> json) =>
      DiscoveryOrigin(
        sourceId: json['sourceId'] as String,
        sourceName: json['sourceName'] as String,
        region: json['region'] as String,
        nativeId: json['nativeId'] as String,
        sourceUrl: json['sourceUrl'] as String?,
        nativeTrack: json['nativeTrack'] == null
            ? null
            : Track.fromJson(
                Map<String, dynamic>.from(json['nativeTrack'] as Map),
              ),
        position: json['position'] as int?,
      );
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'region': region,
    'nativeId': nativeId,
    'sourceUrl': sourceUrl,
    'nativeTrack': nativeTrack?.toJson(),
    'position': position,
  };
}

class DiscoverySourceStatus {
  final String sourceId;
  final String sourceName;
  final String region;
  final bool isStale;
  final bool isUnavailable;
  const DiscoverySourceStatus({
    required this.sourceId,
    required this.sourceName,
    required this.region,
    this.isStale = false,
    this.isUnavailable = false,
  });
  factory DiscoverySourceStatus.fromJson(Map<String, dynamic> json) =>
      DiscoverySourceStatus(
        sourceId: json['sourceId'] as String,
        sourceName: json['sourceName'] as String,
        region: json['region'] as String,
        isStale: json['isStale'] == true,
        isUnavailable: json['isUnavailable'] == true,
      );
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'region': region,
    'isStale': isStale,
    'isUnavailable': isUnavailable,
  };
}

class DiscoveryEntry {
  final Track track;
  final int? position;
  final List<String> genres;
  final List<DiscoveryOrigin> origins;
  final double? rankScore;
  const DiscoveryEntry({
    required this.track,
    this.position,
    this.genres = const [],
    this.origins = const [],
    this.rankScore,
  });
  factory DiscoveryEntry.fromJson(Map<String, dynamic> json) => DiscoveryEntry(
    track: Track.fromJson(json['track'] as Map<String, dynamic>),
    position: json['position'] as int?,
    genres: (json['genres'] as List).cast<String>(),
    origins: (json['origins'] as List? ?? [])
        .map(
          (e) => DiscoveryOrigin.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
    rankScore: (json['rankScore'] as num?)?.toDouble(),
  );
  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'position': position,
    'genres': genres,
    'origins': origins.map((e) => e.toJson()).toList(),
    'rankScore': rankScore,
  };
}

class DiscoveryFeed {
  final List<DiscoverySourceStatus> sources;
  final List<DiscoveryEntry> entries;
  final DateTime fetchedAt;
  final String region;
  final String sourceName;
  final bool isStale;
  const DiscoveryFeed({
    required this.entries,
    this.sources = const [],
    required this.fetchedAt,
    required this.region,
    required this.sourceName,
    this.isStale = false,
  });
  DiscoveryFeed copyWith({bool? isStale}) => DiscoveryFeed(
    entries: entries,
    sources: sources,
    fetchedAt: fetchedAt,
    region: region,
    sourceName: sourceName,
    isStale: isStale ?? this.isStale,
  );
  factory DiscoveryFeed.fromJson(Map<String, dynamic> json) => DiscoveryFeed(
    entries: (json['entries'] as List)
        .map(
          (e) => DiscoveryEntry.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
    sources: (json['sources'] as List? ?? [])
        .map(
          (e) => DiscoverySourceStatus.fromJson(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList(),
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    region: json['region'] as String,
    sourceName: json['sourceName'] as String,
  );
  Map<String, dynamic> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    'sources': sources.map((e) => e.toJson()).toList(),
    'fetchedAt': fetchedAt.toIso8601String(),
    'region': region,
    'sourceName': sourceName,
  };
}

class DiscoveryCatalog {
  final List<DiscoveryGenre> genres;
  final bool isStale;
  final String region;
  final String sourceName;
  const DiscoveryCatalog({
    required this.genres,
    required this.region,
    required this.sourceName,
    this.isStale = false,
  });
  DiscoveryCatalog copyWith({bool? isStale}) => DiscoveryCatalog(
    genres: genres,
    region: region,
    sourceName: sourceName,
    isStale: isStale ?? this.isStale,
  );
  factory DiscoveryCatalog.fromJson(Map<String, dynamic> json) =>
      DiscoveryCatalog(
        genres: (json['genres'] as List)
            .map(
              (e) =>
                  DiscoveryGenre.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        region: json['region'] as String,
        sourceName: json['sourceName'] as String,
      );
  Map<String, dynamic> toJson() => {
    'genres': genres.map((e) => e.toJson()).toList(),
    'region': region,
    'sourceName': sourceName,
  };
}

/// Preserve exact provider identity when a merged card is downloaded through
/// that provider. Metadata search remains the fallback for other services.
Track discoveryTrackForService(
  Track displayTrack,
  List<DiscoveryOrigin> origins,
  String service,
) {
  for (final origin in origins) {
    if (origin.sourceId == service && origin.nativeTrack != null) {
      final native = origin.nativeTrack!;
      return native.copyWith(
        isrc: native.isrc ?? displayTrack.isrc,
        deezerId: native.deezerId ?? displayTrack.deezerId,
        duration: native.duration > 0 ? native.duration : displayTrack.duration,
        genre: displayTrack.genre ?? native.genre,
      );
    }
  }
  return displayTrack;
}
