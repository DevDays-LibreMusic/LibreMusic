import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';

enum AudioVersionModelStatus { available, unavailable, unsupported }

enum AudioVersionLearnedFailure { invalidModel, unavailable, malformedResult }

class AudioVersionLearnedException implements Exception {
  const AudioVersionLearnedException(this.reason);
  final AudioVersionLearnedFailure reason;
}

class AudioVersionClipInput {
  const AudioVersionClipInput(this.clipId, this.pathA, this.pathB);
  final String clipId, pathA, pathB;
}

class AudioVersionEmbeddingFiles {
  const AudioVersionEmbeddingFiles(this.clipId, this.pathA, this.pathB);
  final String clipId, pathA, pathB;
}

/// A local batch of raw float32[599,768] embeddings, not a censorship verdict.
class AudioVersionLearnedBatch {
  const AudioVersionLearnedBatch(this.outputId, this.contexts);
  final String outputId;
  final List<AudioVersionEmbeddingFiles> contexts;
}

typedef AudioVersionLearnedCall =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

class AudioVersionLearnedRunner {
  AudioVersionLearnedRunner({AudioVersionLearnedCall? invoke, bool? supported})
    : _invoke = invoke ?? _invokeChannel,
      _supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const modelId = 'wavlm-layer6-v9-fp32';
  static const modelBytes = 216152021;
  static const modelSha256 =
      '594a8aa0be7b036a14ac8b8d15e588b0f388295fbc026bc2acaed6ae983205eb';
  static const _channel = MethodChannel(
    'com.zarz.mornye/audio_version_learned',
  );
  static final _outputId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  final AudioVersionLearnedCall _invoke;
  final bool _supported;
  final Set<String> _pending = {};
  final Set<String> _cancelled = {};
  bool _disposed = false;

  static Future<Object?> _invokeChannel(
    String method,
    Map<String, Object?> arguments,
  ) => _channel.invokeMethod<Object?>(method, arguments);

  static bool _validContract(Map<Object?, Object?> value) =>
      value['version'] == modelId &&
      value['model_sha256'] == modelSha256 &&
      value['input_samples'] == 192000 &&
      value['normalization'] == 'runtime' &&
      value['output_frames'] == 599 &&
      value['output_channels'] == 768;

  static bool _privateFilePath(Object? path) =>
      path is String && path.startsWith('/') && !path.contains('\u0000');

  Future<AudioVersionModelStatus> status() async {
    if (!_supported) return AudioVersionModelStatus.unsupported;
    if (_disposed) throw const AudioAnalysisCancelled();
    try {
      final raw = await _invoke('status', const {});
      if (_disposed) throw const AudioAnalysisCancelled();
      return raw is Map && _validContract(raw) && raw['status'] == 'available'
          ? AudioVersionModelStatus.available
          : AudioVersionModelStatus.unavailable;
    } on MissingPluginException {
      return AudioVersionModelStatus.unsupported;
    } on PlatformException {
      return AudioVersionModelStatus.unavailable;
    }
  }

  /// Provision the pinned bundled APK asset lazily, without allocating model bytes in Dart.
  Future<void> prepareModel({required String requestId}) async {
    final raw = await _operation('prepareModel', requestId, const {});
    if (raw is! Map || !_validContract(raw) || raw['status'] != 'available') {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.invalidModel,
      );
    }
  }

  /// [source] comes from an explicit local file picker. No URL is downloaded.
  Future<void> importModel(String source, {required String requestId}) async {
    if (source.isEmpty ||
        !const {'', 'file', 'content'}.contains(Uri.tryParse(source)?.scheme)) {
      throw ArgumentError('Select a local analysis model');
    }
    final raw = await _operation('importModel', requestId, {'source': source});
    if (raw is! Map || !_validContract(raw) || raw['status'] != 'available') {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.invalidModel,
      );
    }
  }

  /// Inputs are app-owned little-endian raw mono16k PCM, exactly 192000 samples.
  /// Include extraction zero padding before calling; native code normalizes it once.
  Future<AudioVersionLearnedBatch> infer(
    List<AudioVersionClipInput> clips, {
    required String requestId,
  }) async {
    if (clips.isEmpty ||
        clips.length > 64 ||
        clips.map((c) => c.clipId).toSet().length != clips.length ||
        clips.any(
          (c) =>
              c.clipId.isEmpty ||
              c.clipId.length > 160 ||
              !_privateFilePath(c.pathA) ||
              !_privateFilePath(c.pathB),
        )) {
      throw ArgumentError('Invalid local analysis clips');
    }
    final raw = await _operation('infer', requestId, {
      'clips': [
        for (final clip in clips)
          {'clip_id': clip.clipId, 'path_a': clip.pathA, 'path_b': clip.pathB},
      ],
    });
    if (raw is Map && _validContract(raw) && raw['status'] == 'unavailable') {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.unavailable,
      );
    }
    try {
      if (raw is! Map ||
          !_validContract(raw) ||
          raw['status'] != 'verified' ||
          raw['output_id'] is! String ||
          !_outputId.hasMatch(raw['output_id'] as String) ||
          raw['contexts'] is! List) {
        throw const FormatException();
      }
      final contexts = raw['contexts'] as List;
      if (contexts.length != clips.length) throw const FormatException();
      final expectedIds = clips.map((c) => c.clipId).toSet();
      final seen = <String>{};
      final paths = <String>{};
      final files = <AudioVersionEmbeddingFiles>[];
      for (final context in contexts) {
        if (context is! Map ||
            context['clip_id'] is! String ||
            !expectedIds.contains(context['clip_id']) ||
            !seen.add(context['clip_id'] as String) ||
            !_privateFilePath(context['embedding_a']) ||
            !_privateFilePath(context['embedding_b']) ||
            !paths.add(context['embedding_a'] as String) ||
            !paths.add(context['embedding_b'] as String)) {
          throw const FormatException();
        }
        files.add(
          AudioVersionEmbeddingFiles(
            context['clip_id'] as String,
            context['embedding_a'] as String,
            context['embedding_b'] as String,
          ),
        );
      }
      return AudioVersionLearnedBatch(
        raw['output_id'] as String,
        List.unmodifiable(files),
      );
    } on FormatException {
      await _releaseRawOutput(raw);
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.malformedResult,
      );
    }
  }

  Future<Object?> _operation(
    String method,
    String requestId,
    Map<String, Object?> arguments,
  ) async {
    if (!_supported) {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.unavailable,
      );
    }
    if (_disposed) throw const AudioAnalysisCancelled();
    if (requestId.isEmpty ||
        requestId.length > 160 ||
        !_pending.add(requestId)) {
      throw ArgumentError('Invalid or duplicate analysis request');
    }
    try {
      final raw = await _invoke(method, {
        ...arguments,
        'request_id': requestId,
      });
      if (_disposed || _cancelled.contains(requestId)) {
        await _releaseRawOutput(raw);
        throw const AudioAnalysisCancelled();
      }
      return raw;
    } on MissingPluginException {
      if (_disposed || _cancelled.contains(requestId)) {
        throw const AudioAnalysisCancelled();
      }
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.unavailable,
      );
    } on PlatformException catch (error) {
      if (error.code == 'cancelled' ||
          _disposed ||
          _cancelled.contains(requestId)) {
        throw const AudioAnalysisCancelled();
      }
      throw AudioVersionLearnedException(
        error.code == 'invalid_model'
            ? AudioVersionLearnedFailure.invalidModel
            : AudioVersionLearnedFailure.unavailable,
      );
    } finally {
      _pending.remove(requestId);
      _cancelled.remove(requestId);
    }
  }

  Future<void> _releaseRawOutput(Object? raw) async {
    if (raw is Map &&
        raw['output_id'] is String &&
        _outputId.hasMatch(raw['output_id'] as String)) {
      try {
        await _invoke('releaseOutputs', {'output_id': raw['output_id']});
      } on Exception {
        // These are private temporary files; normal cache cleanup is a fallback.
      }
    }
  }

  /// Must be called in finally after native content postprocessing.
  Future<void> release(AudioVersionLearnedBatch batch) =>
      _releaseRawOutput({'output_id': batch.outputId});

  Future<void> cancel(String requestId) async {
    if (!_pending.contains(requestId)) return;
    _cancelled.add(requestId);
    try {
      await _invoke('cancel', {'request_id': requestId});
    } on Exception {
      // Generation checks still reject the late result and release its outputs.
    }
  }

  void cancelAll() {
    for (final id in _pending.toList()) {
      unawaited(cancel(id));
    }
  }

  void dispose() {
    _disposed = true;
    cancelAll();
  }
}
