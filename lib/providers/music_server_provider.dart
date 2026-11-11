import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/music_server_client.dart';

final musicServerClientProvider = Provider<MusicServerClient>(
  (ref) => MusicServerClient.instance,
);

final musicServerTrackSavedProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, source) async {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return await ref.read(localLibraryProvider.notifier).getById(source) !=
          null;
    });

/// The session lives in secure storage separately from exported app settings.
class MusicServerConnection extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final client = ref.read(musicServerClientProvider);
    await client.restore();
    return client.connected;
  }

  Future<void> login(String address, String username, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref
          .read(musicServerClientProvider)
          .login(address, username, password);
      return true;
    });
  }

  Future<void> logout() async {
    try {
      await ref.read(musicServerClientProvider).logout();
    } finally {
      state = const AsyncData(false);
    }
  }
}

final musicServerConnectionProvider =
    AsyncNotifierProvider<MusicServerConnection, bool>(
      MusicServerConnection.new,
    );
