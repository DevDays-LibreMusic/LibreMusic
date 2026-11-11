import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  late List<String> subscriptions;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    subscriptions = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      subscriptions.add(call.method);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'unconfigured account does not subscribe to native connectivity',
    () async {
      final container = ProviderContainer(
        overrides: [
          lastfmAppCredentialsProvider.overrideWithValue(
            const LastfmAppCredentials(apiKey: '', sharedSecret: ''),
          ),
        ],
      );
      final account = container.read(lastfmAccountProvider);
      await account.ready;
      expect(account.state.appConfigured, isFalse);
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(subscriptions, isEmpty);
    },
  );

  test(
    'configured account resumes authorization and releases subscription',
    () async {
      final methods = <String>[];
      await http.runWithClient(
        () async {
          final container = ProviderContainer(
            overrides: [
              lastfmAppCredentialsProvider.overrideWithValue(
                const LastfmAppCredentials(
                  apiKey: 'test-app-key',
                  sharedSecret: 'test-app-secret',
                ),
              ),
            ],
          );
          final account = container.read(lastfmAccountProvider);
          try {
            await account.ready;
            await Future<void>.delayed(Duration.zero);
            expect(subscriptions, ['listen']);
            final authorization = await account.beginAuthorization();
            expect(authorization?.host, 'www.last.fm');
            expect(account.state.authorizationPending, isTrue);
            final connected = account.states.firstWhere(
              (state) => state.connected,
            );
            binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
            binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            final state = await connected.timeout(const Duration(seconds: 2));
            expect(state.username, 'test-listener');
            expect(state.authorizationPending, isFalse);
            expect(state.error, isNull);
            for (final connection in ['none', 'wifi']) {
              await messenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeSuccessEnvelope([connection]),
                (_) {},
              );
            }
            await Future<void>.delayed(Duration.zero);
            expect(account.state.connected, isTrue);
            expect(account.state.error, isNull);
            expect(methods, ['auth.getToken', 'auth.getSession']);
          } finally {
            container.dispose();
            await Future<void>.delayed(Duration.zero);
          }
          expect(subscriptions, ['listen', 'cancel']);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await Future<void>.delayed(Duration.zero);
          expect(methods, ['auth.getToken', 'auth.getSession']);
        },
        () => MockClient((request) async {
          final method = request.method == 'GET'
              ? request.url.queryParameters['method']!
              : Uri.splitQueryString(request.body)['method']!;
          methods.add(method);
          return http.Response(
            jsonEncode(switch (method) {
              'auth.getToken' => {'token': 'test-browser-token'},
              'auth.getSession' => {
                'session': {'name': 'test-listener', 'key': 'test-session'},
              },
              _ => throw StateError('Unexpected API method'),
            }),
            200,
          );
        }),
      );
    },
  );
}
