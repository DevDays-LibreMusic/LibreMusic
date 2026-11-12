import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/services/discovery_source.dart';

String fixture(String file) =>
    File('test/fixtures/discovery/$file').readAsStringSync();

void main() {
  AppleDiscoverySource source({
    String? lookup,
    String? page,
    String? chart,
    List<Uri>? requests,
  }) => AppleDiscoverySource(
    now: () => DateTime.utc(2026, 11, 12),
    client: MockClient((request) async {
      requests?.add(request.url);
      final body = switch (request.url.host) {
        'music.apple.com' => page ?? fixture('apple_new.html'),
        'itunes.apple.com' => lookup ?? fixture('apple_lookup.json'),
        _ => chart ?? fixture('apple_chart.json'),
      };
      return http.Response(
        body,
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  test(
    'real Apple fixtures supply dated releases and album identities',
    () async {
      final api = source();
      addTearDown(api.close);
      final feed = await api.getFeed(
        const DiscoveryQuery(kind: DiscoveryKind.newReleases),
      );
      expect(feed.entries, hasLength(2));
      expect(
        feed.entries.map((e) => e.track.id),
        containsAll(['6831506154', '6823820064']),
      );
      final song = feed.entries.firstWhere((e) => !e.track.isCollection).track;
      expect(song.source, 'apple-music');
      expect(song.albumId, '6831506152');
      expect(song.duration, 214);
      expect(song.releaseDate, startsWith('2026-11-06'));
      expect(feed.entries.where((e) => e.track.isAlbumItem), hasLength(1));
    },
  );

  test(
    'old, future, undated and unsolicited lookup rows are not new releases',
    () async {
      final rows =
          (jsonDecode(fixture('apple_lookup.json'))
                  as Map<String, dynamic>)['results']
              as List;
      final original = Map<String, dynamic>.from(rows.first as Map);
      for (final date in [
        '2026-01-01T00:00:00Z',
        '2026-11-13T00:00:00Z',
        '2026-11',
        '2026-10-32T00:00:00Z',
        null,
      ]) {
        final api = source(
          lookup: jsonEncode({
            'results': [
              {...original, 'releaseDate': date},
            ],
          }),
        );
        final result = await api.getFeed(
          const DiscoveryQuery(kind: DiscoveryKind.newReleases),
        );
        expect(result.entries, isEmpty);
        api.close();
      }
      final api = source(
        lookup: jsonEncode({
          'results': [
            {...original, 'trackId': 999},
          ],
        }),
      );
      expect(
        (await api.getFeed(
          const DiscoveryQuery(kind: DiscoveryKind.newReleases),
        )).entries,
        isEmpty,
      );
      api.close();
    },
  );

  test('genre filtering preserves global chart position', () async {
    final api = source(
      chart: jsonEncode({
        'feed': {
          'results': [
            {
              'id': '1',
              'name': 'One',
              'genres': [
                {'genreId': '14', 'name': 'Pop'},
              ],
            },
            {
              'id': '2',
              'name': 'Two',
              'genres': [
                {'genreId': '21', 'name': 'Rock'},
                {'genreId': '34', 'name': 'Music'},
              ],
            },
          ],
        },
      }),
    );
    addTearDown(api.close);
    final feed = await api.getFeed(
      const DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Rock'),
    );
    expect(feed.entries.single.position, 2);
    expect(feed.entries.single.genres, ['Rock']);
    expect(feed.entries.single.track.id, '2');
  });

  test(
    'catalog derives genres from provider metadata and serializes',
    () async {
      final api = source();
      addTearDown(api.close);
      final catalog = await api.getCatalog();
      expect(
        catalog.genres.map((g) => g.id),
        containsAll(['0', 'Hip-Hop/Rap']),
      );
      expect(catalog.genres.map((g) => g.name), isNot(contains('Music')));
      expect(
        DiscoveryCatalog.fromJson(catalog.toJson()).sourceName,
        'Apple Music',
      );
      expect(catalog.copyWith(isStale: true).isStale, isTrue);
    },
  );

  test('unknown page layout fails rather than reporting no releases', () async {
    final api = source(
      page: '<script id="serialized-server-data">{"data":[]}</script>',
    );
    addTearDown(api.close);
    await expectLater(
      api.getFeed(const DiscoveryQuery(kind: DiscoveryKind.newReleases)),
      throwsFormatException,
    );
  });

  test(
    'chart feed keeps source metadata through cache serialization',
    () async {
      final api = source();
      addTearDown(api.close);
      final feed = await api.getFeed(
        const DiscoveryQuery(kind: DiscoveryKind.trends),
      );
      final cached = DiscoveryFeed.fromJson(
        jsonDecode(jsonEncode(feed.toJson())) as Map<String, dynamic>,
      );
      expect(cached.entries, hasLength(3));
      expect(cached.entries.first.track.source, 'apple-music');
      expect(cached.entries.first.position, 1);
      expect(cached.copyWith(isStale: true).isStale, isTrue);
    },
  );

  test(
    'album lookup requests songs and excludes album/unrelated tracks',
    () async {
      final requests = <Uri>[];
      final rows =
          (jsonDecode(fixture('apple_lookup.json')) as Map)['results'] as List;
      final api = source(
        requests: requests,
        lookup: jsonEncode({
          'results': [
            ...rows,
            {...rows.first as Map, 'trackId': 123, 'collectionId': 6823820064},
          ],
        }),
      );
      addTearDown(api.close);
      final tracks = await api.getAlbumTracks('6823820064');
      expect(tracks.single.id, '123');
      expect(requests.single.queryParameters['entity'], 'song');
      expect(requests.single.queryParameters['country'], 'us');
      expect(requests.single.queryParameters['limit'], '200');
    },
  );

  test(
    'query isolates kinds and genres and rejects unsupported region',
    () async {
      const a = DiscoveryQuery(kind: DiscoveryKind.trends);
      const b = DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Rock');
      expect(a.cacheKey, isNot(b.cacheKey));
      expect(a, const DiscoveryQuery(kind: DiscoveryKind.trends));
      final api = source();
      addTearDown(api.close);
      await expectLater(
        api.getFeed(
          const DiscoveryQuery(kind: DiscoveryKind.trends, region: 'gb'),
        ),
        throwsArgumentError,
      );
    },
  );
  test('Hip-Hop aliases share one filter across releases and chart', () async {
    final api = source(
      chart: jsonEncode({
        'feed': {
          'results': [
            {
              'id': '1',
              'name': 'Hip-Hop chart song',
              'genres': [
                {'genreId': '18', 'name': 'Hip-Hop'},
              ],
            },
          ],
        },
      }),
    );
    addTearDown(api.close);
    final catalog = await api.getCatalog();
    expect(catalog.genres.where((g) => g.name == 'Hip-Hop/Rap'), hasLength(1));
    expect(catalog.genres.any((g) => g.name == 'Hip-Hop'), isFalse);
    final releases = await api.getFeed(
      const DiscoveryQuery(
        kind: DiscoveryKind.newReleases,
        genreId: 'Hip-Hop/Rap',
      ),
    );
    final chart = await api.getFeed(
      const DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Hip-Hop/Rap'),
    );
    expect(releases.entries, hasLength(2));
    expect(chart.entries.single.position, 1);
  });

  test(
    'genre switches reuse the source feed and concurrent requests coalesce',
    () async {
      final requests = <Uri>[];
      final api = source(requests: requests);
      addTearDown(api.close);
      await Future.wait([
        api.getFeed(const DiscoveryQuery(kind: DiscoveryKind.trends)),
        api.getFeed(
          const DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Pop'),
        ),
      ]);
      await api.getFeed(
        const DiscoveryQuery(kind: DiscoveryKind.trends, genreId: 'Country'),
      );
      expect(requests, hasLength(1));
    },
  );
}
