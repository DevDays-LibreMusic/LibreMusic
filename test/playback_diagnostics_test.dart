import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_diagnostics.dart';
import 'package:mornye/utils/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bounded traces survive verbose off and export without locations or secrets',
    () async {
      final logs = LogBuffer();
      logs.clear();
      LogBuffer.loggingEnabled = false;
      for (var i = 0; i < 150; i++) {
        PlaybackDiagnostics.event(
          'prepare',
          attempt: 'attempt-$i',
          fields: {
            'itemId': 'item-$i',
            'source': 'deezer',
            'trackId': 'https://host/secret-path?unknown-secret=private',
            'title': 'api_key=hidden',
            'unknown': 'not allowed',
          },
        );
      }
      expect(logs.entries.where((e) => e.level == 'DIAG').length, 120);
      logs.add(
        LogEntry(
          timestamp: DateTime.now(),
          level: 'ERROR',
          tag: 'Legacy',
          message:
              "HTTP403 open('/tmp/private-song') https://host/signed-secret?x=unknown",
        ),
      );
      final exported = await logs.exportWithDeviceInfo();
      expect(exported, contains('HTTP403'));
      expect(exported, isNot(contains('private-song')));
      expect(exported, isNot(contains('signed-secret')));
      expect(exported, contains('attempt-149'));
      for (final secret in [
        'secret-path',
        'private',
        'hidden',
        'not allowed',
      ]) {
        expect(exported, isNot(contains(secret)));
      }
      for (final path in [
        r'C:\Users\private\music',
        '/tmp/private',
        "open('/tmp/private')",
        'path=/home/private',
        '/sdcard/private',
        'network://user:pass@host',
      ]) {
        PlaybackDiagnostics.event('resolve', fields: {'trackId': path});
        expect(logs.entries.last.message, contains('location omitted'));
        expect(logs.entries.last.message, isNot(contains(path)));
      }
      expect(logs.filter(search: 'prepare'), isNotEmpty);
      logs.clear();
    },
  );
}
