import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/audio_version_comparison_screen.dart';
import 'package:mornye/services/audio_version_comparison.dart';

void main() {
  testWidgets(
    'selecting B never starts decode; explicit start displays unknown even for identical audio',
    (tester) async {
      var decodes = 0;
      final runner = AudioVersionComparisonRunner(
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
        find.textContaining('Censorship status of both versions: unknown.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Verification model is not installed.'),
        findsOneWidget,
      );
    },
  );
}
