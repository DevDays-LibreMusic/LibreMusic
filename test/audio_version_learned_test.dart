import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_learned.dart';

void main() {
  const outputId = '00000000-0000-4000-8000-000000000001';
  const clips = [AudioVersionClipInput('clip-1', '/cache/a', '/cache/b')];
  Map<String, Object?> response(String status) => {
    'status': status,
    'version': AudioVersionLearnedRunner.modelId,
    'model_sha256': AudioVersionLearnedRunner.modelSha256,
    'input_samples': 192000,
    'normalization': 'runtime',
    'output_frames': 599,
    'output_channels': 768,
    'output_id': outputId,
    'contexts': [
      {
        'clip_id': 'clip-1',
        'embedding_a': '/cache/private/a.f32',
        'embedding_b': '/cache/private/b.f32',
      },
    ],
  };

  test(
    'missing and unsupported backends never imply a verified recording',
    () async {
      final unsupported = AudioVersionLearnedRunner(
        supported: false,
        invoke: (_, _) async => fail('Unsupported backend invoked'),
      );
      expect(await unsupported.status(), AudioVersionModelStatus.unsupported);
      final missing = AudioVersionLearnedRunner(
        supported: true,
        invoke: (_, _) async => throw MissingPluginException(),
      );
      expect(await missing.status(), AudioVersionModelStatus.unsupported);
      await expectLater(
        missing.infer(clips, requestId: 'missing'),
        throwsA(isA<AudioVersionLearnedException>()),
      );
      final unavailable = AudioVersionLearnedRunner(
        supported: true,
        invoke: (_, _) async => response('unavailable'),
      );
      expect(await unavailable.status(), AudioVersionModelStatus.unavailable);
      await expectLater(
        unavailable.infer(clips, requestId: 'not-installed'),
        throwsA(
          isA<AudioVersionLearnedException>().having(
            (e) => e.reason,
            'reason',
            AudioVersionLearnedFailure.unavailable,
          ),
        ),
      );
    },
  );

  test('embeddings remain bound to the exact requested context IDs', () async {
    final calls = <String>[];
    final runner = AudioVersionLearnedRunner(
      supported: true,
      invoke: (method, args) async {
        calls.add(method);
        if (method == 'infer') {
          expect(args['clips'], [
            {'clip_id': 'clip-1', 'path_a': '/cache/a', 'path_b': '/cache/b'},
          ]);
          return response('verified');
        }
        return null;
      },
    );
    final batch = await runner.infer(clips, requestId: 'pair-1');
    expect(batch.contexts.single.clipId, 'clip-1');
    expect(batch.contexts.single.pathA, '/cache/private/a.f32');
    await runner.release(batch);
    expect(calls, ['infer', 'releaseOutputs']);
  });

  test(
    'wrong model and stale cross-pair context release outputs and fail',
    () async {
      Map<String, Object?> firstContext(Map<String, Object?> value) =>
          (value['contexts'] as List<Object?>).first as Map<String, Object?>;
      for (final change in <void Function(Map<String, Object?>)>[
        (r) => r['model_sha256'] = 'another-model',
        (r) => r['output_frames'] = 600,
        (r) => r['normalization'] = 'already_normalized',
        (r) => firstContext(r)['clip_id'] = 'other-pair',
        (r) => firstContext(r)['embedding_b'] = '/cache/private/a.f32',
      ]) {
        var released = false;
        final runner = AudioVersionLearnedRunner(
          supported: true,
          invoke: (method, args) async {
            if (method == 'releaseOutputs') {
              released = true;
              expect(args['output_id'], outputId);
              return null;
            }
            final value = response('verified');
            change(value);
            return value;
          },
        );
        await expectLater(
          runner.infer(clips, requestId: 'bad-result'),
          throwsA(
            isA<AudioVersionLearnedException>().having(
              (e) => e.reason,
              'reason',
              AudioVersionLearnedFailure.malformedResult,
            ),
          ),
        );
        expect(released, isTrue);
      }
    },
  );

  test(
    'late result after cancellation is rejected and private files released',
    () async {
      final pending = Completer<Object?>();
      final calls = <String>[];
      final runner = AudioVersionLearnedRunner(
        supported: true,
        invoke: (method, args) {
          calls.add(method);
          return method == 'infer' ? pending.future : Future.value(null);
        },
      );
      final future = runner.infer(clips, requestId: 'cancel-me');
      final assertion = expectLater(
        future,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await runner.cancel('cancel-me');
      pending.complete(response('verified'));
      await assertion;
      expect(calls, ['infer', 'cancel', 'releaseOutputs']);
    },
  );

  test(
    'invalid model error preserves its meaning; model URLs are rejected',
    () async {
      final runner = AudioVersionLearnedRunner(
        supported: true,
        invoke: (_, _) async => throw PlatformException(code: 'invalid_model'),
      );
      await expectLater(
        runner.importModel('/cache/not-the-model', requestId: 'import'),
        throwsA(
          isA<AudioVersionLearnedException>().having(
            (e) => e.reason,
            'reason',
            AudioVersionLearnedFailure.invalidModel,
          ),
        ),
      );
      await expectLater(
        runner.importModel('https://example.org/model', requestId: 'url'),
        throwsArgumentError,
      );
    },
  );
}
