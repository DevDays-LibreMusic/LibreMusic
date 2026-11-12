import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/log_share_service.dart';

void main() {
  test(
    'shares UTF8 text attachment, redacts data, and keeps files readable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mornye-logshare-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final unrelated = File('${root.path}/keep.txt');
      await unrelated.writeAsString('keep');
      final date = DateTime(2026, 11, 11, 0, 30, 12);
      const content =
          'Diagnostic build: wave-search-v3\n[DIAG] Трек — готов\nERROR api_key=private https://host/signed-secret?token=private';
      final params = await LogShareService.prepare(
        content,
        temporaryDirectory: root,
        now: date,
      );
      expect(params.text, isNull);
      expect(params.files, hasLength(1));
      expect(params.files!.single.mimeType, 'text/plain');
      expect(params.fileNameOverrides, ['Mornye-logs-20261111-003012.txt']);
      final file = File(params.files!.single.path);
      final text = utf8.decode(await file.readAsBytes());
      expect(text, contains('[DIAG] Трек — готов'));
      expect(text, contains('Diagnostic build: wave-search-v3'));
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains('signed-secret')));
      final next = await LogShareService.prepare(
        'second',
        temporaryDirectory: root,
        now: date,
      );
      expect(next.files!.single.path, isNot(file.path));
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), text);
      expect(await unrelated.readAsString(), 'keep');
    },
  );
}
