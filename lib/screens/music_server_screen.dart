import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/music_server_provider.dart';
import 'package:mornye/services/music_server_client.dart';
import 'package:mornye/services/music_server_library.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// A streaming library. No local download action or audio persistence is used.
class MusicServerScreen extends ConsumerStatefulWidget {
  const MusicServerScreen({
    super.key,
    this.initialTrack,
    this.alternativeTracks = const [],
    this.autoPrepare = false,
    this.addToLibrary = false,
  });
  final Track? initialTrack;

  /// Exact versions of the requested track from other catalog providers.
  /// Used only when the server has a matching extension; IDs never cross
  /// provider boundaries and no metadata search can substitute another song.
  final List<Track> alternativeTracks;
  final bool autoPrepare;
  final bool addToLibrary;
  @override
  ConsumerState<MusicServerScreen> createState() => _MusicServerScreenState();
}

class _MusicServerScreenState extends ConsumerState<MusicServerScreen>
    with WidgetsBindingObserver {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _input = TextEditingController();
  final _title = TextEditingController();
  List<Map<String, dynamic>> _sources = [], _tracks = [], _pending = [];
  Map<String, dynamic>? _source, _job;
  String _quality = 'original';
  int? _nextOffset;
  bool _busy = false, _failed = false, _active = true, _loaded = false;
  bool _autoPrepared = false, _sourceUnavailable = false;
  bool _addWhenReady = false;
  Track? _preparedMetadata;
  final _metadataById = <String, Track>{};
  final _saving = <String>{};
  int _generation = 0;
  Timer? _timer;
  MusicServerClient get _client => ref.read(musicServerClientProvider);
  double? get _progress {
    final total = (_job?['total_bytes'] as num?)?.toDouble() ?? 0;
    if (total <= 0) return null;
    return (((_job?['received_bytes'] as num?)?.toDouble() ?? 0) / total).clamp(
      0,
      1,
    );
  }

  Track? _trackForSource(Map<String, dynamic>? source) {
    if (source?['type'] != 'extension') return null;
    return [
          if (widget.initialTrack != null) widget.initialTrack!,
          ...widget.alternativeTracks,
        ]
        .where(
          (track) =>
              !track.isAlbumItem &&
              track.id.isNotEmpty &&
              track.source?.replaceFirst(RegExp(r'^extension:'), '') ==
                  source?['provider_id'],
        )
        .firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _title.text = widget.initialTrack?.name ?? '';
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [_address, _username, _password, _input, _title]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_active && _job != null) unawaited(_poll());
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    var prepare = false;
    final generation = _generation;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final sourceResponse = await _client.request('GET', '/v1/sources');
      final tracks = await _client.request(
        'GET',
        '/v1/tracks?offset=${more ? _nextOffset ?? 0 : 0}',
      );
      final jobs = await _client.request('GET', '/v1/downloads');
      if (!mounted || generation != _generation) return;
      setState(() {
        _sources = (sourceResponse['sources'] as List)
            .cast<Map<String, dynamic>>();
        if (_source == null && _sources.isNotEmpty) {
          final track = widget.initialTrack;
          final matching = _sources
              .where((source) => _trackForSource(source) != null)
              .firstOrNull;
          _source = matching ?? _sources.first;
          _sourceUnavailable = track != null && matching == null;
          if (track != null && matching != null) {
            _input.text = _trackForSource(matching)!.id;
            if (widget.autoPrepare && !_autoPrepared) {
              _autoPrepared = true;
              prepare = true;
            }
          }
          _quality = (_source!['qualities'] as List).first as String;
        }
        if (_sources.isEmpty && widget.initialTrack != null) {
          _sourceUnavailable = true;
        }
        final items = (tracks['items'] as List).cast<Map<String, dynamic>>();
        _tracks = more ? [..._tracks, ...items] : items;
        _nextOffset = tracks['next_offset'] as int?;
        _pending = (jobs['items'] as List)
            .cast<Map<String, dynamic>>()
            .where(
              (job) => !const ['ready', 'cancelled'].contains(job['state']),
            )
            .toList();
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
    if (prepare && mounted && generation == _generation) {
      await _prepare(save: widget.addToLibrary);
    }
  }

  Future<void> _prepare({bool save = false}) async {
    if (_busy ||
        _job != null ||
        _source == null ||
        _input.text.trim().isEmpty) {
      return;
    }
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _failed = false;
      _job = null;
      _addWhenReady = save;
      final track = _trackForSource(_source);
      _preparedMetadata = track != null && _input.text.trim() == track.id
          ? track
          : null;
    });
    try {
      final key = switch (_source!['type']) {
        'url' => 'url',
        'storage' => 'path',
        _ => 'track_id',
      };
      final job = await _client.request('POST', '/v1/playback/prepare', {
        'source': {'connection_id': _source!['id'], key: _input.text.trim()},
        'quality': _quality,
        'title': _title.text.trim(),
        'artist': widget.initialTrack?.artistName ?? '',
      });
      if (!mounted || generation != _generation) return;
      setState(() => _job = job);
      await _acceptJob(job, generation);
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _acceptJob(Map<String, dynamic> job, int generation) async {
    if (job['state'] == 'ready') {
      final metadata = _preparedMetadata;
      if (metadata != null) _metadataById[job['id'] as String] = metadata;
      setState(() {
        _job = null;
        _loaded = false;
      });
      if (_addWhenReady) {
        await _addToLibrary(job);
      } else {
        await _play(job);
      }
    } else if (job['state'] == 'failed' || job['state'] == 'cancelled') {
      setState(() {
        _job = null;
        _failed = job['state'] == 'failed';
      });
    } else if (_active && generation == _generation) {
      _timer = Timer(const Duration(seconds: 2), () => unawaited(_poll()));
    }
  }

  Future<void> _poll() async {
    final job = _job;
    if (job == null || !_active) return;
    final generation = _generation;
    try {
      final next = await _client.request('GET', '/v1/downloads/${job['id']}');
      if (!mounted || generation != _generation) return;
      setState(() => _job = next);
      await _acceptJob(next, generation);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
      // Keep the server-owned job. A transient disconnect must not cancel it.
      if (_active) {
        _timer = Timer(const Duration(seconds: 5), () => unawaited(_poll()));
      }
    }
  }

  Future<void> _cancel() async {
    final job = _job;
    if (job == null) return;
    ++_generation;
    _timer?.cancel();
    try {
      await _client.request('POST', '/v1/downloads/${job['id']}/cancel');
      if (mounted) {
        setState(() {
          _job = null;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  Future<void> _play(Map<String, dynamic> track) async {
    try {
      final id = track['id'] as String;
      final controller = ref.read(musicPlayerControllerProvider);
      await controller.playSingle(
        PlayableMedia(
          id: _client.source(id),
          source: _client.source(id),
          title: (track['title'] as String?)?.isNotEmpty == true
              ? track['title'] as String
              : context.l10n.musicServerTrack,
          artist: track['artist'] as String? ?? '',
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _addToLibrary(Map<String, dynamic> track) async {
    final id = track['id'] as String;
    if (_saving.contains(id)) return;
    setState(() => _saving.add(id));
    try {
      final item = musicServerLibraryItem(
        _client,
        track,
        metadata: _metadataById[id],
      );
      await ref
          .read(localLibraryProvider.notifier)
          .addMusicServerTrack(
            item,
            displayName: context.l10n.musicServerTitle,
          );
      if (!mounted) return;
      ref.invalidate(musicServerTrackSavedProvider(item.filePath));
      showAppSnackBar(
        context,
        content: Text(context.l10n.musicServerAddedToLibrary),
      );
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.musicServerLibraryError),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(id));
    }
  }

  Widget _libraryButton(Map<String, dynamic> track) {
    final id = track['id'] as String;
    return Consumer(
      builder: (context, ref, child) {
        final saved =
            ref
                .watch(musicServerTrackSavedProvider(_client.source(id)))
                .asData
                ?.value ==
            true;
        return AppIconButton(
          tooltip: saved
              ? context.l10n.musicServerInLibrary
              : context.l10n.musicServerAddToLibrary,
          icon: Icon(
            saved ? Icons.library_add_check : Icons.library_add_outlined,
          ),
          onPressed: saved || _saving.contains(id)
              ? null
              : () => _addToLibrary(track),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connection = ref.watch(musicServerConnectionProvider);
    final connected = connection.asData?.value == true;
    if (connected && !_loaded && !_busy) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
    final gap = context.tokens.gapLg;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.musicServerTitle),
        actions: [
          if (connected)
            IconButton(
              tooltip: l10n.networkRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () => _load(),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.all(gap),
          children: [
            Text(l10n.musicServerDescription),
            SizedBox(height: gap),
            if (!connected) ...[
              TextField(
                controller: _address,
                decoration: InputDecoration(labelText: l10n.networkAddress),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              SizedBox(height: gap),
              TextField(
                controller: _username,
                decoration: InputDecoration(labelText: l10n.networkUsername),
                autocorrect: false,
              ),
              SizedBox(height: gap),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.networkPassword),
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
              ),
              SizedBox(height: gap),
              FilledButton(
                onPressed: connection.isLoading
                    ? null
                    : () async {
                        await ref
                            .read(musicServerConnectionProvider.notifier)
                            .login(
                              _address.text,
                              _username.text,
                              _password.text,
                            );
                        _password.clear();
                      },
                child: Text(l10n.musicServerConnect),
              ),
            ] else ...[
              Text(_client.address),
              TextButton(
                onPressed: () async {
                  ++_generation;
                  _timer?.cancel();
                  try {
                    await (await ref
                            .read(musicPlayerControllerProvider)
                            .ensureInitialized())
                        ?.stop();
                  } catch (_) {}
                  try {
                    await ref
                        .read(musicServerConnectionProvider.notifier)
                        .logout();
                  } catch (_) {}
                  if (mounted) {
                    setState(() {
                      _loaded = false;
                      _tracks = [];
                      _sources = [];
                      _pending = [];
                      _source = null;
                      _job = null;
                      _busy = false;
                      _autoPrepared = false;
                      _sourceUnavailable = false;
                      _preparedMetadata = null;
                    });
                  }
                },
                child: Text(l10n.musicServerDisconnect),
              ),
              if (_sources.isNotEmpty) ...[
                SizedBox(height: gap),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _source?['id'] as String?,
                  decoration: InputDecoration(
                    labelText: l10n.musicServerSource,
                  ),
                  items: _sources
                      .map(
                        (s) => DropdownMenuItem(
                          value: s['id'] as String,
                          child: Text(
                            s['name'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (id) => setState(() {
                          _source = _sources.firstWhere((s) => s['id'] == id);
                          _quality =
                              (_source!['qualities'] as List).first as String;
                          final track = _trackForSource(_source);
                          _input.text = track?.id ?? '';
                          _sourceUnavailable =
                              widget.initialTrack != null && track == null;
                        }),
                ),
                SizedBox(height: gap),
                TextField(
                  controller: _input,
                  decoration: InputDecoration(
                    labelText: switch (_source?['type']) {
                      'url' => l10n.musicServerUrl,
                      'storage' => l10n.musicServerPath,
                      _ => l10n.musicServerTrackId,
                    },
                  ),
                  autocorrect: false,
                ),
                SizedBox(height: gap),
                TextField(
                  controller: _title,
                  decoration: InputDecoration(labelText: l10n.musicServerTrack),
                ),
                SizedBox(height: gap),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey(_source?['id']),
                  initialValue: _quality,
                  decoration: InputDecoration(
                    labelText: l10n.musicServerQuality,
                  ),
                  items: ((_source?['qualities'] as List?) ?? ['original'])
                      .cast<String>()
                      .map(
                        (q) => DropdownMenuItem(
                          value: q,
                          child: Text(
                            q,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _quality = value);
                  },
                ),
                SizedBox(height: gap),
                FilledButton.icon(
                  onPressed: _busy || _job != null ? null : () => _prepare(),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l10n.tooltipPlay),
                ),
                SizedBox(height: gap),
                OutlinedButton.icon(
                  onPressed: _busy || _job != null
                      ? null
                      : () => _prepare(save: true),
                  icon: const Icon(Icons.library_add_outlined),
                  label: Text(l10n.musicServerAddToLibrary),
                ),
              ],
              if (_job != null) ...[
                SizedBox(height: gap),
                Text(l10n.musicServerPreparing),
                LinearProgressIndicator(value: _progress),
                TextButton(onPressed: _cancel, child: Text(l10n.dialogCancel)),
              ],
              SizedBox(height: gap),
              ..._pending
                  .where((job) => job['id'] != _job?['id'])
                  .map(
                    (job) => ListTile(
                      leading: Icon(
                        job['state'] == 'failed'
                            ? Icons.error_outline
                            : Icons.hourglass_top,
                      ),
                      title: Text(
                        (job['title'] as String).isEmpty
                            ? l10n.musicServerTrack
                            : job['title'] as String,
                      ),
                      subtitle: Text(
                        job['state'] == 'failed'
                            ? l10n.musicServerError
                            : l10n.musicServerPreparing,
                      ),
                      onTap: _busy || job['state'] == 'failed'
                          ? null
                          : () {
                              ++_generation;
                              _timer?.cancel();
                              setState(() {
                                _job = job;
                                _addWhenReady = false;
                                _preparedMetadata = null;
                              });
                              unawaited(_poll());
                            },
                    ),
                  ),
              ..._tracks.map(
                (track) => ListTile(
                  leading: const Icon(Icons.music_note),
                  title: Text(
                    (track['title'] as String).isEmpty
                        ? l10n.musicServerTrack
                        : track['title'] as String,
                  ),
                  subtitle: Text(track['artist'] as String? ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _libraryButton(track),
                      AppIconButton(
                        tooltip: l10n.tooltipPlay,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () => _play(track),
                      ),
                    ],
                  ),
                  onTap: () => _play(track),
                ),
              ),
              if (_nextOffset != null)
                TextButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: Text(l10n.musicServerMore),
                ),
            ],
            if (_busy || connection.isLoading) const LinearProgressIndicator(),
            if (_sourceUnavailable)
              Padding(
                padding: EdgeInsets.only(top: gap),
                child: Text(l10n.musicServerSourceUnavailable),
              ),
            if (_failed || connection.hasError)
              Padding(
                padding: EdgeInsets.only(top: gap),
                child: Text(l10n.musicServerError),
              ),
          ],
        ),
      ),
    );
  }
}
