import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_learned.dart';

void main() {
  const result = {
    'version': 'audio-version-dsp-v1',
    'status': 'identical_audio',
    'preferred_side': null,
    'absolute_uncensored_status': 'unknown',
    'candidates': <Object?>[],
  };
  test(
    'complete bounded decode passes actual pair to native and cleans after completion',
    () async {
      final commands = <List<String>>[];
      final stages = <AudioComparisonStage>[];
      var cleaned = false;
      final runner = AudioVersionComparisonRunner(
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          cleaned = true;
        },
        byteLength: (_) async => 16000 * 4 * 100,
        decode: (args) async {
          commands.add(args);
          return (id: commands.length, completed: Future.value(true));
        },
        native: (args, {required requestId}) async {
          expect(cleaned, false);
          expect(args, {
            'operation': 'audio_version_compare',
            'path_a': '/private/test/0.f32le',
            'path_b': '/private/test/1.f32le',
          });
          return result;
        },
      );
      final compared = await runner.compare(
        '/a.flac',
        'content://audio/b',
        onProgress: stages.add,
      );
      expect(compared.pathB, 'content://audio/b');
      expect(compared.data['absolute_uncensored_status'], 'unknown');
      expect(stages, AudioComparisonStage.values);
      expect(cleaned, true);
      for (final args in commands) {
        expect(args[args.indexOf('-t') + 1], '601');
        expect(
          args[args.indexOf('-protocol_whitelist') + 1],
          'file,saf,fd,pipe',
        );
        expect(args[args.indexOf('-threads') + 1], '1');
        expect(args[args.indexOf('-ar') + 1], '16000');
        expect(args[args.indexOf('-f') + 1], 'f32le');
      }
    },
  );
  test(
    'overlong complete decode rejects instead of comparing an intro',
    () async {
      var nativeCalled = false;
      var cleaned = false;
      final runner = AudioVersionComparisonRunner(
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          cleaned = true;
        },
        byteLength: (_) async => AudioVersionComparisonRunner.maxPcmBytes + 4,
        decode: (_) async => (id: 5, completed: Future.value(true)),
        native: (_, {required requestId}) async {
          nativeCalled = true;
          return result;
        },
      );
      await expectLater(
        runner.compare('/a', '/b'),
        throwsA(
          isA<AudioComparisonException>().having(
            (e) => e.reason,
            'reason',
            AudioComparisonFailure.duration,
          ),
        ),
      );
      expect(nativeCalled, false);
      expect(cleaned, true);
    },
  );
  test(
    'cancel during native job waits for completion before deleting owned files',
    () async {
      final entered = Completer<void>();
      final completed = Completer<Map<String, dynamic>>();
      final cancelled = <String>[];
      var cleaned = false;
      final runner = AudioVersionComparisonRunner(
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          cleaned = true;
        },
        byteLength: (_) async => AudioVersionComparisonRunner.minPcmBytes,
        decode: (_) async => (id: 4, completed: Future.value(true)),
        cancelNative: (id) async {
          cancelled.add(id);
        },
        native: (_, {required requestId}) {
          entered.complete();
          return completed.future;
        },
      );
      final future = runner.compare('/a', '/b');
      final rejected = expectLater(
        future,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await entered.future;
      runner.cancel();
      expect(cleaned, false);
      expect(cancelled, hasLength(1));
      completed.complete(result);
      await rejected;
      expect(cleaned, true);
    },
  );
  test('network sources are rejected without decoding', () async {
    final runner = AudioVersionComparisonRunner(
      createWork: () async => throw StateError('must not allocate'),
    );
    await expectLater(
      runner.compare('https://example.org/a', '/b'),
      throwsA(isA<AudioComparisonException>()),
    );
  });
  test(
    'cancel during decoder start cancels only its owned id and waits',
    () async {
      final started = Completer<({int id, Future<bool> completed})>();
      final finished = Completer<bool>();
      final entered = Completer<void>();
      final ids = <int>[];
      var cleaned = false;
      final runner = AudioVersionComparisonRunner(
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          cleaned = true;
        },
        decode: (_) {
          entered.complete();
          return started.future;
        },
        cancelDecode: (id) async {
          ids.add(id);
        },
      );
      final future = runner.compare('/a', '/b');
      final rejected = expectLater(
        future,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await entered.future;
      runner.cancel();
      started.complete((id: 41, completed: finished.future));
      await Future<void>.delayed(Duration.zero);
      expect(ids, [41]);
      expect(cleaned, false);
      finished.complete(true);
      await rejected;
      expect(cleaned, true);
    },
  );
  test(
    'local learned pipeline preserves unknown side and releases outputs',
    () async {
      final operations = <String>[];
      var released = false;
      var cleaned = false;
      final learned = AudioVersionLearnedRunner(
        supported: true,
        invoke: (method, args) async {
          final contract = <String, Object?>{
            'version': AudioVersionLearnedRunner.modelId,
            'normalization': 'runtime',
            'model_sha256': AudioVersionLearnedRunner.modelSha256,
            'input_samples': 192000,
            'output_frames': 599,
            'output_channels': 768,
          };
          if (method == 'status') return {...contract, 'status': 'available'};
          if (method == 'releaseOutputs') {
            released = true;
            return null;
          }
          expect(method, 'infer');
          expect(cleaned, false);
          return {
            ...contract,
            'status': 'verified',
            'output_id': '00000000-0000-4000-8000-000000000001',
            'contexts': [
              {
                'clip_id': '0',
                'embedding_a': '/cache/a',
                'embedding_b': '/cache/b',
              },
            ],
          };
        },
      );
      final runner = AudioVersionComparisonRunner(
        learned: learned,
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          expect(released, true);
          cleaned = true;
        },
        byteLength: (_) async => 16000 * 4 * 30,
        decode: (_) async => (id: 1, completed: Future.value(true)),
        native: (args, {required requestId}) async {
          final op = args['operation'] as String;
          operations.add(op);
          if (op == 'audio_version_compare')
            return {
              ...result,
              'status': 'model_verification_required',
              'duration_b': 30,
              'alignment': {'offset': 0.5},
              'candidates': [
                {'start_a': 8.5, 'end_a': 9.5, 'start_b': 8.0, 'end_b': 9.0},
              ],
            };
          if (op == 'audio_version_prepare_clip')
            return {
              'normalization': 'runtime',
              'samples': 192000,
              'model_sha256': AudioVersionLearnedRunner.modelSha256,
            };
          expect(op, 'audio_version_verify_context');
          expect(args['all_events'], [
            {'start_b': 8.0, 'end_b': 9.0},
          ]);
          return {
            'model_sha256': AudioVersionLearnedRunner.modelSha256,
            'preferred_side': null,
            'absolute_uncensored_status': 'unknown',
            'status': 'confirmed_content_change',
            'events': [
              {'start_b': 8.0, 'end_b': 9.0, 'confirmed': true},
            ],
          };
        },
      );
      final compared = await runner.compare('/a', '/b');
      expect(compared.data['verification_status'], 'confirmed_content_change');
      expect(compared.data['preferred_side'], null);
      expect(compared.data['absolute_uncensored_status'], 'unknown');
      expect(operations, [
        'audio_version_compare',
        'audio_version_prepare_clip',
        'audio_version_prepare_clip',
        'audio_version_verify_context',
      ]);
      expect(cleaned, true);
    },
  );
  test(
    'cancellation while model status is pending never publishes DSP result',
    () async {
      final entered = Completer<void>();
      final status = Completer<Object?>();
      var cleaned = false;
      final learned = AudioVersionLearnedRunner(
        supported: true,
        invoke: (method, _) {
          expect(method, 'status');
          entered.complete();
          return status.future;
        },
      );
      final runner = AudioVersionComparisonRunner(
        learned: learned,
        createWork: () async => Directory('/private/test'),
        removeWork: (_) async {
          cleaned = true;
        },
        byteLength: (_) async => AudioVersionComparisonRunner.minPcmBytes,
        decode: (_) async => (id: 1, completed: Future.value(true)),
        native: (_, {required requestId}) async => {
          ...result,
          'status': 'model_verification_required',
        },
      );
      final future = runner.compare('/a', '/b');
      final rejected = expectLater(
        future,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await entered.future;
      runner.cancel();
      expect(cleaned, false);
      status.complete(null);
      await rejected;
      expect(cleaned, true);
    },
  );
}
