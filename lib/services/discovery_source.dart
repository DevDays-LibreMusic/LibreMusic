import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';

abstract class DiscoverySource {
  String get sourceId;
  Future<DiscoveryCatalog> getCatalog();
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query);
  Future<List<Track>> getAlbumTracks(String albumId);
  void close();
}

/// Apple's US editorial new releases and its published Top 100 songs.
/// Genre filtering narrows these selections; chart positions remain global.
/// This source never reads the user's music library or downloads audio.
class AppleDiscoverySource implements DiscoverySource {
  final http.Client _client;
  final DateTime Function() _now;
  final Map<DiscoveryKind, Future<DiscoveryFeed>> _pending = {};
  final Map<DiscoveryKind, DiscoveryFeed> _feeds = {};
  static const cacheLifetime = Duration(minutes: 5);
  static const region = 'us';
  static const sourceName = 'Apple Music';

  AppleDiscoverySource({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  @override
  String get sourceId => 'apple-music';

  Future<String> _get(Uri uri) async {
    final response = await _client
        .get(
          uri,
          headers: {'Accept-Language': 'en-US', 'User-Agent': 'LibreMusic/1.0'},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('Discovery request failed (${response.statusCode})');
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final value = jsonDecode(await _get(uri));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid discovery response');
    }
    return value;
  }

  @override
  Future<DiscoveryCatalog> getCatalog() async {
    Object? failure;
    final feeds = (await Future.wait(
      DiscoveryKind.values.map((kind) async {
        try {
          return await _feed(kind);
        } catch (error) {
          failure = error;
          return null;
        }
      }),
    )).whereType<DiscoveryFeed>().toList();
    if (feeds.isEmpty) throw failure ?? StateError('Discovery unavailable');
    final names =
        feeds.expand((f) => f.entries).expand((e) => e.genres).toSet().toList()
          ..sort();
    return DiscoveryCatalog(
      genres: [
        const DiscoveryGenre(id: '0', name: 'All'),
        ...names.map((name) => DiscoveryGenre(id: name, name: name)),
      ],
      region: region,
      sourceName: sourceName,
    );
  }

  Future<DiscoveryFeed> _feed(DiscoveryKind kind) {
    final cached = _feeds[kind];
    if (cached != null && _now().difference(cached.fetchedAt) < cacheLifetime) {
      return Future.value(cached);
    }
    return _pending.putIfAbsent(kind, () {
      final future = kind == DiscoveryKind.newReleases
          ? _newReleases()
          : _trends();
      return future
          .then((feed) {
            _feeds[kind] = feed;
            return feed;
          })
          .whenComplete(() {
            _pending.remove(kind);
          });
    });
  }

  @override
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    if (query.region != region) {
      throw ArgumentError.value(query.region, 'region');
    }
    final feed = await _feed(query.kind);
    return DiscoveryFeed(
      entries: query.genreId == '0'
          ? feed.entries
          : feed.entries
                .where((entry) => entry.genres.contains(query.genreId))
                .toList(),
      fetchedAt: feed.fetchedAt,
      region: region,
      sourceName: sourceName,
    );
  }

  Future<DiscoveryFeed> _trends() async {
    final json = await _json(
      Uri.parse(
        'https://rss.applemarketingtools.com/api/v2/us/music/most-played/100/songs.json',
      ),
    );
    final feed = json['feed'];
    if (feed is! Map || feed['results'] is! List) {
      throw const FormatException('Apple chart format is unsupported');
    }
    final entries = <DiscoveryEntry>[];
    final seen = <String>{};
    final results = feed['results'] as List;
    for (var index = 0; index < results.length; index++) {
      final row = _map(results[index]);
      final id = row['id']?.toString() ?? '';
      final name = row['name'] as String? ?? '';
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      final genres = (row['genres'] as List? ?? [])
          .map(_map)
          .where((g) => g['genreId'] != '34')
          .map((g) => _canonicalGenre(g['name']?.toString() ?? ''))
          .where((g) => g.isNotEmpty)
          .toSet()
          .toList();
      final url = Uri.tryParse(row['url']?.toString() ?? '');
      final albumMatch = RegExp(
        r'/album/[^/]+/(\d+)',
      ).firstMatch(url?.path ?? '');
      entries.add(
        DiscoveryEntry(
          position: index + 1,
          genres: genres,
          track: Track(
            id: id,
            name: name,
            artistName: row['artistName'] as String? ?? '',
            albumName: '',
            artistId: row['artistId']?.toString(),
            albumId: albumMatch?.group(1),
            coverUrl: row['artworkUrl100'] as String?,
            releaseDate: row['releaseDate'] as String?,
            duration: 0,
            genre: genres.join(', '),
            source: sourceId,
          ),
        ),
      );
    }
    return DiscoveryFeed(
      entries: entries,
      fetchedAt: _now(),
      region: region,
      sourceName: sourceName,
    );
  }

  Future<DiscoveryFeed> _newReleases() async {
    final page = html.parse(
      await _get(Uri.parse('https://music.apple.com/us/new?l=en-US')),
    );
    final script = page.querySelector('script#serialized-server-data');
    if (script == null) {
      throw const FormatException('Apple new releases data is unavailable');
    }
    final payload = jsonDecode(script.text);
    final pages = payload is List ? payload : _map(payload)['data'];
    if (pages is! List) {
      throw const FormatException('Apple new releases format is unsupported');
    }
    final ids = <String>{};
    var recognizedSection = false;
    for (final page in pages) {
      final sections = _map(_map(page)['data'])['sections'];
      if (sections is! List) continue;
      for (final rawSection in sections) {
        final section = _map(rawSection);
        final title = _map(
          _map(_map(section['header'])['item'])['titleLink'],
        )['title'];
        // Deliberately exclude heroes, old editorial picks, and Coming Soon.
        if (!const {
          'Best New Songs',
          'New This Week',
          'Recent Releases',
        }.contains(title)) {
          continue;
        }
        recognizedSection = true;
        for (final rawItem in section['items'] as List? ?? []) {
          final item = _map(rawItem);
          if (item['isDisabled'] == true) continue;
          final descriptor = _map(
            item['contentDescriptor'] ??
                _map(_map(item['segue'])['destination'])['contentDescriptor'],
          );
          if (!const {'song', 'album'}.contains(descriptor['kind'])) continue;
          final id = _map(descriptor['identifiers'])['storeAdamID']?.toString();
          if (id != null && RegExp(r'^\d+$').hasMatch(id)) ids.add(id);
        }
      }
    }
    if (!recognizedSection) {
      throw const FormatException('Apple new release shelves are unavailable');
    }
    final entries = <DiscoveryEntry>[];
    if (ids.isNotEmpty) {
      final json = await _json(
        Uri.https('itunes.apple.com', '/lookup', {
          'id': ids.take(100).join(','),
          'country': region,
        }),
      );
      final rows = json['results'];
      if (rows is! List) {
        throw const FormatException('Apple metadata format is unsupported');
      }
      final today = DateTime.utc(_now().year, _now().month, _now().day);
      for (final row in rows.map(_map)) {
        final track = _lookupTrack(row);
        if (track == null || !ids.contains(track.id)) continue;
        final date = _releaseDate(track.releaseDate);
        if (date == null) continue;
        final releaseDay = DateTime.utc(date.year, date.month, date.day);
        if (releaseDay.isAfter(today) ||
            today.difference(releaseDay).inDays > 30) {
          continue;
        }
        entries.add(
          DiscoveryEntry(
            track: track,
            genres: [
              if (track.genre?.isNotEmpty == true)
                _canonicalGenre(track.genre!),
            ],
          ),
        );
      }
      entries.sort(
        (a, b) => b.track.releaseDate!.compareTo(a.track.releaseDate!),
      );
    }
    return DiscoveryFeed(
      entries: entries,
      fetchedAt: _now(),
      region: region,
      sourceName: sourceName,
    );
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) async {
    if (!RegExp(r'^\d+$').hasMatch(albumId)) {
      throw ArgumentError.value(albumId, 'albumId');
    }
    final json = await _json(
      Uri.https('itunes.apple.com', '/lookup', {
        'id': albumId,
        'entity': 'song',
        'limit': '200',
        'country': region,
      }),
    );
    final rows = json['results'];
    if (rows is! List) {
      throw const FormatException('Apple album format is unsupported');
    }
    return rows
        .map(_map)
        .map(_lookupTrack)
        .whereType<Track>()
        .where((t) => !t.isCollection && t.albumId == albumId)
        .toList();
  }

  Track? _lookupTrack(Map<String, dynamic> row) {
    final isAlbum =
        row['wrapperType'] == 'collection' && row['collectionType'] == 'Album';
    if (!isAlbum && row['kind'] != 'song') return null;
    final id = row[isAlbum ? 'collectionId' : 'trackId']?.toString();
    final name = row[isAlbum ? 'collectionName' : 'trackName'] as String?;
    if (id == null || name == null || name.isEmpty) return null;
    return Track(
      id: id,
      name: name,
      artistName: row['artistName'] as String? ?? '',
      albumName: row['collectionName'] as String? ?? '',
      albumId: row['collectionId']?.toString(),
      artistId: row['artistId']?.toString(),
      coverUrl: row['artworkUrl100'] as String?,
      duration: ((row['trackTimeMillis'] as num? ?? 0) / 1000).round(),
      releaseDate: row['releaseDate'] as String?,
      genre: row['primaryGenreName'] as String?,
      explicit:
          row[isAlbum ? 'collectionExplicitness' : 'trackExplicitness'] ==
          'explicit',
      trackNumber: row['trackNumber'] as int?,
      discNumber: row['discNumber'] as int?,
      totalTracks: row['trackCount'] as int?,
      source: sourceId,
      itemType: isAlbum ? 'album' : null,
    );
  }

  // Apple uses these two labels for the same Hip-Hop category in its
  // editorial lookup and chart feeds. Keep other supplied genres distinct.
  static String _canonicalGenre(String name) =>
      name == 'Hip-Hop' ? 'Hip-Hop/Rap' : name;

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  @override
  void close() {
    _feeds.clear();
    _client.close();
  }

  static DateTime? _releaseDate(String? value) {
    if (value == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}(?:T|$)').hasMatch(value)) {
      return null;
    }
    final date = DateTime.tryParse(value);
    if (date == null) return null;
    final calendarDate =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return value.startsWith(calendarDate) ? date : null;
  }
}
