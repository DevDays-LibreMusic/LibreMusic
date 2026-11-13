import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/widgets/lastfm_wave_card.dart';
import 'package:mornye/widgets/wave_controls.dart';
import 'package:mornye/services/shell_navigation_service.dart';

class _Wave extends WaveSessionController {
  _Wave(this.initial);
  final WaveSessionState initial;
  int _toggles = 0;
  @override
  WaveSessionState build() => initial;
  @override
  Future<void> toggle() async {
    _toggles++;
  }
}

class _EmptyMedia extends CurrentMediaItemNotifier {
  @override
  Stream<MediaItem?> build() => Stream.value(null);
}

Future<void> _pump(
  WidgetTester tester,
  _Wave wave, {
  bool connected = true,
  bool needsReauthentication = false,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        waveSessionProvider.overrideWith(() => wave),
        lastfmAccountStateProvider.overrideWith(
          (ref) => Stream.value(
            LastfmAccountState(
              appConfigured: true,
              connected: connected,
              needsReauthentication: needsReauthentication,
            ),
          ),
        ),
        currentMediaItemProvider.overrideWith(_EmptyMedia.new),
        playbackPlayingProvider.overrideWith((ref) => false),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 640),
              textScaler: TextScaler.linear(scale),
            ),
            child: const SingleChildScrollView(child: LastfmWaveCard()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('artist picker scrolls with keyboard on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await _pump(
      tester,
      _Wave(const WaveSessionState(loaded: true, seedArtists: ['Muse'])),
      scale: 2,
    );
    final context = tester.element(find.byType(LastfmWaveCard));
    showWaveArtistPicker(context);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Done'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.text('Done')).dy, lessThanOrEqualTo(308));
  });

  testWidgets('expired account offers sign-in without hiding playback', (
    tester,
  ) async {
    await _pump(
      tester,
      _Wave(const WaveSessionState(loaded: true, active: true)),
      needsReauthentication: true,
    );
    expect(
      find.text('Sign in to Last.fm again — music keeps playing'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets(
    'personal wave starts with one play action and has no batch controls',
    (tester) async {
      final wave = _Wave(
        const WaveSessionState(loaded: true, seedArtists: ['Slipknot']),
      );
      await _pump(tester, wave);
      expect(find.text('My wave'), findsOneWidget);
      expect(find.text('Refresh'), findsNothing);
      expect(find.text('More tracks'), findsNothing);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      expect(wave._toggles, 1);
    },
  );

  testWidgets(
    'first use offers account or artist choice without credential fields',
    (tester) async {
      await _pump(
        tester,
        _Wave(const WaveSessionState(loaded: true)),
        connected: false,
      );
      expect(find.text('Connect Last.fm'), findsOneWidget);
      expect(find.text('Choose artists'), findsOneWidget);
      expect(find.text('Last.fm API key'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets(
    'context remains visible and long titles fit increased text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const title = 'Очень длинное название альбома для проверки доступности';
      await _pump(
        tester,
        _Wave(
          const WaveSessionState(
            loaded: true,
            active: true,
            context: WaveContext(kind: WaveKind.album, title: title),
          ),
        ),
        scale: 1.6,
      );
      expect(find.text('Wave by album'), findsOneWidget);
      expect(find.byTooltip('Return to my wave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('empty connected profile offers artist selection', (
    tester,
  ) async {
    await _pump(
      tester,
      _Wave(const WaveSessionState(loaded: true, needsSeeds: true)),
    );
    expect(find.text('Choose artists'), findsOneWidget);
    expect(find.text('Connect Last.fm'), findsNothing);
  });

  testWidgets(
    'unavailable selected track offers explicit similar music action',
    (tester) async {
      await _pump(
        tester,
        _Wave(
          const WaveSessionState(
            loaded: true,
            seedUnavailable: true,
            error: 'Selected song is unavailable',
          ),
        ),
      );
      expect(find.text('Play similar music'), findsOneWidget);
      expect(find.text('Selected song is unavailable'), findsOneWidget);
      final owner = Object();
      ShellTab? selected;
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => selected = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await tester.ensureVisible(find.text('Open Library'));
      await tester.tap(find.text('Open Library'));
      expect(selected, ShellTab.library);
    },
  );
}
