import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_source_preference.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_learned.dart';

class AudioVersionComparisonScreen extends StatefulWidget {
  const AudioVersionComparisonScreen({
    super.key,
    required this.pathA,
    required this.nameA,
    this.runner,
    this.pickAudio,
    this.initialPathB,
    this.nameB,
    this.savePreference,
  });
  final String pathA, nameA;
  final String? initialPathB, nameB;
  final Future<bool> Function(AudioVersionComparison)? savePreference;
  final AudioVersionComparisonRunner? runner;
  final Future<String?> Function()? pickAudio;
  @override
  State<AudioVersionComparisonScreen> createState() =>
      _AudioVersionComparisonScreenState();
}

class _AudioVersionComparisonScreenState
    extends State<AudioVersionComparisonScreen> {
  late final _runner = widget.runner ?? AudioVersionComparisonRunner();
  String? _pathB;
  AudioComparisonStage? _stage;
  AudioVersionComparison? _result;
  AudioComparisonFailure? _error;
  bool _busy = false;
  bool _saved = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pathB = widget.initialPathB;
  }

  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _runner.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final generation = ++_generation;
    _runner.cancel();
    setState(() {
      _result = null;
      _saved = false;
      _error = null;
      _busy = false;
    });
    try {
      final path = await (widget.pickAudio?.call() ?? _pickAudio());
      if (!mounted || generation != _generation || path == null) return;
      setState(() {
        _pathB = path;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = AudioComparisonFailure.unsupportedInput;
        });
      }
    }
  }

  static Future<String?> _pickAudio() async =>
      (await FilePicker.pickFile(type: FileType.audio))?.path;

  Future<void> _start() async {
    final pathB = _pathB;
    if (pathB == null || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _result = null;
      _saved = false;
      _error = null;
      _stage = AudioComparisonStage.preparingModels;
    });
    try {
      final result = await _runner.compare(
        widget.pathA,
        pathB,
        onProgress: (stage) {
          if (mounted && generation == _generation) {
            setState(() {
              _stage = stage;
            });
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() {
          _result = result;
        });
      }
    } on AudioAnalysisCancelled {
      // Cancellation never publishes the previous pair's result.
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is AudioComparisonException
              ? error.reason
              : AudioComparisonFailure.unavailable;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _cancel() {
    if (_saving) return;
    _generation++;
    _runner.cancel();
    setState(() {
      _busy = false;
      _stage = null;
      _result = null;
      _saved = false;
    });
  }

  Future<void> _savePreference() async {
    final result = _result;
    final pair = result?.sourcePair;
    if (result == null || pair == null || _busy) return;
    final side = result.data['preferred_side'];
    if (!const {'A', 'B'}.contains(side) ||
        result.data['direction_status'] != 'consistent_vocal_loss') {
      return;
    }
    setState(() {
      _busy = true;
      _saving = true;
    });
    var saved = false;
    try {
      saved =
          await (widget.savePreference?.call(result) ??
              AudioSourcePreference.instance.saveConfirmed(
                pair,
                side == 'A'
                    ? AudioSourcePreferenceVerdict.a
                    : AudioSourcePreferenceVerdict.b,
                directionModelSha256: AudioVersionDemucsRunner.modelSha256,
                contentModelSha256: AudioVersionLearnedRunner.modelSha256,
              ));
    } catch (_) {
      // A failed persistence operation never publishes a saved preference.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saving = false;
      _saved = saved;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? context.l10n.audioComparePreferenceSaved
              : context.l10n.audioComparePreferenceFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final result = _result;
    final status = result?.data['status'];
    final verification = result?.data['verification_status'];
    final summary = switch (verification ?? status) {
      'confirmed_content_change' => l.audioCompareContentChanged,
      'no_confirmed_content_change' => l.audioCompareContentUnconfirmed,
      'verification_uncertain' => l.audioCompareContentUncertain,
      'identical_audio' => l.audioCompareIdentical,
      'alignment_unreliable' => l.audioCompareUnaligned,
      'insufficient_shared_bandwidth' => l.audioCompareBandwidth,
      _ => l.audioCompareReview,
    };
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: Text(l.audioCompareTitle)),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l.audioComparePrivacy),
            const SizedBox(height: 16),
            Text('A: ${widget.nameA}'),
            if (_pathB != null)
              Text(
                'B: ${widget.nameB ?? Uri.tryParse(_pathB!)?.pathSegments.lastOrNull ?? _pathB}',
              ),
            const SizedBox(height: 12),
            if (widget.initialPathB == null)
              OutlinedButton(
                onPressed: _busy ? null : _pick,
                child: Text(l.audioCompareSelect),
              ),
            FilledButton(
              onPressed: _busy || _pathB == null ? null : _start,
              child: Text(l.audioCompareStart),
            ),
            if (_busy && !_saving) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              Text(switch (_stage) {
                AudioComparisonStage.preparingModels =>
                  l.audioComparePreparingModels,
                AudioComparisonStage.decodingA => l.audioCompareDecodeA,
                AudioComparisonStage.decodingB => l.audioCompareDecodeB,
                AudioComparisonStage.separating => l.audioCompareSeparating,
                _ => l.audioCompareAnalyzing,
              }),
              TextButton(onPressed: _cancel, child: Text(l.audioCompareCancel)),
            ],
            if (_saving) const LinearProgressIndicator(),
            if (_error != null)
              Text(switch (_error) {
                AudioComparisonFailure.duration => l.audioCompareDurationError,
                AudioComparisonFailure.modelImport => l.audioCompareModelError,
                _ => l.audioCompareError,
              }),
            const SizedBox(height: 20),
            Text(l.audioCompareModelsAutomatic),
            if (result != null) ...[
              const Divider(),
              Text(summary, style: Theme.of(context).textTheme.titleMedium),
              Text(switch (result.data['preferred_side']) {
                'A' => l.audioComparePreferA,
                'B' => l.audioComparePreferB,
                _ =>
                  result.data['direction_status'] == 'mixed'
                      ? l.audioCompareMixed
                      : l.audioCompareDirectionUnknown,
              }),
              Text(l.audioCompareUnknown),
              if (result.sourcePair != null &&
                  result.data['direction_status'] == 'consistent_vocal_loss')
                FilledButton(
                  onPressed: _busy || _saved ? null : _savePreference,
                  child: Text(
                    _saved
                        ? l.audioComparePreferenceSaved
                        : l.audioCompareUsePreferred,
                  ),
                ),
              Text(
                MaterialLocalizations.of(
                  context,
                ).formatMediumDate(result.startedAt.toLocal()),
              ),
              Text(
                MaterialLocalizations.of(context).formatTimeOfDay(
                  TimeOfDay.fromDateTime(result.startedAt.toLocal()),
                ),
              ),
              for (final candidate
                  in (result.data['verified_events'] as List? ??
                      result.data['candidates'] as List? ??
                      const []))
                if (candidate is Map &&
                    candidate['start_a'] is num &&
                    candidate['end_a'] is num &&
                    candidate['start_b'] is num &&
                    candidate['end_b'] is num)
                  ListTile(
                    leading: Icon(
                      candidate['confirmed'] == true
                          ? Icons.check_circle_outline
                          : Icons.hearing,
                    ),
                    title: Text(
                      'A: ${_seconds(candidate['start_a'] as num)}–${_seconds(candidate['end_a'] as num)}',
                    ),
                    subtitle: Text(
                      'B: ${_seconds(candidate['start_b'] as num)}–${_seconds(candidate['end_b'] as num)}',
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  String _seconds(num seconds) {
    if (!seconds.isFinite || seconds < 0) return '?';
    final whole = seconds.floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
  }
}
