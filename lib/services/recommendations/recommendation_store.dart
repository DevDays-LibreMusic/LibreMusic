import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

/// Separate additive schema: existing settings and listening data are untouched.
class RecommendationStore {
  RecommendationStore({Future<Database> Function()? open}) : _open = open;
  final Future<Database> Function()? _open;
  final _database = sqlite.SingleFlightInitializer<Database>();
  Future<Database> get database => _database.getOrCreate(
    () =>
        _open?.call() ??
        sqlite.openAppDatabase(
          'recommendations.db',
          version: 1,
          onCreate: create,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 1) await create(db, newVersion);
          },
        ),
  );

  static Future<void> create(Database db, int version) async {
    await db.execute(
      'CREATE TABLE profiles(id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    );
    await db.execute('''CREATE TABLE outcomes(
      id INTEGER PRIMARY KEY, profile_id TEXT NOT NULL, revision INTEGER NOT NULL,
      at INTEGER NOT NULL, parts TEXT NOT NULL, reward REAL NOT NULL, weight REAL NOT NULL,
      artist TEXT NOT NULL)''');
    await db.execute(
      'CREATE INDEX outcomes_profile ON outcomes(profile_id, revision, at)',
    );
  }

  Future<List<RecommendationProfile>> profiles() async => [
    for (final row in await (await database).query('profiles', orderBy: 'id'))
      RecommendationProfile.fromJson(
        jsonDecode(row['data'] as String) as Map<String, dynamic>,
      ),
  ];

  Future<void> save(RecommendationProfile profile) async {
    if (!profile.valid) throw const FormatException('Invalid profile');
    await (await database).insert('profiles', {
      'id': profile.id,
      'data': jsonEncode(profile.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    await (await database).transaction((txn) async {
      await txn.delete('profiles', where: 'id = ?', whereArgs: [id]);
      await txn.delete('outcomes', where: 'profile_id = ?', whereArgs: [id]);
    });
  }

  /// Revision bump prevents already queued feedback from undoing a reset.
  Future<RecommendationProfile?> reset(String id) async =>
      (await database).transaction((txn) async {
        final rows = await txn.query(
          'profiles',
          where: 'id = ?',
          whereArgs: [id],
        );
        await txn.delete('outcomes', where: 'profile_id = ?', whereArgs: [id]);
        if (rows.isEmpty) return null;
        final current = RecommendationProfile.fromJson(
          jsonDecode(rows.single['data'] as String) as Map<String, dynamic>,
        );
        final updated = current.update({'revision': current.revision + 1});
        await txn.update(
          'profiles',
          {'data': jsonEncode(updated.toJson())},
          where: 'id = ?',
          whereArgs: [id],
        );
        return updated;
      });

  Future<void> record(
    RecommendationProfile profile,
    Map<String, double> parts, {
    required double reward,
    required double weight,
    required String artist,
  }) async {
    if (!profile.learning) return;
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'profiles',
        where: 'id = ?',
        whereArgs: [profile.id],
      );
      if (rows.isEmpty) return;
      final current = RecommendationProfile.fromJson(
        jsonDecode(rows.single['data'] as String) as Map<String, dynamic>,
      );
      if (!current.learning || current.revision != profile.revision) return;
      await txn.insert('outcomes', {
        'profile_id': profile.id,
        'revision': profile.revision,
        'at': DateTime.now().millisecondsSinceEpoch,
        'parts': jsonEncode(parts),
        'reward': reward.clamp(0, 1),
        'weight': weight.clamp(0, 4),
        'artist': artist,
      });
      // One global bound, even with many profiles.
      await txn.rawDelete(
        'DELETE FROM outcomes WHERE id NOT IN (SELECT id FROM outcomes ORDER BY id DESC LIMIT 2000)',
      );
    });
  }

  Future<({List<AutoplayRankOutcome> outcomes, Map<String, double> affinity})>
  learning(RecommendationProfile profile) async {
    if (!profile.learning) {
      return (outcomes: <AutoplayRankOutcome>[], affinity: <String, double>{});
    }
    final rows = await (await database).query(
      'outcomes',
      where: 'profile_id = ? AND revision = ?',
      whereArgs: [profile.id, profile.revision],
      orderBy: 'id',
    );
    final affinity = <String, double>{};
    final counts = <String, double>{};
    final outcomes = <AutoplayRankOutcome>[];
    for (final row in rows) {
      final reward = (row['reward'] as num).toDouble();
      final weight = (row['weight'] as num).toDouble();
      final artist = row['artist'] as String;
      affinity[artist] = (affinity[artist] ?? 0) + (2 * reward - 1) * weight;
      counts[artist] = (counts[artist] ?? 0) + weight;
      outcomes.add(
        AutoplayRankOutcome(
          at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
          parts: (jsonDecode(row['parts'] as String) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toDouble())),
          reward: reward,
          weight: weight,
        ),
      );
    }
    return (
      outcomes: outcomes,
      affinity: affinity.map((k, v) => MapEntry(k, v / (2 + counts[k]!))),
    );
  }
}
