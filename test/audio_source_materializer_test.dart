import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/audio_source_materializer.dart';
import 'package:mornye/services/download_request_payload.dart';

void main() {
  const track = Track(
    id: 'item',
    source: 'provider',
    name: 'Title',
    artistName: 'Artist',
    albumName: '',
    duration: 60,
  );
  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('materializer');
  });
  tearDown(() => work.delete(recursive: true));

  test(
    'direct download retains exact audio and releases only owned recording',
    () async {
      late DownloadRequestPayload payload;
      final materializer = AudioSourceMaterializer(
        directory: () async => work,
        cancelDownload: (_) async {},
        download: (request) async {
          payload = request;
          final file = await File(
            '${request.outputDir}/audio.mp3',
          ).writeAsString('audio');
          return {
            'success': true,
            'resolved_provider_id': 'provider',
            'resolved_provider_track_id': 'item',
            'file_path': file.path,
          };
        },
      );
      final asset = await materializer.materialize(
        track,
        quality: 'MP3',
        requestId: 'job',
      );
      expect(payload.source, 'provider');
      expect(payload.spotifyId, 'item');
      expect(payload.useFallback, isFalse);
      expect(await File(asset.path).readAsString(), 'audio');
      expect(asset.identity.itemId, 'item');
      await materializer.release(asset);
      expect(await File(asset.path).exists(), isFalse);
      expect(await work.exists(), isTrue);
    },
  );

  test('mismatched provider recording is rejected and cleaned', () async {
    final materializer = AudioSourceMaterializer(
      directory: () async => work,
      cancelDownload: (_) async {},
      download: (request) async {
        final file = await File(
          '${request.outputDir}/audio',
        ).writeAsString('audio');
        return {
          'success': true,
          'resolved_provider_id': 'provider',
          'resolved_provider_track_id': 'different-item',
          'file_path': file.path,
        };
      },
    );
    await expectLater(
      materializer.materialize(track, quality: 'MP3', requestId: 'job'),
      throwsStateError,
    );
    expect(await work.list().isEmpty, isTrue);
  });

  test('provider cannot bind an unrelated existing file', () async {
    final external = await File(
      '${work.path}/unrelated',
    ).writeAsString('audio');
    final materializer = AudioSourceMaterializer(
      directory: () async => work,
      cancelDownload: (_) async {},
      download: (_) async => {
        'success': true,
        'resolved_provider_id': 'provider',
        'resolved_provider_track_id': 'item',
        'file_path': external.path,
      },
    );
    await expectLater(
      materializer.materialize(track, quality: 'MP3', requestId: 'job'),
      throwsStateError,
    );
    expect(await external.exists(), isTrue);
  });
}
