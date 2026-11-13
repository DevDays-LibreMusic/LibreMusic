import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_learned.dart';

/// Local HTDemucs execution. FFT and overlap/add remain in the Rust backend.
class AudioVersionDemucsRunner {
  AudioVersionDemucsRunner({AudioVersionLearnedCall? invoke, bool? supported})
    : _invoke = invoke ?? _call,
      _supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  static const modelId = 'htdemucs-trunk-fp32';
  static const modelBytes = 174263852;
  static const modelSha256 =
      '273be7e599749c71ef29b6f34c20721937c336aa85b3e1f2fde5b57a987f07ba';
  static const _channel = MethodChannel('com.zarz.mornye/audio_version_demucs');
  final AudioVersionLearnedCall _invoke;
  final bool _supported;
  final Set<String> _pending = {}, _cancelled = {};
  bool _disposed = false;
  static Future<Object?> _call(String method, Map<String, Object?> args) =>
      _channel.invokeMethod<Object?>(method, args);
  bool _contract(Map<Object?, Object?> value) =>
      value['version'] == modelId && value['model_sha256'] == modelSha256;
  Future<AudioVersionModelStatus> status() async {
    if (!_supported) return AudioVersionModelStatus.unsupported;
    try {
      final value = await _invoke('status', {});
      if (_disposed) throw const AudioAnalysisCancelled();
      return value is Map && _contract(value) && value['status'] == 'available'
          ? AudioVersionModelStatus.available
          : AudioVersionModelStatus.unavailable;
    } on MissingPluginException {
      return AudioVersionModelStatus.unsupported;
    } on PlatformException {
      return AudioVersionModelStatus.unavailable;
    }
  }

  Future<void> prepareModel({required String requestId}) async {
    final raw = await _operation('prepareModel', requestId, const {});
    if (raw is! Map || !_contract(raw) || raw['status'] != 'available') {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.invalidModel,
      );
    }
  }

  Future<void> importModel(String source, {required String requestId}) async {
    if (source.isEmpty ||
        !const {'', 'file', 'content'}.contains(Uri.tryParse(source)?.scheme)) {
      throw ArgumentError('Select a local analysis model');
    }
    final value = await _operation('importModel', requestId, {
      'source': source,
    });
    if (value is! Map || !_contract(value) || value['status'] != 'available') {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.invalidModel,
      );
    }
  }

  Future<Map<String, dynamic>> infer(
    List<Map<String, String>> clips, {
    required String requestId,
  }) async {
    if (clips.isEmpty ||
        clips.length > 6 ||
        clips.map((c) => c['clip_id']).toSet().length != clips.length ||
        clips.any(
          (c) =>
              c['clip_id']?.isNotEmpty != true ||
              ![c['wave_path'], c['spec_path']].every(
                (p) => p != null && p.startsWith('/') && !p.contains('\u0000'),
              ),
        )) {
      throw ArgumentError('Invalid private Demucs tensors');
    }
    final raw = await _operation('infer', requestId, {'clips': clips});
    try {
      if (raw is! Map ||
          !_contract(raw) ||
          raw['status'] != 'verified' ||
          !_validOutput(raw['output_id']) ||
          raw['contexts'] is! List) {
        throw const FormatException();
      }
      final contexts = raw['contexts'] as List;
      final expected = clips.map((c) => c['clip_id']).toSet();
      final seen = <String>{}, paths = <String>{};
      if (contexts.length != clips.length) throw const FormatException();
      for (final c in contexts) {
        if (c is! Map ||
            c['clip_id'] is! String ||
            !expected.contains(c['clip_id']) ||
            !seen.add(c['clip_id'] as String)) {
          throw const FormatException();
        }
        for (final key in ['freq_path', 'time_path']) {
          final p = c[key];
          if (p is! String ||
              !p.startsWith('/') ||
              p.contains('\u0000') ||
              !paths.add(p)) {
            throw const FormatException();
          }
        }
      }
      return Map<String, dynamic>.from(raw);
    } on FormatException {
      if (raw is Map) await release(raw);
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.malformedResult,
      );
    }
  }

  static bool _validOutput(Object? id) =>
      id is String &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      ).hasMatch(id);
  Future<void> release(Map<Object?, Object?> value) async {
    if (!_validOutput(value['output_id'])) return;
    try {
      await _invoke('releaseOutputs', {'output_id': value['output_id']});
    } on Exception {
      /* OS cache fallback. */
    }
  }

  Future<Object?> _operation(
    String method,
    String id,
    Map<String, Object?> args,
  ) async {
    if (_disposed) throw const AudioAnalysisCancelled();
    if (!_supported) {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.unavailable,
      );
    }
    if (id.isEmpty || id.length > 160 || !_pending.add(id)) {
      throw ArgumentError('Invalid analysis request');
    }
    try {
      final raw = await _invoke(method, {...args, 'request_id': id});
      if (_disposed || _cancelled.contains(id)) {
        if (raw is Map) await release(raw);
        throw const AudioAnalysisCancelled();
      }
      return raw;
    } on PlatformException catch (e) {
      if (e.code == 'cancelled' || _disposed || _cancelled.contains(id)) {
        throw const AudioAnalysisCancelled();
      }
      throw AudioVersionLearnedException(
        e.code == 'invalid_model'
            ? AudioVersionLearnedFailure.invalidModel
            : AudioVersionLearnedFailure.unavailable,
      );
    } on MissingPluginException {
      throw const AudioVersionLearnedException(
        AudioVersionLearnedFailure.unavailable,
      );
    } finally {
      _pending.remove(id);
      _cancelled.remove(id);
    }
  }

  void cancelAll() {
    for (final id in _pending.toList()) {
      _cancelled.add(id);
      unawaited(
        _invoke('cancel', {'request_id': id}).catchError((Object _) => null),
      );
    }
  }

  void dispose() {
    _disposed = true;
    cancelAll();
  }
}
