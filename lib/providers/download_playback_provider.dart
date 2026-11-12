import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_playback.dart';
import 'package:mornye/services/playback_diagnostics.dart';

final downloadPlaybackProvider = Provider<DownloadPlaybackCoordinator>((ref) {
  return DownloadPlaybackCoordinator(ref);
});

class DownloadPlaybackCoordinator {
  DownloadPlaybackCoordinator(
    this.ref, {
    DownloadPlaybackService? service,
    bool? supported,
  }) : service = service ?? DownloadPlaybackService.instance,
       supported = supported ?? Platform.isAndroid {
    if (!this.supported) return;
    // Observe every state transition, not a 100ms polling snapshot: a native
    // worker can publish completion and remove the item in the same turn.
    ref.listen(downloadQueueProvider, (previous, next) {
      for (final item in next.items) {
        this.service.rememberCompleted(item);
      }
    });
  }

  final Ref ref;
  final DownloadPlaybackService service;
  final bool supported;

  Future<List<String?>> fillMissingPaths(
    List<Track> tracks,
    List<String?> paths, {
    required int startIndex,
    String? attempt,
    Future<String?> Function(Track)? resolveExisting,
  }) async {
    if (!supported ||
        tracks.length != paths.length ||
        !paths.any((path) => path == null || path.isEmpty)) {
      return paths;
    }
    final settings = ref.read(settingsProvider);
    final downloadService = resolveEffectiveDownloadService(
      settings.defaultService,
      ref.read(extensionProvider),
    );
    if (downloadService.isEmpty) return paths;

    final resolved = List<String?>.of(paths);
    for (var index = 0; index < tracks.length; index++) {
      if (resolved[index]?.isNotEmpty == true) continue;
      final track = tracks[index];
      final trackAttempt = attempt ?? PlaybackDiagnostics.traceForTrack(track);
      late final String reference;
      Future<String> prepare(bool Function() isCurrent) async {
        final existing = await resolveExisting?.call(track);
        if (!isCurrent()) throw const DownloadPlaybackSelectionChanged();
        if (existing?.isNotEmpty == true) {
          PlaybackDiagnostics.event(
            'local_reuse',
            attempt: trackAttempt,
            fields: {'trackId': track.id, 'source': track.source},
          );
          return existing!;
        }
        final queue = ref.read(downloadQueueProvider.notifier);
        final active = ref.read(downloadQueueProvider).items.where((item) {
          return item.service.toLowerCase() == downloadService.toLowerCase() &&
              item.track.id == track.id &&
              item.track.source == track.source &&
              (item.status == DownloadStatus.queued ||
                  item.status == DownloadStatus.downloading ||
                  item.status == DownloadStatus.finalizing ||
                  (item.status == DownloadStatus.completed &&
                      item.filePath?.isNotEmpty == true));
        }).firstOrNull;
        if (active?.status == DownloadStatus.completed) {
          return active!.filePath!;
        }
        final id =
            active?.id ??
            queue.addMultipleToQueue([track], downloadService).single;
        PlaybackDiagnostics.event(
          'download_prepare',
          attempt: trackAttempt,
          fields: {
            'reference': reference,
            'itemId': id,
            'trackId': track.id,
            'source': track.source,
            'provider': downloadService,
            'result': active == null ? 'created' : 'reused',
          },
        );
        service.registerItem(
          id,
          () => ref.read(downloadQueueProvider).lookup.byItemId[id],
          ownerSource: reference,
        );
        if (ref.read(downloadQueueProvider).isPaused) queue.resumeQueue();
        return downloadPlaybackSource(id);
      }

      reference = service.registerLazy(
        () => prepare(() => true),
        prepareGuarded: prepare,
        prioritize: (source) {
          if (isDownloadPlaybackSource(source)) {
            ref
                .read(downloadQueueProvider.notifier)
                .downloadNext(
                  source.substring(downloadPlaybackScheme.length + 1),
                );
          }
        },
      );
      resolved[index] = reference;
    }
    await service.prepareWindow(
      resolved.whereType<String>().toList(),
      startIndex,
    );
    return resolved;
  }
}
