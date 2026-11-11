import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/music_server_library.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/file_access.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

Future<MusicServerClient> _client({String user = 'listener'}) async {
  final client = MusicServerClient(
    client: MockClient(
      (_) async => throw StateError('Unexpected HTTP request'),
    ),
    readSession: () async => jsonEncode({
      'version': 1,
      'address': 'https://music.example.org',
      'refresh_token': 'fixture-refresh',
      'user_id': user,
    }),
    writeSession: (_) async {},
  );
  await client.restore();
  return client;
}

final _asset = {
  'id': 'a' * 64,
  'state': 'ready',
  'title': 'Example track',
  'artist': 'Example artist',
  'mime': 'audio/mpeg',
};
const _metadata = Track(
  id: 'provider-track',
  name: 'Example track',
  artistName: 'Example artist',
  albumName: 'Example album',
  genre: 'ambient',
  coverUrl: 'https://images.example.org/cover.jpg',
  isrc: 'TEST00000001',
  duration: 180,
  source: 'extension:example.audio',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a saved asset survives restart and repeated adds without audio files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'server-library-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/library.db';
      var db = await SqliteProcessDatabase.open(path: path);
      addTearDown(() => db.close());
      await createNativeLibraryFixture(db);
      final client = await _client();
      final item = musicServerLibraryItem(client, _asset, metadata: _metadata);
      final library = LibraryDatabase.withDatabase(db, historyAttached: true);
      await saveMusicServerLibraryItem(library, item, displayName: 'Server');
      await saveMusicServerLibraryItem(
        library,
        musicServerLibraryItem(client, _asset),
        displayName: 'Server',
      );
      await db.close();
      db = await SqliteProcessDatabase.open(path: path);
      final restored = LibraryDatabase.withDatabase(db);
      final stored = LocalLibraryItem.fromJson(
        (await restored.getById(item.id))!,
      );
      expect(
        (await db.rawQuery('SELECT COUNT(*) AS n FROM library')).single['n'],
        1,
      );
      expect(stored.albumName, _metadata.albumName);
      expect(stored.genre, _metadata.genre);
      expect(stored.coverPath, _metadata.coverUrl);
      expect(stored.isrc, _metadata.isrc);
      expect(stored.scannedAt, item.scannedAt);
      final media = playableFromLocal(stored);
      expect(media.source, client.source(_asset['id']!));
      expect(media.isNetwork, isTrue);
      expect(media.toJson().toString(), isNot(contains('refresh')));
      expect(media.toJson().toString(), isNot(contains('/v1/media/')));
      expect(
        (await directory.list().toList()).every(
          (file) => file.path.startsWith(path),
        ),
        isTrue,
      );
    },
  );

  test('different accounts retain separate library references', () async {
    final db = await SqliteProcessDatabase.open();
    addTearDown(db.close);
    await createNativeLibraryFixture(db);
    final library = LibraryDatabase.withDatabase(db);
    final first = musicServerLibraryItem(await _client(user: 'first'), _asset);
    final secondClient = await _client(user: 'second');
    final second = musicServerLibraryItem(secondClient, _asset);
    await saveMusicServerLibraryItem(library, first, displayName: 'Server');
    await saveMusicServerLibraryItem(library, second, displayName: 'Server');
    expect(first.id, isNot(second.id));
    expect(first.sourceId, isNot(second.sourceId));
    expect(
      (await db.rawQuery('SELECT COUNT(*) AS n FROM library')).single['n'],
      2,
    );
    await expectLater(
      secondClient.resolve(first.filePath),
      throwsA(isA<MusicServerException>()),
    );
  });

  test(
    'cleanup retains streaming entries and local deletion cannot delete server audio',
    () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await createNativeLibraryFixture(db);
      final library = LibraryDatabase.withDatabase(db);
      final item = musicServerLibraryItem(await _client(), _asset);
      await saveMusicServerLibraryItem(library, item, displayName: 'Server');
      expect(await fileExists(item.filePath), isTrue);
      expect(await fileStat(item.filePath), isNotNull);
      expect(
        (await fileExistenceByPath([item.filePath]))[item.filePath],
        isNull,
      );
      expect(await cleanupMissingLibraryRows(db), 0);
      expect(await library.getById(item.id), isNotNull);
      expect(await deleteFile(item.filePath), isFalse);
    },
  );

  test('unfinished jobs cannot enter the library', () async {
    final client = await _client();
    for (final state in ['queued', 'downloading', 'failed', 'cancelled']) {
      expect(
        () => musicServerLibraryItem(client, {..._asset, 'state': state}),
        throwsA(isA<MusicServerException>()),
      );
    }
  });
}
