import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/services/discovery_source.dart';

/// Stores catalog metadata only. Audio downloads and library/storage settings
/// deliberately have no dependency on this repository.
class DiscoveryRepository {
  DiscoveryRepository({
    required this.source,
    DiscoveryMetadataCache? cache,
    this.persist = true,
  }) : cache = cache ?? DiscoveryMetadataCache();

  final DiscoverySource source;
  final bool persist;
  final DiscoveryMetadataCache cache;

  Future<DiscoveryCatalog> getCatalog() async {
    if (!persist) return source.getCatalog();
    final key = '${source.sourceId}:catalog:us';
    try {
      final catalog = await source.getCatalog();
      await cache.write(key, catalog.toJson());
      return catalog;
    } catch (_) {
      final saved = await cache.read(key);
      if (saved != null) {
        try {
          return DiscoveryCatalog.fromJson(saved).copyWith(isStale: true);
        } catch (_) {
          // A damaged cache must not hide the original network failure.
        }
      }
      rethrow;
    }
  }

  Future<DiscoveryFeed> getFeed(DiscoveryQuery query) async {
    if (!persist) return source.getFeed(query);
    final key = '${source.sourceId}:${query.cacheKey}';
    try {
      final feed = await source.getFeed(query);
      await cache.write(key, feed.toJson());
      return feed;
    } catch (_) {
      final saved = await cache.read(key);
      if (saved != null) {
        try {
          return DiscoveryFeed.fromJson(saved).copyWith(isStale: true);
        } catch (_) {
          // Treat invalid cached metadata as a miss.
        }
      }
      rethrow;
    }
  }
}

/// A bounded, best-effort disk cache, separate from music storage. Cache IO
/// failure must never turn a successful catalog request into a failed request.
class DiscoveryMetadataCache {
  DiscoveryMetadataCache({
    this.directory = getApplicationSupportDirectory,
    this.maxEntries = 48,
  });

  final Future<Directory> Function() directory;
  final int maxEntries;
  Future<void> _pending = Future.value();
  int _sequence = 0;

  Future<Directory> _root() async =>
      Directory('${(await directory()).path}/discovery_metadata');

  String _name(String key) => sha256.convert(utf8.encode(key)).toString();

  Future<Map<String, dynamic>?> read(String key) async {
    try {
      await _pending;
      final file = File('${(await _root()).path}/${_name(key)}.json');
      if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
        return null;
      }
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, Map<String, dynamic> value) {
    final result = _pending.then((_) async {
      File? temporary;
      try {
        final root = await _root();
        await root.create(recursive: true);
        final destination = '${root.path}/${_name(key)}.json';
        temporary = File('$destination.${_sequence++}.tmp');
        await temporary.writeAsString(jsonEncode(value), flush: true);
        await temporary.rename(destination);
        final files = <(File, DateTime)>[];
        await for (final entity in root.list()) {
          if (entity is File && entity.path.endsWith('.json')) {
            files.add((entity, (await entity.stat()).modified));
          }
        }
        files.sort((a, b) => b.$2.compareTo(a.$2));
        for (final old in files.skip(maxEntries)) {
          await old.$1.delete();
        }
      } catch (_) {
        // Disk full, unavailable app directory, etc. are cache misses only.
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {
          // Best-effort cleanup, without affecting catalog access.
        }
      }
    });
    _pending = result;
    return result;
  }
}
