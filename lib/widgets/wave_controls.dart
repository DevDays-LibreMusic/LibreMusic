import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/widgets/lastfm_account_sheet.dart';

String waveText(BuildContext context, String ru, String en) =>
    Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

String waveKindLabel(BuildContext context, WaveKind kind) => switch (kind) {
  WaveKind.personal => waveText(context, 'Моя волна', 'My wave'),
  WaveKind.track => waveText(context, 'Волна по треку', 'Wave by track'),
  WaveKind.artist => waveText(
    context,
    'Волна по исполнителю',
    'Wave by artist',
  ),
  WaveKind.album => waveText(context, 'Волна по альбому', 'Wave by album'),
  WaveKind.genre => waveText(context, 'Волна по жанру', 'Wave by genre'),
};

String waveModeLabel(BuildContext context, WaveMode mode) => switch (mode) {
  WaveMode.familiar => waveText(context, 'Знакомое', 'Familiar'),
  WaveMode.balanced => waveText(context, 'Баланс', 'Balance'),
  WaveMode.discovery => waveText(context, 'Открытия', 'Discoveries'),
};

class WavePlayerHeading extends ConsumerWidget {
  const WavePlayerHeading({super.key, this.color});
  final Color? color;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(waveSessionProvider);
    if (!state.active) {
      return Text(
        waveText(context, 'Сейчас играет', 'Now playing'),
        style: TextStyle(color: color),
      );
    }
    return Semantics(
      label:
          '${waveKindLabel(context, state.context.kind)} ${state.context.title}',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              waveKindLabel(context, state.context.kind),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
            if (state.context.kind != WaveKind.personal)
              Text(
                state.context.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class WaveStartButton extends ConsumerStatefulWidget {
  const WaveStartButton({
    super.key,
    required this.wave,
    this.enabled = true,
    this.onStarted,
    this.currentItemId,
  });
  final WaveContext wave;
  final String? currentItemId;
  final bool enabled;
  final VoidCallback? onStarted;
  @override
  ConsumerState<WaveStartButton> createState() => _WaveStartButtonState();
}

class _WaveStartButtonState extends ConsumerState<WaveStartButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final wave = widget.wave;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 64),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        onPressed: !widget.enabled || busy
            ? null
            : () async {
                setState(() => busy = true);
                final controller = ref.read(waveSessionProvider.notifier);
                try {
                  await controller.start(
                    wave,
                    currentItemId: widget.currentItemId,
                  );
                } finally {
                  if (mounted) setState(() => busy = false);
                }
                if (!context.mounted) return;
                final state = ref.read(waveSessionProvider);
                if (state.error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.error!),
                      action: state.seedUnavailable
                          ? SnackBarAction(
                              label: waveText(
                                context,
                                'Похожее',
                                'Play similar',
                              ),
                              onPressed: () => controller.playSimilar(),
                            )
                          : null,
                    ),
                  );
                } else {
                  widget.onStarted?.call();
                }
              },
        child: Row(
          children: [
            const Icon(Icons.waves_rounded),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    waveKindLabel(context, wave.kind),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    wave.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CurrentTrackWaveActions extends ConsumerWidget {
  const CurrentTrackWaveActions({super.key, required this.item});
  final MediaItem item;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerCollectionTrackProvider(item)).value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        WaveStartButton(
          currentItemId: item.id,
          wave: WaveContext(
            kind: WaveKind.track,
            title: item.title,
            artist: item.artist ?? '',
            track: track,
          ),
          enabled: track != null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => showWaveSettings(context),
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(
                    waveText(context, 'Настроить волну', 'Tune wave'),
                  ),
                ),
              ),
              if (track != null)
                PopupMenuButton<String>(
                  tooltip: waveText(
                    context,
                    'Действия с треком',
                    'Track actions',
                  ),
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (action) {
                    if (action == 'save') {
                      ref.read(waveSessionProvider.notifier).saveTrack(track);
                    } else {
                      excludeFromWave(
                        context,
                        ref,
                        track,
                        artist: action == 'artist',
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'track',
                      child: Text(
                        waveText(
                          context,
                          'Не предлагать этот трек',
                          'Do not recommend this track',
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'artist',
                      child: Text(
                        waveText(
                          context,
                          'Не предлагать исполнителя',
                          'Do not recommend this artist',
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'save',
                      child: Text(
                        waveText(
                          context,
                          'Сохранить на устройстве',
                          'Save on device',
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

void excludeFromWave(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  required bool artist,
}) {
  final controller = ref.read(waveSessionProvider.notifier);
  if (artist) {
    controller.excludeArtist(track.artistName);
  } else {
    controller.excludeTrack(track);
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        waveText(
          context,
          'Больше не будем предлагать',
          'Removed from recommendations',
        ),
      ),
      action: SnackBarAction(
        label: waveText(context, 'Отменить', 'Undo'),
        onPressed: () {
          if (artist) {
            controller.unblockArtist(waveArtistKey(track.artistName));
          } else {
            controller.unblockTrack(waveTrackKey(track.artistName, track.name));
          }
        },
      ),
    ),
  );
}

Future<void> showWaveSettings(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: .85,
        child: WaveSettingsBody(),
      ),
    );

class WaveSettingsPage extends StatelessWidget {
  const WaveSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        waveText(context, 'Моя волна и Last.fm', 'My wave and Last.fm'),
      ),
    ),
    body: const SafeArea(child: WaveSettingsBody()),
  );
}

class WaveSettingsBody extends ConsumerWidget {
  const WaveSettingsBody({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(waveSessionProvider);
    final controller = ref.read(waveSessionProvider.notifier);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        Text(
          waveText(context, 'Настроить волну', 'Tune your wave'),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        for (final mode in WaveMode.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              state.mode == mode
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(waveModeLabel(context, mode)),
            subtitle: Text(switch (mode) {
              WaveMode.familiar => waveText(
                context,
                'Больше любимого и знакомого',
                'More favorites and familiar music',
              ),
              WaveMode.balanced => waveText(
                context,
                'Знакомая музыка и новые находки',
                'Familiar music with new discoveries',
              ),
              WaveMode.discovery => waveText(
                context,
                'Больше новых треков и исполнителей',
                'More new songs and artists',
              ),
            }),
            onTap: () => controller.setMode(mode),
          ),
        if (state.context.kind != WaveKind.personal)
          TextButton.icon(
            onPressed: () => controller.returnToPersonal(),
            icon: const Icon(Icons.waves),
            label: Text(
              waveText(context, 'Вернуться к моей волне', 'Return to my wave'),
            ),
          ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_outline),
          title: const Text('Last.fm'),
          subtitle: Text(
            waveText(
              context,
              'Аккаунт, прослушивания и лайки',
              'Account, listening history and likes',
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLastfmAccount(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.people_outline),
          title: Text(
            waveText(context, 'Любимые исполнители', 'Favorite artists'),
          ),
          subtitle: Text(
            state.seedArtists.isEmpty
                ? waveText(
                    context,
                    'Выбрать для начала',
                    'Choose to get started',
                  )
                : state.seedArtists.join(', '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => showWaveArtistPicker(context),
        ),
        const Divider(height: 32),
        Text(
          waveText(context, 'Музыка на устройстве', 'Music on this device'),
          style: theme.textTheme.titleLarge,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(waveText(context, 'Временный кэш', 'Temporary cache')),
          subtitle: Text('${(state.cacheBytes / 1048576).round()} MB'),
          trailing: TextButton(
            onPressed: () => controller.clearCache(),
            child: Text(waveText(context, 'Очистить', 'Clear')),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final mb in [256, 512, 1024, 2048])
              ChoiceChip(
                label: Text(mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB'),
                selected: state.cacheLimitBytes == mb * 1048576,
                onSelected: (_) => controller.setCacheLimit(mb * 1048576),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            waveText(
              context,
              'Готовить музыку через мобильную сеть',
              'Prepare music on mobile data',
            ),
          ),
          subtitle: Text(
            waveText(
              context,
              'При выключении дополнительная фоновая загрузка — только по Wi-Fi. Запущенная музыка использует доступную сеть.',
              'When off, additional background downloads use Wi-Fi only. Playback uses the available connection.',
            ),
          ),
          value: state.backgroundMobile,
          onChanged: controller.setBackgroundMobile,
        ),
        const Divider(height: 32),
        Text(
          waveText(context, 'Не предлагать', 'Excluded from recommendations'),
          style: theme.textTheme.titleLarge,
        ),
        if (state.blockedTracks.isEmpty && state.blockedArtists.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              waveText(
                context,
                'Пока ничего не исключено',
                'Nothing excluded yet',
              ),
            ),
          ),
        for (final entry in state.blockedTracks.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.music_note),
            title: Text(entry.value),
            trailing: IconButton(
              tooltip: waveText(
                context,
                'Вернуть в рекомендации',
                'Allow recommendations',
              ),
              icon: const Icon(Icons.undo),
              onPressed: () => controller.unblockTrack(entry.key),
            ),
          ),
        for (final artist in state.blockedArtists)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person),
            title: Text(artist),
            trailing: IconButton(
              tooltip: waveText(
                context,
                'Вернуть в рекомендации',
                'Allow recommendations',
              ),
              icon: const Icon(Icons.undo),
              onPressed: () => controller.unblockArtist(artist),
            ),
          ),
      ],
    );
  }
}

Future<void> showWaveArtistPicker(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: .85,
        child: _WaveArtistPicker(),
      ),
    );

class _WaveArtistPicker extends ConsumerStatefulWidget {
  const _WaveArtistPicker();
  @override
  ConsumerState<_WaveArtistPicker> createState() => _WaveArtistPickerState();
}

class _WaveArtistPickerState extends ConsumerState<_WaveArtistPicker> {
  final _query = TextEditingController();
  late List<String> _selected;
  List<String> _results = [];
  bool _searching = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _selected = [...ref.read(waveSessionProvider).seedArtists];
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final artists = await ref
          .read(waveSessionProvider.notifier)
          .searchArtists(query);
      if (!mounted || generation != _generation) return;
      setState(() => _results = artists);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = waveText(
            context,
            'Не удалось найти исполнителей. Попробуй ещё раз.',
            'Could not find artists. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      8,
      24,
      16 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          waveText(context, 'С чего начнём?', 'Where shall we start?'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          waveText(
            context,
            'Выбери несколько любимых исполнителей для разнообразной волны.',
            'Choose a few favorite artists for a varied wave.',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            labelText: waveText(context, 'Найти исполнителя', 'Find an artist'),
            suffixIcon: IconButton(
              tooltip: waveText(context, 'Поиск', 'Search'),
              onPressed: () => _search(_query.text),
              icon: const Icon(Icons.search),
            ),
          ),
        ),
        if (_searching) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Expanded(
          child: ListView(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final artist in _selected)
                    InputChip(
                      label: Text(artist),
                      onDeleted: () => setState(() => _selected.remove(artist)),
                    ),
                ],
              ),
              for (final artist in _results)
                CheckboxListTile(
                  title: Text(artist),
                  value: _selected.contains(artist),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(artist);
                    } else {
                      _selected.remove(artist);
                    }
                  }),
                ),
            ],
          ),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () async {
                  final controller = ref.read(waveSessionProvider.notifier);
                  await controller.setSeedArtists(_selected);
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text(waveText(context, 'Готово', 'Done')),
        ),
      ],
    ),
  );
}

class WaveHistorySection extends ConsumerWidget {
  const WaveHistorySection({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contexts = ref.watch(
      waveSessionProvider.select((s) => s.recentContexts),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(
              waveText(context, 'История прослушиваний', 'Listening history'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ListeningStatisticsScreen(),
              ),
            ),
          ),
          if (contexts.isNotEmpty)
            Text(
              waveText(context, 'Недавние волны', 'Recent waves'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          for (final wave in contexts.take(5))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.waves),
              title: Text(
                wave.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(waveKindLabel(context, wave.kind)),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => ref.read(waveSessionProvider.notifier).start(wave),
            ),
        ],
      ),
    );
  }
}
