import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/wave_session_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/widgets/lastfm_account_sheet.dart';
import 'package:mornye/widgets/mornye_player_favorite_button.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/wave_controls.dart';

class LastfmWaveCard extends ConsumerWidget {
  const LastfmWaveCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => PlayerArtworkTheme(
    artUri: ref.watch(currentMediaItemProvider).value?.artUri?.toString(),
    child: const _WaveHero(),
  );
}

class _WaveHero extends ConsumerWidget {
  const _WaveHero();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wave = ref.watch(waveSessionProvider);
    final account = ref.watch(lastfmAccountStateProvider).value;
    final media = ref.watch(currentMediaItemProvider).value;
    final playing = ref.watch(playbackPlayingProvider);
    final loading = wave.busy || ref.watch(playbackLoadingProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final personal = wave.context.kind == WaveKind.personal;
    final onboarding =
        wave.needsSeeds ||
        wave.loaded &&
            wave.seedArtists.isEmpty &&
            account?.connected != true &&
            !wave.active;
    void openPlayer() => Navigator.of(
      context,
      rootNavigator: true,
    ).push(NowPlayingRoute(child: const NowPlayingScreen()));
    final compact = MediaQuery.sizeOf(context).height < 850;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer,
            colors.surface,
            colors.secondaryContainer.withValues(alpha: .65),
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!personal)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.only(left: 14),
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                waveKindLabel(context, wave.context.kind),
                                style: theme.textTheme.labelSmall,
                              ),
                              Text(
                                wave.context.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: waveText(
                            context,
                            'Вернуться к моей волне',
                            'Return to my wave',
                          ),
                          onPressed: () => ref
                              .read(waveSessionProvider.notifier)
                              .returnToPersonal(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Spacer(),
              IconButton(
                tooltip: waveText(
                  context,
                  'Настройки волны и Last.fm',
                  'Wave and Last.fm settings',
                ),
                onPressed: () => showWaveSettings(context),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 20),
          if (onboarding) ...[
            Text(
              waveText(context, 'Музыка под твой вкус', 'Music for your taste'),
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              waveText(
                context,
                account?.connected == true
                    ? 'Выбери любимых исполнителей, чтобы начать подбор.'
                    : 'Подключи Last.fm или выбери любимых исполнителей.',
                account?.connected == true
                    ? 'Choose favorite artists to get started.'
                    : 'Connect Last.fm or choose your favorite artists.',
              ),
            ),
            const SizedBox(height: 20),
            if (account?.connected != true)
              FilledButton(
                onPressed: () => showLastfmAccount(context),
                child: Text(
                  waveText(context, 'Подключить Last.fm', 'Connect Last.fm'),
                ),
              ),
            TextButton(
              onPressed: () => showWaveArtistPicker(context),
              child: Text(
                waveText(context, 'Выбрать исполнителей', 'Choose artists'),
              ),
            ),
          ] else ...[
            if (personal)
              Text(
                waveText(context, 'Моя волна', 'My wave'),
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              )
            else
              InkWell(
                onTap: media?.artist?.isNotEmpty == true
                    ? () =>
                          navigateToArtist(context, artistName: media!.artist!)
                    : null,
                child: Text(
                  media?.artist ?? wave.context.title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            SizedBox(height: compact ? 16 : 24),
            if (!personal && media != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox.square(
                    dimension: compact ? 72 : 120,
                    child: PlayerArtwork(
                      artUri: media.artUri?.toString(),
                      colorScheme: colors,
                    ),
                  ),
                ),
              ),
            if (!personal) SizedBox(height: compact ? 12 : 20),
            Center(
              child: SizedBox.square(
                dimension: personal ? (compact ? 100 : 120) : 64,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: loading
                      ? null
                      : () => ref.read(waveSessionProvider.notifier).toggle(),
                  child: loading
                      ? SizedBox.square(
                          dimension: 30,
                          child: CircularProgressIndicator(
                            color: colors.primary,
                          ),
                        )
                      : Icon(
                          playing && wave.active
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: personal ? 58 : 36,
                        ),
                ),
              ),
            ),
            SizedBox(height: compact ? 12 : 20),
            if (media != null)
              Material(
                color: colors.surface.withValues(alpha: .8),
                borderRadius: BorderRadius.circular(28),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: openPlayer,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                media.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                media.artist ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        MornyePlayerFavoriteButton(mediaItem: media),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: () => showWaveSettings(context),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(
                  '${waveText(context, 'Настроить волну', 'Tune wave')} · ${waveModeLabel(context, wave.mode)}',
                ),
              ),
            ),
          ],
          if (wave.offline)
            Center(
              child: Chip(
                avatar: const Icon(Icons.wifi_off, size: 18),
                label: Text(waveText(context, 'Без сети', 'Offline')),
              ),
            ),
          if (account?.needsReauthentication == true)
            TextButton.icon(
              onPressed: () => showLastfmAccount(context),
              icon: const Icon(Icons.account_circle_outlined),
              label: Text(
                waveText(
                  context,
                  'Войдите в Last.fm снова — музыка продолжит играть',
                  'Sign in to Last.fm again — music keeps playing',
                ),
              ),
            ),
          if (wave.seedUnavailable)
            FilledButton.icon(
              onPressed: loading
                  ? null
                  : () => ref.read(waveSessionProvider.notifier).playSimilar(),
              icon: const Icon(Icons.waves),
              label: Text(
                waveText(context, 'Включить похожее', 'Play similar music'),
              ),
            ),
          if (wave.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Text(
                    wave.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.error),
                  ),
                  TextButton.icon(
                    onPressed: loading
                        ? null
                        : () => ref.read(waveSessionProvider.notifier).retry(),
                    icon: const Icon(Icons.refresh),
                    label: Text(waveText(context, 'Повторить', 'Retry')),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        ShellNavigationService.requestTab(ShellTab.library),
                    icon: const Icon(Icons.library_music_outlined),
                    label: Text(
                      waveText(context, 'Открыть библиотеку', 'Open Library'),
                    ),
                  ),
                ],
              ),
            ),
          if (!onboarding) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 76,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _DirectionCard(
                    label: waveText(context, 'Открытия', 'Discoveries'),
                    icon: Icons.auto_awesome,
                    onTap: () => ref
                        .read(waveSessionProvider.notifier)
                        .setMode(WaveMode.discovery),
                  ),
                  for (final genre in ['Rock', 'Electronic', 'Hip-hop', 'Jazz'])
                    _DirectionCard(
                      label: genre,
                      icon: Icons.waves,
                      onTap: () => ref
                          .read(waveSessionProvider.notifier)
                          .start(
                            WaveContext(kind: WaveKind.genre, title: genre),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectionCard extends StatelessWidget {
  const _DirectionCard({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: FilledButton.tonal(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(label)],
      ),
    ),
  );
}
