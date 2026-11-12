import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/services/discovery_additional_sources.dart';

String fixture(String name) =>
    File('test/fixtures/discovery/$name.json').readAsStringSync();
http.Response jsonResponse(Object data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  const trends = DiscoveryQuery(kind: DiscoveryKind.trends);
  const releases = DiscoveryQuery(kind: DiscoveryKind.newReleases);

  test(
    'Deezer chart preserves native IDs and actual order, not popularity score',
    () async {
      final source = DeezerDiscoverySource(
        client: MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode(fixture('deezer-chart')), 200),
        ),
      );
      addTearDown(source.close);
      final feed = await source.getFeed(trends);
      expect(feed.region, 'auto');
      expect(feed.entries, hasLength(2));
      expect(feed.entries.first.position, 1);
      expect(feed.entries.first.track.id, '3818963601');
      expect(feed.entries.first.track.source, 'deezer');
      expect(feed.entries.first.track.duration, 209);
      expect(feed.entries.first.track.explicit, true);
      expect(feed.entries.first.genres, isEmpty);
      expect(() => source.getFeed(releases), throwsUnsupportedError);
    },
  );

  test('iTunes chart preview duration is not the recording duration', () async {
    final source = ItunesDiscoverySource(
      client: MockClient(
        (_) async =>
            http.Response.bytes(utf8.encode(fixture('itunes-chart')), 200),
      ),
    );
    addTearDown(source.close);
    final feed = await source.getFeed(trends);
    expect(feed.sourceName, 'iTunes Charts');
    expect(feed.entries.first.track.id, '1844932150');
    expect(feed.entries.first.track.albumId, '1844932149');
    expect(feed.entries.first.track.duration, 0);
    expect(feed.entries.first.genres, ['Country']);
    expect(feed.entries.first.position, 1);
  });

  test(
    'iTunes recent songs and albums require their own exact recent date',
    () async {
      final fixtureJson =
          jsonDecode(fixture('itunes-albums')) as Map<String, dynamic>;
      final feedJson = fixtureJson['feed'] as Map<String, dynamic>;
      final original =
          (feedJson['entry'] as List).first as Map<String, dynamic>;
      final rows = <Map<String, dynamic>>[];
      final dates = [
        '2026-11-06T00:00:00Z',
        '2026-10-13',
        '2026-10-12',
        '2026-11-13',
        '2026',
        '2026-10-32',
        '',
      ];
      for (var i = 0; i < dates.length; i++) {
        rows.add({
          ...original,
          'id': {
            'attributes': {'im:id': '$i'},
          },
          'im:releaseDate': {'label': dates[i]},
        });
      }
      final source = ItunesDiscoverySource(
        now: () => DateTime.utc(2026, 11, 12),
        client: MockClient(
          (request) async => jsonResponse({
            'feed': {
              'entry': rows
                  .map(
                    (row) => {
                      ...row,
                      'im:name': {
                        'label': request.url.path.contains('topsongs')
                            ? 'Song'
                            : 'Album',
                      },
                    },
                  )
                  .toList(),
            },
          }),
        ),
      );
      addTearDown(source.close);
      final feed = await source.getFeed(releases);
      expect(feed.entries.map((e) => e.track.id), ['0', '1', '0', '1']);
      expect(feed.entries.where((e) => e.track.isAlbumItem), hasLength(2));
      expect(feed.entries.where((e) => !e.track.isCollection), hasLength(2));
      expect(feed.entries.map((e) => e.position), [1, 2, 1, 2]);
      expect(feed.entries.first.track.name, 'Song');
      expect(feed.entries.last.track.name, 'Album');
    },
  );

  for (final failedChart in ['topalbums', 'topsongs']) {
    test(
      'iTunes keeps the other new-release chart when $failedChart fails',
      () async {
        final source = ItunesDiscoverySource(
          now: () => DateTime.utc(2026, 11, 12),
          client: MockClient((request) async {
            if (request.url.path.contains(failedChart)) {
              return http.Response('unavailable', 503);
            }
            return jsonResponse({
              'feed': {
                'entry': [
                  {
                    'id': {
                      'attributes': {'im:id': '123'},
                    },
                    'im:name': {'label': 'Fresh music'},
                    'im:releaseDate': {'label': '2026-11-10'},
                  },
                ],
              },
            });
          }),
        );
        addTearDown(source.close);
        final feed = await source.getFeed(releases);
        expect(feed.entries, hasLength(1));
        expect(
          feed.entries.single.track.isAlbumItem,
          failedChart == 'topsongs',
        );
      },
    );
  }

  test(
    'iTunes reports failure when neither release chart is available',
    () async {
      final source = ItunesDiscoverySource(
        client: MockClient((_) async => http.Response('unavailable', 503)),
      );
      addTearDown(source.close);
      await expectLater(source.getFeed(releases), throwsStateError);
    },
  );

  test('Yandex preserves version, ISRC and original chart position', () async {
    final source = YandexDiscoverySource(
      client: MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), false);
        return jsonResponse({
          'result': {
            'chart': {
              'tracks': [
                {
                  'chart': {'position': 9},
                  'track': {
                    'id': 111,
                    'title': 'Песня',
                    'version': 'Live',
                    'durationMs': 192500,
                    'isrc': 'RUABC2600011',
                    'contentWarning': 'explicit',
                    'artists': [
                      {'name': 'Артист'},
                    ],
                    'albums': [
                      {
                        'id': 12,
                        'title': 'Альбом',
                        'genre': 'rock',
                        'releaseDate': '2026-11-01',
                      },
                    ],
                    'coverUri': 'avatars.yandex.net/get-music-content/123/%%',
                  },
                },
              ],
            },
          },
        });
      }),
    );
    addTearDown(source.close);
    final entry = (await source.getFeed(trends)).entries.single;
    expect(entry.position, 9);
    expect(entry.track.name, 'Песня (Live)');
    expect(entry.track.artistName, 'Артист');
    expect(entry.track.isrc, 'RUABC2600011');
    expect(entry.track.duration, 193);
    expect(entry.track.explicit, true);
    expect(
      entry.track.coverUrl,
      'https://avatars.yandex.net/get-music-content/123/600x600',
    );
    expect(entry.genres, ['rock']);
  });

  test(
    'Yandex hydrates only selected albums and requires actual release dates',
    () async {
      final paths = <String>[];
      final source = YandexDiscoverySource(
        now: () => DateTime.utc(2026, 11, 12),
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/landing3/new-releases') {
            return jsonResponse({
              'result': {
                'newReleases': [1, 2, 3, 4],
              },
            });
          }
          expect(request.method, 'POST');
          expect(request.bodyFields['album-ids'], '1,2,3,4');
          return jsonResponse({
            'result': [
              {
                'id': 1,
                'title': 'New',
                'releaseDate': '2026-11-02',
                'genre': 'pop',
              },
              {'id': 2, 'title': 'Old', 'releaseDate': '2025-11-02'},
              {'id': 3, 'title': 'Incomplete', 'year': 2026},
              {'id': 4, 'title': 'Future', 'releaseDate': '2026-11-20'},
              {'id': 99, 'title': 'Unrequested', 'releaseDate': '2026-11-02'},
            ],
          });
        }),
      );
      addTearDown(source.close);
      final feed = await source.getFeed(releases);
      expect(paths, ['/landing3/new-releases', '/albums']);
      expect(feed.entries.map((e) => e.track.id), ['1']);
      expect(feed.entries.single.track.isAlbumItem, true);
    },
  );

  test(
    'Yandex reuses optional configured OAuth but errors do not expose it',
    () async {
      final source = YandexDiscoverySource(
        tokenProvider: () async => 'OAuth private-test-token',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'OAuth private-test-token');
          return http.Response('private-test-token', 451);
        }),
      );
      addTearDown(source.close);
      await expectLater(
        source.getFeed(trends),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('451') &&
                !error.toString().contains('private-test-token'),
          ),
        ),
      );
    },
  );

  test(
    'provider API errors and malformed responses do not become empty success',
    () async {
      final deezer = DeezerDiscoverySource(
        client: MockClient(
          (_) async => jsonResponse({
            'error': {'type': 'DataException'},
          }),
        ),
      );
      final itunes = ItunesDiscoverySource(
        client: MockClient(
          (_) async => jsonResponse({'feed': <String, dynamic>{}}),
        ),
      );
      final yandex = YandexDiscoverySource(
        client: MockClient(
          (_) async => jsonResponse({
            'result': {'chart': <String, dynamic>{}},
          }),
        ),
      );
      addTearDown(deezer.close);
      addTearDown(itunes.close);
      addTearDown(yandex.close);
      await expectLater(deezer.getFeed(trends), throwsStateError);
      await expectLater(itunes.getFeed(trends), throwsFormatException);
      await expectLater(yandex.getFeed(trends), throwsFormatException);
    },
  );

  test(
    'Last.fm global chart uses existing app key without user authorization',
    () async {
      final source = LastFmDiscoverySource(
        apiKey: 'test-application-key',
        client: MockClient((request) async {
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'ws.audioscrobbler.com');
          expect(request.url.queryParameters['method'], 'chart.gettoptracks');
          expect(
            request.url.queryParameters['api_key'],
            'test-application-key',
          );
          expect(request.headers.containsKey('Authorization'), false);
          return jsonResponse({
            'tracks': {
              'track': [
                {
                  'name': 'Song',
                  'artist': {'name': 'Artist'},
                  'mbid': 'recording-mbid',
                  'duration': '180',
                  'listeners': '90000',
                },
                {
                  'name': 'Another',
                  'artist': {'name': 'Band / Duo'},
                  'mbid': '',
                  'duration': '0',
                  'listeners': '100',
                },
              ],
            },
          });
        }),
      );
      addTearDown(source.close);
      final feed = await source.getFeed(trends);
      expect(feed.region, 'global');
      expect(feed.entries.first.position, 1);
      expect(feed.entries.first.track.id, 'recording-mbid');
      expect(feed.entries.first.track.duration, 180);
      expect(feed.entries.last.track.id, 'Band%20%2F%20Duo/Another');
      expect(feed.entries.every((e) => e.genres.isEmpty), true);
      expect(() => source.getFeed(releases), throwsUnsupportedError);
    },
  );

  test(
    'Last.fm requires an application key and never leaks it through transport errors',
    () async {
      expect(() => LastFmDiscoverySource(apiKey: ' '), throwsArgumentError);
      final source = LastFmDiscoverySource(
        apiKey: 'private-test-key',
        client: MockClient((request) async {
          throw http.ClientException('failed URI ${request.url}', request.url);
        }),
      );
      addTearDown(source.close);
      await expectLater(
        source.getFeed(trends),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('Last.fm') &&
                !error.toString().contains('private-test-key'),
          ),
        ),
      );
    },
  );

  test('parallel reads share requests but failures can be retried', () async {
    var requests = 0;
    final source = DeezerDiscoverySource(
      client: MockClient((_) async {
        requests++;
        if (requests == 1) {
          return http.Response('', 503);
        }
        return http.Response.bytes(utf8.encode(fixture('deezer-chart')), 200);
      }),
    );
    addTearDown(source.close);
    await expectLater(source.getFeed(trends), throwsStateError);
    final result = await Future.wait([
      source.getFeed(trends),
      source.getFeed(trends),
    ]);
    expect(result.every((f) => f.entries.length == 2), true);
    expect(requests, 2);
  });
}
