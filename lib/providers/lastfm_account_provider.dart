import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/lastfm_account_controller.dart';
import 'package:mornye/services/lastfm_account_service.dart';
import 'package:mornye/services/secure_storage_options.dart';

export 'package:mornye/services/lastfm_account_controller.dart';
export 'package:mornye/services/lastfm_account_service.dart';

final lastfmAppCredentialsProvider = Provider<LastfmAppCredentials>(
  (ref) => const LastfmAppCredentials.fromEnvironment(),
);

final lastfmAccountProvider = Provider<LastfmAccountController>((ref) {
  final controller = LastfmAccountController(
    service: LastfmAccountService(
      credentials: ref.watch(lastfmAppCredentialsProvider),
    ),
    storage: DeviceLastfmAccountStorage(),
  );
  final connectivity = ref.read(lastfmAppCredentialsProvider).configured
      ? Connectivity().onConnectivityChanged.listen((results) {
          if (results.any((result) => result != ConnectivityResult.none)) {
            unawaited(controller.flush());
          }
        }, onError: (Object _) {})
      : null;
  final lifecycle = AppLifecycleListener(
    onResume: () {
      unawaited(controller.flush());
      if (controller.state.authorizationPending) {
        unawaited(controller.completeAuthorization());
      }
    },
  );
  ref.onDispose(() {
    unawaited(connectivity?.cancel());
    lifecycle.dispose();
    controller.dispose();
  });
  return controller;
});

final lastfmAccountStateProvider = StreamProvider<LastfmAccountState>(
  (ref) => ref.watch(lastfmAccountProvider).states,
);

class DeviceLastfmAccountStorage implements LastfmAccountStorage {
  static const sessionKey = 'lastfm_account_session';
  static const dataKey = 'lastfm_account_data';
  static const _secure = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );

  @override
  Future<String?> readSession() => _secure.read(key: sessionKey);

  @override
  Future<void> writeSession(String? value) => value == null
      ? _secure.delete(key: sessionKey)
      : _secure.write(key: sessionKey, value: value);

  @override
  Future<String?> readData() async =>
      (await SharedPreferences.getInstance()).getString(dataKey);

  @override
  Future<void> writeData(String value) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      dataKey,
      value,
    );
    if (!saved) throw StateError('Last.fm local data could not be saved');
  }
}
