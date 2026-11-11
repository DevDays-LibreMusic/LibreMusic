import 'dart:io';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_playback_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_playback.dart';

const _tracks = [
  Track(
    id: 'first',
    name: 'First',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
  Track(
    id: 'second',
    name: 'Second',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
];

DownloadItem _item(String id, DownloadStatus status, {String? filePath}) {
  return DownloadItem(
    id: id,
    track: _tracks.first,
    service: 'example',
    status: status,
    filePath: filePath,
    createdAt: DateTime.utc(2026),
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultService: 'example');
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  String? prioritized;
  int sequence = 0;

  void completeAndRemove(String id, String path) {
    final current = state.items.firstWhere((item) => item.id == id);
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.id == id)
            current.copyWith(status: DownloadStatus.completed, filePath: path)
          else
            item,
      ],
    );
    state = state.copyWith(
      items: state.items.where((item) => item.id != id).toList(),
    );
  }

  void removeForTest(String id) {
    state = state.copyWith(
      items: state.items.where((item) => item.id != id).toList(),
    );
  }

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  List<String> addMultipleToQueue(
    List<Track> tracks,
    String service, {
    String? qualityOverride,
    String? playlistName,
    List<int?>? playlistPositions,
  }) {
    final items = [
      for (var index = 0; index < tracks.length; index++)
        DownloadItem(
          id: 'download-${sequence++}',
          track: tracks[index],
          service: service,
          createdAt: DateTime.utc(2026),
        ),
    ];
    state = state.copyWith(items: [...state.items, ...items]);
    return [for (final item in items) item.id];
  }

  @override
  void downloadNext(String id) {
    prioritized = id;
  }
}

void main() {
  test(
    'selecting a stalled preload starts a fresh lookup without awaiting it',
    () async {
      final service = DownloadPlaybackService();
      addTearDown(service.close);
      final obsolete = Completer<String>();
      var lookups = 0;
      final first = service.registerLazy(() async => '/music/first.flac');
      final next = service.registerLazy(
        () =>
            ++lookups == 1 ? obsolete.future : Future.value('/music/next.flac'),
      );
      await service.prepareWindow([first, next], 0);
      expect(lookups, 1);
      service.suspendWindow();
      await service
          .prepareWindow([first, next], 1)
          .timeout(const Duration(seconds: 1));
      expect(await service.resolve(next), '/music/next.flac');
      expect(lookups, 2);
      // Late completion of the cancelled lookup must not evict the fresh result.
      obsolete.complete('/music/obsolete.flac');
      await Future<void>.delayed(Duration.zero);
      expect(await service.resolve(next), '/music/next.flac');
      expect(lookups, 2);
    },
  );

  test(
    'progressive file readers retire outside current, next and outgoing tracks',
    () async {
      final directory = await Directory.systemTemp.createTemp('reader-window-');
      final paths = <String, String>{};
      for (var i = 0; i < 4; i++) {
        final file = File('${directory.path}/$i.flac.partial');
        await file.writeAsBytes([0x66, 0x4c, 0x61, 0x43]);
        paths['$i'] = file.path;
      }
      final service = DownloadPlaybackService(
        progressReader: () async => {
          'items': {
            for (final entry in paths.entries)
              entry.key: {'playback_path': entry.value, 'bytes_total': 4},
          },
        },
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await service.close();
        await directory.delete(recursive: true);
      });
      final sources = [
        for (var i = 0; i < 4; i++) downloadPlaybackSource('$i'),
      ];
      for (var i = 0; i < 4; i++) {
        service.registerItem(
          '$i',
          () => _item('$i', DownloadStatus.downloading),
        );
      }
      await service.prepareWindow(sources, 0);
      final first = await service.resolve(sources[0]);
      await service.prepareWindow(sources, 1);
      final second = await service.resolve(sources[1]);
      await service.prepareWindow(sources, 2);
      final retired = await (await client.headUrl(Uri.parse(first))).close();
      final outgoing = await (await client.headUrl(Uri.parse(second))).close();
      expect(retired.statusCode, HttpStatus.notFound);
      expect(outgoing.statusCode, HttpStatus.ok);
      await retired.drain<void>();
      await outgoing.drain<void>();
    },
  );

  test(
    'session references never alias and expired references fail promptly',
    () async {
      final first = DownloadPlaybackService();
      final second = DownloadPlaybackService();
      addTearDown(first.close);
      addTearDown(second.close);
      final old = first.registerLazy(() async => '/music/old.flac');
      final fresh = second.registerLazy(() async => '/music/new.flac');
      expect(old, isNot(fresh));
      await expectLater(
        second.resolve(old).timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      await second.close();
      expect(
        () => second.registerLazy(() async => '/music/new.flac'),
        throwsStateError,
      );
      await expectLater(second.resolve(fresh), throwsStateError);
    },
  );

  test(
    'replacing queue retires callbacks and stopping blocks pending preparation',
    () async {
      final service = DownloadPlaybackService();
      addTearDown(service.close);
      final obsolete = service.registerLazy(() async => '/music/old.flac');
      final next = service.registerLazy(() async => '/music/new.flac');
      await service.prepareWindow([next], 0);
      await expectLater(service.resolve(obsolete), throwsStateError);
      final gate = Completer<void>();
      var enqueued = false;
      final pending = service.registerLazy(
        () async => '',
        prepareGuarded: (current) async {
          await gate.future;
          if (!current()) throw const DownloadPlaybackSelectionChanged();
          enqueued = true;
          return '/music/pending.flac';
        },
      );
      final preparing = service.prepareWindow([pending], 0);
      service.suspendWindow();
      gate.complete();
      await preparing;
      expect(enqueued, isFalse);
    },
  );

  for (final ending in ['cancel', 'failure', 'close', 'replace']) {
    test(
      'stalled progressive HTTP reader terminates promptly on $ending',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'playback-abort-',
        );
        final file = File('${directory.path}/song.flac.partial');
        await file.writeAsBytes([0x66, 0x4c, 0x61, 0x43, 1, 2, 3, 4]);
        DownloadItem? item = _item('item', DownloadStatus.downloading);
        final service = DownloadPlaybackService(
          poll: const Duration(milliseconds: 5),
          progressReader: () async => {
            'items': {
              'item': {'playback_path': file.path, 'bytes_total': 100},
            },
          },
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await service.close();
          await directory.delete(recursive: true);
        });
        service.registerItem('item', () => item);
        final url = await service.resolve(downloadPlaybackSource('item'));
        final response = await (await client.getUrl(Uri.parse(url))).close();
        final received = Completer<void>();
        final completed = Completer<void>();
        response.listen(
          (bytes) {
            if (!received.isCompleted) received.complete();
          },
          onDone: () {
            if (!completed.isCompleted) completed.complete();
          },
          onError: (Object error) {
            if (!completed.isCompleted) completed.complete();
          },
        );
        await received.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError("No initial bytes"),
        );
        switch (ending) {
          case 'cancel':
            item = null;
          case 'failure':
            item = _item('item', DownloadStatus.failed);
          case 'close':
            await service.close().timeout(const Duration(seconds: 1));
          case 'replace':
            await service.prepareWindow([], -1);
        }
        await completed.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError("HTTP did not terminate"),
        );
        await service.close().timeout(const Duration(seconds: 1));
      },
    );
  }

  test(
    'play reuses a manual queued download without replacing or cancelling it',
    () async {
      final queue = _Queue();
      final service = DownloadPlaybackService();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
          downloadPlaybackProvider.overrideWith(
            (ref) => DownloadPlaybackCoordinator(
              ref,
              service: service,
              supported: true,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await service.close();
      });
      container.read(downloadQueueProvider);
      final manual = queue.addMultipleToQueue([
        _tracks.first,
      ], 'example').single;
      final paths = await container
          .read(downloadPlaybackProvider)
          .fillMissingPaths([_tracks.first], [null], startIndex: 0);
      expect(queue.state.items.length, 1);
      expect(queue.state.items.single.id, manual);
      queue.completeAndRemove(manual, '/music/manual.flac');
      expect(await service.resolve(paths.single!), '/music/manual.flac');
    },
  );

  test(
    'new current window retries a pending preload inherited from old window',
    () async {
      final service = DownloadPlaybackService();
      addTearDown(service.close);
      final pending = Completer<void>();
      var prepared = 0;
      Future<String> prepare(bool Function() current) async {
        await pending.future;
        if (!current()) throw const DownloadPlaybackSelectionChanged();
        prepared++;
        return '/music/next.flac';
      }

      final first = service.registerLazy(() async => '/music/first.flac');
      final next = service.registerLazy(
        () => prepare(() => true),
        prepareGuarded: prepare,
      );
      await service.prepareWindow([first, next], 0);
      // _loadIndex follows fillMissingPaths and repeats the same window.
      await service.prepareWindow([first, next], 0);
      pending.complete();
      await Future<void>.delayed(Duration.zero);
      expect(prepared, 1);
      expect(await service.resolve(next), '/music/next.flac');
    },
  );

  test(
    'pending next lookup does not block current and failed prepare retries',
    () async {
      final service = DownloadPlaybackService();
      addTearDown(service.close);
      final pending = Completer<String>();
      final current = service.registerLazy(() async => '/music/current.flac');
      final next = service.registerLazy(() => pending.future);
      await service
          .prepareWindow([current, next], 0)
          .timeout(const Duration(seconds: 1));
      expect(await service.resolve(current), '/music/current.flac');
      pending.complete('/music/next.flac');
      var attempts = 0;
      final retry = service.registerLazy(() async {
        if (++attempts == 1) throw StateError('temporary');
        return '/music/retry.flac';
      });
      await expectLater(service.resolve(retry), throwsStateError);
      expect(await service.resolve(retry), '/music/retry.flac');
      expect(attempts, 2);
    },
  );

  test('obsolete window lookup cannot enqueue after a skip', () async {
    final queue = _Queue();
    final service = DownloadPlaybackService();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(() => queue),
        downloadPlaybackProvider.overrideWith(
          (ref) => DownloadPlaybackCoordinator(
            ref,
            service: service,
            supported: true,
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await service.close();
    });
    final delayed = Completer<String?>();
    final tracks = [
      for (var i = 0; i < 5; i++)
        Track(
          id: 's$i',
          name: 'S$i',
          artistName: 'A',
          albumName: 'B',
          duration: 180,
        ),
    ];
    final paths = await container
        .read(downloadPlaybackProvider)
        .fillMissingPaths(
          tracks,
          List.filled(5, null),
          startIndex: 0,
          resolveExisting: (track) =>
              track.id == 's1' ? delayed.future : Future.value(null),
        );
    await service.prepareWindow(paths.cast<String>(), 3);
    delayed.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(queue.state.items.map((i) => i.track.id), ['s0', 's3', 's4']);
  });

  test(
    'lazy album schedules current and next, follows skips and reuses local files',
    () async {
      final queue = _Queue();
      final service = DownloadPlaybackService(
        progressReader: () async => const {'items': <String, Object?>{}},
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
          downloadPlaybackProvider.overrideWith(
            (ref) => DownloadPlaybackCoordinator(
              ref,
              service: service,
              supported: true,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await service.close();
      });
      final tracks = [
        for (var i = 0; i < 10; i++)
          Track(
            id: 'song-$i',
            name: 'Song $i',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
      ];
      final available = <String, String>{};
      final paths = await container
          .read(downloadPlaybackProvider)
          .fillMissingPaths(
            tracks,
            List.filled(10, null),
            startIndex: 0,
            resolveExisting: (track) async => available[track.id],
          );
      await Future<void>.delayed(Duration.zero);
      expect(paths.length, 10);
      expect(paths.every((p) => p != null), isTrue);
      expect(queue.state.items.map((t) => t.track.id), ['song-0', 'song-1']);
      expect(queue.prioritized, 'download-0');
      // A manual/local download can complete while this lazy track is waiting.
      available['song-6'] = 'content://library/six';
      await service.prepareWindow(paths.cast<String>(), 6);
      expect(await service.resolve(paths[6]!), 'content://library/six');
      expect(queue.state.items.map((t) => t.track.id), [
        'song-0',
        'song-1',
        'song-7',
      ]);
      // Reordering follows actual player order, not the original album position.
      await service.prepareWindow([paths[7]!, paths[4]!, paths[8]!], 0);
      await Future<void>.delayed(Duration.zero);
      expect(queue.state.items.map((t) => t.track.id), [
        'song-0',
        'song-1',
        'song-7',
        'song-4',
      ]);
      // Repeated prepare does not duplicate preloads, old work is not cancelled.
      await service.prepareWindow([paths[7]!, paths[4]!], 0);
      expect(queue.state.items.length, 4);
      // A separate explicit download-all action remains unrestricted.
      queue.addMultipleToQueue(tracks, 'example');
      expect(queue.state.items.length, 14);
    },
  );

  test(
    'lazy resolve prepares one track without recursively preloading album',
    () async {
      final service = DownloadPlaybackService();
      addTearDown(service.close);
      var prepared = 0;
      final sources = [
        for (var i = 0; i < 20; i++)
          service.registerLazy(() async {
            prepared++;
            return '/music/track.flac';
          }),
      ];
      expect(await service.resolve(sources[5]), '/music/track.flac');
      expect(prepared, 1);
      await service.prepareWindow(sources, 5);
      expect(prepared, 2);
    },
  );

  test('failed next preparation does not fail current window', () async {
    final service = DownloadPlaybackService();
    addTearDown(service.close);
    final current = service.registerLazy(() async => '/music/current.flac');
    final next = service.registerLazy(
      () async => throw StateError('failed next'),
    );
    await service.prepareWindow([current, next], 0);
    expect(await service.resolve(current), '/music/current.flac');
    await expectLater(service.resolve(next), throwsStateError);
  });

  test(
    'serves a growing audio file through final rename with byte ranges',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'download-playback',
      );
      final file = File('${directory.path}/song.flac.partial');
      await file.writeAsBytes([0x66, 0x4c, 0x61, 0x43, 4, 5, 6, 7, 8, 9]);
      final service = DownloadPlaybackService(
        progressReader: () async => {
          'items': {
            'item': {
              'playback_path': file.path,
              'bytes_total': 20,
              'status': 'downloading',
            },
          },
        },
        poll: const Duration(milliseconds: 5),
        patience: const Duration(seconds: 2),
      );
      service.registerItem(
        'item',
        () => _item('item', DownloadStatus.downloading),
      );
      addTearDown(() async {
        await service.close();
        await directory.delete(recursive: true);
      });

      final source = await service.resolve(downloadPlaybackSource('item'));
      // Rust finalization renames the staged file. An already open stream must
      // keep reading the inode even though its original pathname disappears.
      final renamed = await file.rename('${directory.path}/song.flac');
      final writing = Future<void>.delayed(
        const Duration(milliseconds: 30),
        () async {
          await renamed.writeAsBytes(
            List.generate(10, (index) => index + 10),
            mode: FileMode.append,
            flush: true,
          );
        },
      );
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(Uri.parse(source));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5-14');
      final response = await request.close();
      final body = await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      await writing;

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 5-14/20',
      );
      expect(response.headers.contentType?.mimeType, 'audio/flac');
      expect(body, List.generate(10, (index) => index + 5));
    },
  );

  test('uses the finalized file after the download completes', () async {
    final service = DownloadPlaybackService(
      progressReader: () async => throw StateError('Progress is not needed'),
    );
    service.registerItem(
      'item',
      () => _item(
        'item',
        DownloadStatus.completed,
        filePath: '/music/final.flac',
      ),
    );
    addTearDown(service.close);

    expect(
      await service.resolve(downloadPlaybackSource('item')),
      '/music/final.flac',
    );
  });

  test(
    'waits for finalization when the container is not recognizable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'download-playback',
      );
      final file = File('${directory.path}/song.flac.partial');
      await file.writeAsBytes(List.generate(20, (index) => index));
      var item = _item('item', DownloadStatus.downloading);
      final service = DownloadPlaybackService(
        progressReader: () async => {
          'items': {
            'item': {'playback_path': file.path, 'bytes_total': 20},
          },
        },
        poll: const Duration(milliseconds: 5),
        patience: const Duration(seconds: 2),
      );
      service.registerItem('item', () => item);
      addTearDown(() async {
        await service.close();
        await directory.delete(recursive: true);
      });

      final resolving = service.resolve(downloadPlaybackSource('item'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      item = _item(
        'item',
        DownloadStatus.completed,
        filePath: '/music/decrypted.flac',
      );

      expect(await resolving, '/music/decrypted.flac');
    },
  );

  test(
    'queues missing album tracks and prioritizes the selected track',
    () async {
      final queue = _Queue();
      final service = DownloadPlaybackService(
        progressReader: () async => const {'items': <String, Object?>{}},
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
          downloadPlaybackProvider.overrideWith(
            (ref) => DownloadPlaybackCoordinator(
              ref,
              service: service,
              supported: true,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await service.close();
      });

      final paths = await container
          .read(downloadPlaybackProvider)
          .fillMissingPaths(_tracks, [null, null], startIndex: 1);

      expect(paths, hasLength(2));
      expect(paths.every((path) => isDownloadPlaybackSource(path!)), isTrue);
      expect(paths[0], isNot(paths[1]));
      expect(queue.state.items.map((item) => item.track.id), ['second']);
      expect(queue.prioritized, 'download-0');
      // Actual worker contract: completion is published, then queue row removed
      // synchronously; the selected download must keep its final SAF identity.
      queue.completeAndRemove('download-0', 'content://music/final');
      await service.prepareWindow(paths.cast<String>(), 0);
      queue.removeForTest('download-1');
      expect(await service.resolve(paths[1]!), 'content://music/final');
      await expectLater(service.resolve(paths[0]!), throwsStateError);
      expect(await service.resolve(paths[1]!), 'content://music/final');
    },
  );
}
