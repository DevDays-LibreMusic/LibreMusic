part of 'recommendations_screen.dart';

class RecommendationEditor extends ConsumerStatefulWidget {
  const RecommendationEditor({super.key, this.profile});
  final RecommendationProfile? profile;
  @override
  ConsumerState<RecommendationEditor> createState() =>
      _RecommendationEditorState();
}

class _RecommendationEditorState extends ConsumerState<RecommendationEditor> {
  late RecommendationProfile _profile =
      widget.profile ??
      RecommendationProfile(
        id: 'rec_${DateTime.now().microsecondsSinceEpoch}',
        name: '',
      );
  late final _fields = <String, TextEditingController>{
    for (final key in [
      'name',
      'genres',
      'excludedGenres',
      'artists',
      'excludedArtists',
      'folders',
      'minSeconds',
      'maxSeconds',
      'minYear',
      'maxYear',
      'repeatDays',
    ])
      key: TextEditingController(
        text: switch (_profile.toJson()[key]) {
          final List<Object?> value => value.join('; '),
          null => '',
          final value => '$value',
        },
      ),
  };
  bool _dirty = false, _busy = false, _saved = false;
  int _generation = 0;
  RecommendationResult? _result;
  String? _error;
  PlayableMedia? _seed;
  final _rated = <String>{};

  @override
  void dispose() {
    _generation++;
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _change(Map<String, dynamic> values) => setState(() {
    _profile = _profile.update(values);
    _dirty = true;
    _generation++;
    _busy = false;
    _result = null;
  });

  RecommendationProfile _read() {
    final data = <String, dynamic>{};
    for (final entry in _fields.entries) {
      final value = entry.value.text.trim();
      if ([
        'minSeconds',
        'maxSeconds',
        'minYear',
        'maxYear',
        'repeatDays',
      ].contains(entry.key)) {
        if (value.isNotEmpty &&
            (int.tryParse(value) == null || int.parse(value) < 0)) {
          throw const FormatException('Number');
        }
        data[entry.key] = value.isEmpty ? null : int.parse(value);
      } else if (entry.key == 'name') {
        data[entry.key] = value;
      } else {
        data[entry.key] = value
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
    final profile = _profile.update(data);
    if (!profile.valid) throw const FormatException('Range');
    return profile;
  }

  Future<void> _save() async {
    final profile = _read().update({
      'revision': _profile.revision + (_dirty ? 1 : 0),
    });
    await ref.read(recommendationProfilesProvider.notifier).save(profile);
    if (mounted) {
      setState(() {
        _profile = profile;
        _saved = true;
        _dirty = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on RecommendationCancelled {
      /* A newer request owns the screen. */
    } on FormatException {
      if (mounted) setState(() => _error = context.l10n.recInvalid);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.recFailure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    await _save();
    if (!mounted) return;
    final generation = ++_generation;
    final runtime = ref.read(musicPlayerRuntimeProvider);
    final result = await runtime.recommendations.generate(
      _profile,
      includeLocal: ref.read(settingsProvider).localLibraryEnabled,
      session: [?_seed],
      cancelled: () => !mounted || generation != _generation,
      loadSignals: (candidates) async => [
        ?await runtime.songAnalysis.loadSignal(
          session: [?_seed],
          candidates: candidates,
        ),
      ],
    );
    if (mounted && generation == _generation) {
      setState(() {
        _result = result;
        _rated.clear();
      });
    }
  }

  Future<void> _play({bool append = false}) async {
    final picks = _result!.picks;
    final runtime = ref.read(musicPlayerRuntimeProvider);
    runtime.recommendations.remember(_profile, picks);
    final player = ref.read(musicPlayerControllerProvider);
    if (append) {
      for (final pick in picks) {
        await player.addToQueue(
          runtime.recommendations.mediaFor(_profile, pick),
        );
      }
    } else {
      await player.setShuffle(false);
      await player.playAll(
        picks
            .map((p) => runtime.recommendations.mediaFor(_profile, p))
            .toList(),
      );
    }
  }

  Future<void> _playlist() => showAddTracksToPlaylistSheet(context, ref, [
    for (final pick in _result!.picks)
      Track(
        id:
            pick.media.displayMetadata['recommendationCollectionId']
                as String? ??
            pick.media.id,
        name: pick.media.title,
        artistName: pick.media.artist,
        albumName: pick.media.album,
        duration: pick.media.duration?.inSeconds ?? 0,
        genre: pick.media.genre,
        source:
            pick.media.displayMetadata['recommendationCollectionSource']
                as String? ??
            'local',
        explicit: pick.candidate.markedExplicit,
      ),
  ], playlistNamePrefill: _profile.name);

  Widget _field(String key, String label, {bool numeric = false}) => Padding(
    padding: EdgeInsets.only(bottom: context.tokens.gapMd),
    child: TextField(
      controller: _fields[key],
      enabled: !_busy,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {
        _dirty = true;
        _result = null;
        _error = null;
      }),
    ),
  );

  Widget _slider(String key, String label, double value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      Slider(
        value: value,
        divisions: 10,
        label: '${(value * 100).round()}%',
        onChanged: _busy ? null : (v) => _change({key: v}),
      ),
    ],
  );

  String _reason(RecommendationPick pick) {
    final entries = pick.parts.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final l = context.l10n;
    return switch (entries.firstOrNull?.key) {
      'discovery' => l.recReasonDiscovery,
      'familiar' => l.recReasonFamiliar,
      'history' => l.recReasonHistory,
      'sound' => l.recReasonSound,
      'similarity' => l.recReasonSimilar,
      _ => l.recReasonFilters,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final collections = ref.watch(libraryCollectionsProvider);
    final playlists = collections.playlists;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: l.recProfile,
            actions: [
              IconButton(
                tooltip: l.recSave,
                icon: const Icon(Icons.save_outlined),
                onPressed: _busy ? null : () => _run(_save),
              ),
            ],
          ),
          SliverPadding(
            padding: EdgeInsets.all(context.tokens.gapLg),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field('name', l.recName),
                  Text(l.recFilterHelp),
                  SizedBox(height: context.tokens.gapMd),
                  _field('genres', l.recGenres),
                  _field('excludedGenres', l.recExcludedGenres),
                  _field('artists', l.recArtists),
                  _field('excludedArtists', l.recExcludedArtists),
                  _field('folders', l.recFolders),
                  if (playlists.isNotEmpty) ...[
                    Text(l.recPlaylists),
                    for (final playlist in playlists)
                      CheckboxListTile(
                        title: Text(playlist.name),
                        value: _profile.playlistIds.contains(playlist.id),
                        onChanged: _busy
                            ? null
                            : (value) => _change({
                                'playlistIds': [
                                  ..._profile.playlistIds.where(
                                    (id) => id != playlist.id,
                                  ),
                                  if (value == true) playlist.id,
                                ],
                              }),
                      ),
                  ],
                  _field('minSeconds', l.recMinSeconds, numeric: true),
                  _field('maxSeconds', l.recMaxSeconds, numeric: true),
                  _field('minYear', l.recMinYear, numeric: true),
                  _field('maxYear', l.recMaxYear, numeric: true),
                  _field('repeatDays', l.recRepeatDays, numeric: true),
                  SwitchListTile(
                    title: Text(l.recUnknown),
                    value: _profile.excludeUnknown,
                    onChanged: _busy
                        ? null
                        : (v) => _change({'excludeUnknown': v}),
                  ),
                  SwitchListTile(
                    title: Text(l.recExplicit),
                    subtitle: Text(l.recExplicitHelp),
                    value: _profile.excludeMarkedExplicit,
                    onChanged: _busy
                        ? null
                        : (v) => _change({'excludeMarkedExplicit': v}),
                  ),
                  _slider('discovery', l.recDiscovery, _profile.discovery),
                  _slider('diversity', l.recDiversity, _profile.diversity),
                  _slider('history', l.recHistory, _profile.history),
                  _slider('sound', l.recSound, _profile.sound),
                  Text(l.recSoundHelp),
                  SwitchListTile(
                    title: Text(l.recLearning),
                    subtitle: Text(l.recLearningHelp),
                    value: _profile.learning,
                    onChanged: _busy ? null : (v) => _change({'learning': v}),
                  ),
                  if (_seed != null)
                    ListTile(
                      title: Text(_seed!.title),
                      subtitle: Text(l.recSeed),
                      trailing: IconButton(
                        tooltip: l.recClearSeed,
                        icon: const Icon(Icons.close),
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _seed = null;
                                _result = null;
                              }),
                      ),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : () => _run(_generate),
                    child: Text(l.recGenerate),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_result case final result?) ...[
                    Text(l.recResult(result.picks.length, result.requested)),
                    if (result.picks.length < result.requested)
                      Text(l.recShortage),
                    if (result.picks.isNotEmpty)
                      Wrap(
                        spacing: context.tokens.gapSm,
                        children: [
                          FilledButton(
                            onPressed: _busy ? null : () => _run(() => _play()),
                            child: Text(l.recPlay),
                          ),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() => _play(append: true)),
                            child: Text(l.recQueue),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _run(_playlist),
                            child: Text(l.recPlaylist),
                          ),
                        ],
                      ),
                    for (final pick in result.picks)
                      Card(
                        child: Padding(
                          padding: EdgeInsets.all(context.tokens.gapSm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                pick.media.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(pick.media.artist),
                              Text(_reason(pick)),
                              Wrap(
                                children: [
                                  for (final positive in [true, false])
                                    IconButton(
                                      tooltip: positive ? l.recMore : l.recLess,
                                      icon: Icon(
                                        positive
                                            ? Icons.thumb_up_outlined
                                            : Icons.thumb_down_outlined,
                                      ),
                                      onPressed:
                                          _busy ||
                                              !_profile.learning ||
                                              _rated.contains(
                                                pick.candidate.key,
                                              )
                                          ? null
                                          : () => _run(() async {
                                              await ref
                                                  .read(
                                                    musicPlayerRuntimeProvider,
                                                  )
                                                  .recommendations
                                                  .rate(
                                                    _profile,
                                                    pick,
                                                    positive ? 1 : 0,
                                                  );
                                              if (mounted) {
                                                setState(
                                                  () => _rated.add(
                                                    pick.candidate.key,
                                                  ),
                                                );
                                              }
                                            }),
                                    ),
                                  IconButton(
                                    tooltip: l.recExclude,
                                    icon: const Icon(Icons.block),
                                    onPressed: _busy
                                        ? null
                                        : () => _run(() async {
                                            _profile = _profile.update({
                                              'excludedTracks': [
                                                ..._profile.excludedTracks,
                                                pick.candidate.key,
                                              ],
                                            });
                                            _dirty = true;
                                            await _save();
                                            if (mounted) {
                                              setState(() => _result = null);
                                            }
                                          }),
                                  ),
                                  IconButton(
                                    tooltip: l.recSimilar,
                                    icon: const Icon(Icons.radio),
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() {
                                            _seed = pick.media;
                                            _result = null;
                                          }),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (widget.profile != null || _saved) ...[
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final updated = await ref
                                  .read(musicPlayerRuntimeProvider)
                                  .recommendations
                                  .reset(_profile.id);
                              if (!mounted) return;
                              if (updated != null) {
                                _profile = _profile.update({
                                  'revision': updated.revision,
                                });
                              }
                              ref.invalidate(recommendationProfilesProvider);
                              setState(() => _result = null);
                            }),
                      child: Text(l.recReset),
                    ),
                    if (_profile.excludedTracks.isNotEmpty)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _change({'excludedTracks': <String>[]}),
                        child: Text(l.recClearExclusions),
                      ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await ref
                                  .read(recommendationProfilesProvider.notifier)
                                  .delete(_profile.id);
                              if (context.mounted) Navigator.of(context).pop();
                            }),
                      child: Text(l.recDelete),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
