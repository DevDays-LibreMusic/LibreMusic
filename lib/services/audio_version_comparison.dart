import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_learned.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart' show isContentUri;

enum AudioComparisonStage { decodingA, decodingB, comparing }

enum AudioComparisonFailure {
  unsupportedInput,
  duration,
  decode,
  unavailable,
  modelImport,
}

class AudioComparisonException implements Exception {
  const AudioComparisonException(this.reason);
  final AudioComparisonFailure reason;
}

/// A snapshot of this exact pair; advisory metadata is never used as a verdict.
class AudioVersionComparison {
  const AudioVersionComparison(
    this.pathA,
    this.pathB,
    this.startedAt,
    this.data,
  );
  final String pathA, pathB;
  final DateTime startedAt;
  final Map<String, dynamic> data;
}

typedef ComparisonDecoder =
    Future<({int id, Future<bool> completed})> Function(List<String>);
typedef ComparisonNative =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic>, {
      required String requestId,
    });

class AudioVersionComparisonRunner {
  AudioVersionComparisonRunner({
    AudioVersionLearnedRunner? learned,
    ComparisonDecoder? decode,
    Future<void> Function(int)? cancelDecode,
    ComparisonNative? native,
    Future<void> Function(String)? cancelNative,
    Future<Directory> Function()? createWork,
    Future<int> Function(String)? byteLength,
    Future<void> Function(Directory)? removeWork,
  }) : learned = learned ?? AudioVersionLearnedRunner(),
       _jobs = AudioAnalysisJobs<bool>(
         start: decode ?? _decode,
         cancel: cancelDecode ?? FFmpegExecution.cancel,
       ),
       _native = native ?? PlatformBridge.runNativeDataJob,
       _cancelNative = cancelNative ?? PlatformBridge.cancelNativeDataJob,
       _createWork = createWork ?? _temporaryDirectory,
       _byteLength = byteLength ?? ((path) => File(path).length()),
       _removeWork =
           removeWork ??
           ((work) async {
             await work.delete(recursive: true);
           });

  static const maxPcmBytes = 38400000;
  static const minPcmBytes = 13 * 16000 * 4;
  final AudioVersionLearnedRunner learned;
  final AudioAnalysisJobs<bool> _jobs;
  final ComparisonNative _native;
  final Future<void> Function(String) _cancelNative;
  final Future<Directory> Function() _createWork;
  final Future<int> Function(String) _byteLength;
  final Future<void> Function(Directory) _removeWork;
  final Set<String> _requests = {};
  int _generation = 0;
  bool _disposed = false;

  static Future<Directory> _temporaryDirectory() async =>
      (await getTemporaryDirectory()).createTemp('audio-version-');

  static bool isLocalInput(String path) {
    final uri = Uri.tryParse(path);
    return path.isNotEmpty &&
        (isContentUri(path) ||
            uri?.scheme == 'file' ||
            (uri?.scheme.isEmpty ?? false));
  }

  static Future<({int id, Future<bool> completed})> _decode(
    List<String> arguments,
  ) async {
    final index = arguments.indexOf('-i') + 1;
    if (!isDesktopPlatform && isContentUri(arguments[index])) {
      final saf = await FFmpegKitConfig.getSafParameterForRead(
        arguments[index],
      );
      if (saf == null || saf.isEmpty) {
        throw const AudioComparisonException(
          AudioComparisonFailure.unsupportedInput,
        );
      }
      arguments = List.of(arguments)..[index] = saf;
    }
    final session = await FFmpegExecution.start(arguments);
    return (
      id: session.id,
      completed: session.completed.then((result) => result.success),
    );
  }

  void cancel() {
    _generation++;
    _jobs.invalidate();
    learned.cancelAll();
    for (final request in _requests.toList()) {
      unawaited(_cancelNative(request).catchError((Object _) {}));
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
    _jobs.dispose();
    learned.dispose();
  }

  Future<AudioVersionComparison> compare(
    String pathA,
    String pathB, {
    void Function(AudioComparisonStage)? onProgress,
  }) async {
    cancel();
    final generation = _generation;
    final startedAt = DateTime.now();
    void check() {
      if (_disposed || generation != _generation) {
        throw const AudioAnalysisCancelled();
      }
    }

    check();
    if (!isLocalInput(pathA) || !isLocalInput(pathB)) {
      throw const AudioComparisonException(
        AudioComparisonFailure.unsupportedInput,
      );
    }
    Directory? work;
    try {
      work = await _createWork();
      check();
      final outputs = <String>[];
      for (final (index, path) in [pathA, pathB].indexed) {
        check();
        onProgress?.call(
          index == 0
              ? AudioComparisonStage.decodingA
              : AudioComparisonStage.decodingB,
        );
        final output = '${work.path}/$index.f32le';
        final success = await _jobs.run([
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-y',
          '-threads',
          '1',
          '-filter_threads',
          '1',
          '-protocol_whitelist',
          'file,saf,fd,pipe',
          '-i',
          path,
          '-t',
          '601',
          '-vn',
          '-sn',
          '-dn',
          '-ac',
          '1',
          '-ar',
          '16000',
          '-c:a',
          'pcm_f32le',
          '-f',
          'f32le',
          output,
        ]);
        check();
        if (!success) {
          throw const AudioComparisonException(AudioComparisonFailure.decode);
        }
        final bytes = await _byteLength(output);
        check();
        if (bytes < minPcmBytes || bytes > maxPcmBytes || bytes % 4 != 0) {
          throw const AudioComparisonException(AudioComparisonFailure.duration);
        }
        outputs.add(output);
      }
      check();
      onProgress?.call(AudioComparisonStage.comparing);
      final request = 'audio-version-${work.path}';
      _requests.add(request);
      final Map<String, dynamic> result;
      try {
        result = await _native({
          'operation': 'audio_version_compare',
          'path_a': outputs[0],
          'path_b': outputs[1],
        }, requestId: request);
      } finally {
        _requests.remove(request);
      }
      check();
      if (result['version'] != 'audio-version-dsp-v1' ||
          !const {
            'model_verification_required',
            'alignment_unreliable',
            'identical_audio',
            'insufficient_shared_bandwidth',
          }.contains(result['status']) ||
          result['preferred_side'] != null ||
          result['absolute_uncensored_status'] != 'unknown') {
        throw const AudioComparisonException(
          AudioComparisonFailure.unavailable,
        );
      }
      if (result['status'] == 'model_verification_required' &&
          await learned.status() == AudioVersionModelStatus.available) {
        check();
        await _verify(result, outputs, work, check);
        check();
      }
      check();
      return AudioVersionComparison(pathA, pathB, startedAt, result);
    } finally {
      // Native/decoder completion owns these files, even after UI cancellation.
      if (work != null) {
        try {
          await _removeWork(work);
        } on FileSystemException {
          /* OS temp cleanup remains available. */
        }
      }
    }
  }

  Future<Map<String, dynamic>> _job(
    Map<String, dynamic> args,
    String id,
  ) async {
    _requests.add(id);
    try {
      return await _native(args, requestId: id);
    } finally {
      _requests.remove(id);
    }
  }

  Future<void> _verify(
    Map<String, dynamic> result,
    List<String> pcm,
    Directory work,
    void Function() check,
  ) async {
    final candidates = (result['candidates'] as List)
        .cast<Map<String, dynamic>>();
    if (candidates.isEmpty) return;
    // Bounded sequential contexts avoid retaining model activations for a song.
    if (candidates.length > 64) {
      result['verification_status'] = 'verification_uncertain';
      return;
    }
    final offset = ((result['alignment'] as Map)['offset'] as num).toDouble();
    final all = [
      for (final c in candidates)
        {'start_b': c['start_b'], 'end_b': c['end_b']},
    ];
    final events = <Map<String, dynamic>>[];
    var uncertain = false;
    final clips = <AudioVersionClipInput>[];
    final starts = <String, double>{};
    for (var i = 0; i < candidates.length; i++) {
      check();
      final c = candidates[i];
      if ((c['end_b'] as num) - (c['start_b'] as num) > 10) {
        uncertain = true;
        events.add({...c, 'confirmed': false});
        continue;
      }
      final start = (((c['start_b'] as num) + (c['end_b'] as num)) / 2 - 6)
          .clamp(
            0.0,
            ((result['duration_b'] as num).toDouble() - 12).clamp(0.0, 600.0),
          )
          .toDouble();
      final paths = [
        '${work.path}/context-$i-a.f32le',
        '${work.path}/context-$i-b.f32le',
      ];
      for (var side = 0; side < 2; side++) {
        final prepared = await _job({
          'operation': 'audio_version_prepare_clip',
          'path': pcm[side],
          'start_seconds': start + (side == 0 ? offset : 0),
          'output_path': paths[side],
        }, 'prepare-${work.path}-$i-$side');
        check();
        if (prepared['normalization'] != 'runtime' ||
            prepared['samples'] != 192000 ||
            prepared['model_sha256'] != AudioVersionLearnedRunner.modelSha256) {
          throw const AudioComparisonException(
            AudioComparisonFailure.unavailable,
          );
        }
      }
      starts['$i'] = start;
      clips.add(AudioVersionClipInput('$i', paths[0], paths[1]));
    }
    if (clips.isNotEmpty) {
      // One session per pair; native code still runs A/B contexts sequentially.
      final batch = await learned.infer(clips, requestId: 'infer-${work.path}');
      try {
        check();
        for (final embedding in batch.contexts) {
          final i = int.parse(embedding.clipId);
          final c = candidates[i];
          final verified = await _job({
            'operation': 'audio_version_verify_context',
            'embedding_a': embedding.pathA,
            'embedding_b': embedding.pathB,
            'context_start_b': starts[embedding.clipId],
            'events': [all[i]],
            'all_events': all,
            'model_sha256': AudioVersionLearnedRunner.modelSha256,
          }, 'verify-${work.path}-$i');
          check();
          if (verified['model_sha256'] !=
                  AudioVersionLearnedRunner.modelSha256 ||
              verified['preferred_side'] != null ||
              verified['absolute_uncensored_status'] != 'unknown' ||
              verified['events'] is! List) {
            throw const AudioComparisonException(
              AudioComparisonFailure.unavailable,
            );
          }
          uncertain |= verified['status'] == 'verification_uncertain';
          for (final event in verified['events'] as List) {
            events.add({
              ...Map<String, dynamic>.from(event as Map),
              'start_a': c['start_a'],
              'end_a': c['end_a'],
            });
          }
        }
      } finally {
        await learned.release(batch);
      }
    }
    result['verified_events'] = events;
    result['verification_status'] = events.any((e) => e['confirmed'] == true)
        ? 'confirmed_content_change'
        : uncertain
        ? 'verification_uncertain'
        : 'no_confirmed_content_change';
  }
}
