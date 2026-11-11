import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';
import 'support/sqlite_process_database.dart';

void main() {
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await LibrarySchema.create(db, LibrarySchema.version);
    await db.execute("ATTACH DATABASE ':memory:' AS history_db");
    final schema = File('lib/services/history_schema.dart').readAsStringSync();
    final create = RegExp(
      r'CREATE TABLE history \([\s\S]*?\n\s*\)',
    ).firstMatch(schema)!.group(0)!;
    await db.execute(
      create.replaceFirst(
        'CREATE TABLE history',
        'CREATE TABLE history_db.history',
      ),
    );
    await db.execute(
      'CREATE TABLE history_db.history_path_keys(item_id TEXT, path_key TEXT)',
    );
    store = LibraryQueueStore(db, historyFts: false, localFts: false);
    for (var i = 0; i < 600; i++) {
      await db.insert('history_db.history', {
        'id': 'id${i.toString().padLeft(4, '0')}',
        'track_name': 'Song $i',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': '/music/$i.flac',
        'downloaded_at': '2026-11-10',
        'service': 'example',
        'duration': i == 599 ? 200 : 30,
        'release_date': '2020',
      });
    }
  });
  tearDown(() async => db.close());
  test(
    'ranges filter before page limit, including songs beyond initial pages',
    () async {
      final rows = await store.recommendationPage(
        source: 'downloaded',
        limit: 10,
        minSeconds: 100,
      );
      expect(rows.map((r) => r['id']), ['id0599']);
    },
  );
  test('unknown handling, explicit flag and network files', () async {
    await db.rawUpdate(
      "UPDATE history_db.history SET duration = NULL, release_date = NULL WHERE id = 'id0599'",
    );
    expect(
      await store.recommendationPage(
        source: 'downloaded',
        limit: 10,
        minSeconds: 100,
      ),
      isEmpty,
    );
    expect(
      await store.recommendationPage(
        source: 'downloaded',
        limit: 10,
        minSeconds: 100,
        excludeUnknown: false,
      ),
      hasLength(1),
    );
    await db.rawUpdate(
      "UPDATE history_db.history SET explicit = 1 WHERE id = 'id0599'",
    );
    expect(
      await store.recommendationPage(
        source: 'downloaded',
        limit: 10,
        minSeconds: 100,
        excludeUnknown: false,
        excludeMarkedExplicit: true,
      ),
      isEmpty,
    );
    await db.rawUpdate(
      "UPDATE history_db.history SET file_path = 'https://host/song' WHERE id = 'id0599'",
    );
    expect(
      await store.recommendationPage(
        source: 'downloaded',
        limit: 10,
        minSeconds: 100,
        excludeUnknown: false,
      ),
      isEmpty,
    );
  });
  test('seek pages have no overlap', () async {
    final first = await store.recommendationPage(
      source: 'downloaded',
      limit: 256,
    );
    final second = await store.recommendationPage(
      source: 'downloaded',
      limit: 256,
      afterId: first.last['id'] as String,
    );
    expect(first.length, 256);
    expect(second.length, 256);
    expect(
      first
          .map((r) => r['id'])
          .toSet()
          .intersection(second.map((r) => r['id']).toSet()),
      isEmpty,
    );
  });
  test(
    'music server has a dedicated page and stays out of local results',
    () async {
      const sourceId = 'musicserver:account';
      final source = 'musicserver://account/${'a' * 64}';
      await db.insert('library_sources', {
        'id': sourceId,
        'path': 'musicserver://account/',
        'display_name': 'Server',
        'enabled': 1,
        'available': 1,
      });
      await db.insert('library', {
        'id': source,
        'source_id': sourceId,
        'file_path': source,
        'track_name': 'Remote song',
        'artist_name': 'Remote artist',
        'album_name': 'Remote album',
        'genre': 'ambient',
        'duration': 180,
        'release_date': '2024',
        'scanned_at': '2026-11-10T00:00:00Z',
      });
      expect(
        await store.recommendationPage(source: 'local', limit: 10),
        isEmpty,
      );
      final rows = await store.recommendationPage(
        source: 'musicserver',
        limit: 10,
      );
      expect(rows, hasLength(1));
      expect(rows.single['file_path'], source);
      expect(rows.single['genre'], 'ambient');
    },
  );
}
