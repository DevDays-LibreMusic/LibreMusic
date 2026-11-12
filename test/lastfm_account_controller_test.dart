import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lastfm_account_controller.dart';
import 'package:mornye/services/lastfm_account_service.dart';

class MemoryAccountStorage implements LastfmAccountStorage {
  String? session;
  String? data;
  bool failDataWrites = false;
  @override
  Future<String?> readSession() async => session;
  @override
  Future<String?> readData() async => data;
  @override
  Future<void> writeSession(String? value) async {
    session = value;
  }

  @override
  Future<void> writeData(String value) async {
    if (failDataWrites) throw StateError('disk');
    data = value;
  }
}

const credentials = LastfmAppCredentials(
  apiKey: 'application-key',
  sharedSecret: 'application-secret',
);
const track = LastfmListeningTrack(
  title: 'Duality',
  artist: 'Slipknot',
  duration: Duration(seconds: 240),
);
final started = DateTime.utc(2026, 11, 11, 5);

MemoryAccountStorage connectedStorage([String user = 'listener']) =>
    MemoryAccountStorage()
      ..session = jsonEncode({
        'apiKey': credentials.apiKey,
        'username': user,
        'sessionKey': 'session-$user',
      });

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  LastfmAccountController make(
    MemoryAccountStorage store,
    Future<http.Response> Function(http.Request) respond, {
    DateTime Function()? now,
  }) {
    final controller = LastfmAccountController(
      service: LastfmAccountService(
        minimumInterval: Duration.zero,
        credentials: credentials,
        client: MockClient(respond),
      ),
      storage: store,
      now: now ?? () => started.add(const Duration(minutes: 5)),
      retryInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  http.Response success() => http.Response(
    '{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"}}}',
    200,
  );
  Future<void> listen(
    LastfmAccountController controller, {
    String id = 'play-1',
    int seconds = 120,
  }) => controller.recordListening(
    playId: id,
    track: track,
    startedAt: started,
    listened: Duration(seconds: seconds),
  );

  test(
    'qualification and stable occurrence ID prevent repeated scrobbles',
    () async {
      var requests = 0;
      final storage = connectedStorage();
      final controller = make(storage, (_) async {
        requests++;
        return success();
      });
      await controller.ready;
      await listen(controller, seconds: 119);
      await settle();
      expect(requests, 0);
      await listen(controller);
      await settle();
      await listen(controller, seconds: 150);
      await settle();
      expect(requests, 1);
      expect(controller.state.pendingCount, 0);
      expect(storage.data, contains('scrobble:play-1'));
      expect(storage.data, isNot(contains('session-listener')));
    },
  );

  test(
    'offline outbox survives restart and retries original timestamp once',
    () async {
      final storage = connectedStorage();
      var now = started.add(const Duration(minutes: 5));
      final first = make(storage, (_) async {
        throw http.ClientException('offline');
      }, now: () => now);
      await first.ready;
      await listen(first);
      await settle();
      expect(first.state.pendingCount, 1);
      first.dispose();
      now = now.add(const Duration(minutes: 2));
      var sent = 0;
      final second = make(storage, (request) async {
        sent++;
        expect(
          request.bodyFields['timestamp'],
          '${started.millisecondsSinceEpoch ~/ 1000}',
        );
        return success();
      }, now: () => now);
      await second.ready;
      await settle();
      await listen(second);
      await settle();
      expect(sent, 1);
      expect(second.state.pendingCount, 0);
    },
  );

  test(
    'session expiry retains history until same account reconnects',
    () async {
      final storage = connectedStorage();
      var expired = true;
      var scrobbles = 0;
      final controller = make(storage, (request) async {
        final method = request.method == 'GET'
            ? request.url.queryParameters['method']
            : request.bodyFields['method'];
        switch (method) {
          case 'auth.getToken':
            return http.Response('{"token":"token"}', 200);
          case 'auth.getSession':
            return http.Response(
              '{"session":{"name":"listener","key":"renewed"}}',
              200,
            );
          default:
            scrobbles++;
            return expired ? http.Response('{"error":9}', 403) : success();
        }
      });
      await controller.ready;
      await listen(controller);
      await settle();
      expect(controller.state.needsReauthentication, isTrue);
      expect(controller.state.pendingCount, 1);
      await controller.flush();
      expect(scrobbles, 1);
      await controller.beginAuthorization();
      expired = false;
      expect(await controller.completeAuthorization(), isTrue);
      await settle();
      expect(controller.state.connected, isTrue);
      expect(controller.state.pendingCount, 0);
      expect(scrobbles, 2);
    },
  );

  test('another account never receives queued listening events', () async {
    final storage = connectedStorage();
    var scrobbles = 0;
    final controller = make(storage, (request) async {
      final method = request.method == 'GET'
          ? request.url.queryParameters['method']
          : request.bodyFields['method'];
      if (method == 'auth.getToken') {
        return http.Response('{"token":"token"}', 200);
      }
      if (method == 'auth.getSession') {
        return http.Response(
          '{"session":{"name":"other","key":"other-session"}}',
          200,
        );
      }
      scrobbles++;
      throw http.ClientException('offline');
    });
    await controller.ready;
    await listen(controller);
    await settle();
    expect(controller.state.pendingCount, 1);
    await controller.beginAuthorization();
    await controller.completeAuthorization();
    await settle();
    expect(controller.state.username, 'other');
    expect(controller.state.pendingCount, 0);
    expect(scrobbles, 1);
  });

  test('disabled history is not queued and pending history is held', () async {
    final storage = connectedStorage();
    var now = started.add(const Duration(minutes: 5));
    var offline = true;
    var requests = 0;
    final controller = make(storage, (_) async {
      requests++;
      if (offline) throw http.ClientException('offline');
      return success();
    }, now: () => now);
    await controller.ready;
    await listen(controller);
    await settle();
    await controller.setScrobblingEnabled(false);
    await listen(controller, id: 'disabled-play');
    offline = false;
    now = now.add(const Duration(minutes: 2));
    await controller.flush();
    expect(requests, 1);
    expect(controller.state.pendingCount, 1);
    await controller.setScrobblingEnabled(true);
    await settle();
    expect(requests, 2);
    expect(controller.state.pendingCount, 0);
  });

  test('offline like then unlike sends only latest preference', () async {
    var now = started.add(const Duration(minutes: 5));
    var offline = true;
    final methods = <String>[];
    final controller = make(connectedStorage(), (request) async {
      if (offline) throw http.ClientException('offline');
      methods.add(request.bodyFields['method']!);
      return http.Response('{}', 200);
    }, now: () => now);
    await controller.ready;
    await controller.setLoved(track, true);
    await settle();
    await controller.setLoved(track, false);
    await settle();
    expect(controller.state.pendingCount, 1);
    offline = false;
    now = now.add(const Duration(minutes: 2));
    await controller.flush();
    expect(methods, ['track.unlove']);
  });

  test('failed now-playing is never saved for later', () async {
    final controller = make(connectedStorage(), (_) async {
      throw http.ClientException('offline');
    });
    await controller.ready;
    await controller.nowPlaying(track);
    expect(controller.state.pendingCount, 0);
  });

  test(
    'disconnect removes secure credentials and all pending external writes',
    () async {
      final storage = connectedStorage();
      final controller = make(storage, (_) async {
        throw http.ClientException('offline');
      });
      await controller.ready;
      await listen(controller);
      await settle();
      await controller.disconnect();
      expect(storage.session, isNull);
      expect(controller.state.username, isNull);
      expect(controller.state.pendingCount, 0);
      expect(
        (jsonDecode(storage.data!) as Map<String, dynamic>)['pending'],
        isEmpty,
      );
    },
  );

  test('failed durable enqueue does not send an unrecorded event', () async {
    final storage = connectedStorage()..failDataWrites = true;
    var sent = 0;
    final controller = make(storage, (_) async {
      sent++;
      return success();
    });
    await controller.ready;
    await listen(controller);
    await settle();
    expect(sent, 0);
    expect(controller.state.pendingCount, 0);
    expect(controller.state.error?.kind, LastfmAccountErrorKind.storage);
  });

  test('concurrent flush callers do not send same entry twice', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final controller = make(connectedStorage(), (_) {
      requests++;
      return response.future;
    });
    await controller.ready;
    await listen(controller);
    await settle();
    final other = controller.flush();
    response.complete(success());
    await other;
    await settle();
    expect(requests, 1);
    expect(controller.state.pendingCount, 0);
  });
  test('now playing preference persists independently of scrobbling', () async {
    final store = connectedStorage();
    final methods = <String>[];
    final controller = make(store, (request) async {
      methods.add(request.bodyFields['method']!);
      return success();
    });
    await controller.ready;
    await controller.setNowPlayingEnabled(false);
    await controller.nowPlaying(track);
    await listen(controller);
    await settle();
    await controller.flush();
    expect(methods, ['track.scrobble']);
    expect(controller.state.scrobblingEnabled, isTrue);
    final restored = make(store, (_) async => success());
    await restored.ready;
    expect(restored.state.nowPlayingEnabled, isFalse);
  });

  test('cancelled authorization cannot publish a delayed session', () async {
    final gate = Completer<http.Response>();
    final store = MemoryAccountStorage();
    final controller = make(store, (request) async {
      if (request.bodyFields['method'] == 'auth.getToken') {
        return http.Response('{"token":"approval-token"}', 200);
      }
      return gate.future;
    });
    await controller.ready;
    await controller.beginAuthorization();
    final finish = controller.completeAuthorization();
    await settle();
    final cancel = controller.cancelAuthorization();
    gate.complete(
      http.Response('{"session":{"name":"listener","key":"secret"}}', 200),
    );
    expect(await finish, isFalse);
    await cancel;
    expect(controller.state.connected, isFalse);
    expect(store.session, isNull);
  });
  test(
    'temporary authorization failure retries the existing browser token',
    () async {
      var tokenRequests = 0;
      var exchangeRequests = 0;
      final controller = make(MemoryAccountStorage(), (request) async {
        if (request.bodyFields['method'] == 'auth.getToken') {
          tokenRequests++;
          return http.Response('{"token":"approval-token"}', 200);
        }
        exchangeRequests++;
        if (exchangeRequests == 1) throw http.ClientException('offline');
        expect(request.bodyFields['token'], 'approval-token');
        return http.Response(
          '{"session":{"name":"listener","key":"secret"}}',
          200,
        );
      });
      await controller.ready;
      await controller.beginAuthorization();
      expect(await controller.completeAuthorization(), isFalse);
      expect(controller.state.authorizationPending, isTrue);
      expect(await controller.completeAuthorization(), isTrue);
      expect(tokenRequests, 1);
    },
  );

  test('expired queued history is never sent after restart', () async {
    final store = connectedStorage();
    final first = make(
      store,
      (_) async => throw http.ClientException('offline'),
    );
    await first.ready;
    await listen(first);
    await settle();
    expect(first.state.pendingCount, 1);
    first.dispose();
    var requests = 0;
    final restored = make(store, (_) async {
      requests++;
      return success();
    }, now: () => started.add(const Duration(days: 15)));
    await restored.ready;
    await restored.flush();
    expect(requests, 0);
  });
}
