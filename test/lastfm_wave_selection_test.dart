import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/widgets/wave_controls.dart';

class _Wave extends WaveSessionController {
  _Wave(this.initial);
  final WaveSessionState initial;
  WaveContext? _selected;
  int _starts = 0;
  Completer<void>? _pending;
  String? _currentItemId;
  @override
  WaveSessionState build() => initial;
  @override
  Future<void> start(
    WaveContext context, {
    bool preserveCurrent = false,
    bool skipSeed = false,
    String? currentItemId,
  }) async {
    _selected = context;
    _currentItemId = currentItemId;
    _starts++;
    if (_pending != null) await _pending!.future;
  }
}

void main() {
  const track = Track(
    id: 'deezer:3819908',
    name: 'Duality',
    artistName: 'Slipknot',
    albumName: 'Vol. 3',
    duration: 252,
    source: 'deezer',
  );
  const wave = WaveContext(
    kind: WaveKind.track,
    title: 'Duality',
    artist: 'Slipknot',
    track: track,
  );

  testWidgets(
    'track wave action passes exact selected track identity to session',
    (tester) async {
      final controller = _Wave(const WaveSessionState(loaded: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [waveSessionProvider.overrideWith(() => controller)],
          child: const MaterialApp(
            home: Scaffold(
              body: WaveStartButton(wave: wave, currentItemId: 'playing-item'),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      expect(controller._selected?.track, same(track));
      expect(controller._selected?.kind, WaveKind.track);
      expect(controller._currentItemId, 'playing-item');
    },
  );

  testWidgets('pending wave action cannot create a second start request', (
    tester,
  ) async {
    final controller = _Wave(const WaveSessionState(loaded: true))
      .._pending = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [waveSessionProvider.overrideWith(() => controller)],
        child: const MaterialApp(
          home: Scaffold(body: WaveStartButton(wave: wave)),
        ),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    expect(controller._starts, 1);
    controller._pending!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'player heading identifies wave seed separately from song metadata',
    (tester) async {
      final controller = _Wave(
        const WaveSessionState(loaded: true, active: true, context: wave),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [waveSessionProvider.overrideWith(() => controller)],
          child: const MaterialApp(home: Scaffold(body: WavePlayerHeading())),
        ),
      );
      expect(find.text('Wave by track'), findsOneWidget);
      expect(find.text('Duality'), findsOneWidget);
    },
  );
}
