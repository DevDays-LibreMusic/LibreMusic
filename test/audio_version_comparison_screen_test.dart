import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/audio_version_comparison_screen.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';
import 'package:mornye/services/audio_source_preference.dart';

class _ConfirmedRunner extends AudioVersionComparisonRunner {
  _ConfirmedRunner()
    : super(
        learned: AudioVersionLearnedRunner(supported: false),
        demucs: AudioVersionDemucsRunner(supported: false),
      );
  @override
  Future<AudioVersionComparison> compare(
    String pathA,
    String pathB, {
    void Function(AudioComparisonStage)? onProgress,
  }) async => AudioVersionComparison(pathA, pathB, DateTime(2026), {
    'preferred_side': 'A',
    'direction_status': 'consistent_vocal_loss',
    'verification_status': 'confirmed_content_change',
  }, sourcePair: const AudioSourcePair('/a', '/b', 'encoded-a', 'encoded-b'));
}

void main() {
  for (final failed in [true, false]) {
    testWidgets(
      'pending preference save blocks leaving; failure=$failed settles safely',
      (tester) async {
        final save = Completer<bool>();
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: nav,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => AudioVersionComparisonScreen(
              pathA: '/a',
              nameA: 'A',
              initialPathB: '/b',
              runner: _ConfirmedRunner(),
              savePreference: (_) => save.future,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start comparison'));
        await tester.pumpAndSettle();
        final button = find.text(
          'Use the more complete recording for this pair',
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        expect(await nav.currentState!.maybePop(), true);
        await tester.pump();
        expect(find.byType(AudioVersionComparisonScreen), findsOneWidget);
        if (failed) {
          save.completeError(StateError('preferences unavailable'));
        } else {
          save.complete(true);
        }
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            failed
                ? 'Files changed or this source'
                : 'Preference saved for future playback',
          ),
          findsWidgets,
        );
        await nav.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(AudioVersionComparisonScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selecting B never starts decode; explicit start displays unknown even for identical audio',
    (tester) async {
      var decodes = 0;
      final runner = AudioVersionComparisonRunner(
        capturePair: (_, _) async => null,
        createWork: () async => Directory('/private/comparison'),
        removeWork: (_) async {},
        byteLength: (_) async => AudioVersionComparisonRunner.minPcmBytes,
        decode: (_) async {
          decodes++;
          return (id: decodes, completed: Future.value(true));
        },
        native: (_, {required requestId}) async => {
          'version': 'audio-version-dsp-v1',
          'status': 'identical_audio',
          'preferred_side': null,
          'absolute_uncensored_status': 'unknown',
          'candidates': <Object?>[],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AudioVersionComparisonScreen(
            pathA: '/a',
            nameA: 'Track A',
            runner: runner,
            pickAudio: () async => '/b',
          ),
        ),
      );
      await tester.tap(find.text('Select second audio file'));
      await tester.pumpAndSettle();
      expect(decodes, 0);
      await tester.tap(find.text('Start comparison'));
      await tester.pumpAndSettle();
      expect(decodes, 2);
      expect(find.text('Decoded audio is identical'), findsOneWidget);
      expect(
        find.textContaining('Absolute censorship status remains unknown.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Verification model is not installed.'),
        findsOneWidget,
      );
    },
  );
}
