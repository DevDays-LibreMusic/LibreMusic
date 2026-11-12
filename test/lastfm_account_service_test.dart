import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lastfm_account_service.dart';

const credentials = LastfmAppCredentials(
  apiKey: 'application-key',
  sharedSecret: 'application-secret',
);
const session = LastfmSession(username: 'listener', key: 'session-secret');
const track = LastfmListeningTrack(
  title: 'Второй эшелон',
  artist: 'Гражданская Оборона',
  album: 'Всё идёт по плану',
  duration: Duration(seconds: 180),
);

void main() {
  test('qualifies audible time, not short or unknown-duration tracks', () {
    expect(track.qualifies(const Duration(seconds: 89)), isFalse);
    expect(track.qualifies(const Duration(seconds: 90)), isTrue);
    expect(
      const LastfmListeningTrack(
        title: 'a',
        artist: 'b',
      ).qualifies(const Duration(minutes: 10)),
      isFalse,
    );
    expect(
      const LastfmListeningTrack(
        title: 'a',
        artist: 'b',
        duration: Duration(seconds: 30),
      ).qualifies(const Duration(seconds: 30)),
      isFalse,
    );
    expect(
      const LastfmListeningTrack(
        title: 'a',
        artist: 'b',
        duration: Duration(minutes: 20),
      ).qualifies(const Duration(minutes: 4)),
      isTrue,
    );
  });

  test('token request is signed without format and uses HTTPS', () async {
    final service = LastfmAccountService(
      minimumInterval: Duration.zero,
      credentials: credentials,
      client: MockClient((request) async {
        expect(request.url.scheme, 'https');
        expect(
          request.bodyFields['api_sig'],
          '4a3a28dbb0821a60e3b0a8a177c6d038',
        );
        expect(request.bodyFields['format'], 'json');
        expect(request.method, 'POST');
        expect(request.url.query, isEmpty);
        expect(request.headers['User-Agent'], 'Mornye/Lastfm');
        return http.Response('{"token":"request-token"}', 200);
      }),
    );
    addTearDown(service.dispose);
    expect(await service.requestToken(), 'request-token');
    expect(service.authorizationUri('request-token').queryParameters, {
      'api_key': 'application-key',
      'token': 'request-token',
    });
  });

  test(
    'scrobble writes UTF8 metadata and stable original timestamp in POST body',
    () async {
      final service = LastfmAccountService(
        minimumInterval: Duration.zero,
        credentials: credentials,
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.query, isEmpty);
          expect(request.bodyFields['track'], track.title);
          expect(request.bodyFields['artist'], track.artist);
          expect(request.bodyFields['timestamp'], '1700000000');
          expect(request.bodyFields['chosenByUser'], '0');
          expect(request.bodyFields['sk'], session.key);
          final signed = Map<String, String>.from(request.bodyFields)
            ..remove('api_sig')
            ..remove('format');
          final keys = signed.keys.toList()..sort();
          final expected = md5
              .convert(
                utf8.encode(
                  '${keys.map((key) => '$key${signed[key]}').join()}${credentials.sharedSecret}',
                ),
              )
              .toString();
          expect(request.bodyFields['api_sig'], expected);
          expect(
            request.bodyFields.containsValue(credentials.sharedSecret),
            isFalse,
          );
          return http.Response(
            '{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"}}}',
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final result = await service.scrobble(
        session,
        track,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          1700000000000,
          isUtc: true,
        ),
        chosenByUser: false,
      );
      expect(result.accepted, isTrue);
    },
  );

  test(
    'API error is classified even on non-200 and never exposes server body',
    () async {
      final service = LastfmAccountService(
        minimumInterval: Duration.zero,
        credentials: credentials,
        client: MockClient(
          (_) async => http.Response(
            '{"error":9,"message":"secret token signed-url"}',
            403,
          ),
        ),
      );
      addTearDown(service.dispose);
      try {
        await service.nowPlaying(session, track);
        fail('Expected invalid session');
      } on LastfmAccountException catch (error) {
        expect(error.kind, LastfmAccountErrorKind.sessionExpired);
        expect(error.toString(), isNot(contains('secret')));
        expect(error.message(), isNot(contains('signed-url')));
      }
    },
  );

  test(
    'scrobble ignored status distinguishes permanent rejection and retryable limit',
    () async {
      var code = 5;
      final service = LastfmAccountService(
        minimumInterval: Duration.zero,
        credentials: credentials,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'scrobbles': {
                '@attr': {'accepted': '0', 'ignored': '1'},
                'scrobble': {
                  'ignoredMessage': {'code': '$code'},
                },
              },
            }),
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      var result = await service.scrobble(
        session,
        track,
        startedAt: DateTime.now(),
        chosenByUser: true,
      );
      expect(result.accepted, isFalse);
      expect(result.retryLater, isTrue);
      code = 3;
      result = await service.scrobble(
        session,
        track,
        startedAt: DateTime.now(),
        chosenByUser: true,
      );
      expect(result.retryLater, isFalse);
    },
  );

  test('empty successful body is not a successful scrobble', () async {
    final service = LastfmAccountService(
      minimumInterval: Duration.zero,
      credentials: credentials,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.scrobble(
        session,
        track,
        startedAt: DateTime.now(),
        chosenByUser: true,
      ),
      throwsA(
        isA<LastfmAccountException>().having(
          (e) => e.kind,
          'kind',
          LastfmAccountErrorKind.invalidResponse,
        ),
      ),
    );
  });

  test(
    'missing application configuration never starts network request',
    () async {
      final service = LastfmAccountService(
        minimumInterval: Duration.zero,
        credentials: const LastfmAppCredentials(apiKey: '', sharedSecret: ''),
        client: MockClient((_) async {
          fail('Should not request');
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.requestToken(),
        throwsA(
          isA<LastfmAccountException>().having(
            (e) => e.kind,
            'kind',
            LastfmAccountErrorKind.notConfigured,
          ),
        ),
      );
    },
  );
}
