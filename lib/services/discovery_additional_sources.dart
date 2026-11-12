import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_source.dart';

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String _text(dynamic value) => value?.toString() ?? '';
int _integer(dynamic value) => int.tryParse(_text(value)) ?? 0;
String _label(dynamic value) => _text(_map(value)['label']);

/// Exact publication dates only; an added-to-catalog date or a year is not a
/// release date. Providers may return future preorder entries in their charts.
bool _recent(String? value, DateTime now) {
  if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}(?:$|T)').hasMatch(value)) {
    return false;
  }
  final day = value.substring(0, 10);
  final date = DateTime.tryParse(day);
  if (date == null || date.toIso8601String().substring(0, 10) != day) {
    return false;
  }
  final age = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(date.year, date.month, date.day));
  return !age.isNegative && age <= const Duration(days: 30);
}

abstract class _PublicDiscoverySource implements DiscoverySource {
  _PublicDiscoverySource({http.Client? client, DateTime Function()? now})
    : client = client ?? http.Client(),
      now = now ?? DateTime.now;

  final http.Client client;
  final DateTime Function() now;
  final Map<DiscoveryKind, Future<DiscoveryFeed>> _pending = {};
  final Map<DiscoveryKind, DiscoveryFeed> _cached = {};
  String get sourceName;
  String get region;
  Set<DiscoveryKind> get supportedKinds;
  Future<List<DiscoveryEntry>> load(DiscoveryKind kind);
  Future<Map<String, String>> requestHeaders() async => const {};

  Future<dynamic> request(Uri uri, {Map<String, String>? body}) async {
    final headers = {'User-Agent': 'LibreMusic/1.0', ...await requestHeaders()};
    final response =
        await (body == null
                ? client.get(uri, headers: headers)
                : client.post(uri, headers: headers, body: body))
            .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      // Never include response bodies or authorization material in failures.
      throw StateError(
        '$sourceName request failed: HTTP ${response.statusCode}',
      );
    }
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (_map(value).containsKey('error')) {
      throw StateError('$sourceName returned an API error');
    }
    return value;
  }

  Future<DiscoveryFeed> _feed(DiscoveryKind kind) {
    if (!supportedKinds.contains(kind)) {
      throw UnsupportedError('$sourceName does not provide ${kind.name}');
    }
    final cached = _cached[kind];
    if (cached != null &&
        now().difference(cached.fetchedAt) < const Duration(minutes: 5)) {
      return Future.value(cached);
    }
    return _pending.putIfAbsent(kind, () {
      return load(kind)
          .then((entries) {
            final feed = DiscoveryFeed(
              entries: entries,
              fetchedAt: now(),
              region: region,
              sourceName: sourceName,
            );
            _cached[kind] = feed;
            return feed;
          })
          .whenComplete(() {
            _pending.remove(kind);
          });
    });
  }

  @override
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    // Each adapter has a fixed, truthful market. The aggregate query does not
    // relabel an IP-selected chart as a US chart.
    final feed = await _feed(query.kind);
    return DiscoveryFeed(
      entries: query.genreId == '0'
          ? feed.entries
          : feed.entries
                .where((e) => e.genres.contains(query.genreId))
                .toList(),
      fetchedAt: feed.fetchedAt,
      region: feed.region,
      sourceName: feed.sourceName,
    );
  }

  @override
  Future<DiscoveryCatalog> getCatalog() async {
    final genres = <String>{};
    var successes = 0;
    Object? failure;
    for (final kind in supportedKinds) {
      try {
        final feed = await _feed(kind);
        genres.addAll(feed.entries.expand((e) => e.genres));
        successes++;
      } catch (error) {
        failure = error;
      }
    }
    if (successes == 0) {
      throw failure ?? StateError('No discovery data');
    }
    final names = genres.toList()..sort();
    return DiscoveryCatalog(
      genres: [
        const DiscoveryGenre(id: '0', name: 'All'),
        ...names.map((g) => DiscoveryGenre(id: g, name: g)),
      ],
      region: region,
      sourceName: sourceName,
    );
  }

  @override
  void close() => client.close();
}

/// Deezer's public ordered chart. Its market is chosen by the service/IP, not
/// by a country parameter. The chart does not supply track genres or ISRCs; we
/// deliberately leave those unknown rather than infer them from artist names.
class DeezerDiscoverySource extends _PublicDiscoverySource {
  DeezerDiscoverySource({super.client, super.now});
  @override
  String get sourceId => 'deezer';
  @override
  String get sourceName => 'Deezer';
  @override
  String get region => 'auto';
  @override
  Set<DiscoveryKind> get supportedKinds => {DiscoveryKind.trends};

  Track _track(Map<String, dynamic> row, [Map<String, dynamic>? album]) {
    album ??= _map(row['album']);
    return Track(
      id: _text(row['id']),
      name: _text(row['title']),
      artistName: _text(_map(row['artist'])['name']),
      artistId: _text(_map(row['artist'])['id']),
      albumName: _text(album['title']),
      albumId: _text(album['id']),
      coverUrl: _text(album['cover_xl'] ?? album['cover_big']),
      duration: _integer(row['duration']),
      isrc: row['isrc'] as String?,
      explicit: row['explicit_lyrics'] as bool?,
      releaseDate:
          row['release_date'] as String? ?? album['release_date'] as String?,
      deezerId: _text(row['id']),
      source: sourceId,
    );
  }

  @override
  Future<List<DiscoveryEntry>> load(DiscoveryKind kind) async {
    final json = _map(
      await request(
        Uri.https('api.deezer.com', '/chart/0/tracks', {'limit': '100'}),
      ),
    );
    if (json['data'] is! List) {
      throw const FormatException('Invalid Deezer chart');
    }
    final entries = <DiscoveryEntry>[];
    final seen = <String>{};
    final rows = json['data'] as List;
    for (var index = 0; index < rows.length; index++) {
      final row = _map(rows[index]);
      final track = _track(row);
      if (track.id.isEmpty || track.name.isEmpty || !seen.add(track.id)) {
        continue;
      }
      entries.add(DiscoveryEntry(track: track, position: index + 1));
    }
    return entries;
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) async {
    if (!RegExp(r'^\d+$').hasMatch(albumId)) {
      throw ArgumentError('Invalid album ID');
    }
    final album = _map(
      await request(Uri.https('api.deezer.com', '/album/$albumId')),
    );
    final tracks = _map(album['tracks'])['data'];
    if (tracks is! List) {
      throw const FormatException('Invalid Deezer album');
    }
    return tracks.map((e) => _track(_map(e), album)).toList();
  }
}

/// Apple's public iTunes sales charts, distinct from Apple Music streaming.
/// New releases are recently released songs and albums in their sales charts,
/// not a claim to provide all new music. Aggregate scoring groups this with
/// Apple Music so two related Apple feeds cannot count as two independent votes.
class ItunesDiscoverySource extends _PublicDiscoverySource {
  ItunesDiscoverySource({super.client, super.now});
  @override
  String get sourceId => 'itunes';
  @override
  String get sourceName => 'iTunes Charts';
  @override
  String get region => 'us';
  @override
  Set<DiscoveryKind> get supportedKinds => DiscoveryKind.values.toSet();

  @override
  Future<List<DiscoveryEntry>> load(DiscoveryKind kind) async {
    if (kind == DiscoveryKind.trends) {
      return _loadChart(albums: false, recentOnly: false);
    }
    // A broken album feed must not hide fresh songs (and vice versa). Each
    // chart retains its own original positions; neither becomes a second vote.
    Object? failure;
    var successes = 0;
    final feeds = await Future.wait(
      [false, true].map((albums) async {
        try {
          final entries = await _loadChart(albums: albums, recentOnly: true);
          successes++;
          return entries;
        } catch (error) {
          failure = error;
          return <DiscoveryEntry>[];
        }
      }),
    );
    if (successes == 0) {
      throw failure ?? StateError('iTunes new releases are unavailable');
    }
    return feeds.expand((entries) => entries).toList();
  }

  Future<List<DiscoveryEntry>> _loadChart({
    required bool albums,
    required bool recentOnly,
  }) async {
    final chart = albums ? 'topalbums' : 'topsongs';
    final data = _map(
      await request(
        Uri.parse('https://itunes.apple.com/us/rss/$chart/limit=100/json'),
      ),
    );
    final rows = _map(data['feed'])['entry'];
    if (rows is! List) {
      throw const FormatException('Invalid iTunes chart');
    }
    final entries = <DiscoveryEntry>[];
    final seen = <String>{};
    for (var index = 0; index < rows.length; index++) {
      final row = _map(rows[index]);
      final id = _text(_map(_map(row['id'])['attributes'])['im:id']);
      final name = _label(row['im:name']);
      final date = _label(row['im:releaseDate']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) {
        continue;
      }
      if (recentOnly && !_recent(date, now())) {
        continue;
      }
      final genre = _text(_map(_map(row['category'])['attributes'])['label']);
      final images = row['im:image'] as List? ?? [];
      final link = _label(row['id']);
      final albumId = albums
          ? id
          : RegExp(r'/album/[^/]+/(\d+)').firstMatch(link)?.group(1);
      entries.add(
        DiscoveryEntry(
          position: index + 1,
          genres: genre.isEmpty ? const [] : [genre],
          track: Track(
            id: id,
            name: name,
            artistName: _label(row['im:artist']),
            albumName: albums
                ? name
                : _label(_map(row['im:collection'])['im:name']),
            albumId: albumId,
            duration: 0, // Feed preview duration is NOT the recording duration.
            coverUrl: images.isEmpty ? null : _label(images.last),
            releaseDate: date.isEmpty ? null : date,
            genre: genre,
            totalTracks: albums ? _integer(_label(row['im:itemCount'])) : null,
            itemType: albums ? 'album' : null,
            source: sourceId,
          ),
        ),
      );
    }
    return entries;
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) async {
    if (!RegExp(r'^\d+$').hasMatch(albumId)) {
      throw ArgumentError('Invalid album ID');
    }
    final json = _map(
      await request(
        Uri.https('itunes.apple.com', '/lookup', {
          'id': albumId,
          'country': region,
          'entity': 'song',
          'limit': '200',
        }),
      ),
    );
    if (json['results'] is! List) {
      throw const FormatException('Invalid iTunes album');
    }
    return (json['results'] as List)
        .map(_map)
        .where(
          (r) =>
              r['wrapperType'] == 'track' &&
              r['kind'] == 'song' &&
              _text(r['collectionId']) == albumId,
        )
        .map(
          (r) => Track(
            id: _text(r['trackId']),
            name: _text(r['trackName']),
            artistName: _text(r['artistName']),
            albumName: _text(r['collectionName']),
            albumId: albumId,
            duration: (_integer(r['trackTimeMillis']) / 1000).round(),
            coverUrl: r['artworkUrl100'] as String?,
            releaseDate: r['releaseDate'] as String?,
            explicit: r['trackExplicitness'] == null
                ? null
                : r['trackExplicitness'] == 'explicit',
            trackNumber: _integer(r['trackNumber']),
            source: sourceId,
          ),
        )
        .toList();
  }
}

/// Public catalog endpoints documented by the independent yandex-music-api
/// project, not a supported official Yandex developer API. A restricted market
/// can return HTTP 451, and anonymous access can be revoked by the service.
/// Such errors are surfaced to the aggregator, never replaced with fake data.
class YandexDiscoverySource extends _PublicDiscoverySource {
  YandexDiscoverySource({super.client, super.now, this.tokenProvider});
  final Future<String?> Function()? tokenProvider;
  @override
  Future<Map<String, String>> requestHeaders() async {
    String? token;
    try {
      token = await tokenProvider?.call().timeout(const Duration(seconds: 2));
    } catch (_) {
      // An uninstalled extension or unavailable keyring must not block public
      // metadata requests. Authorization remains optional for this adapter.
    }
    final value = token?.trim().replaceFirst(
      RegExp(r'^OAuth\s+', caseSensitive: false),
      '',
    );
    if (value == null || value.isEmpty) {
      return const {};
    }
    if (value.contains('\r') || value.contains('\n')) {
      throw const FormatException('Invalid Yandex authorization');
    }
    return {'Authorization': 'OAuth $value'};
  }

  @override
  String get sourceId => 'yandex-music';
  @override
  String get sourceName => 'Yandex Music';
  @override
  String get region => 'auto';
  @override
  Set<DiscoveryKind> get supportedKinds => DiscoveryKind.values.toSet();

  Future<dynamic> _result(String path, {Map<String, String>? body}) async {
    final json = _map(
      await request(Uri.https('api.music.yandex.net', path), body: body),
    );
    if (!json.containsKey('result')) {
      throw const FormatException('Invalid Yandex response');
    }
    return json['result'];
  }

  String _artists(dynamic value) => (value is List ? value : const <dynamic>[])
      .map((a) => _text(_map(a)['name']))
      .where((s) => s.isNotEmpty)
      .join(', ');
  String? _cover(dynamic value) {
    final uri = _text(value);
    if (uri.isEmpty) {
      return null;
    }
    return 'https://${uri.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^//'), '').replaceAll('%%', '600x600')}';
  }

  Track _track(Map<String, dynamic> row, [Map<String, dynamic>? album]) {
    album ??= row['albums'] is List && (row['albums'] as List).isNotEmpty
        ? _map((row['albums'] as List).first)
        : {};
    final version = _text(row['version']);
    return Track(
      id: _text(row['id']),
      name: '${_text(row['title'])}${version.isEmpty ? '' : ' ($version)'}',
      artistName: _artists(row['artists']),
      albumName: _text(album['title']),
      albumId: _text(album['id']),
      coverUrl: _cover(row['coverUri'] ?? album['coverUri']),
      duration: (_integer(row['durationMs']) / 1000).round(),
      isrc: row['isrc'] as String?,
      explicit: row['contentWarning'] == null
          ? null
          : row['contentWarning'] == 'explicit',
      releaseDate: album['releaseDate'] as String?,
      genre: album['genre'] as String?,
      source: sourceId,
    );
  }

  @override
  Future<List<DiscoveryEntry>> load(DiscoveryKind kind) async {
    final entries = <DiscoveryEntry>[];
    final seen = <String>{};
    if (kind == DiscoveryKind.trends) {
      final result = _map(await _result('/landing3/chart'));
      final rows = _map(result['chart'])['tracks'];
      if (rows is! List) {
        throw const FormatException('Invalid Yandex chart');
      }
      for (var index = 0; index < rows.length; index++) {
        final row = _map(rows[index]);
        final raw = _map(row['track']);
        if (raw.isEmpty) {
          continue;
        }
        final track = _track(raw);
        if (track.id.isEmpty || track.name.isEmpty || !seen.add(track.id)) {
          continue;
        }
        final position = _integer(_map(row['chart'])['position']);
        entries.add(
          DiscoveryEntry(
            track: track,
            position: position > 0 ? position : index + 1,
            genres: track.genre?.isNotEmpty == true ? [track.genre!] : const [],
          ),
        );
      }
    } else {
      final landing = _map(await _result('/landing3/new-releases'));
      if (landing['newReleases'] is! List) {
        throw const FormatException('Invalid Yandex releases');
      }
      final ids = (landing['newReleases'] as List)
          .map(_text)
          .where((id) => RegExp(r'^\d+$').hasMatch(id))
          .take(100)
          .toSet();
      if (ids.isEmpty) {
        return entries;
      }
      final albums = await _result(
        '/albums',
        body: {'album-ids': ids.join(',')},
      );
      if (albums is! List) {
        throw const FormatException('Invalid Yandex albums');
      }
      for (final raw in albums) {
        final row = _map(raw);
        final id = _text(row['id']);
        final date = row['releaseDate'] as String?;
        if (!ids.contains(id) || !seen.add(id) || !_recent(date, now())) {
          continue;
        }
        final title = _text(row['title']);
        if (title.isEmpty) {
          continue;
        }
        final version = _text(row['version']);
        final genre = _text(row['genre']);
        entries.add(
          DiscoveryEntry(
            genres: genre.isEmpty ? const [] : [genre],
            track: Track(
              id: id,
              name: '$title${version.isEmpty ? '' : ' ($version)'}',
              artistName: _artists(row['artists']),
              albumName: title,
              albumId: id,
              coverUrl: _cover(row['coverUri']),
              duration: 0,
              itemType: 'album',
              releaseDate: date,
              genre: genre,
              totalTracks: _integer(row['trackCount']),
              explicit: row['contentWarning'] == null
                  ? null
                  : row['contentWarning'] == 'explicit',
              source: sourceId,
            ),
          ),
        );
      }
    }
    return entries;
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) async {
    if (!RegExp(r'^\d+$').hasMatch(albumId)) {
      throw ArgumentError('Invalid album ID');
    }
    final album = _map(await _result('/albums/$albumId/with-tracks'));
    if (album['volumes'] is! List) {
      throw const FormatException('Invalid Yandex album');
    }
    return (album['volumes'] as List)
        .whereType<List<dynamic>>()
        .expand((e) => e)
        .map((e) => _track(_map(e), album))
        .toList();
  }
}

/// Last.fm's official global chart. Uses the application's existing API key;
/// no user account/session or shared secret is needed for this read-only call.
/// The API does not provide release dates or genres for this chart.
class LastFmDiscoverySource extends _PublicDiscoverySource {
  LastFmDiscoverySource({required String apiKey, super.client, super.now})
    : _apiKey = apiKey.trim() {
    if (_apiKey.isEmpty) {
      throw ArgumentError('Last.fm application API key is required');
    }
  }

  final String _apiKey;
  @override
  String get sourceId => 'lastfm';
  @override
  String get sourceName => 'Last.fm';
  @override
  String get region => 'global';
  @override
  Set<DiscoveryKind> get supportedKinds => {DiscoveryKind.trends};

  @override
  Future<List<DiscoveryEntry>> load(DiscoveryKind kind) async {
    dynamic response;
    try {
      response = await request(
        Uri.https('ws.audioscrobbler.com', '/2.0/', {
          'method': 'chart.gettoptracks',
          'api_key': _apiKey,
          'format': 'json',
          'limit': '100',
        }),
      );
    } catch (_) {
      // ClientException can include its URI; the query contains an API key.
      // Do not propagate it to UI status, logs, or cached error metadata.
      throw StateError('Last.fm chart request failed');
    }
    final rows = _map(_map(response)['tracks'])['track'];
    if (rows is! List) {
      throw const FormatException('Invalid Last.fm chart');
    }
    final entries = <DiscoveryEntry>[];
    final seen = <String>{};
    for (var index = 0; index < rows.length; index++) {
      final row = _map(rows[index]);
      final title = _text(row['name']);
      final artist = _text(_map(row['artist'])['name']);
      if (title.isEmpty || artist.isEmpty) {
        continue;
      }
      final mbid = _text(row['mbid']);
      final id = mbid.isNotEmpty
          ? mbid
          : '${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}';
      if (!seen.add(id)) {
        continue;
      }
      final images = row['image'] is List
          ? row['image'] as List
          : const <dynamic>[];
      String? cover;
      for (final image in images.reversed) {
        final url = _text(_map(image)['#text']);
        if (url.startsWith('https://') &&
            !url.contains('2a96cbd8b46e442fc41c2b86b821562f')) {
          cover = url;
          break;
        }
      }
      entries.add(
        DiscoveryEntry(
          position: index + 1,
          track: Track(
            id: id,
            name: title,
            artistName: artist,
            albumName: '',
            duration: _integer(row['duration']),
            coverUrl: cover,
            source: sourceId,
          ),
        ),
      );
    }
    return entries;
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) =>
      throw UnsupportedError('Last.fm chart does not provide albums');
}
