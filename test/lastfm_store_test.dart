import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  test(
    'account session stays in secure storage, outside preferences',
    () async {
      final store = DeviceLastfmAccountStorage();
      await store.writeSession('private-session-key');
      await store.writeData('{"nowPlayingEnabled":false,"pending":[]}');
      final restored = DeviceLastfmAccountStorage();
      expect(await restored.readSession(), 'private-session-key');
      expect(
        await restored.readData(),
        '{"nowPlayingEnabled":false,"pending":[]}',
      );
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect('${prefs.get(key)}', isNot(contains('private-session-key')));
      }
      await restored.writeSession(null);
      expect(await store.readSession(), isNull);
    },
  );
  test(
    'new installation has no account and storage preserves unread state',
    () async {
      final store = DeviceLastfmAccountStorage();
      expect(await store.readSession(), isNull);
      expect(await store.readData(), isNull);
      await store.writeData('invalid');
      expect(await store.readData(), 'invalid');
    },
  );
}
