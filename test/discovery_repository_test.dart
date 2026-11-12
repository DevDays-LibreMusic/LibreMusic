import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_repository.dart';
import 'package:mornye/services/discovery_source.dart';

class _Source implements DiscoverySource {
  bool fail = false;
  @override
  String get sourceId => 'test';
  @override
  Future<DiscoveryCatalog> getCatalog() async {
    if (fail) throw StateError('offline');
    return const DiscoveryCatalog(
      genres: [DiscoveryGenre(id: 'rock', name: 'Rock')],
      region: 'us',
      sourceName: 'Test',
    );
  }

  @override
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    if (fail) throw StateError('offline');
    return DiscoveryFeed(
      entries: [
        DiscoveryEntry(
          track: Track(
            id: query.genreId,
            name: query.kind.name,
            artistName: 'Artist',
            albumName: 'Album',
            duration: 100,
          ),
          position: query.kind == DiscoveryKind.trends ? 7 : null,
        ),
      ],
      fetchedAt: DateTime.utc(2026, 11, 12),
      sourceName: 'Test',
      region: query.region,
    );
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) async => [];
  @override
  void close() {}
}

void main() {
  late Directory directory;
  late _Source source;
  late DiscoveryRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('discovery-test-');
    source = _Source();
    repository = DiscoveryRepository(
      source: source,
      cache: DiscoveryMetadataCache(directory: () async => directory),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'offline fallback preserves entries, rank and original fetched date',
    () async {
      const query = DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'rock');
      final live = await repository.getFeed(query);
      source.fail = true;
      final cached = await repository.getFeed(query);
      expect(live.isStale, isFalse);
      expect(cached.isStale, isTrue);
      expect(cached.entries.single.track.id, 'rock');
      expect(cached.entries.single.position, 7);
      expect(cached.fetchedAt, live.fetchedAt);
    },
  );

  test(
    'genre, tab and region never fall back to a different cached feed',
    () async {
      const original = DiscoveryQuery(
        kind: DiscoveryKind.trends,
        genreId: 'rock',
      );
      await repository.getFeed(original);
      source.fail = true;
      for (final query in const [
        DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'pop'),
        DiscoveryQuery(kind: DiscoveryKind.newReleases, genreId: 'rock'),
        DiscoveryQuery(
          kind: DiscoveryKind.trends,
          genreId: 'rock',
          region: 'gb',
        ),
      ]) {
        await expectLater(repository.getFeed(query), throwsStateError);
      }
    },
  );

  test(
    'catalog survives process restart without library or settings',
    () async {
      await repository.getCatalog();
      source.fail = true;
      final restarted = DiscoveryRepository(
        source: source,
        cache: DiscoveryMetadataCache(directory: () async => directory),
      );
      final catalog = await restarted.getCatalog();
      expect(catalog.isStale, isTrue);
      expect(catalog.genres.single.id, 'rock');
    },
  );

  test('cache IO failure cannot fail successful source data', () async {
    final unavailable = DiscoveryRepository(
      source: source,
      cache: DiscoveryMetadataCache(
        directory: () async => throw FileSystemException('unavailable'),
      ),
    );
    final result = await unavailable.getFeed(
      const DiscoveryQuery(kind: DiscoveryKind.trends),
    );
    expect(result.entries, isNotEmpty);
    expect(result.isStale, isFalse);
  });

  test('cache is bounded and corrupted JSON is treated as a miss', () async {
    final cache = DiscoveryMetadataCache(
      directory: () async => directory,
      maxEntries: 2,
    );
    for (var index = 0; index < 4; index++) {
      await cache.write('key-$index', {'value': index});
    }
    final files = await Directory(
      '${directory.path}/discovery_metadata',
    ).list().toList();
    expect(files.whereType<File>().length, 2);
    for (final file in files.whereType<File>()) {
      await file.writeAsString('invalid json');
    }
    expect(await cache.read('key-3'), isNull);
  });
}
