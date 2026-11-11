import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

/// Full-track playback through the music server, separate from local downloads.
class TrackListenButton extends StatelessWidget {
  const TrackListenButton({super.key, required this.track, this.dense = false});

  final Track track;
  final bool dense;

  @override
  Widget build(BuildContext context) => AppIconButton(
    tooltip: context.l10n.musicServerListen,
    icon: AppIcon(
      Icons.headphones_outlined,
      color: Theme.of(context).colorScheme.primary,
      size: 20,
    ),
    onPressed: () => listenToTrack(context, track),
    padding: EdgeInsets.zero,
    constraints: dense
        ? const BoxConstraints(minWidth: 32, minHeight: 32)
        : const BoxConstraints(minWidth: 48, minHeight: 48),
    style: dense
        ? IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap)
        : null,
  );
}
