import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';

import 'support/fixed_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final preferExplicit in [true, false]) {
    test(
      'custom search applies uncensored-first=$preferExplicit to matching versions',
      () async {
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'customSearchWithExtension') return null;
          return jsonEncode([
            {
              'id': 'explicit',
              'name': 'Song',
              'artists': 'Artist',
              'duration_ms': 200000,
              'explicit': true,
              'audio_quality': 'LOW',
            },
            {
              'id': 'unrelated',
              'name': 'Another Song',
              'artists': 'Other Artist',
              'duration_ms': 200000,
              'explicit': false,
            },
            {
              'id': 'clean',
              'name': 'Song (Clean)',
              'artists': 'Artist',
              'duration_ms': 200000,
              'explicit': false,
              'audio_quality': 'LOSSLESS',
            },
          ]);
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                AppSettings(preferExplicitTracks: preferExplicit),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container
            .read(trackProvider.notifier)
            .customSearch('example', 'Song');
        expect(
          container.read(trackProvider).tracks.map((track) => track.id),
          preferExplicit
              ? ['explicit', 'unrelated', 'clean']
              : ['clean', 'unrelated', 'explicit'],
        );
      },
    );
  }
}
