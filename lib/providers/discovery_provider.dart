import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_repository.dart';
import 'package:mornye/services/discovery_source.dart';
import 'package:mornye/services/discovery_additional_sources.dart';
import 'package:mornye/services/discovery_composite_source.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';

final discoverySourceProvider = Provider.autoDispose<DiscoverySource>((ref) {
  final lastfmKey = ref.watch(lastfmAppCredentialsProvider).apiKey.trim();
  final source = CompositeDiscoverySource(
    registrations: [
      if (lastfmKey.isNotEmpty)
        DiscoverySourceRegistration(
          source: LastFmDiscoverySource(apiKey: lastfmKey),
          name: 'Last.fm',
          region: 'global',
          family: 'lastfm',
          kinds: {DiscoveryKind.trends},
        ),
      DiscoverySourceRegistration(
        source: AppleDiscoverySource(),
        name: 'Apple Music',
        region: 'us',
        family: 'apple',
        kinds: DiscoveryKind.values.toSet(),
      ),
      DiscoverySourceRegistration(
        source: DeezerDiscoverySource(),
        name: 'Deezer',
        region: 'auto',
        family: 'deezer',
        kinds: {DiscoveryKind.trends},
      ),
      DiscoverySourceRegistration(
        source: ItunesDiscoverySource(),
        name: 'iTunes Charts',
        region: 'us',
        family: 'apple',
        kinds: DiscoveryKind.values.toSet(),
      ),
      DiscoverySourceRegistration(
        source: YandexDiscoverySource(
          tokenProvider: () async {
            try {
              final settings = await PlatformBridge.getExtensionSettings(
                'yandex-music',
              ).timeout(const Duration(seconds: 2));
              return settings['token'] as String?;
            } catch (_) {
              return null;
            }
          },
        ),
        name: 'Yandex Music',
        region: 'auto',
        family: 'yandex',
        kinds: DiscoveryKind.values.toSet(),
      ),
    ],
  );
  ref.onDispose(source.close);
  return source;
});

final discoveryRepositoryProvider = Provider.autoDispose<DiscoveryRepository>(
  (ref) => DiscoveryRepository(
    source: ref.watch(discoverySourceProvider),
    persist: false,
  ),
);

final discoveryCatalogProvider = FutureProvider.autoDispose<DiscoveryCatalog>(
  (ref) => ref.watch(discoveryRepositoryProvider).getCatalog(),
);

// Family keys isolate responses for different filters. A late response cannot
// replace the feed currently watched by the screen after the user switches tabs.
final discoveryFeedProvider = FutureProvider.autoDispose
    .family<DiscoveryFeed, DiscoveryQuery>(
      (ref, query) => ref.watch(discoveryRepositoryProvider).getFeed(query),
    );

final discoveryAlbumTracksProvider = FutureProvider.autoDispose
    .family<List<Track>, String>(
      (ref, albumId) =>
          ref.watch(discoverySourceProvider).getAlbumTracks(albumId),
    );
