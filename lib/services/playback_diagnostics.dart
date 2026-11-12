import 'dart:convert';
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/logger.dart';

/// Small, always-on lifecycle trace. Never record requests, URLs or file paths.
class PlaybackDiagnostics {
  static int _next = 0;
  static final _trackTraces = <String, String>{};
  static void bindTrack(Track track, String trace) {
    if (_trackTraces.length >= 200) {
      _trackTraces.remove(_trackTraces.keys.first);
    }
    _trackTraces['${track.source}:${track.id}'] = trace;
  }

  static String? traceForTrack(Track track) =>
      _trackTraces['${track.source}:${track.id}'];
  static const build = String.fromEnvironment(
    'MORNYE_DIAGNOSTIC_BUILD',
    defaultValue: 'development',
  );
  static String begin(String origin) {
    final id = 'play-${DateTime.now().millisecondsSinceEpoch}-${++_next}';
    event('begin', attempt: id, fields: {'origin': origin, 'build': build});
    return id;
  }

  static void track(
    String stage,
    Track track, {
    required String origin,
    String? attempt,
  }) => event(
    stage,
    attempt: attempt,
    fields: {
      'origin': origin,
      'trackId': track.id,
      'source': track.source ?? '',
      'isrc': track.isrc ?? '',
      'duration': track.duration,
      'title': track.name,
      'artist': track.artistName,
      'album': track.albumName,
    },
  );

  static void event(
    String stage, {
    String? attempt,
    Map<String, Object?> fields = const {},
  }) {
    const allowed = {
      'reference',
      'origin',
      'build',
      'source',
      'trackId',
      'isrc',
      'duration',
      'title',
      'artist',
      'album',
      'count',
      'index',
      'itemId',
      'provider',
      'version',
      'result',
      'errorType',
      'sourceKind',
    };
    String clean(Object? value) {
      var text = redactDiagnosticText('$value');
      if (RegExp(
        r'(?:[a-z][a-z0-9+.-]*://|(?:^|[^a-z0-9])/[^\s]+|[a-z]:[\\/])',
        caseSensitive: false,
      ).hasMatch(text)) {
        return '[location omitted]';
      }
      return text.length > 160 ? '${text.substring(0, 160)}…' : text;
    }

    LogBuffer().add(
      LogEntry(
        timestamp: DateTime.now(),
        level: 'DIAG',
        tag: 'PlaybackTrace',
        message: jsonEncode({
          'stage': clean(stage),
          if (attempt != null) 'attempt': clean(attempt),
          for (final entry in fields.entries)
            if (allowed.contains(entry.key)) entry.key: clean(entry.value),
        }),
      ),
    );
  }
}
