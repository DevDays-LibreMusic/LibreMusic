import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/discovery_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/music_server_screen.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/error_card.dart';

import 'package:mornye/widgets/track_detail_actions.dart';

String _releaseDateLabel(BuildContext context, String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:$|T)').hasMatch(value)) return value;
  final day = value.substring(0, 10);
  final date = DateTime.tryParse(day);
  if (date == null || date.toIso8601String().substring(0, 10) != day) {
    return value;
  }
  return DateFormat.yMMMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).format(date);
}

enum _ReleaseType { all, tracks, albums }

/// An online catalog. Reading the page never resolves or downloads audio.
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  DiscoveryKind _kind = DiscoveryKind.newReleases;
  String _genreId = '0';
  String? _genreName;
  _ReleaseType _releaseType = _ReleaseType.all;

  DiscoveryQuery get _query => DiscoveryQuery(kind: _kind, genreId: _genreId);

  List<DiscoveryEntry> _visibleEntries(DiscoveryFeed feed) {
    if (_kind != DiscoveryKind.newReleases ||
        _releaseType == _ReleaseType.all) {
      return feed.entries;
    }
    return feed.entries
        .where(
          (entry) =>
              entry.track.isAlbumItem == (_releaseType == _ReleaseType.albums),
        )
        .toList();
  }

  Future<void> _refresh() async {
    final query = _query;
    ref.invalidate(discoverySourceProvider);
    try {
      await ref.read(discoveryFeedProvider(query).future);
    } catch (_) {
      // The feed renders the error, or the last successful cached response.
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(discoveryCatalogProvider);
    final feed = ref.watch(discoveryFeedProvider(_query));
    final l10n = context.l10n;
    return Scaffold(
      body: AppRefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            AppSliverHeader.tabRoot(
              title: l10n.discoveryTitle,
              alignToContent: true,
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l10n.discoveryDescription),
                          const SizedBox(height: 16),
                          SegmentedButton<DiscoveryKind>(
                            segments: [
                              ButtonSegment(
                                value: DiscoveryKind.newReleases,
                                label: Text(l10n.discoveryNewReleases),
                                icon: const Icon(Icons.new_releases_outlined),
                              ),
                              ButtonSegment(
                                value: DiscoveryKind.trends,
                                label: Text(l10n.discoveryTrends),
                                icon: const Icon(Icons.trending_up),
                              ),
                            ],
                            selected: {_kind},
                            onSelectionChanged: (selection) =>
                                setState(() => _kind = selection.single),
                          ),
                          const SizedBox(height: 12),
                          if (_kind == DiscoveryKind.newReleases) ...[
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final type in _ReleaseType.values)
                                  ChoiceChip(
                                    key: ValueKey('release-type-${type.name}'),
                                    label: Text(switch (type) {
                                      _ReleaseType.all => l10n.libraryFilterAll,
                                      _ReleaseType.tracks => l10n.searchTracks,
                                      _ReleaseType.albums => l10n.searchAlbums,
                                    }),
                                    selected: _releaseType == type,
                                    onSelected: (_) =>
                                        setState(() => _releaseType = type),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                          catalog.when(
                            loading: () => const LinearProgressIndicator(),
                            error: (_, _) => _DiscoveryError(
                              message: l10n.discoveryGenresError,
                              onRetry: () =>
                                  ref.invalidate(discoverySourceProvider),
                            ),
                            data: (data) => SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  if (!data.genres.any(
                                    (genre) => genre.id == _genreId,
                                  ))
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        end: 8,
                                      ),
                                      child: InputChip(
                                        label: Text(
                                          _genreName ??
                                              (_genreId == '0'
                                                  ? l10n.discoveryAllGenres
                                                  : _genreId),
                                        ),
                                        selected: true,
                                        onDeleted: () => setState(() {
                                          _genreId = '0';
                                          _genreName = null;
                                        }),
                                      ),
                                    ),
                                  for (final genre in data.genres)
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        end: 8,
                                      ),
                                      child: ChoiceChip(
                                        label: Text(
                                          genre.id == '0'
                                              ? l10n.discoveryAllGenres
                                              : genre.name,
                                        ),
                                        selected: _genreId == genre.id,
                                        onSelected: (_) => setState(() {
                                          _genreId = genre.id;
                                          _genreName = genre.name;
                                        }),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (catalog.value?.isStale == true &&
                              feed.value?.isStale != true) ...[
                            const SizedBox(height: 8),
                            Text(l10n.discoveryStale),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton(
                                onPressed: _refresh,
                                child: Text(l10n.discoveryRetry),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  ...feed.when(
                    loading: () => [
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: AppLoadingIndicator()),
                        ),
                      ),
                    ],
                    error: (_, _) => [
                      SliverToBoxAdapter(
                        child: _DiscoveryError(
                          message: l10n.discoveryLoadError,
                          onRetry: _refresh,
                        ),
                      ),
                    ],
                    data: (data) {
                      final entries = _visibleEntries(data);
                      return [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _DiscoverySources(feed: data, kind: _kind),
                                Text(
                                  l10n.discoveryUpdatedAt(
                                    DateFormat.yMd(
                                      Localizations.localeOf(
                                        context,
                                      ).toLanguageTag(),
                                    ).add_Hm().format(data.fetchedAt.toLocal()),
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (data.isStale) ...[
                                  const SizedBox(height: 8),
                                  Text(l10n.discoveryStale),
                                  TextButton(
                                    onPressed: _refresh,
                                    child: Text(l10n.discoveryRetry),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        if (entries.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(l10n.discoveryEmpty),
                            ),
                          ),
                        SliverList.builder(
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return _DiscoveryTrackTile(
                              key: ValueKey(
                                '${_kind.name}:$_genreId:${entry.track.source}:${entry.track.itemType}:${entry.track.id}',
                              ),
                              track: entry.track,
                              canListen: _kind == DiscoveryKind.trends,
                              showItemType: _kind == DiscoveryKind.newReleases,
                              position: entry.position,
                              sourceName: data.sourceName,
                              origins: entry.origins,
                            );
                          },
                        ),
                      ];
                    },
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: context.navBarBottomInset + 24),
            ),
          ],
        ),
      ),
    );
  }
}

String _regionLabel(BuildContext context, String region) => switch (region) {
  'mixed' => context.l10n.discoveryMixedRegion,
  'global' || 'world' => context.l10n.discoveryGlobalRegion,
  'auto' || '' => context.l10n.discoveryUnknownRegion,
  _ => region.toUpperCase(),
};

class _DiscoverySources extends StatelessWidget {
  const _DiscoverySources({required this.feed, required this.kind});
  final DiscoveryFeed feed;
  final DiscoveryKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final partial = feed.sources.any(
      (source) => source.isUnavailable || source.isStale,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (partial && !feed.isStale)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l10n.discoveryPartial),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          title: Text(l10n.discoverySources),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                kind == DiscoveryKind.trends
                    ? l10n.discoveryRankingExplanation
                    : l10n.discoveryRecentExplanation,
              ),
            ),
            const SizedBox(height: 8),
            if (feed.sources.isEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  l10n.discoverySourceRegion(
                    feed.sourceName,
                    _regionLabel(context, feed.region),
                  ),
                ),
              ),
            for (final source in feed.sources)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      source.isUnavailable
                          ? Icons.cloud_off_outlined
                          : source.isStale
                          ? Icons.history
                          : Icons.check_circle_outline,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          l10n.discoverySourceRegion(
                            source.sourceName,
                            _regionLabel(context, source.region),
                          ),
                          source.isUnavailable
                              ? l10n.discoverySourceUnavailable
                              : source.isStale
                              ? l10n.discoverySourceCached
                              : l10n.discoverySourceFresh,
                        ].join(' · '),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DiscoveryOrigins extends StatelessWidget {
  const _DiscoveryOrigins({required this.origins, required this.fallback});
  final List<DiscoveryOrigin> origins;
  final String fallback;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: origins.isEmpty
        ? [Text(fallback)]
        : [
            for (final origin in origins)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    context.l10n.discoverySourceRegion(
                      origin.sourceName,
                      _regionLabel(context, origin.region),
                    ),
                    if (origin.position != null)
                      context.l10n.discoveryOriginalPosition(origin.position!),
                  ].join('\n'),
                ),
              ),
          ],
  );
}

class _DiscoveryError extends StatelessWidget {
  const _DiscoveryError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: ErrorCard(
      error: message,
      colorScheme: Theme.of(context).colorScheme,
      onRetry: onRetry,
    ),
  );
}

class _DiscoveryTrackTile extends ConsumerWidget {
  const _DiscoveryTrackTile({
    super.key,
    required this.track,
    required this.sourceName,
    this.position,
    this.origins = const [],
    this.canListen = false,
    this.showItemType = false,
  });
  final bool canListen;
  final bool showItemType;
  final List<DiscoveryOrigin> origins;
  final Track track;
  final String sourceName;
  final int? position;

  void _download(BuildContext context, WidgetRef ref) => downloadSingleTrack(
    context,
    ref,
    track,
    forceQualityPicker: ref.read(settingsProvider).allowQualityVariants,
    trackForService: (service) =>
        discoveryTrackForService(track, origins, service),
  );

  void _open(BuildContext context, WidgetRef ref) {
    if (track.isAlbumItem) {
      pushPage<void>(
        context,
        (_) => _DiscoveryAlbumScreen(
          album: track,
          sourceName: sourceName,
          origins: origins,
        ),
      );
      return;
    }
    showAppBottomSheet<void>(
      context: context,
      title: track.name,
      subtitle: track.artistName,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (track.albumName.isNotEmpty) Text(track.albumName),
              if (track.releaseDate?.isNotEmpty == true)
                Text(
                  context.l10n.discoveryReleaseDate(
                    _releaseDateLabel(context, track.releaseDate!),
                  ),
                ),
              _DiscoveryOrigins(origins: origins, fallback: sourceName),
              const SizedBox(height: 16),
              if (canListen) ...[
                _DiscoveryListenButton(
                  track: track,
                  origins: origins,
                  onOpening: () => Navigator.of(sheetContext).pop(),
                  navigationContext: context,
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: Text(context.l10n.downloadTitle),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _download(context, ref);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: SizedBox(
      width: position == null ? 56 : 88,
      child: Row(
        children: [
          if (position != null)
            SizedBox(
              width: 32,
              child: Text('$position', textAlign: TextAlign.center),
            ),
          if (track.coverUrl?.isNotEmpty == true)
            CachedCoverImage(
              imageUrl: track.coverUrl!,
              width: 56,
              height: 56,
              borderRadius: BorderRadius.circular(8),
            )
          else
            SizedBox(
              width: 56,
              height: 56,
              child: Icon(
                track.isAlbumItem
                    ? Icons.album_outlined
                    : Icons.music_note_outlined,
              ),
            ),
        ],
      ),
    ),
    title: Text(track.name, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        track.artistName,
        [
          if (showItemType)
            track.isAlbumItem
                ? context.l10n.recentTypeAlbum
                : context.l10n.recentTypeSong,
          if (track.releaseDate?.isNotEmpty == true)
            _releaseDateLabel(context, track.releaseDate!),
        ].where((part) => part.isNotEmpty).join(' · '),
      ].where((part) => part.isNotEmpty).join('\n'),
    ),
    onTap: () => _open(context, ref),
    trailing: track.isAlbumItem
        ? const Icon(Icons.chevron_right)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canListen)
                _DiscoveryListenButton(
                  track: track,
                  origins: origins,
                  compact: MediaQuery.sizeOf(context).width < 600,
                ),
              IconButton(
                tooltip: context.l10n.downloadTitle,
                icon: const Icon(Icons.download_outlined),
                onPressed: () => _download(context, ref),
              ),
            ],
          ),
  );
}

/// A user action starts server preparation, never the local download queue.
class _DiscoveryListenButton extends StatefulWidget {
  const _DiscoveryListenButton({
    required this.track,
    required this.origins,
    this.onOpening,
    this.navigationContext,
    this.compact = false,
  });
  final Track track;
  final List<DiscoveryOrigin> origins;
  final VoidCallback? onOpening;
  final BuildContext? navigationContext;
  final bool compact;

  @override
  State<_DiscoveryListenButton> createState() => _DiscoveryListenButtonState();
}

class _DiscoveryListenButtonState extends State<_DiscoveryListenButton> {
  bool _opening = false;

  Future<void> _listen() async {
    if (_opening) return;
    setState(() => _opening = true);
    final navigatorContext = widget.navigationContext ?? context;
    final track = widget.track;
    final alternatives = widget.origins
        .map((origin) => origin.nativeTrack)
        .whereType<Track>()
        .toList();
    widget.onOpening?.call();
    try {
      await pushPage<void>(
        navigatorContext,
        (_) => MusicServerScreen(
          initialTrack: track,
          alternativeTracks: alternatives,
          autoPrepare: true,
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.compact
      ? IconButton.filledTonal(
          onPressed: _opening ? null : _listen,
          tooltip: context.l10n.musicServerListen,
          icon: const Icon(Icons.headphones_outlined, size: 20),
        )
      : FilledButton.tonalIcon(
          onPressed: _opening ? null : _listen,
          icon: const Icon(Icons.headphones_outlined, size: 20),
          label: Text(context.l10n.musicServerListen),
        );
}

class _DiscoveryAlbumScreen extends ConsumerWidget {
  const _DiscoveryAlbumScreen({
    required this.album,
    required this.sourceName,
    required this.origins,
  });
  final List<DiscoveryOrigin> origins;
  final Track album;
  final String sourceName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = discoveryAlbumTracksProvider(
      '${album.source}:${album.albumId ?? album.id}',
    );
    final tracks = ref.watch(provider);
    Future<void> refresh() async {
      try {
        await ref.refresh(provider.future).then((_) {});
      } catch (_) {
        /* Rendered below. */
      }
    }

    return Scaffold(
      body: AppRefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            AppSliverHeader.page(title: album.name),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(album.artistName),
                          _DiscoveryOrigins(
                            origins: origins,
                            fallback: sourceName,
                          ),
                        ],
                      ),
                    ),
                  ),
                  ...tracks.when(
                    loading: () => [
                      const SliverToBoxAdapter(
                        child: Center(child: AppLoadingIndicator()),
                      ),
                    ],
                    error: (_, _) => [
                      SliverToBoxAdapter(
                        child: _DiscoveryError(
                          message: context.l10n.discoveryLoadError,
                          onRetry: refresh,
                        ),
                      ),
                    ],
                    data: (data) => [
                      if (data.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(context.l10n.discoveryEmpty),
                          ),
                        ),
                      SliverList.builder(
                        itemCount: data.length,
                        itemBuilder: (context, index) => _DiscoveryTrackTile(
                          track: data[index],
                          sourceName:
                              origins
                                  .where(
                                    (origin) =>
                                        origin.sourceId == data[index].source,
                                  )
                                  .map((origin) => origin.sourceName)
                                  .firstOrNull ??
                              sourceName,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: context.navBarBottomInset + 24),
            ),
          ],
        ),
      ),
    );
  }
}
