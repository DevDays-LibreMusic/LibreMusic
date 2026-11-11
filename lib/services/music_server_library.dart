import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:sqflite/sqflite.dart';

/// A durable library reference to a completed server asset, never a media ticket.
LocalLibraryItem musicServerLibraryItem(
  MusicServerClient client,
  Map<String, dynamic> asset, {
  Track? metadata,
}) {
  final id = asset['id'] as String? ?? '';
  if (!client.connected ||
      asset['state'] != 'ready' ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
    throw const MusicServerException('asset_not_ready');
  }
  final source = client.source(id);
  return LocalLibraryItem(
    id: source,
    sourceId: 'musicserver:${client.identity}',
    filePath: source,
    trackName: metadata?.name ?? asset['title'] as String? ?? '',
    artistName: metadata?.artistName ?? asset['artist'] as String? ?? '',
    albumName: metadata?.albumName ?? '',
    albumArtist: metadata?.albumArtist,
    coverPath: metadata?.coverUrl,
    duration: metadata?.duration,
    genre: metadata?.genre,
    isrc: metadata?.isrc,
    trackNumber: metadata?.trackNumber,
    discNumber: metadata?.discNumber,
    releaseDate: metadata?.releaseDate,
    explicit: metadata?.isExplicit ?? false,
    format: switch (asset['mime']) {
      'audio/mpeg' => 'mp3',
      'audio/flac' => 'flac',
      'audio/mp4' => 'm4a',
      'audio/ogg' => 'ogg',
      _ => null,
    },
    scannedAt: DateTime.now(),
  );
}

/// Inserts only metadata into the existing library schema. Repeated adds keep
/// the original row, including its richer catalog metadata and added date.
Future<void> saveMusicServerLibraryItem(
  LibraryDatabase library,
  LocalLibraryItem item, {
  required String displayName,
}) async {
  final uri = Uri.parse(item.filePath);
  if (uri.scheme != MusicServerClient.scheme ||
      item.id != item.filePath ||
      item.sourceId != 'musicserver:${uri.host}') {
    throw const MusicServerException('invalid_library_source');
  }
  final db = await library.database;
  await sqlite.transactionWithBusyRetry(db, (txn) async {
    await txn.insert('library_sources', {
      'id': item.sourceId,
      'path': uri.replace(path: '/').toString(),
      'display_name': displayName,
      'enabled': 1,
      'available': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update(
      'library_sources',
      {'enabled': 1, 'available': 1},
      where: 'id = ?',
      whereArgs: [item.sourceId],
    );
    await txn.insert(
      'library',
      LibraryRowMapper.encode(item.toJson(), sourceId: item.sourceId),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final batch = txn.batch();
    sqlite.putPathKeysInBatch(
      batch,
      'library_path_keys',
      item.id,
      item.filePath,
    );
    await batch.commit(noResult: true);
  });
}
