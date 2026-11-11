import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/services/recommendations/recommendation_store.dart';
import 'support/sqlite_process_database.dart';

void main() {
  late SqliteProcessDatabase db;
  late RecommendationStore store;
  const first = RecommendationProfile(id: 'a', name: 'Work');
  const second = RecommendationProfile(id: 'b', name: 'Evening');
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await RecommendationStore.create(db, 1);
    store = RecommendationStore(open: () async => db);
  });
  tearDown(() async => db.close());

  test(
    'profiles persist across store instances; feedback stays in its profile',
    () async {
      await store.save(first);
      await store.save(second);
      await store.record(
        first,
        {'history': 1},
        reward: 1,
        weight: 3,
        artist: 'artist',
      );
      final restored = RecommendationStore(open: () async => db);
      expect((await restored.profiles()).map((p) => p.name), [
        'Work',
        'Evening',
      ]);
      expect((await restored.learning(first)).outcomes, hasLength(1));
      expect((await restored.learning(second)).outcomes, isEmpty);
    },
  );
  test(
    'stale, disabled and deleted profile feedback cannot re-create learning',
    () async {
      await store.save(first.update({'revision': 2}));
      await store.record(first, {}, reward: 1, weight: 1, artist: 'artist');
      expect((await store.learning(first)).outcomes, isEmpty);
      await store.save(first.update({'learning': false}));
      await store.record(first, {}, reward: 1, weight: 1, artist: 'artist');
      expect((await store.learning(first)).outcomes, isEmpty);
      await store.delete(first.id);
      await store.record(first, {}, reward: 1, weight: 1, artist: 'artist');
      expect(await store.profiles(), isEmpty);
      expect((await store.learning(first)).outcomes, isEmpty);
    },
  );
  test('reset and delete preserve other profiles', () async {
    for (final p in [first, second]) {
      await store.save(p);
      await store.record(
        p,
        {'history': 1},
        reward: 1,
        weight: 1,
        artist: 'artist',
      );
    }
    await store.reset(first.id);
    expect((await store.learning(first)).outcomes, isEmpty);
    await store.record(
      first,
      {'history': 1},
      reward: 1,
      weight: 1,
      artist: 'stale',
    );
    expect((await store.learning(first)).outcomes, isEmpty);
    expect((await store.learning(second)).outcomes, hasLength(1));
    await store.delete(first.id);
    expect((await store.profiles()).single.id, second.id);
  });
}
