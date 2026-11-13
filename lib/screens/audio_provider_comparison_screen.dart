import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/audio_source_materializer.dart';
import 'package:mornye/services/audio_source_preference.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';
import 'package:mornye/screens/audio_version_comparison_screen.dart';

/// Users choose two concrete provider items; titles only seed the search box.
class AudioProviderComparisonScreen extends ConsumerStatefulWidget {
  const AudioProviderComparisonScreen({super.key, required this.seed});
  final Track seed;
  @override
  ConsumerState<AudioProviderComparisonScreen> createState() =>
      _AudioProviderComparisonScreenState();
}

class _AudioProviderComparisonScreenState
    extends ConsumerState<AudioProviderComparisonScreen> {
  late final _query = TextEditingController(
    text: '${widget.seed.artistName} ${widget.seed.name}',
  );
  String? _provider;
  Track? _a, _b;
  List<Track> _results = [];
  bool _busy = false;
  String? _error;
  int _generation = 0;
  final _materializer = AudioSourceMaterializer();
  String? _transferId;
  @override
  void dispose() {
    _generation++;
    final id = _transferId;
    if (id != null) _materializer.cancel(id);
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final provider = _provider;
    if (provider == null || _busy || _query.text.trim().isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _results = [];
    });
    try {
      final rows = await PlatformBridge.customSearchWithExtension(
        provider,
        _query.text.trim(),
        cancelPrevious: true,
      ).timeout(const Duration(seconds: 45));
      final tracks = rows
          .map((r) => Track.fromBackendMap(r, source: provider))
          .where((t) => !t.isCollection && t.id.isNotEmpty)
          .toList();
      if (mounted && generation == _generation) {
        setState(() => _results = tracks);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = context.l10n.audioCompareError);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _compare() async {
    if (_a == null || _b == null || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    AudioSourceAsset? a, b;
    var retained = false;
    try {
      _transferId = 'audio-compare-${DateTime.now().microsecondsSinceEpoch}-a';
      a = await _materializer.materialize(
        _a!,
        quality: 'LOSSLESS',
        requestId: _transferId!,
      );
      if (!mounted || generation != _generation) return;
      _transferId = 'audio-compare-${DateTime.now().microsecondsSinceEpoch}-b';
      b = await _materializer.materialize(
        _b!,
        quality: 'LOSSLESS',
        requestId: _transferId!,
      );
      _transferId = null;
      if (!mounted || generation != _generation) return;
      final assetA = a, assetB = b;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AudioVersionComparisonScreen(
            pathA: assetA.path,
            nameA:
                '${_a!.name} (${assetA.identity.providerId}:${assetA.identity.itemId})',
            initialPathB: assetB.path,
            nameB:
                '${_b!.name} (${assetB.identity.providerId}:${assetB.identity.itemId})',
            savePreference: (result) async {
              final pair = result.sourcePair;
              final side = result.data['preferred_side'];
              if (pair == null ||
                  !const {'A', 'B'}.contains(side) ||
                  result.data['direction_status'] != 'consistent_vocal_loss') {
                return false;
              }
              final saved = await AudioSourcePreference.instance.saveConfirmed(
                pair,
                side == 'A'
                    ? AudioSourcePreferenceVerdict.a
                    : AudioSourcePreferenceVerdict.b,
                directionModelSha256: AudioVersionDemucsRunner.modelSha256,
                contentModelSha256: AudioVersionLearnedRunner.modelSha256,
                providerA: assetA.identity,
                providerB: assetB.identity,
              );
              retained |= saved;
              return saved;
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = context.l10n.audioCompareError);
      }
    } finally {
      _transferId = null;
      if (!retained) {
        if (a != null) await _materializer.release(a);
        if (b != null) await _materializer.release(b);
      }
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final providers = ref
        .watch(extensionProvider)
        .extensions
        .where(
          (e) => e.enabled && e.hasMetadataProvider && e.hasDownloadProvider,
        )
        .toList();
    _provider ??=
        providers.where((e) => e.id == widget.seed.source).firstOrNull?.id ??
        providers.firstOrNull?.id;
    return Scaffold(
      appBar: AppBar(title: Text(l.audioCompareTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(l.audioCompareProviderInstructions),
          const SizedBox(height: 12),
          Text(
            'A: ${_a == null ? l.audioCompareNotSelected : '${_a!.artistName} — ${_a!.name} (${_a!.source}:${_a!.id})'}',
          ),
          Text(
            'B: ${_b == null ? l.audioCompareNotSelected : '${_b!.artistName} — ${_b!.name} (${_b!.source}:${_b!.id})'}',
          ),
          FilledButton(
            onPressed: _busy || _a == null || _b == null ? null : _compare,
            child: Text(l.audioCompareStart),
          ),
          DropdownButtonFormField<String>(
            initialValue: _provider,
            items: [
              for (final p in providers)
                DropdownMenuItem(value: p.id, child: Text(p.displayName)),
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _provider = v;
                    _results = [];
                  }),
          ),
          TextField(
            controller: _query,
            enabled: !_busy,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: l.audioCompareSearchVersions,
            ),
          ),
          OutlinedButton(
            onPressed: _busy || _provider == null ? null : _search,
            child: Text(l.audioCompareSearchVersions),
          ),
          if (_busy) ...[
            const LinearProgressIndicator(),
            Text(l.audioComparePreparing),
          ],
          if (_error != null) Text(_error!),
          for (final t in _results)
            ListTile(
              title: Text(t.name),
              subtitle: Text(
                '${t.artistName} · ${t.albumName}\n${t.source}:${t.id}',
              ),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _a = t;
                            if (_b?.source == t.source && _b?.id == t.id) {
                              _b = null;
                            }
                          }),
                    child: const Text('A'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _b = t;
                            if (_a?.source == t.source && _a?.id == t.id) {
                              _a = null;
                            }
                          }),
                    child: const Text('B'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
