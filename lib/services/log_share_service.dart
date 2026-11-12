import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, XFile;
import 'package:mornye/utils/logger.dart';

/// Shares real files so Android's share provider grants the receiver URI access.
class LogShareService {
  static Future<ShareParams> prepare(
    String text, {
    Directory? temporaryDirectory,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final temporary = temporaryDirectory ?? await getTemporaryDirectory();
    final root = Directory('${temporary.path}/mornye-log-shares');
    await root.create(recursive: true);
    // Never remove a fresh share: recipients may open its URI later. Cleanup
    // only our own old directories, at most 20 deletions per new export.
    try {
      var removed = 0;
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory ||
            !entry.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('export-')) {
          continue;
        }
        if (timestamp.difference((await entry.stat()).modified) >
            const Duration(days: 7)) {
          try {
            await entry.delete(recursive: true);
          } on FileSystemException {
            /* Best-effort old export cleanup. */
          }
          if (++removed >= 20) break;
        }
      }
    } on FileSystemException {
      // Concurrent cleanup must not prevent creating the new attachment.
    }
    final folder = await root.createTemp('export-');
    String two(int n) => n.toString().padLeft(2, '0');
    final filename =
        'Mornye-logs-${timestamp.year}${two(timestamp.month)}${two(timestamp.day)}-${two(timestamp.hour)}${two(timestamp.minute)}${two(timestamp.second)}.txt';
    final file = File('${folder.path}/$filename');
    await file.writeAsString(
      sanitizeLogExportText(text),
      encoding: utf8,
      flush: true,
    );
    return ShareParams(
      files: [XFile(file.path, mimeType: 'text/plain')],
      fileNameOverrides: [filename],
    );
  }
}
