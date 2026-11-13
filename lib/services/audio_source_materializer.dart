import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_source_preference.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AudioSourceAsset {
  const AudioSourceAsset(this.identity, this.path, this.digest);
  final AudioProviderSource identity;
  final String path, digest;
}

/// Downloads locally using the configured provider. No audio leaves the phone.
/// The retained recording is the preference target; provider URLs are not proof
/// that a subsequent fetch would contain the same bytes.
class AudioSourceMaterializer {
  AudioSourceMaterializer({
    Future<Directory> Function()? directory,
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)? download,
    Future<void> Function(String)? cancelDownload,
  }) : _directory = directory ?? _assetDirectory,
       _download = download ?? _downloadExact,
       _cancelDownload = cancelDownload ?? PlatformBridge.cancelDownload;

  final Future<Directory> Function() _directory;
  final Future<Map<String, dynamic>> Function(DownloadRequestPayload) _download;
  final Future<void> Function(String) _cancelDownload;
  final _cancelled = <String>{};
  final _owned = <String, Directory>{};
  static const maxAssetBytes = 512 * 1024 * 1024;
  static Future<Directory> _assetDirectory() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'audio-version-assets',
    ),
  ).create(recursive: true);
  static Future<Map<String, dynamic>> _downloadExact(
    DownloadRequestPayload payload,
  ) => PlatformBridge.downloadByStrategy(
    payload: payload,
    useExtensions: true,
    useFallback: false,
  );

  Future<void> cancel(String requestId) async {
    _cancelled.add(requestId);
    try {
      await _cancelDownload(requestId);
    } catch (_) {}
  }

  Future<AudioSourceAsset> materialize(
    Track track, {
    required String quality,
    required String requestId,
  }) async {
    final provider = track.source?.trim() ?? '';
    if (provider.isEmpty || track.id.isEmpty || requestId.isEmpty) {
      throw ArgumentError('An exact provider and item identity is required');
    }
    _cancelled.remove(requestId);
    final root = await _directory();
    if (_cancelled.contains(requestId)) throw const AudioAnalysisCancelled();
    final work = await root.createTemp('recording-');
    if (_cancelled.contains(requestId)) {
      await _remove(work);
      throw const AudioAnalysisCancelled();
    }
    final payload = DownloadRequestPayload(
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      outputDir: work.path,
      filenameFormat: 'recording',
      service: provider,
      downloadProvider: provider,
      source: provider,
      providerTrackId: track.id,
      spotifyId: track.id,
      itemId: requestId,
      quality: quality,
      durationMs: track.duration * 1000,
      embedMetadata: false,
      embedLyrics: false,
      useExtensions: true,
      useFallback: false,
    );
    final transfer = Future.sync(() => _download(payload));
    try {
      final result = await transfer.timeout(const Duration(minutes: 5));
      if (_cancelled.contains(requestId)) throw const AudioAnalysisCancelled();
      if (result['success'] != true ||
          result['resolved_provider_id'] != provider ||
          result['resolved_provider_track_id'] != track.id) {
        throw StateError(
          'The provider did not confirm the requested recording',
        );
      }
      final returned = result['file_path'];
      if (returned is! String || !p.isWithin(work.path, returned)) {
        throw StateError(
          'Provider returned audio outside its retained directory',
        );
      }
      final file = File(returned);
      final actual = await file.resolveSymbolicLinks();
      if (!p.isWithin(await work.resolveSymbolicLinks(), actual)) {
        throw StateError('Provider returned an external audio link');
      }
      final size = await file.length();
      if (size <= 0 || size > maxAssetBytes) {
        throw StateError('Recording exceeds the local analysis file limit');
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (_cancelled.contains(requestId)) throw const AudioAnalysisCancelled();
      _owned[returned] = work;
      return AudioSourceAsset(
        AudioProviderSource(provider, track.id, materializedDigest: digest),
        returned,
        digest,
      );
    } catch (_) {
      // Native cancellation acknowledges before every worker has necessarily
      // stopped. Retire the directory again once an overdue transfer settles.
      unawaited(_cancelDownload(requestId).catchError((Object _) {}));
      unawaited(
        transfer.then<void>(
          (_) => _remove(work),
          onError: (Object _, StackTrace _) => _remove(work),
        ),
      );
      await _remove(work);
      rethrow;
    }
  }

  /// Release only recordings created by this instance and not saved as a rule.
  Future<void> release(AudioSourceAsset asset) async {
    final work = _owned.remove(asset.path);
    if (work != null) await _remove(work);
  }

  static Future<void> _remove(Directory work) async {
    try {
      if (await work.exists()) await work.delete(recursive: true);
    } catch (_) {}
  }
}
