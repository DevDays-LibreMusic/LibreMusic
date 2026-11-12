import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  test(
    'checks LAN access before login and after permission revocation',
    () async {
      var granted = true;
      var requests = 0;
      final checked = <Uri>[];
      final client = MusicServerClient(
        ensureAccess: (target) async {
          checked.add(target);
          if (!granted) throw const LocalNetworkPermissionException();
        },
        client: MockClient((request) async {
          requests++;
          return http.Response(
            '{"access_token":"a","refresh_token":"r","user_id":"alice"}',
            200,
          );
        }),
        readSession: () async => null,
        writeSession: (_) async {},
      );
      const address = 'https://192.168.1.10';
      await client.login(address, 'alice', 'password');
      expect(requests, 1);
      granted = false;
      await expectLater(
        client.request('GET', '/v1/library'),
        throwsA(isA<LocalNetworkPermissionException>()),
      );
      await expectLater(
        client.login(address, 'alice', 'password'),
        throwsA(isA<LocalNetworkPermissionException>()),
      );
      expect(
        requests,
        1,
        reason: 'Denied access must not send credentials or API requests',
      );
      expect(checked, List.filled(3, Uri.parse(address)));
    },
  );

  test('requires HTTPS except for loopback development', () {
    expect(
      MusicServerClient.validateAddress('https://music.example.org').scheme,
      'https',
    );
    expect(
      MusicServerClient.validateAddress('http://127.0.0.1:8080').port,
      8080,
    );
    for (final address in [
      'http://music.example.org',
      'https://user:pass@music.example.org',
      'https://music.example.org/private',
      'https://music.example.org?token=secret',
    ]) {
      expect(
        () => MusicServerClient.validateAddress(address),
        throwsA(isA<MusicServerException>()),
      );
    }
  });

  test(
    'restores session, coalesces refresh and resolves fresh playback tickets',
    () async {
      String? stored;
      var refreshes = 0, tickets = 0;
      final calls = <http.Request>[];
      Future<http.Response> respond(http.Request request) async {
        calls.add(request);
        if (request.url.path == '/v1/auth/login') {
          return http.Response(
            jsonEncode({
              'access_token': 'access',
              'refresh_token': 'refresh',
              'user_id': 'alice',
            }),
            200,
          );
        }
        if (request.url.path == '/v1/auth/refresh') {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response(
            jsonEncode({
              'access_token': 'renewed',
              'refresh_token': 'rotated',
              'user_id': 'alice',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/playback-ticket')) {
          tickets++;
          return http.Response(
            jsonEncode({
              'path': '/v1/media/${tickets.toString().padLeft(64, '0')}',
            }),
            200,
          );
        }
        return http.Response('{"items":[]}', 200);
      }

      final first = MusicServerClient(
        client: MockClient(respond),
        readSession: () async => stored,
        writeSession: (s) async => stored = s,
      );
      await first.login(
        'https://music.example.org',
        'alice',
        'not-persisted-password',
      );
      expect(stored, isNot(contains('not-persisted-password')));
      expect(stored, isNot(contains('access_token')));
      final source = first.source('a' * 64);
      final restored = MusicServerClient(
        client: MockClient(respond),
        readSession: () async => stored,
        writeSession: (s) async => stored = s,
      );
      final callsBeforeAvailability = calls.length;
      expect(await restored.canResolveSource(source), isTrue);
      expect(
        await restored.canResolveSource(
          'musicserver://another-account/${'a' * 64}',
        ),
        isFalse,
      );
      expect(
        await restored.canResolveSource('https://example.org/song'),
        isFalse,
      );
      expect(calls, hasLength(callsBeforeAvailability));
      final resolved = await Future.wait([
        restored.resolve(source),
        restored.resolve(source),
      ]);
      expect(refreshes, 1);
      expect(resolved[0], isNot(resolved[1]));
      expect(stored, contains('rotated'));
      expect(stored, isNot(contains('/v1/media/')));
      expect(
        calls
            .where((r) => r.url.path.endsWith('/playback-ticket'))
            .every((r) => r.headers['Authorization'] == 'Bearer renewed'),
        isTrue,
      );
      final media = PlayableMedia(
        id: source,
        source: source,
        title: 'Track',
        artist: 'Artist',
      );
      expect(media.isNetwork, isTrue);
      expect(media.toJson()['source'], source);
      expect(jsonEncode(media.toJson()), isNot(contains('/v1/media/')));
    },
  );

  test(
    'refuses a ticket redirect to another origin and an old account source',
    () async {
      final client = MusicServerClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/login')) {
            final body = jsonDecode(r.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'access_token': 'a',
                'refresh_token': 'r',
                'user_id': body['username'],
              }),
              200,
            );
          }
          return http.Response('{"path":"https://other.example/audio"}', 200);
        }),
        readSession: () async => null,
        writeSession: (_) async {},
      );
      await client.login('https://music.example.org', 'alice', 'password');
      final source = client.source('a' * 64);
      await expectLater(
        client.resolve(source),
        throwsA(isA<MusicServerException>()),
      );
      await client.login('https://music.example.org', 'bob', 'password');
      await expectLater(
        client.resolve(source),
        throwsA(isA<MusicServerException>()),
      );
    },
  );

  test('logout erases local session even when server is unreachable', () async {
    String? stored;
    final client = MusicServerClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/login')) {
          return http.Response(
            '{"access_token":"a","refresh_token":"r","user_id":"alice"}',
            200,
          );
        }
        throw http.ClientException('offline');
      }),
      readSession: () async => stored,
      writeSession: (s) async => stored = s,
    );
    await client.login('https://music.example.org', 'alice', 'password');
    await expectLater(client.logout(), throwsA(isA<http.ClientException>()));
    expect(stored, isNull);
    expect(client.connected, isFalse);
  });
}
