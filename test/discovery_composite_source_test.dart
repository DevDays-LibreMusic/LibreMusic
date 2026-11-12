import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_composite_source.dart';
import 'package:mornye/services/discovery_repository.dart';
import 'package:mornye/services/discovery_source.dart';

class FakeSource implements DiscoverySource {
  @override
  final String sourceId;
  bool fail = false;
  int calls = 0;
  Future<void> Function()? before;
  FakeSource(this.sourceId);
  @override
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    calls++;
    await before?.call();
    if (fail) throw StateError('offline');
    return DiscoveryFeed(
      entries: [
        DiscoveryEntry(
          track: Track(
            id: sourceId,
            name: 'Song $sourceId',
            artistName: sourceId,
            albumName: '',
            duration: 180,
            source: sourceId,
            releaseDate: '2026-11-10',
          ),
          genres: ['Pop'],
        ),
      ],
      fetchedAt: DateTime.utc(2026, 11, 12),
      region: query.region,
      sourceName: sourceId,
    );
  }

  @override
  Future<DiscoveryCatalog> getCatalog() => throw UnimplementedError();
  @override
  Future<List<Track>> getAlbumTracks(String id) async => [
    Track(
      id: id,
      name: id,
      artistName: '',
      albumName: '',
      duration: 0,
      source: sourceId,
    ),
  ];
  @override
  void close() {}
}

void main() {
  late Directory directory;
  late DiscoveryMetadataCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('composite-');
    cache = DiscoveryMetadataCache(directory: () async => directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  CompositeDiscoverySource composite(
    List<FakeSource> sources, {
    Duration timeout = const Duration(seconds: 1),
  }) => CompositeDiscoverySource(
    registrations: [
      for (final s in sources)
        DiscoverySourceRegistration(
          source: s,
          name: s.sourceId,
          region: 'us',
          family: s.sourceId,
          kinds: DiscoveryKind.values.toSet(),
        ),
    ],
    cache: cache,
    now: () => DateTime.utc(2026, 11, 12),
    sourceTimeout: timeout,
  );
  test(
    'working source survives timeout and failure with truthful statuses',
    () async {
      final a = FakeSource('a'),
          b = FakeSource('b')..fail = true,
          c = FakeSource('c')..before = () => Completer<void>().future;
      final feed = await composite(
        [a, b, c],
        timeout: const Duration(milliseconds: 20),
      ).getFeed(const DiscoveryQuery(kind: DiscoveryKind.trends));
      expect(feed.entries.length, 1);
      expect(feed.sources.where((s) => s.isUnavailable).length, 2);
      expect(feed.isStale, isFalse);
    },
  );
  test(
    'per-source cache survives restart and retains missing source contribution',
    () async {
      final a = FakeSource('a'), b = FakeSource('b');
      const query = DiscoveryQuery(kind: DiscoveryKind.trends);
      await composite([a, b]).getFeed(query);
      b.fail = true;
      final result = await composite([a, b]).getFeed(query);
      expect(result.entries.length, 2);
      expect(result.sources.last.isStale, isTrue);
      expect(result.isStale, isFalse);
      a.fail = true;
      final stale = await composite([a, b]).getFeed(query);
      expect(stale.isStale, isTrue);
    },
  );
  test(
    'filters share a source request and retain aggregate positions',
    () async {
      final a = FakeSource('a');
      final source = composite([a]);
      await source.getFeed(const DiscoveryQuery(kind: DiscoveryKind.trends));
      final empty = await source.getFeed(
        const DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Jazz'),
      );
      expect(empty.entries, isEmpty);
      expect(a.calls, 1);
    },
  );
  test('catalog and both tabs obey shared concurrency bound', () async {
    var active = 0, peak = 0;
    final sources = [
      for (var i = 0; i < 5; i++)
        FakeSource('$i')
          ..before = () async {
            active++;
            if (active > peak) peak = active;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            active--;
          },
    ];
    final source = composite(sources);
    await Future.wait([
      source.getCatalog(),
      source.getFeed(const DiscoveryQuery(kind: DiscoveryKind.trends)),
    ]);
    expect(peak, lessThanOrEqualTo(3));
    expect(sources.every((s) => s.calls == 2), isTrue);
  });
  test('expired source cache cannot resurrect an old unified feed', () async {
    final a = FakeSource('a');
    const query = DiscoveryQuery(kind: DiscoveryKind.trends);
    final saved = await composite([a]).getFeed(query);
    await cache.write('unified-discovery:${query.cacheKey}', saved.toJson());
    a.fail = true;
    final expired = CompositeDiscoverySource(
      registrations: [
        DiscoverySourceRegistration(
          source: a,
          name: 'A',
          region: 'us',
          family: 'a',
          kinds: {DiscoveryKind.trends},
        ),
      ],
      cache: cache,
      now: () => DateTime.utc(2026, 11, 21),
    );
    final repository = DiscoveryRepository(
      source: expired,
      cache: cache,
      persist: false,
    );
    await expectLater(repository.getFeed(query), throwsStateError);
  });

  test('album native IDs route to the right source', () async {
    final source = composite([FakeSource('a'), FakeSource('b')]);
    final tracks = await source.getAlbumTracks('b:123');
    expect(tracks.single.source, 'b');
    expect(tracks.single.id, '123');
  });
}
