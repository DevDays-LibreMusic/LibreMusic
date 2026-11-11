import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recommendation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';
import 'package:mornye/services/recommendations/recommendation_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/utils/nav_bar_inset.dart';

part 'recommendation_editor.dart';

class RecommendationsScreen extends ConsumerWidget {
  const RecommendationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final profiles = ref.watch(recommendationProfilesProvider);
    final active = ref.watch(activeRecommendationProfileProvider);
    void open(RecommendationProfile? profile) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecommendationEditor(profile: profile),
      ),
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: l.recTitle,
            actions: [
              IconButton(
                tooltip: l.recCreate,
                icon: const Icon(Icons.add),
                onPressed: () => open(null),
              ),
            ],
          ),
          SliverPadding(
            padding: EdgeInsets.all(context.tokens.gapLg),
            sliver: SliverToBoxAdapter(child: Text(l.recDescription)),
          ),
          ...settingsSectionSlivers(
            title: l.recAutoplay,
            children: [
              SettingsItem(
                icon: Icons.playlist_play,
                title: l.recDefaultAutoplay,
                selected: active.isEmpty,
                onTap: () => ref
                    .read(recommendationProfilesProvider.notifier)
                    .activate(null),
              ),
            ],
          ),
          profiles.when(
            loading: () => const SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => SliverToBoxAdapter(
              child: TextButton(
                onPressed: () => ref.invalidate(recommendationProfilesProvider),
                child: Text(l.recRetry),
              ),
            ),
            data: (items) => SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final p = items[index];
                return ListTile(
                  title: Text(p.name),
                  subtitle: active == p.id ? Text(l.recActive) : null,
                  leading: const Icon(Icons.tune),
                  onTap: () => open(p),
                  trailing: IconButton(
                    tooltip: l.recUseAutoplay,
                    icon: Icon(
                      active == p.id
                          ? Icons.check_circle
                          : Icons.play_circle_outline,
                    ),
                    onPressed: () => ref
                        .read(recommendationProfilesProvider.notifier)
                        .activate(p.id),
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(context.tokens.gapLg),
              child: FilledButton.icon(
                onPressed: () => open(null),
                icon: const Icon(Icons.add),
                label: Text(l.recCreate),
              ),
            ),
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
