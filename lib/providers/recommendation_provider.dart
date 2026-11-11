import 'package:mornye/services/recommendations/recommendation_service.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/music_player_service.dart'
    show refreshRecommendationProfile;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/providers/music_player_provider.dart';

final recommendationProfilesProvider =
    AsyncNotifierProvider<RecommendationProfiles, List<RecommendationProfile>>(
      RecommendationProfiles.new,
    );

class RecommendationProfiles
    extends AsyncNotifier<List<RecommendationProfile>> {
  @override
  Future<List<RecommendationProfile>> build() =>
      ref.read(musicPlayerRuntimeProvider).recommendations.store.profiles();

  Future<void> save(RecommendationProfile profile) async {
    await ref
        .read(musicPlayerRuntimeProvider)
        .recommendations
        .store
        .save(profile);
    if (!ref.mounted) return;
    ref.invalidateSelf();
    if (ref.read(settingsProvider).recommendationProfileId == profile.id) {
      refreshRecommendationProfile(
        runtime: ref.read(musicPlayerRuntimeProvider),
      );
    }
  }

  Future<void> delete(String id) async {
    final service = ref.read(musicPlayerRuntimeProvider).recommendations;
    await service.reset(id);
    await service.store.delete(id);
    if (!ref.mounted) return;
    ref.invalidateSelf();
    if (ref.read(settingsProvider).recommendationProfileId == id) {
      ref.read(settingsProvider.notifier).setRecommendationProfileId('');
    }
    refreshRecommendationProfile(runtime: ref.read(musicPlayerRuntimeProvider));
  }

  Future<void> activate(String? id) async {
    ref.read(settingsProvider.notifier).setRecommendationProfileId(id ?? '');
    refreshRecommendationProfile(runtime: ref.read(musicPlayerRuntimeProvider));
  }
}

final activeRecommendationProfileProvider = Provider<String>(
  (ref) => ref.watch(settingsProvider.select((s) => s.recommendationProfileId)),
);

/// Read only eligible local rows, including downloads, in bounded pages.
final recommendationGenresProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final library = ref.read(musicPlayerRuntimeProvider).recommendations.library;
  final includeLocal = ref.watch(
    settingsProvider.select((s) => s.localLibraryEnabled),
  );
  final genres = <String>{};
  for (final source in [
    'downloaded',
    if (includeLocal) ...['local', 'musicserver'],
  ]) {
    String? after;
    while (ref.mounted) {
      final rows = await library.getRecommendationPage(
        source: source,
        limit: 256,
        afterId: after,
      );
      for (final row in rows) {
        genres.addAll(recommendationGenres(row['genre'] as String?));
      }
      if (rows.length < 256) break;
      after = rows.last['id'] as String;
    }
  }
  return genres.toList()..sort();
});

final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => ref.read(musicPlayerRuntimeProvider).recommendations,
);
