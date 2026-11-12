import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/discovery_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/discovery_screen.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/download_service_picker.dart';

class _DownloadSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(askQualityBeforeDownload: true);
}

class _EmptyExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

const _catalog = DiscoveryCatalog(
  genres: [
    DiscoveryGenre(id: '0', name: 'All'),
    DiscoveryGenre(id: '14', name: 'Pop'),
  ],
  region: 'mixed',
  sourceName: 'Unified discovery',
);

const _track = Track(
  id: '123',
  name: 'New song',
  artistName: 'Artist',
  albumName: 'Record',
  duration: 200,
  source: 'apple-music',
  releaseDate: '2026-11-10T08:00:00Z',
);

DiscoveryFeed _feed({
  String name = 'New song',
  bool stale = false,
  List<DiscoverySourceStatus> sources = const [],
  List<DiscoveryOrigin> origins = const [],
  int? position,
}) => DiscoveryFeed(
  entries: [
    DiscoveryEntry(
      track: _track.copyWith(name: name),
      origins: origins,
      position: position,
    ),
  ],
  sources: sources,
  fetchedAt: DateTime(2026, 11, 12),
  region: 'mixed',
  sourceName: 'Unified discovery',
  isStale: stale,
);

void main() {
  setUp(() => debugDesktopPlatformOverride = false);
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> showScreen(
    WidgetTester tester, {
    Future<DiscoveryFeed> Function(DiscoveryQuery)? load,
    double width = 390,
    double textScale = 1,
    Future<List<Track>> Function(String)? albumTracks,
  }) async {
    tester.view.physicalSize = Size(width, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoveryCatalogProvider.overrideWith((ref) async => _catalog),
          settingsProvider.overrideWith(_DownloadSettings.new),
          extensionProvider.overrideWith(_EmptyExtensions.new),
          discoveryFeedProvider.overrideWith(
            (ref, query) => load?.call(query) ?? Future.value(_feed()),
          ),
          if (albumTracks != null)
            discoveryAlbumTracksProvider.overrideWith(
              (ref, key) => albumTracks(key),
            ),
          // Browsing and opening metadata must never even initialize the queue.
          downloadQueueProvider.overrideWith(
            () => throw StateError('Unexpected download queue access'),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const DiscoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Trends Listen fits narrow screens and remains explicit', (
    tester,
  ) async {
    await showScreen(
      tester,
      width: 320,
      textScale: 1.5,
      load: (_) async => _feed(position: 1),
    );
    expect(find.byTooltip('Listen'), findsNothing);
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Listen'), findsOneWidget);
    expect(find.byTooltip('Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('New song'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Listen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new releases mix tracks and albums in the supplied order', (
    tester,
  ) async {
    await showScreen(
      tester,
      load: (_) async => DiscoveryFeed(
        entries: [
          DiscoveryEntry(track: _track),
          DiscoveryEntry(
            track: _track.copyWith(
              id: 'album',
              name: 'New album',
              itemType: 'album',
            ),
          ),
          DiscoveryEntry(
            track: _track.copyWith(id: 'single', name: 'Fresh single'),
          ),
        ],
        fetchedAt: DateTime(2026, 11, 12),
        region: 'mixed',
        sourceName: 'Unified discovery',
      ),
    );
    expect(
      tester.getTopLeft(find.text('New song')).dy,
      lessThan(tester.getTopLeft(find.text('New album')).dy),
    );
    expect(
      tester.getTopLeft(find.text('New album')).dy,
      lessThan(tester.getTopLeft(find.text('Fresh single')).dy),
    );
    expect(find.text('Artist\nSong · Nov 10, 2026'), findsNWidgets(2));
    expect(find.text('Artist\nAlbum · Nov 10, 2026'), findsOneWidget);
    expect(find.byTooltip('Listen'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'release type filters compose with genre and do not filter Trends',
    (tester) async {
      final queries = <DiscoveryQuery>[];
      await showScreen(
        tester,
        load: (query) async {
          queries.add(query);
          if (query.kind == DiscoveryKind.trends) {
            return _feed(name: 'Chart song');
          }
          return DiscoveryFeed(
            entries: [
              DiscoveryEntry(
                track: _track.copyWith(
                  name: query.genreId == '14' ? 'Pop song' : 'New song',
                ),
              ),
              DiscoveryEntry(
                track: _track.copyWith(
                  id: 'album',
                  name: query.genreId == '14' ? 'Pop album' : 'New album',
                  itemType: 'album',
                ),
              ),
            ],
            fetchedAt: DateTime(2026, 11, 12),
            region: 'mixed',
            sourceName: 'Unified discovery',
          );
        },
      );
      await tester.tap(find.byKey(const ValueKey('release-type-tracks')));
      await tester.pumpAndSettle();
      expect(find.text('New song'), findsOneWidget);
      expect(find.text('New album'), findsNothing);
      expect(queries, hasLength(1)); // Type filtering never refetches metadata.

      await tester.tap(find.text('Pop'));
      await tester.pumpAndSettle();
      expect(find.text('Pop song'), findsOneWidget);
      expect(find.text('Pop album'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('release-type-albums')));
      await tester.pumpAndSettle();
      expect(find.text('Pop song'), findsNothing);
      expect(find.text('Pop album'), findsOneWidget);

      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      expect(find.text('Chart song'), findsOneWidget);
      expect(find.byKey(const ValueKey('release-type-albums')), findsNothing);
      await tester.tap(find.text('New releases'));
      await tester.pumpAndSettle();
      expect(find.text('Pop album'), findsOneWidget);
      expect(find.text('Pop song'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('release-type-albums')),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('release-type-all')));
      await tester.pumpAndSettle();
      expect(find.text('Pop song'), findsOneWidget);
      expect(find.text('Pop album'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening a track shows metadata and an explicit download action',
    (tester) async {
      await showScreen(tester);
      await tester.tap(find.text('New song'));
      await tester.pumpAndSettle();
      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Released: Nov 10, 2026'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit download opens the existing service and quality picker',
    (tester) async {
      await showScreen(tester);
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadServicePicker), findsOneWidget);
      final picker = tester.widget<DownloadServicePicker>(
        find.byType(DownloadServicePicker),
      );
      expect(picker.trackName, 'New song');
      expect(picker.artistName, 'Artist');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late result from a previous genre cannot replace current selection',
    (tester) async {
      final late = Completer<DiscoveryFeed>();
      await showScreen(
        tester,
        load: (query) async {
          if (query.genreId == '14') return late.future;
          return _feed(
            name: query.kind == DiscoveryKind.trends
                ? 'Chart song'
                : 'New song',
          );
        },
      );
      await tester.tap(find.text('Pop'));
      await tester.pump();
      await tester.tap(find.text('All genres'));
      await tester.pumpAndSettle();
      late.complete(_feed(name: 'Late pop song'));
      await tester.pumpAndSettle();
      expect(find.text('New song'), findsOneWidget);
      expect(find.text('Late pop song'), findsNothing);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      expect(find.text('Chart song'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cached offline response is visibly marked and can retry', (
    tester,
  ) async {
    await showScreen(tester, load: (_) async => _feed(stale: true));
    expect(
      find.text('Could not refresh. Showing the last saved selection.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('New song'), findsOneWidget);
  });

  testWidgets(
    'source failure leaves the unified feed available with attribution',
    (tester) async {
      await showScreen(
        tester,
        load: (_) async => _feed(
          sources: const [
            DiscoverySourceStatus(
              sourceId: 'apple-music',
              sourceName: 'Apple Music',
              region: 'us',
            ),
            DiscoverySourceStatus(
              sourceId: 'deezer',
              sourceName: 'Deezer',
              region: 'global',
              isStale: true,
            ),
            DiscoverySourceStatus(
              sourceId: 'yandex-music',
              sourceName: 'Yandex Music',
              region: 'ru',
              isUnavailable: true,
            ),
          ],
        ),
      );
      expect(find.text('New song'), findsOneWidget);
      expect(
        find.text(
          'Some sources could not refresh. Available selections are still shown.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Could not refresh. Showing the last saved selection.'),
        findsNothing,
      );
      await tester.tap(find.text('Sources and ranking'));
      await tester.pumpAndSettle();
      expect(find.text('Apple Music · US · Updated'), findsOneWidget);
      expect(find.text('Deezer · Global · Saved selection'), findsOneWidget);
      expect(
        find.text('Yandex Music · RU · Temporarily unavailable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('merged track details retain original source chart positions', (
    tester,
  ) async {
    await showScreen(
      tester,
      load: (_) async => _feed(
        position: 1,
        origins: const [
          DiscoveryOrigin(
            sourceId: 'apple-music',
            sourceName: 'Apple Music',
            region: 'us',
            nativeId: '123',
            position: 12,
          ),
          DiscoveryOrigin(
            sourceId: 'deezer',
            sourceName: 'Deezer',
            region: 'global',
            nativeId: '456',
            position: 3,
          ),
        ],
      ),
    );
    expect(find.text('New song'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.text('New song'));
    await tester.pumpAndSettle();
    expect(
      find.text('Apple Music · US\nOriginal chart position: 12'),
      findsOneWidget,
    );
    expect(
      find.text('Deezer · Global\nOriginal chart position: 3'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('album navigation keeps its provider namespace', (tester) async {
    final requested = <String>[];
    await showScreen(
      tester,
      load: (_) async => DiscoveryFeed(
        entries: [
          DiscoveryEntry(
            track: _track.copyWith(
              id: '456',
              albumId: '789',
              name: 'New album',
              source: 'deezer',
              itemType: 'album',
            ),
          ),
        ],
        fetchedAt: DateTime(2026, 11, 12),
        region: 'mixed',
        sourceName: 'Unified discovery',
      ),
      albumTracks: (key) async {
        requested.add(key);
        return [_track.copyWith(name: 'Album song', source: 'deezer')];
      },
    );
    await tester.tap(find.text('New album'));
    await tester.pumpAndSettle();
    expect(requested, ['deezer:789']);
    expect(find.text('Album song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page supports narrow screens and enlarged text', (tester) async {
    await showScreen(tester, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
  });
}
