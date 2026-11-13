import 'dart:async';

import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_aggregation.dart';
import 'package:mornye/services/discovery_repository.dart';
import 'package:mornye/services/discovery_source.dart';

class DiscoverySourceRegistration {
  final DiscoverySource source;
  final String name;
  final String region;
  final String family;
  final Set<DiscoveryKind> kinds;
  const DiscoverySourceRegistration({
    required this.source,
    required this.name,
    required this.region,
    required this.family,
    required this.kinds,
  });
}

/// Bounded parallel requests with independent, persistent source caches.
/// A regional restriction, outage or missing capability never removes working
/// providers. The UI sees one ranking and the truthful status of each source.
class CompositeDiscoverySource implements DiscoverySource {
  final List<DiscoverySourceRegistration> registrations;
  final DiscoveryMetadataCache cache;
  final DateTime Function() now;
  final Duration sourceTimeout;
  final Map<DiscoveryKind, Future<DiscoveryFeed>> _pending = {};
  final Map<DiscoveryKind, DiscoveryFeed> _feeds = {};
  final Map<DiscoveryKind, DateTime> _loadedAt = {};
  final List<Completer<void>> _waiting = [];
  int _active = 0;

  Future<T> _limited<T>(Future<T> Function() action) async {
    if (_active >= 3) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  CompositeDiscoverySource({
    required this.registrations,
    DiscoveryMetadataCache? cache,
    DateTime Function()? now,
    this.sourceTimeout = const Duration(seconds: 40),
  }) : cache = cache ?? DiscoveryMetadataCache(),
       now = now ?? DateTime.now;
  @override
  String get sourceId => 'unified-discovery';

  Future<DiscoveryFeed> _readSource(
    DiscoverySourceRegistration registration,
    DiscoveryKind kind,
  ) async {
    final query = DiscoveryQuery(kind: kind, region: registration.region);
    final key = '${registration.source.sourceId}:${query.cacheKey}';
    try {
      final feed = await registration.source
          .getFeed(query)
          .timeout(sourceTimeout);
      await cache.write(key, feed.toJson());
      return feed;
    } catch (_) {
      final saved = await cache.read(key);
      if (saved != null) {
        try {
          final feed = DiscoveryFeed.fromJson(saved);
          // Old trends should not masquerade as a current chart indefinitely.
          if (now().difference(feed.fetchedAt) <= const Duration(days: 7)) {
            return feed.copyWith(isStale: true);
          }
        } catch (_) {
          /* Invalid metadata is a cache miss. */
        }
      }
      rethrow;
    }
  }

  Future<DiscoveryFeed> _load(DiscoveryKind kind) async {
    final applicable = registrations
        .where((s) => s.kinds.contains(kind))
        .toList();
    final rankings = <DiscoveryRanking>[];
    final statuses = <DiscoverySourceStatus>[];
    for (var start = 0; start < applicable.length; start += 3) {
      final batch = applicable.skip(start).take(3);
      final results = await Future.wait(
        batch.map((registration) async {
          try {
            final feed = await _limited(() => _readSource(registration, kind));
            return (registration, feed);
          } catch (_) {
            return (registration, null);
          }
        }),
      );
      for (final (registration, feed) in results) {
        statuses.add(
          DiscoverySourceStatus(
            sourceId: registration.source.sourceId,
            sourceName: registration.name,
            region: feed?.region ?? registration.region,
            isStale: feed?.isStale ?? false,
            isUnavailable: feed == null,
          ),
        );
        if (feed != null) {
          rankings.add(
            DiscoveryRanking(
              sourceId: registration.source.sourceId,
              family: registration.family,
              feed: feed,
            ),
          );
        }
      }
    }
    if (rankings.isEmpty) throw StateError('No discovery sources available');
    final entries = aggregateDiscovery(rankings, kind, now: now());
    final oldest = rankings
        .map((r) => r.feed.fetchedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    return DiscoveryFeed(
      entries: entries,
      fetchedAt: oldest,
      region: 'mixed',
      sourceName: rankings.map((r) => r.feed.sourceName).join(' · '),
      sources: statuses,
      isStale: rankings.every((r) => r.feed.isStale),
    );
  }

  Future<DiscoveryFeed> _feed(DiscoveryKind kind) {
    final saved = _feeds[kind];
    if (saved != null &&
        now().difference(_loadedAt[kind]!) < const Duration(minutes: 5)) {
      return Future.value(saved);
    }
    return _pending.putIfAbsent(
      kind,
      () => _load(kind)
          .then((feed) {
            _feeds[kind] = feed;
            _loadedAt[kind] = now();
            return feed;
          })
          .whenComplete(() {
            _pending.remove(kind);
          }),
    );
  }

  @override
  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    final feed = await _feed(query.kind);
    if (query.genreId == '0') return feed;
    return DiscoveryFeed(
      entries: feed.entries
          .where((e) => e.genres.contains(query.genreId))
          .toList(),
      fetchedAt: feed.fetchedAt,
      region: feed.region,
      sourceName: feed.sourceName,
      sources: feed.sources,
      isStale: feed.isStale,
    );
  }

  @override
  Future<DiscoveryCatalog> getCatalog() async {
    final results = await Future.wait(
      DiscoveryKind.values.map((kind) async {
        try {
          return await _feed(kind);
        } catch (_) {
          return null;
        }
      }),
    );
    final feeds = results.whereType<DiscoveryFeed>().toList();
    if (feeds.isEmpty) throw StateError('No discovery genres available');
    final genres =
        feeds.expand((f) => f.entries).expand((e) => e.genres).toSet().toList()
          ..sort();
    return DiscoveryCatalog(
      genres: [
        const DiscoveryGenre(id: '0', name: 'All'),
        ...genres.map((g) => DiscoveryGenre(id: g, name: g)),
      ],
      region: 'mixed',
      sourceName: 'Discovery',
      isStale: feeds.every((f) => f.isStale),
    );
  }

  @override
  Future<List<Track>> getAlbumTracks(String albumId) {
    final colon = albumId.indexOf(':');
    if (colon < 1) throw ArgumentError('Album needs source and native ID');
    final sourceId = albumId.substring(0, colon);
    final source = registrations
        .where((r) => r.source.sourceId == sourceId)
        .firstOrNull;
    if (source == null) throw ArgumentError('Unknown album source');
    return source.source.getAlbumTracks(albumId.substring(colon + 1));
  }

  @override
  void close() {
    for (final r in registrations) {
      r.source.close();
    }
  }
}
