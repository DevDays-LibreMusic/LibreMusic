import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lastfm_wave_service.dart';

Map<String, dynamic> track(String title, String artist) => {
  'name': title,
  'artist': {'name': artist},
  'image': [
    {'size': 'large', '#text': 'https://example.com/cover.jpg'},
  ],
};

http.Response response(String container, Object tracks) => http.Response(
  jsonEncode({
    container: {'track': tracks},
  }),
  200,
);

void main() {
  for (final malformed in [
    <String, Object>{},
    {'track': 'broken'},
    {
      'track': [
        {'bad': true},
      ],
    },
  ]) {
    test('rejects malformed track shape $malformed', () async {
      final service = LastfmWaveService(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'toptracks': malformed}), 200),
        ),
      );
      await expectLater(
        service.recommend(username: 'listener', apiKey: 'secret'),
        throwsA(
          isA<LastfmWaveException>().having(
            (e) => e.kind,
            'kind',
            LastfmWaveErrorKind.unexpectedResponse,
          ),
        ),
      );
      service.dispose();
    });
  }
  test(
    'parses API rejection before HTTP status and sanitizes diagnostics',
    () async {
      final service = LastfmWaveService(
        client: MockClient(
          (_) async => http.Response(
            '{"error":10,"message":"secret reflected https://example.com?api_key=secret"}',
            403,
          ),
        ),
      );
      try {
        await service.recommend(username: 'listener', apiKey: 'secret');
        fail('expected rejection');
      } on LastfmWaveException catch (error) {
        expect(error.kind, LastfmWaveErrorKind.invalidKey);
        expect(error.httpStatus, 403);
        expect(error.code, 10);
        expect(error.diagnostic, contains('method=user.getTopTracks'));
        expect(error.toString(), isNot(contains('secret')));
        expect(error.toString(), isNot(contains('https://')));
      }
      service.dispose();
    },
  );

  test(
    'mixes diverse seeds, deduplicates and retains different versions',
    () async {
      final requests = <http.Request>[];
      final service = LastfmWaveService(
        client: MockClient((request) async {
          requests.add(request);
          final query = request.url.queryParameters;
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'ws.audioscrobbler.com');
          expect(query['api_key'], 'secret');
          if (query['method'] == 'user.getTopTracks') {
            expect(query['user'], 'listener');
            expect(query['period'], '1month');
            return response('toptracks', [
              for (var i = 0; i < 20; i++) track('Seed $i', 'Artist ${i % 6}'),
            ]);
          }
          return response('similartracks', [
            track('A song', 'Shared artist'),
            track(' a SONG ', ' shared ARTIST '),
            track('A song (Live)', 'Shared artist'),
            track('New ${query['track']}', 'New ${query['artist']}'),
          ]);
        }),
      );
      addTearDown(service.dispose);
      final wave = await service.recommend(
        username: ' listener ',
        apiKey: 'secret',
      );
      expect(requests.length, 6);
      expect(wave.length, lessThanOrEqualTo(20));
      expect(wave.where((t) => t.title == 'A song'), hasLength(1));
      expect(wave.where((t) => t.title == 'A song (Live)'), hasLength(1));
      expect(wave.where((t) => t.title.startsWith('New ')), hasLength(5));
      expect(wave.first.artworkUrl, 'https://example.com/cover.jpg');
      expect(
        LastfmWaveTrack.fromJson(wave.first.toJson()).title,
        wave.first.title,
      );
    },
  );

  test(
    'uses overall history for a quiet month and seeds for sparse similarity',
    () async {
      final periods = <String?>[];
      final service = LastfmWaveService(
        client: MockClient((request) async {
          final query = request.url.queryParameters;
          if (query['method'] == 'user.getTopTracks') {
            periods.add(query['period']);
            return response(
              'toptracks',
              query['period'] == '1month'
                  ? []
                  : track('Old favorite', 'Artist'),
            );
          }
          return response('similartracks', []);
        }),
      );
      addTearDown(service.dispose);
      final wave = await service.recommend(username: 'listener', apiKey: 'key');
      expect(periods, ['1month', 'overall']);
      expect(wave.single.title, 'Old favorite');
    },
  );

  test(
    'empty listening history returns no fabricated recommendations',
    () async {
      var calls = 0;
      final service = LastfmWaveService(
        client: MockClient((_) async {
          calls++;
          return response('toptracks', []);
        }),
      );
      addTearDown(service.dispose);
      expect(
        await service.recommend(username: 'listener', apiKey: 'key'),
        isEmpty,
      );
      expect(calls, 2);
    },
  );

  test(
    'partial similar failure keeps recommendations from other seeds',
    () async {
      final service = LastfmWaveService(
        client: MockClient((request) async {
          final query = request.url.queryParameters;
          if (query['method'] == 'user.getTopTracks') {
            return response('toptracks', [
              track('One', 'A'),
              track('Two', 'B'),
            ]);
          }
          if (query['track'] == 'One') return http.Response('Unavailable', 503);
          return response('similartracks', [track('Discovery', 'C')]);
        }),
      );
      addTearDown(service.dispose);
      final wave = await service.recommend(username: 'listener', apiKey: 'key');
      expect(wave.first.title, 'Discovery');
    },
  );

  for (final error in [10, 26, 29]) {
    test('API error $error is safe and stops requests', () async {
      var calls = 0;
      final service = LastfmWaveService(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({'error': error, 'message': 'sensitive-key-in-url'}),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.recommend(username: 'listener', apiKey: 'sensitive-key-in-url'),
        throwsA(
          isA<LastfmWaveException>()
              .having((e) => e.code, 'code', error)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('sensitive')),
              ),
        ),
      );
      expect(calls, 1);
    });
  }

  test(
    'complete similarity outage reports failure instead of caching a fake success',
    () async {
      final service = LastfmWaveService(
        client: MockClient((request) async {
          if (request.url.queryParameters['method'] == 'user.getTopTracks') {
            return response('toptracks', [track('One', 'A')]);
          }
          throw http.ClientException('secret-url');
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.recommend(username: 'listener', apiKey: 'key'),
        throwsA(
          isA<LastfmWaveException>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret-url')),
          ),
        ),
      );
    },
  );

  test('invalid input performs no requests', () async {
    final service = LastfmWaveService(
      client: MockClient((_) async => throw StateError('Must not request')),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.recommend(username: ' ', apiKey: 'key'),
      throwsA(isA<LastfmWaveException>()),
    );
  });

  test('malformed response is an explicit error', () async {
    final service = LastfmWaveService(
      client: MockClient(
        (_) async => http.Response('{"unexpected":true}', 200),
      ),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.recommend(username: 'listener', apiKey: 'key'),
      throwsA(isA<LastfmWaveException>()),
    );
  });
}
