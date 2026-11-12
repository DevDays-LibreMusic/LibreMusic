import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/lastfm_account_sheet.dart';

class _MemoryStorage implements LastfmAccountStorage {
  String? session;
  String? data;
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
    data = value;
  }
}

const _credentials = LastfmAppCredentials(
  apiKey: 'application-key',
  sharedSecret: 'application-secret',
);

Future<void> _pumpPanel(
  WidgetTester tester,
  LastfmAccountController controller, {
  bool mornye = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [lastfmAccountProvider.overrideWithValue(controller)],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SingleChildScrollView(child: LastfmAccountPanel()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets(
      'Last.fm controls are independent and disconnect safely ($mornye)',
      (tester) async {
        final store = _MemoryStorage()
          ..session = jsonEncode({
            'apiKey': _credentials.apiKey,
            'username': 'listener',
            'sessionKey': 'session-listener',
          });
        final controller = LastfmAccountController(
          service: LastfmAccountService(
            credentials: _credentials,
            client: MockClient((_) async => http.Response('{}', 200)),
          ),
          storage: store,
          retryInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        await controller.ready;
        await _pumpPanel(tester, controller, mornye: mornye);
        expect(find.text('Connected as listener'), findsOneWidget);
        final history = find.widgetWithText(
          SwitchListTile,
          'Send listening history',
        );
        final nowPlaying = find.widgetWithText(
          SwitchListTile,
          'Share now playing',
        );
        final likes = find.widgetWithText(SwitchListTile, 'Sync likes');
        expect(tester.widget<SwitchListTile>(history).value, isTrue);
        expect(tester.widget<SwitchListTile>(nowPlaying).value, isTrue);
        final initialLikes = controller.state.loveSyncEnabled;
        await tester.tap(history);
        await tester.pumpAndSettle();
        expect(controller.state.scrobblingEnabled, isFalse);
        expect(controller.state.nowPlayingEnabled, isTrue);
        await tester.tap(nowPlaying);
        await tester.pumpAndSettle();
        expect(controller.state.nowPlayingEnabled, isFalse);
        expect(controller.state.scrobblingEnabled, isFalse);
        expect(controller.state.loveSyncEnabled, initialLikes);
        await tester.tap(likes);
        await tester.pumpAndSettle();
        expect(controller.state.loveSyncEnabled, !initialLikes);
        expect(controller.state.scrobblingEnabled, isFalse);
        expect(controller.state.nowPlayingEnabled, isFalse);
        await tester.tap(find.text('Disconnect account'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(controller.state.connected, isTrue);
        await tester.tap(find.text('Disconnect account'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(controller.state.connected, isFalse);
        expect(store.session, isNull);
        expect(find.text('Connect Last.fm'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'unconfigured builds disable connection without developer fields',
    (tester) async {
      var requests = 0;
      final controller = LastfmAccountController(
        service: LastfmAccountService(
          credentials: const LastfmAppCredentials(apiKey: '', sharedSecret: ''),
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        ),
        storage: _MemoryStorage(),
        retryInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.ready;
      await _pumpPanel(tester, controller);
      expect(
        find.text('Last.fm connection is not configured in this build.'),
        findsOneWidget,
      );
      final button = find.widgetWithText(FilledButton, 'Connect Last.fm');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(requests, 0);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
