import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recommendation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/recommendations/recommendation_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/collection_scaffold.dart';

class RecommendationFlowScreen extends ConsumerStatefulWidget {
  const RecommendationFlowScreen({super.key});

  @override
  ConsumerState<RecommendationFlowScreen> createState() => _FlowState();
}

class _FlowState extends ConsumerState<RecommendationFlowScreen> {
  final _scroll = ScrollController();
  RecommendationProfile _profile = const RecommendationProfile(
    id: 'recommendation_flow',
    name: 'Recommendation flow',
  );
  RecommendationResult? _result;
  bool _loading = true, _playing = false, _failed = false;
  bool _initialized = false;
  int _generation = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final profiles = await ref.read(recommendationProfilesProvider.future);
      if (!mounted) return;
      _profile =
          profiles.where((p) => p.id == _profile.id).firstOrNull ?? _profile;
      _initialized = true;
      await _generate();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _change(String key, List<String> values) {
    _debounce?.cancel();
    _generation++;
    setState(() {
      _profile = _profile.update({
        key: values,
        'revision': _profile.revision + 1,
      });
      _result = null;
      _loading = true;
      _failed = false;
    });
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_generate()),
    );
  }

  Future<void> _generate() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _result = null;
    });
    try {
      final result = await ref
          .read(recommendationServiceProvider)
          .generate(
            _profile,
            includeLocal: ref.read(settingsProvider).localLibraryEnabled,
            cancelled: () => !mounted || generation != _generation,
          );
      if (mounted && generation == _generation) {
        setState(() => _result = result);
      }
    } on RecommendationCancelled {
      // A newer filter selection owns the screen.
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _play([int index = 0]) async {
    final picks = _result?.picks;
    if (_playing || picks == null || picks.isEmpty) return;
    setState(() => _playing = true);
    try {
      final profile = _profile.update({'name': context.l10n.recFlowTitle});
      final profiles = ref.read(recommendationProfilesProvider.notifier);
      await profiles.save(profile);
      if (!mounted) return;
      await profiles.activate(profile.id);
      if (!mounted) return;
      ref.read(settingsProvider.notifier).setAutoplay(true);
      final service = ref.read(musicPlayerRuntimeProvider).recommendations;
      final ordered = [...picks.skip(index), ...picks.take(index)];
      service.remember(profile, ordered);
      final player = ref.read(musicPlayerControllerProvider);
      await player.setShuffle(false);
      await player.setRepeatMode(AudioServiceRepeatMode.none);
      await player.playAll(
        ordered.map((p) => service.mediaFor(profile, p)).toList(),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.recFailure)));
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Widget _chips(
    String key,
    List<String> selected,
    Map<String, String> options,
  ) {
    return Wrap(
      spacing: context.tokens.gapSm,
      runSpacing: context.tokens.gapSm,
      children: [
        AppChoiceChip(
          label: Text(context.l10n.recFlowAny),
          selected: selected.isEmpty,
          onSelected: !_initialized || _playing
              ? null
              : (_) => _change(key, []),
        ),
        for (final option in options.entries)
          AppChoiceChip(
            label: Text(option.value),
            selected: selected.contains(option.key),
            onSelected: !_initialized || _playing
                ? null
                : (value) => _change(key, [
                    ...selected.where((v) => v != option.key),
                    if (value) option.key,
                  ]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final genres = ref.watch(recommendationGenresProvider);
    final picks = _result?.picks ?? [];
    return CollectionScaffold(
      scrollController: _scroll,
      isSelectionMode: false,
      onExitSelectionMode: () {},
      appBar: AppSliverHeader.page(
        title: l.recFlowTitle,
        actions: [
          IconButton(
            tooltip: l.recFlowRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _playing
                ? null
                : () {
                    ref.invalidate(recommendationGenresProvider);
                    unawaited(_generate());
                  },
          ),
        ],
      ),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.all(context.tokens.gapLg),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: context.tokens.gapMd,
              children: [
                Text(l.recFlowSubtitle),
                Text(
                  l.recFlowMood,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _chips('moods', _profile.moods, {
                  'calm': l.recFlowCalm,
                  'energetic': l.recFlowEnergetic,
                  'bright': l.recFlowBright,
                  'melancholic': l.recFlowMelancholic,
                }),
                Text(l.recFlowHint),
                Text(
                  l.recFlowGenres,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                genres.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => TextButton(
                    onPressed: () =>
                        ref.invalidate(recommendationGenresProvider),
                    child: Text(l.recRetry),
                  ),
                  data: (items) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (items.isEmpty) Text(l.recFlowNoGenres),
                      _chips('genres', _profile.genres, {
                        for (final genre in {...items, ..._profile.genres})
                          genre: genre,
                      }),
                    ],
                  ),
                ),
                Text(l.recFlowApplyHint),
                FilledButton.icon(
                  onPressed: _loading || _playing || picks.isEmpty
                      ? null
                      : () => _play(),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l.recFlowPlay),
                ),
                if (_loading || _playing) const LinearProgressIndicator(),
                if (_failed) ...[
                  Text(l.recFailure),
                  TextButton(
                    onPressed: _initialized ? _generate : _initialize,
                    child: Text(l.recRetry),
                  ),
                ] else if (!_loading && picks.isEmpty)
                  Text(l.recFlowEmpty),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: picks.length,
          itemBuilder: (context, index) {
            final media = picks[index].media;
            return ListTile(
              title: Text(media.title),
              subtitle: Text(
                [
                  media.artist,
                  if (media.genre?.isNotEmpty ?? false) media.genre!,
                ].join(' · '),
              ),
              leading: Text('${index + 1}'),
              trailing: IconButton(
                tooltip: l.recPlay,
                icon: const Icon(Icons.play_arrow),
                onPressed: _playing ? null : () => _play(index),
              ),
              onTap: _playing ? null : () => _play(index),
            );
          },
        ),
      ],
    );
  }
}
