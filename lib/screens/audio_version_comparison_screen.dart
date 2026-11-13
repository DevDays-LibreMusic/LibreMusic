import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_learned.dart';

class AudioVersionComparisonScreen extends StatefulWidget {
  const AudioVersionComparisonScreen({
    super.key,
    required this.pathA,
    required this.nameA,
    this.runner,
    this.pickAudio,
  });
  final String pathA, nameA;
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
  AudioVersionModelStatus _model = AudioVersionModelStatus.unavailable;

  @override
  void initState() {
    super.initState();
    _refreshModel();
  }

  Future<void> _refreshModel() async {
    final status = await _runner.learned.status();
    if (mounted) setState(() => _model = status);
  }

  Future<void> _importModel() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (!mounted || generation != _generation || file?.path == null) return;
      await _runner.learned.importModel(
        file!.path!,
        requestId: "model-$generation",
      );
      if (mounted && generation == _generation) await _refreshModel();
    } on AudioAnalysisCancelled {
      // The import was cancelled by this screen.
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = AudioComparisonFailure.modelImport);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
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
      _error = null;
      _stage = AudioComparisonStage.decodingA;
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
    _generation++;
    _runner.cancel();
    setState(() {
      _busy = false;
      _stage = null;
      _result = null;
    });
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
    return Scaffold(
      appBar: AppBar(title: Text(l.audioCompareTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(l.audioComparePrivacy),
          const SizedBox(height: 16),
          Text('A: ${widget.nameA}'),
          if (_pathB != null)
            Text(
              'B: ${Uri.tryParse(_pathB!)?.pathSegments.lastOrNull ?? _pathB}',
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy ? null : _pick,
            child: Text(l.audioCompareSelect),
          ),
          FilledButton(
            onPressed: _busy || _pathB == null ? null : _start,
            child: Text(l.audioCompareStart),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            Text(switch (_stage) {
              AudioComparisonStage.decodingA => l.audioCompareDecodeA,
              AudioComparisonStage.decodingB => l.audioCompareDecodeB,
              _ => l.audioCompareAnalyzing,
            }),
            TextButton(onPressed: _cancel, child: Text(l.audioCompareCancel)),
          ],
          if (_error != null)
            Text(switch (_error) {
              AudioComparisonFailure.duration => l.audioCompareDurationError,
              AudioComparisonFailure.modelImport => l.audioCompareModelError,
              _ => l.audioCompareError,
            }),
          const SizedBox(height: 20),
          Text(
            _model == AudioVersionModelStatus.available
                ? l.audioCompareModelReady
                : l.audioCompareNoModel,
          ),
          if (_model != AudioVersionModelStatus.unsupported)
            OutlinedButton(
              onPressed: _busy ? null : _importModel,
              child: Text(l.audioCompareImportModel),
            ),
          if (result != null) ...[
            const Divider(),
            Text(summary, style: Theme.of(context).textTheme.titleMedium),
            Text(l.audioCompareUnknown),
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
    );
  }

  String _seconds(num seconds) {
    if (!seconds.isFinite || seconds < 0) return '?';
    final whole = seconds.floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
  }
}
