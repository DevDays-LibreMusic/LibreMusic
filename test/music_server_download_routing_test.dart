import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/providers/discovery_provider.dart';
import 'package:mornye/screens/discovery_screen.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/music_server_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/music_server_screen.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/track_listen_button.dart';
import 'package:mornye/widgets/download_service_picker.dart';

import 'support/fixed_settings.dart';

const _track = Track(
  id: 'provider-track-42',
  name: 'Example track',
  artistName: 'Example artist',
  albumName: 'Example album',
  source: 'extension:example.audio',
  duration: 180,
);

final _savedSession = jsonEncode({
  'version': 1,
  'address': 'https://music.example.org',
  'user_id': 'listener',
  'refresh_token': 'saved-refresh',
});

class _LocalQueue extends DownloadQueueNotifier {
  int _builds = 0;
  final requests = <Track>[];
  final qualities = <String?>[];

  @override
  DownloadQueueState build() {
    _builds++;
    return const DownloadQueueState();
  }

  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
  }) {
    requests.add(track);
    qualities.add(qualityOverride);
    return 'local-job';
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example.audio',
        name: 'example.audio',
        displayName: 'Example audio',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [
          QualityOption(id: 'local-lossless', label: 'Local lossless'),
        ],
      ),
    ],
  );

  @override
  void refreshEnabledExtensionHealth({bool force = false}) {}
}

class _Server {
  _Server({
    this.provider = 'example.audio',
    this.prepareStatus = 202,
    this.ready = false,
    this.readyOnPrepare = false,
    this.pollState = 'queued',
  });
  final String provider;
  final int prepareStatus;
  final bool ready;
  final bool readyOnPrepare;
  String pollState;
  final requests = <http.Request>[];
  Map<String, dynamic> get asset => {
    'id': 'a' * 64,
    'state': 'ready',
    'title': _track.name,
    'artist': _track.artistName,
    'mime': 'audio/mpeg',
  };

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final body = switch (request.url.path) {
      '/v1/auth/refresh' || '/v1/auth/login' => {
        'access_token': 'fresh-access',
        'refresh_token': 'rotated-refresh',
        'user_id': 'listener',
      },
      '/v1/sources' => {
        'sources': [
          {
            'id': 'server-source',
            'name':
                'Server source with a very long descriptive name for mobile screens',
            'type': 'extension',
            'provider_id': provider,
            'qualities': ['LOSSLESS'],
          },
        ],
      },
      '/v1/playback/prepare' =>
        readyOnPrepare ? asset : {'id': 'a' * 64, 'state': 'queued'},
      '/v1/downloads' => {'items': <Map<String, dynamic>>[]},
      '/v1/tracks' => {
        'items': ready ? [asset] : <Map<String, dynamic>>[],
        'next_offset': null,
      },
      final path when path.startsWith('/v1/downloads/') =>
        ready || pollState == 'ready'
            ? asset
            : {'id': 'a' * 64, 'state': pollState},
      _ => {'items': <Map<String, dynamic>>[], 'next_offset': null},
    };
    return http.Response(
      jsonEncode(body),
      request.url.path == '/v1/playback/prepare' ? prepareStatus : 200,
    );
  }

  Iterable<http.Request> get preparations =>
      requests.where((request) => request.url.path == '/v1/playback/prepare');
}

class _Library extends LocalLibraryNotifier {
  final items = <String, LocalLibraryItem>{};
  bool _failSave = false;

  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<LocalLibraryItem?> getById(String id) async => items[id];

  @override
  Future<void> addMusicServerTrack(
    LocalLibraryItem item, {
    required String displayName,
  }) async {
    if (_failSave) throw StateError('Library unavailable');
    items[item.id] = item;
    state = state.copyWith(loadedIndexVersion: state.loadedIndexVersion + 1);
  }
}

class _Player extends Fake implements MusicPlayerController {
  final played = <PlayableMedia>[];

  @override
  Future<void> playSingle(PlayableMedia media) async => played.add(media);
}

class _ObservedClient extends MusicServerClient {
  _ObservedClient({super.client, super.readSession, super.writeSession});
  final errors = <Object>[];

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      return await super.request(method, path, body);
    } catch (error) {
      errors.add(error);
      rethrow;
    }
  }
}

Future<GoRouter> _showActions(
  WidgetTester tester,
  MusicServerClient client,
  _LocalQueue queue, {
  String action = 'Listen',
  bool askQuality = false,
  _Library? library,
  _Player? player,
  Track? discoveryTrack,
  List<DiscoveryOrigin> origins = const [],
}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => discoveryTrack != null
            ? const DiscoveryScreen()
            : Scaffold(
                body: Consumer(
                  builder: (context, ref, child) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const TrackListenButton(track: _track),
                      FilledButton(
                        onPressed: () =>
                            addTrackToServerLibrary(context, _track),
                        child: const Text('Save streaming track'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            downloadSingleTrack(context, ref, _track),
                        child: const Text('Download track'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      GoRoute(
        path: '/music-server',
        builder: (context, state) => MusicServerScreen(
          initialTrack: state.extra as Track?,
          autoPrepare: state.uri.queryParameters['prepare'] == '1',
          addToLibrary: state.uri.queryParameters['library'] == '1',
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (discoveryTrack != null) ...[
          discoveryCatalogProvider.overrideWith(
            (ref) async => const DiscoveryCatalog(
              genres: [DiscoveryGenre(id: '0', name: 'All')],
              region: 'mixed',
              sourceName: 'Unified discovery',
            ),
          ),
          discoveryFeedProvider.overrideWith(
            (ref, query) async => DiscoveryFeed(
              entries: [
                DiscoveryEntry(track: discoveryTrack, origins: origins),
              ],
              fetchedAt: DateTime.now(),
              region: 'mixed',
              sourceName: 'Unified discovery',
            ),
          ),
        ],
        musicServerClientProvider.overrideWithValue(client),
        localLibraryProvider.overrideWith(() => library ?? _Library()),
        musicPlayerControllerProvider.overrideWithValue(player ?? _Player()),
        downloadQueueProvider.overrideWith(() => queue),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(
              defaultService: 'example.audio',
              askQualityBeforeDownload: askQuality,
            ),
          ),
        ),
        extensionProvider.overrideWith(_Extensions.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (discoveryTrack != null) {
    expect(find.text('Listen'), findsNothing);
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listen'));
    return router;
  }
  await tester.tap(switch (action) {
    'Listen' => find.byTooltip('Listen'),
    'Save' => find.text('Save streaming track'),
    _ => find.text('Download track'),
  });
  return router;
}

Future<void> _pumpServer(WidgetTester tester) async {
  // The server's pending job deliberately keeps a progress animation alive.
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    // Let HTTP response streams finish outside the simulated frame clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

void main() {
  testWidgets('server source selector fits narrow mobile viewport', (
    tester,
  ) async {
    final server = _Server();
    final client = MusicServerClient(
      client: MockClient(server.respond),
      readSession: () async => _savedSession,
      writeSession: (_) async {},
    );
    await _showActions(tester, client, _LocalQueue(), action: 'Listen');
    await _pumpServer(tester);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final ready in [false, true]) {
    testWidgets(
      'Trends Listen uses a matching origin and streams only ready audio: reuse $ready',
      (tester) async {
        final server = _Server(readyOnPrepare: ready);
        final queue = _LocalQueue();
        final player = _Player();
        final client = MusicServerClient(
          client: MockClient(server.respond),
          readSession: () async => _savedSession,
          writeSession: (_) async {},
        );
        await _showActions(
          tester,
          client,
          queue,
          discoveryTrack: _track.copyWith(
            id: 'apple-id',
            source: 'apple-music',
          ),
          origins: const [
            DiscoveryOrigin(
              sourceId: 'example.audio',
              sourceName: 'Example',
              region: 'global',
              nativeId: 'provider-track-42',
              nativeTrack: _track,
            ),
          ],
          player: player,
        );
        await _pumpServer(tester);
        expect(server.preparations, hasLength(1));
        final prepared = jsonDecode(server.preparations.single.body) as Map;
        expect(prepared['source'], {
          'connection_id': 'server-source',
          'track_id': _track.id,
        });
        if (!ready) {
          expect(player.played, isEmpty);
          server.pollState = 'ready';
          await _pumpServer(tester);
          await _pumpServer(tester);
        }
        expect(player.played.single.source, client.source('a' * 64));
        expect(server.preparations, hasLength(1));
        expect(queue._builds, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Trends Listen cannot send a catalog ID to an unrelated server provider',
    (tester) async {
      final server = _Server();
      final queue = _LocalQueue();
      final player = _Player();
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async => _savedSession,
        writeSession: (_) async {},
      );
      await _showActions(
        tester,
        client,
        queue,
        discoveryTrack: _track.copyWith(source: 'itunes', id: '123'),
        player: player,
      );
      await _pumpServer(tester);
      expect(server.preparations, isEmpty);
      expect(player.played, isEmpty);
      expect(queue._builds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Leaving Trends preparation stops polling and never starts playback',
    (tester) async {
      final server = _Server();
      final queue = _LocalQueue();
      final player = _Player();
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async => _savedSession,
        writeSession: (_) async {},
      );
      await _showActions(
        tester,
        client,
        queue,
        discoveryTrack: _track,
        player: player,
      );
      await _pumpServer(tester);
      expect(server.preparations, hasLength(1));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      final count = server.requests.length;
      server.pollState = 'ready';
      await tester.pump(const Duration(seconds: 10));
      expect(server.requests.length, count);
      expect(player.played, isEmpty);
      expect(queue._builds, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Failed Trends preparation is retryable and never falls back to local',
    (tester) async {
      final server = _Server(pollState: 'failed');
      final queue = _LocalQueue();
      final player = _Player();
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async => _savedSession,
        writeSession: (_) async {},
      );
      await _showActions(
        tester,
        client,
        queue,
        discoveryTrack: _track,
        player: player,
      );
      await _pumpServer(tester);
      await _pumpServer(tester);
      expect(player.played, isEmpty);
      expect(queue._builds, 0);
      final play = find.widgetWithText(FilledButton, 'Play');
      await tester.ensureVisible(play);
      await tester.tap(play);
      await _pumpServer(tester);
      expect(server.preparations, hasLength(2));
      expect(player.played, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final signIn in [false, true]) {
    testWidgets(
      'Add to library prepares a server reference, sign-in: $signIn',
      (tester) async {
        final server = _Server(ready: true);
        final queue = _LocalQueue();
        final library = _Library();
        final player = _Player();
        final client = MusicServerClient(
          client: MockClient(server.respond),
          readSession: () async => signIn ? null : _savedSession,
          writeSession: (_) async {},
        );
        await _showActions(
          tester,
          client,
          queue,
          action: 'Save',
          library: library,
          player: player,
        );
        await _pumpServer(tester);
        if (signIn) {
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(0), 'https://music.example.org');
          await tester.enterText(fields.at(1), 'listener');
          await tester.enterText(fields.at(2), 'fixture-password');
          await tester.tap(find.text('Connect to server'));
        }
        await _pumpServer(tester);
        await _pumpServer(tester);
        expect(server.preparations, hasLength(1));
        final saved = library.items.values.single;
        expect(saved.filePath, client.source('a' * 64));
        expect(saved.trackName, _track.name);
        expect(saved.albumName, _track.albumName);
        expect(saved.duration, _track.duration);
        expect(queue._builds, 0);
        expect(player.played, isEmpty);
        expect(
          find.byTooltip('In library', skipOffstage: false),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('ready server track can be added from the server list', (
    tester,
  ) async {
    final server = _Server(ready: true);
    final library = _Library();
    final queue = _LocalQueue();
    final client = MusicServerClient(
      client: MockClient(server.respond),
      readSession: () async => _savedSession,
      writeSession: (_) async {},
    );
    await _showActions(tester, client, queue, library: library);
    await _pumpServer(tester);
    await _pumpServer(tester);
    final add = find.byTooltip('Add to library (streaming)');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await _pumpServer(tester);
    expect(library.items.values.single.filePath, client.source('a' * 64));
    expect(find.byTooltip('In library'), findsOneWidget);
    expect(queue._builds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('library write failure leaves the track available to retry', (
    tester,
  ) async {
    final server = _Server(ready: true);
    final library = _Library().._failSave = true;
    final queue = _LocalQueue();
    final client = MusicServerClient(
      client: MockClient(server.respond),
      readSession: () async => _savedSession,
      writeSession: (_) async {},
    );
    await _showActions(tester, client, queue, action: 'Save', library: library);
    await _pumpServer(tester);
    await _pumpServer(tester);
    expect(library.items, isEmpty);
    expect(
      find.text('Could not add the track to the library. Try again.'),
      findsOneWidget,
    );
    expect(queue._builds, 0);
    library._failSave = false;
    final add = find.byTooltip('Add to library (streaming)');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await _pumpServer(tester);
    expect(library.items, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Listen restores the server connection and prepares the track', (
    tester,
  ) async {
    final restored = Completer<String?>();
    final server = _Server();
    final queue = _LocalQueue();
    final client = _ObservedClient(
      client: MockClient(server.respond),
      readSession: () => restored.future,
      writeSession: (_) async {},
    );
    await _showActions(tester, client, queue);
    await _pumpServer(tester);
    expect(queue._builds, 0);
    expect(server.requests, isEmpty);

    restored.complete(_savedSession);
    await _pumpServer(tester);
    expect(find.byType(MusicServerScreen), findsOneWidget);
    expect(client.errors, isEmpty);
    expect(
      server.preparations,
      hasLength(1),
      reason: server.requests.map((request) => request.url).join(', '),
    );
    final request = server.preparations.single;
    expect(request.method, 'POST');
    expect(request.headers['Authorization'], 'Bearer fresh-access');
    expect(jsonDecode(request.body), {
      'source': {'connection_id': 'server-source', 'track_id': _track.id},
      'quality': 'LOSSLESS',
      'title': _track.name,
      'artist': _track.artistName,
    });
    expect(queue._builds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in ['server error', 'missing source', 'storage error']) {
    testWidgets('$scenario cannot fall back to local download', (tester) async {
      final server = _Server(
        provider: scenario == 'missing source'
            ? 'other.audio'
            : 'example.audio',
        prepareStatus: scenario == 'server error' ? 503 : 202,
      );
      final queue = _LocalQueue();
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async {
          if (scenario == 'storage error') throw StateError('storage locked');
          return _savedSession;
        },
        writeSession: (_) async {},
      );
      await _showActions(tester, client, queue);
      await _pumpServer(tester);
      expect(queue._builds, 0);
      expect(
        server.preparations,
        hasLength(scenario == 'server error' ? 1 : 0),
      );
      if (scenario == 'missing source') {
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pump();
        expect(
          find.textContaining(
            'provider is not configured',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final session in ['connected', 'not configured', 'storage locked']) {
    testWidgets('Download stays local when server is $session', (tester) async {
      final server = _Server();
      final queue = _LocalQueue();
      var reads = 0;
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async {
          reads++;
          if (session == 'storage locked') throw StateError('storage locked');
          return session == 'connected' ? _savedSession : null;
        },
        writeSession: (_) async {},
      );
      if (session == 'connected') {
        await client.restore();
        expect(client.connected, isTrue);
        reads = 0;
      }
      await _showActions(tester, client, queue, action: 'Download');
      await _pumpServer(tester);
      expect(queue.requests, [_track]);
      expect(reads, 0);
      expect(server.requests, isEmpty);
      expect(find.byType(MusicServerScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Listen keeps the requested track through server sign-in', (
    tester,
  ) async {
    final server = _Server();
    final queue = _LocalQueue();
    final client = MusicServerClient(
      client: MockClient(server.respond),
      readSession: () async => null,
      writeSession: (_) async {},
    );
    await _showActions(tester, client, queue);
    await _pumpServer(tester);
    expect(find.byType(MusicServerScreen), findsOneWidget);
    expect(queue._builds, 0);
    expect(server.requests, isEmpty);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://music.example.org');
    await tester.enterText(fields.at(1), 'listener');
    await tester.enterText(fields.at(2), 'fixture-password');
    await tester.tap(find.text('Connect to server'));
    await _pumpServer(tester);
    expect(server.preparations, hasLength(1));
    final prepared =
        jsonDecode(server.preparations.single.body) as Map<String, dynamic>;
    final source = prepared['source'] as Map<String, dynamic>;
    expect(source['track_id'], _track.id);
    expect(queue._builds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Download retains the local quality picker with a connected server',
    (tester) async {
      final server = _Server();
      final queue = _LocalQueue();
      final client = MusicServerClient(
        client: MockClient(server.respond),
        readSession: () async => _savedSession,
        writeSession: (_) async {},
      );
      await client.restore();
      await _showActions(
        tester,
        client,
        queue,
        action: 'Download',
        askQuality: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DownloadServicePicker), findsOneWidget);
      expect(queue.requests, isEmpty);
      await tester.tap(find.text('Local lossless'));
      await tester.pumpAndSettle();
      expect(queue.requests, [_track]);
      expect(queue.qualities, ['local-lossless']);
      expect(server.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
