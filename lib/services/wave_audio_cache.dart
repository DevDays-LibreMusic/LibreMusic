import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/track.dart';
import 'package:mornye/models/wave_session.dart';

/// Owns only files below its dedicated root, never saved Library downloads.
class WaveAudioCache {
  WaveAudioCache(this.root);
  final Directory root;
  final Map<String, ({Track track, String path, int touched})> _entries = {};
  final Set<String> protectedPaths = {};
  final Set<String> activeDirectories = {};
  Future<void> _writes = Future.value();
  int limitBytes = 1073741824;
  int bytes = 0;
  bool _loaded = false;
  String key(Track track) => waveRecordingKey(track);
  String folderName(Track track) =>
      sha256.convert(utf8.encode(key(track))).toString();
  bool _owns(String path) => p.isWithin(
    p.normalize(root.absolute.path),
    p.normalize(File(path).absolute.path),
  );
  Future<void> load() async {
    if (_loaded) return;
    await root.create(recursive: true);
    final manifest = File('${root.path}/index.json');
    if (await manifest.exists()) {
      try {
        final rows = jsonDecode(await manifest.readAsString()) as List;
        for (final value in rows) {
          final row = Map<String, dynamic>.from(value as Map);
          final track = Track.fromJson(
            Map<String, dynamic>.from(row['track'] as Map),
          );
          final path = row['path'] as String;
          if (_owns(path) && await File(path).exists()) {
            _entries[key(track)] = (
              track: track,
              path: path,
              touched: row['touched'] as int,
            );
          }
        }
      } on Object {
        _entries.clear();
      }
    }
    _loaded = true;
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('.partial')) {
        try {
          await entry.delete();
        } on FileSystemException {
          // A concurrent filesystem cleanup may have already removed the file.
        }
      }
    }
    await trim();
  }

  Future<String?> lookup(Track track) async {
    await load();
    final id = key(track), entry = _entries[key(track)];
    if (entry == null) return null;
    if (!await File(entry.path).exists()) {
      _entries.remove(id);
      return null;
    }
    _entries[id] = (
      track: entry.track,
      path: entry.path,
      touched: DateTime.now().millisecondsSinceEpoch,
    );
    return entry.path;
  }

  Future<Directory> directoryFor(Track track, {String? attempt}) async {
    await load();
    return Directory(
      '${root.path}/${folderName(track)}${attempt == null ? '' : '/${int.parse(attempt)}'}',
    ).create(recursive: true);
  }

  Future<void> remember(Track track, String path) async {
    await load();
    if (!_owns(path) || !await File(path).exists()) {
      throw StateError('Invalid wave cache file');
    }
    _entries[key(track)] = (
      track: track,
      path: path,
      touched: DateTime.now().millisecondsSinceEpoch,
    );
    await trim();
  }

  List<Track> get tracks => _entries.values.map((e) => e.track).toList();
  Future<void> trim({bool clear = false}) {
    final operation = _writes.then((_) async {
      final files = await root
          .list(recursive: true, followLinks: false)
          .where(
            (e) =>
                e is File &&
                !e.path.endsWith('/index.json') &&
                !e.path.endsWith('/index.json.tmp'),
          )
          .cast<File>()
          .toList();
      bytes = 0;
      final sizes = <String, int>{};
      for (final file in files) {
        try {
          sizes[file.path] = await file.length();
          bytes += sizes[file.path]!;
        } on FileSystemException {
          // A concurrent filesystem cleanup may have already removed the file.
        }
      }
      files.sort((a, b) {
        int age(String path) =>
            _entries.values.where((e) => e.path == path).firstOrNull?.touched ??
            0;
        return age(a.path).compareTo(age(b.path));
      });
      for (final file in files) {
        if (!clear && bytes <= limitBytes) break;
        if (protectedPaths.contains(file.path) ||
            activeDirectories.any((dir) => file.path.startsWith('$dir/'))) {
          continue;
        }
        try {
          await file.delete();
          bytes -= sizes[file.path] ?? 0;
          _entries.removeWhere((_, e) => e.path == file.path);
        } on FileSystemException {
          // A concurrent filesystem cleanup may have already removed the file.
        }
      }
      final data = [
        for (final e in _entries.values)
          {'track': e.track.toJson(), 'path': e.path, 'touched': e.touched},
      ];
      final temp = File('${root.path}/index.json.tmp');
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename('${root.path}/index.json');
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
