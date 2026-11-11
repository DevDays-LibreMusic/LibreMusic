import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';
import 'package:mornye/services/recommendations/recommendation_service.dart';
import 'package:mornye/services/recommendations/recommendation_store.dart';
import 'support/sqlite_process_database.dart';

class _Library extends LibraryDatabase {
  _Library(super.database) : super.withDatabase();
  int reads = 0;
  @override
  Future<List<Map<String, Object?>>> getRecommendationPage({
    required String source,
    required int limit,
    String? afterId,
    int? minSeconds,
    int? maxSeconds,
    int? minYear,
    int? maxYear,
    bool excludeUnknown = true,
    bool excludeMarkedExplicit = false,
  }) async {
    reads++;
    final start = afterId == null ? 0 : int.parse(afterId) + 1;
    return [
      for (var i = start; i < start + limit && i < 800; i++)
        {
          'id': '$i',
          'file_path': '/music/$i.flac',
          'track_name': 'Song $i',
          'artist_name': 'Artist ${i % 10}',
          'genre': i >= 780 ? 'Jazz' : 'Pop',
          'duration': 180,
          'release_date': '2020',
          'explicit': 0,
        },
    ];
  }
}

class _RemoteLibrary extends LibraryDatabase {
  _RemoteLibrary(super.database) : super.withDatabase();

  @override
  Future<List<Map<String, Object?>>> getRecommendationPage({
    required String source,
    required int limit,
    String? afterId,
    int? minSeconds,
    int? maxSeconds,
    int? minYear,
    int? maxYear,
    bool excludeUnknown = true,
    bool excludeMarkedExplicit = false,
  }) async {
    if (source != 'musicserver' || afterId != null) return [];
    return [
      {
        'id': 'musicserver://account/${'a' * 64}',
        'file_path': 'musicserver://account/${'a' * 64}',
        'track_name': 'Remote song',
        'artist_name': 'Remote artist',
        'album_name': 'Remote album',
        'genre': 'Jazz',
        'duration': 180,
        'release_date': '2024',
        'explicit': 0,
        'collection_id': 'musicserver://account/${'a' * 64}',
        'collection_source': 'local',
      },
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late RecommendationStore store;
  late _Library library;
  const profile = RecommendationProfile(
    id: 'work',
    name: 'Work',
    genres: ['Jazz'],
  );
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await RecommendationStore.create(db, 1);
    store = RecommendationStore(open: () async => db);
    await store.save(profile);
    library = _Library(db);
  });
  tearDown(() async => db.close());

  test(
    'filters before sampling across all pages; unavailable files are omitted',
    () async {
      final service = RecommendationService(
        store: store,
        library: library,
        loadHistory: () async => const RecommendationHistory(),
        exists: (path) async => path != '/music/799.flac',
      );
      final result = await service.generate(profile, includeLocal: false);
      expect(library.reads, 4);
      expect(result.matched, 20);
      expect(result.picks.length, 19);
      expect(result.picks.every((p) => p.media.genre == 'Jazz'), true);
      expect(
        result.picks.any((p) => p.media.source.endsWith('/799.flac')),
        false,
      );
    },
  );
  test('cancelled request stops before loading any library page', () async {
    final service = RecommendationService(
      store: store,
      library: library,
      loadHistory: () async => const RecommendationHistory(),
      exists: (_) async => true,
    );
    await expectLater(
      service.generate(profile, cancelled: () => true),
      throwsA(isA<RecommendationCancelled>()),
    );
    expect(library.reads, 0);
  });
  test('empty strict filter does not fall back to other music', () async {
    final service = RecommendationService(
      store: store,
      library: library,
      loadHistory: () async => const RecommendationHistory(),
      exists: (_) async => true,
    );
    final result = await service.generate(
      profile.update({
        'genres': ['Classical'],
      }),
      includeLocal: false,
    );
    expect(result.picks, isEmpty);
    expect(result.matched, 0);
  });
  test(
    'connected server assets pass availability without a file check',
    () async {
      var serverChecks = 0;
      var fileChecks = 0;
      final service = RecommendationService(
        store: store,
        library: _RemoteLibrary(db),
        loadHistory: () async => const RecommendationHistory(),
        exists: (_) async {
          fileChecks++;
          return false;
        },
        serverAvailable: (_) async {
          serverChecks++;
          return true;
        },
      );
      final result = await service.generate(profile, includeLocal: true);
      expect(result.picks, hasLength(1));
      expect(result.picks.single.media.source, startsWith('musicserver://'));
      expect(serverChecks, 1);
      expect(fileChecks, 0);
    },
  );

  test('disconnected server assets fail closed', () async {
    final service = RecommendationService(
      store: store,
      library: _RemoteLibrary(db),
      loadHistory: () async => const RecommendationHistory(),
      exists: (_) async => true,
      serverAvailable: (_) async => false,
    );
    final result = await service.generate(profile, includeLocal: true);
    expect(result.matched, 1);
    expect(result.picks, isEmpty);
  });
}
