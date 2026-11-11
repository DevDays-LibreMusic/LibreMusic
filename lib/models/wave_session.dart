import 'package:mornye/models/track.dart';

enum WaveKind { personal, track, artist, album, genre }

enum WaveMode { familiar, balanced, discovery }

class WaveContext {
  const WaveContext({
    this.kind = WaveKind.personal,
    this.title = 'Моя волна',
    this.artist = '',
    this.track,
    this.albumTracks = const [],
  });
  final WaveKind kind;
  final String title;
  final String artist;
  final Track? track;
  final List<Track> albumTracks;
  String get key => '${kind.name}:$artist:$title';
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'artist': artist,
    if (track != null) 'track': track!.toJson(),
    'albumTracks': albumTracks.map((t) => t.toJson()).toList(),
  };
  factory WaveContext.fromJson(Map<String, dynamic> json) => WaveContext(
    kind: WaveKind.values.byName(json['kind'] as String),
    title: json['title'] as String,
    artist: json['artist'] as String? ?? '',
    track: json['track'] is Map
        ? Track.fromJson(Map<String, dynamic>.from(json['track'] as Map))
        : null,
    albumTracks: (json['albumTracks'] as List? ?? [])
        .map((t) => Track.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
  );
}

String waveTrackKey(String artist, String title) =>
    '${artist.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}\u0000${title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}';
String waveArtistKey(String artist) =>
    artist.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String waveRecordingKey(Track track) {
  final id = track.id.trim();
  final source = (track.source ?? '').trim().toLowerCase();
  if (id.isNotEmpty) {
    final normalized = source.isNotEmpty && id.startsWith('$source:')
        ? id.substring(source.length + 1)
        : id;
    return 'catalog:$source:$normalized';
  }
  final isrc = track.isrc?.trim().toUpperCase() ?? '';
  if (isrc.isNotEmpty) return 'isrc:$isrc';
  return 'metadata:${waveTrackKey(track.artistName, track.name)}:${track.albumName}:${track.duration}';
}

class WaveSessionState {
  const WaveSessionState({
    this.needsSeeds = false,
    this.seedUnavailable = false,
    this.context = const WaveContext(),
    this.mode = WaveMode.balanced,
    this.busy = false,
    this.error,
    this.offline = false,
    this.active = false,
    this.loaded = false,
    this.seedArtists = const [],
    this.recentContexts = const [],
    this.blockedTracks = const {},
    this.blockedArtists = const {},
    this.cacheBytes = 0,
    this.cacheLimitBytes = 1073741824,
    this.backgroundMobile = false,
  });
  final bool needsSeeds, seedUnavailable;
  final WaveContext context;
  final WaveMode mode;
  final bool busy, offline, active, loaded;
  final String? error;
  final List<String> seedArtists;
  final List<WaveContext> recentContexts;
  final Map<String, String> blockedTracks;
  final Set<String> blockedArtists;
  final int cacheBytes, cacheLimitBytes;
  final bool backgroundMobile;
  WaveSessionState copyWith({
    bool? needsSeeds,
    bool? seedUnavailable,
    WaveContext? context,
    WaveMode? mode,
    bool? busy,
    String? error,
    bool clearError = false,
    bool? offline,
    bool? active,
    bool? loaded,
    List<String>? seedArtists,
    List<WaveContext>? recentContexts,
    Map<String, String>? blockedTracks,
    Set<String>? blockedArtists,
    int? cacheBytes,
    int? cacheLimitBytes,
    bool? backgroundMobile,
  }) => WaveSessionState(
    needsSeeds: needsSeeds ?? this.needsSeeds,
    seedUnavailable: seedUnavailable ?? this.seedUnavailable,
    context: context ?? this.context,
    mode: mode ?? this.mode,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
    offline: offline ?? this.offline,
    active: active ?? this.active,
    loaded: loaded ?? this.loaded,
    seedArtists: seedArtists ?? this.seedArtists,
    recentContexts: recentContexts ?? this.recentContexts,
    blockedTracks: blockedTracks ?? this.blockedTracks,
    blockedArtists: blockedArtists ?? this.blockedArtists,
    cacheBytes: cacheBytes ?? this.cacheBytes,
    cacheLimitBytes: cacheLimitBytes ?? this.cacheLimitBytes,
    backgroundMobile: backgroundMobile ?? this.backgroundMobile,
  );
}
