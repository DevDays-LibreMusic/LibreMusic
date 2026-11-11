import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_diagnostics.dart';

const downloadPlaybackScheme = 'mornye-download';

typedef DownloadItemReader = DownloadItem? Function();
typedef DownloadProgressReader = Future<Map<String, dynamic>> Function();

String downloadPlaybackSource(String itemId) =>
    '$downloadPlaybackScheme:$itemId';

bool isDownloadPlaybackSource(String source) =>
    source.startsWith('$downloadPlaybackScheme:');

class DownloadPlaybackSelectionChanged implements Exception {
  const DownloadPlaybackSelectionChanged();
}

class DownloadPlaybackService {
  DownloadPlaybackService({
    DownloadProgressReader progressReader =
        PlatformBridge.getAllDownloadProgress,
    Duration poll = const Duration(milliseconds: 100),
    Duration patience = const Duration(minutes: 2),
  }) : _progressReader = progressReader,
       _poll = poll,
       _patience = patience;

  static final instance = DownloadPlaybackService();

  final DownloadProgressReader _progressReader;
  final Duration _poll;
  final Duration _patience;
  final _lazy = <String, Future<String> Function(bool Function())>{};
  final _prioritize = <String, void Function(String)>{};
  final _prepared = <String, Future<String>>{};
  final _preparing = <String>{};
  final String _sessionId = List.generate(
    12,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final _preparedSources = <String, String>{};
  int _cancelGeneration = 0;
  Completer<void> _cancelled = Completer<void>();
  String? _currentSource;
  Set<String>? _readerSources;
  int _lazySequence = 0;
  int _windowGeneration = 0;

  final _items = <String, DownloadItemReader>{};
  final _entries = <String, _ArrivingDownload>{};
  final _completedPaths = <String, String>{};
  final _token = [
    for (var i = 0; i < 16; i++) Random.secure().nextInt(256),
  ].map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  Future<HttpServer>? _server;
  bool _closed = false;

  void registerItem(
    String itemId,
    DownloadItemReader read, {
    String? ownerSource,
  }) {
    if (_closed) throw StateError('Audio playback is unavailable');
    _items[itemId] = read;
    if (ownerSource != null && isDownloadPlaybackSource(ownerSource)) {
      _preparedSources[ownerSource.substring(
        downloadPlaybackScheme.length + 1,
      )] = downloadPlaybackSource(
        itemId,
      );
    }
  }

  String registerLazy(
    Future<String> Function() prepare, {
    Future<String> Function(bool Function())? prepareGuarded,
    void Function(String)? prioritize,
  }) {
    if (_closed) throw StateError('Audio playback is unavailable');
    final id = 'lazy-$_sessionId-${++_lazySequence}';
    _lazy[id] = prepareGuarded ?? (_) => prepare();
    if (prioritize != null) _prioritize[id] = prioritize;
    return downloadPlaybackSource(id);
  }

  Future<String> _prepare(String id, {bool Function()? isCurrent}) {
    final existing = _prepared[id];
    if (existing != null) return existing;
    late final Future<String> pending;
    final cancellation = _cancelGeneration;
    bool current() =>
        !_closed &&
        _lazy.containsKey(id) &&
        cancellation == _cancelGeneration &&
        (isCurrent?.call() ?? true);
    pending =
        Future<String>.sync(() {
              if (!current()) throw const DownloadPlaybackSelectionChanged();
              return _lazy[id]!(current);
            })
            .then((source) {
              if (!current()) throw const DownloadPlaybackSelectionChanged();
              _preparedSources[id] = source;
              _preparing.remove(id);
              return source;
            })
            .catchError((Object error, StackTrace stack) {
              if (identical(_prepared[id], pending)) {
                _prepared.remove(id);
                _preparing.remove(id);
              }
              Error.throwWithStackTrace(error, stack);
            });
    _prepared[id] = pending;
    _preparing.add(id);
    return pending;
  }

  /// Stop player-owned readers/lookups without cancelling shared download jobs.
  void suspendWindow() {
    _windowGeneration++;
    _cancelGeneration++;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _cancelled = Completer<void>();
    // A new selection must not await an obsolete lookup that may never finish.
    // Settled sources remain reusable; shared download jobs are not cancelled.
    for (final id in _preparing) {
      _prepared.remove(id);
    }
    _preparing.clear();
    for (final entry in _entries.values) {
      unawaited(entry.close());
    }
    _entries.clear();
  }

  Future<T> _untilCancelled<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>(
      (_) => throw const DownloadPlaybackSelectionChanged(),
    ),
  ]);

  void releaseSources() {
    suspendWindow();
    _retainSources(const []);
    _currentSource = null;
    _readerSources = null;
  }

  Set<String> _sourceIds(Iterable<String> sources) {
    final ids = <String>{};
    void retain(String source) {
      if (!isDownloadPlaybackSource(source)) return;
      final id = source.substring(downloadPlaybackScheme.length + 1);
      if (!ids.add(id)) return;
      final prepared = _preparedSources[id];
      if (prepared != null) retain(prepared);
    }

    for (final source in sources) {
      retain(source);
    }
    return ids;
  }

  void _retainSources(List<String> sources) {
    final retained = _sourceIds(sources);
    _lazy.removeWhere((id, _) => !retained.contains(id));
    _prioritize.removeWhere((id, _) => !retained.contains(id));
    _prepared.removeWhere((id, _) => !retained.contains(id));
    _preparing.removeWhere((id) => !retained.contains(id));
    _preparedSources.removeWhere((id, _) => !retained.contains(id));
    _items.removeWhere((id, _) => !retained.contains(id));
    _completedPaths.removeWhere((id, _) => !retained.contains(id));
    for (final id in _entries.keys.toList()) {
      if (!retained.contains(id)) unawaited(_entries.remove(id)!.close());
    }
  }

  void _checkItem(String itemId) {
    if (_closed) throw StateError('Audio playback is unavailable');
    if (_completedPaths.containsKey(itemId)) return;
    final item = _items[itemId]?.call();
    if (item == null) {
      throw StateError('The download was cancelled or is no longer available');
    }
    if (item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.skipped) {
      throw StateError(item.errorMessage);
    }
  }

  /// The current item is scheduled first. The next lookup must never delay
  /// opening it; old window lookups cannot enqueue work after a skip.
  Future<void> prepareWindow(List<String> sources, int index) async {
    _retainSources(sources);
    final currentSource = index >= 0 && index < sources.length
        ? sources[index]
        : null;
    _readerSources = {
      ?_currentSource,
      ?currentSource,
      if (index >= 0 && index + 1 < sources.length) sources[index + 1],
    };
    _currentSource = currentSource;
    final readerIds = _sourceIds(_readerSources!);
    for (final id in _entries.keys.toList()) {
      if (!readerIds.contains(id)) unawaited(_entries.remove(id)!.close());
    }
    final generation = ++_windowGeneration;
    bool current() => !_closed && generation == _windowGeneration;
    Future<void> prepareAt(int position, {bool priority = false}) async {
      if (!current() || position < 0 || position >= sources.length) return;
      final source = sources[position];
      if (!isDownloadPlaybackSource(source)) return;
      final id = source.substring(downloadPlaybackScheme.length + 1);
      if (!_lazy.containsKey(id)) return;
      try {
        String prepared;
        try {
          prepared = await _prepare(id, isCurrent: current);
        } on DownloadPlaybackSelectionChanged {
          // A still-current window may inherit a pending preload from the
          // previous window. Its obsolete guard is not a failure of this one.
          if (!current()) return;
          prepared = await _prepare(id, isCurrent: current);
        }
        if (priority && current()) _prioritize[id]?.call(prepared);
      } on Object {
        // resolve reports current failures. A failed next never blocks current.
      }
    }

    try {
      await _untilCancelled(prepareAt(index, priority: true));
    } on DownloadPlaybackSelectionChanged {
      return;
    }
    if (current()) unawaited(prepareAt(index + 1));
  }

  /// Queue completion is transient: completed items are removed immediately.
  /// Retain the final destination for registered player references.
  void rememberCompleted(DownloadItem item) {
    if (_items.containsKey(item.id) &&
        item.status == DownloadStatus.completed &&
        item.filePath?.isNotEmpty == true) {
      _completedPaths[item.id] = item.filePath!;
    }
  }

  Future<String> resolve(String source) async {
    if (!isDownloadPlaybackSource(source)) return source;
    if (_closed) throw StateError('Audio playback is unavailable');
    final cancellation = _cancelGeneration;
    final itemId = source.substring(downloadPlaybackScheme.length + 1);
    if (_lazy.containsKey(itemId)) {
      final prepared = await _untilCancelled(_prepare(itemId));
      PlaybackDiagnostics.event(
        'download_resolve',
        attempt: itemId,
        fields: {
          'itemId': isDownloadPlaybackSource(prepared)
              ? prepared.substring(downloadPlaybackScheme.length + 1)
              : null,
          'sourceKind': isDownloadPlaybackSource(prepared)
              ? 'download'
              : 'local',
        },
      );
      if (_closed || cancellation != _cancelGeneration) {
        throw const DownloadPlaybackSelectionChanged();
      }
      return resolve(prepared);
    }
    if (!_items.containsKey(itemId) && !_completedPaths.containsKey(itemId)) {
      throw StateError(
        'This playback reference has expired; select the track again',
      );
    }
    final timeout = Stopwatch()..start();
    while (!_closed) {
      if (cancellation != _cancelGeneration) {
        throw const DownloadPlaybackSelectionChanged();
      }
      final completed = _completedPaths[itemId];
      if (completed != null) {
        PlaybackDiagnostics.event(
          'playable',
          attempt: itemId,
          fields: {
            'sourceKind': completed.startsWith('content://') ? 'saf' : 'file',
          },
        );
        return completed;
      }
      final item = _items[itemId]?.call();
      if (item != null) {
        if (item.status == DownloadStatus.completed &&
            item.filePath?.isNotEmpty == true) {
          return item.filePath!;
        }
        if (item.status == DownloadStatus.failed ||
            item.status == DownloadStatus.skipped) {
          PlaybackDiagnostics.event(
            'download_error',
            attempt: itemId,
            fields: {'errorType': item.errorType?.name ?? 'unknown'},
          );
          throw StateError(item.errorMessage);
        }
      } else if (_items.containsKey(itemId)) {
        throw StateError('The download was cancelled');
      }

      final progress = await _untilCancelled(_progressReader());
      if (_closed || cancellation != _cancelGeneration) {
        throw const DownloadPlaybackSelectionChanged();
      }
      final items = progress['items'];
      final raw = items is Map ? items[itemId] : null;
      if (raw is Map) {
        final path = raw['playback_path']?.toString() ?? '';
        final total = (raw['bytes_total'] as num?)?.toInt() ?? 0;
        if (path.isNotEmpty && total > 0) {
          try {
            if (await _hasPlayableHeader(path)) {
              if (_closed || cancellation != _cancelGeneration) {
                throw const DownloadPlaybackSelectionChanged();
              }
              _checkItem(itemId);
              return await _serve(itemId, path, total);
            }
          } on FileSystemException {
            // The output can be renamed while the player opens it.
          }
        }
      }
      if (timeout.elapsed >= _patience) {
        throw StateError('Timed out while preparing audio playback');
      }
      await Future<void>.delayed(_poll);
    }
    throw StateError('Audio playback is unavailable');
  }

  Future<bool> _hasPlayableHeader(String path) async {
    final file = await File(path).open();
    late final List<int> bytes;
    try {
      bytes = await file.read(16);
    } finally {
      await file.close();
    }
    bool matches(int offset, List<int> signature) {
      if (bytes.length < offset + signature.length) return false;
      for (var index = 0; index < signature.length; index++) {
        if (bytes[offset + index] != signature[index]) return false;
      }
      return true;
    }

    return matches(0, [0x66, 0x4c, 0x61, 0x43]) ||
        matches(0, [0x4f, 0x67, 0x67, 0x53]) ||
        matches(0, [0x49, 0x44, 0x33]) ||
        matches(4, [0x66, 0x74, 0x79, 0x70]) ||
        matches(0, [0x44, 0x53, 0x44, 0x20]) ||
        matches(0, [0x46, 0x4f, 0x52, 0x4d]) ||
        (matches(0, [0x52, 0x49, 0x46, 0x46]) &&
            matches(8, [0x57, 0x41, 0x56, 0x45])) ||
        (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0);
  }

  Future<String> _serve(String itemId, String path, int total) async {
    final cancellation = _cancelGeneration;
    void checkOwner() {
      if (_closed ||
          cancellation != _cancelGeneration ||
          (_readerSources != null &&
              !_sourceIds(_readerSources!).contains(itemId))) {
        throw const DownloadPlaybackSelectionChanged();
      }
      _checkItem(itemId);
    }

    final server = await (_server ??= _bind());
    checkOwner();
    var entry = _entries[itemId];
    if (entry != null && (entry.total != total || entry.path != path)) {
      _entries.remove(itemId);
      await entry.close();
      entry = null;
    }
    if (entry == null) {
      checkOwner();
      final file = await File(path).open();
      try {
        checkOwner();
        // Another HTTP consumer may have opened this item while we awaited IO.
        if (_entries.containsKey(itemId)) {
          await file.close();
        } else {
          _entries[itemId] = _ArrivingDownload(
            file: file,
            total: total,
            path: path,
            poll: _poll,
            patience: _patience,
            checkActive: () => _checkItem(itemId),
          );
        }
      } on Object {
        await file.close();
        rethrow;
      }
    }
    return 'http://127.0.0.1:${server.port}/$_token/${Uri.encodeComponent(itemId)}';
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serveRequest(request)));
    return server;
  }

  Future<void> _serveRequest(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final itemId = segments.length == 2 && segments.first == _token
        ? Uri.decodeComponent(segments.last)
        : '';
    final entry = _entries[itemId];
    if (entry == null ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final total = entry.total;
    var start = 0;
    var end = total - 1;
    final range = RegExp(
      r'^bytes=(\d*)-(\d*)$',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null) {
      final first = int.tryParse(range[1]!);
      final last = int.tryParse(range[2]!);
      if (first != null) {
        start = first;
        if (last != null && last < end) end = last;
      } else if (last != null) {
        start = max(0, total - last);
      }
      if (start > end || start >= total) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
    }
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = _contentType(entry.path);
    response.bufferOutput = false;
    response.contentLength = end - start + 1;
    try {
      if (request.method == 'GET') {
        var offset = start;
        while (offset <= end) {
          final bytes = await entry.read(
            offset,
            min(256 * 1024, end - offset + 1),
          );
          response.add(bytes);
          await response.flush();
          offset += bytes.length;
        }
      }
      await response.close();
    } on Object {
      // A truncated response or disconnected reader can make close fail too.
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } on Object {
        try {
          await response.close();
        } on Object {
          /* Already disconnected. */
        }
      }
    }
  }

  ContentType _contentType(String path) {
    final extension = path
        .toLowerCase()
        .replaceFirst(RegExp(r'\.partial$'), '')
        .split('.')
        .last;
    return switch (extension) {
      'flac' => ContentType('audio', 'flac'),
      'mp3' => ContentType('audio', 'mpeg'),
      'm4a' || 'mp4' || 'aac' => ContentType('audio', 'mp4'),
      'ogg' || 'opus' => ContentType('audio', 'ogg'),
      'wav' => ContentType('audio', 'wav'),
      _ => ContentType.binary,
    };
  }

  Future<void> close() async {
    _closed = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _cancelGeneration++;
    _windowGeneration++;
    for (final entry in _entries.values) {
      await entry.close();
    }
    _entries.clear();
    _items.clear();
    _lazy.clear();
    _prioritize.clear();
    _prepared.clear();
    _preparing.clear();
    _preparedSources.clear();
    _completedPaths.clear();
    final server = _server;
    _server = null;
    if (server != null) await (await server).close(force: true);
  }
}

class _ArrivingDownload {
  _ArrivingDownload({
    required this.file,
    required this.total,
    required this.path,
    required this.poll,
    required this.patience,
    required this.checkActive,
  });

  final RandomAccessFile file;
  final int total;
  final String path;
  final Duration poll;
  final Duration patience;
  final void Function() checkActive;
  bool _closed = false;
  Future<void>? _closing;
  Future<void> _readTail = Future<void>.value();

  Future<List<int>> read(int offset, int length) {
    final result = _readTail.then((_) => _read(offset, length));
    _readTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<int>> _read(int offset, int length) async {
    final timeout = Stopwatch()..start();
    while (true) {
      if (_closed) throw StateError('Audio reader closed');
      checkActive();
      final available = await file.length();
      if (offset < available) {
        await file.setPosition(offset);
        return file.read(min(length, available - offset));
      }
      if (timeout.elapsed >= patience) {
        throw StateError('Audio download stalled');
      }
      await Future<void>.delayed(poll);
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _readTail;
      await file.close();
    }();
  }
}
