import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';

const contract = {
  'version': AudioVersionDemucsRunner.modelId,
  'model_sha256': AudioVersionDemucsRunner.modelSha256,
};
const outputId = '00000000-0000-4000-8000-000000000001';
const input = [
  {'clip_id': '0', 'wave_path': '/cache/wave', 'spec_path': '/cache/spec'},
];
Map<String, Object> output() => {
  ...contract,
  'status': 'verified',
  'output_id': outputId,
  'contexts': [
    {'clip_id': '0', 'freq_path': '/cache/freq', 'time_path': '/cache/time'},
  ],
};
void main() {
  test('Demucs import requires local selected matching pinned model', () async {
    var calls = 0;
    final runner = AudioVersionDemucsRunner(
      supported: true,
      invoke: (method, args) async {
        calls++;
        expect(method, 'importModel');
        throw PlatformException(code: 'invalid_model');
      },
    );
    await expectLater(
      runner.importModel('https://host/model', requestId: 'url'),
      throwsArgumentError,
    );
    expect(calls, 0);
    await expectLater(
      runner.importModel('/picked/model', requestId: 'local'),
      throwsA(
        isA<AudioVersionLearnedException>().having(
          (e) => e.reason,
          'reason',
          AudioVersionLearnedFailure.invalidModel,
        ),
      ),
    );
  });
  test(
    'tensor outputs stay bound to exact requested clip and pinned model',
    () async {
      var released = false;
      final runner = AudioVersionDemucsRunner(
        supported: true,
        invoke: (method, args) async {
          if (method == 'releaseOutputs') {
            released = true;
            return null;
          }
          return {...output(), 'model_sha256': 'wrong-model'};
        },
      );
      await expectLater(
        runner.infer(input, requestId: 'wrong'),
        throwsA(isA<AudioVersionLearnedException>()),
      );
      expect(released, true);
    },
  );
  test('late Demucs result is released after cancellation', () async {
    final entered = Completer<void>(), late = Completer<Object?>();
    var released = false;
    final runner = AudioVersionDemucsRunner(
      supported: true,
      invoke: (method, args) async {
        if (method == 'cancel') return null;
        if (method == 'releaseOutputs') {
          released = true;
          return null;
        }
        entered.complete();
        return late.future;
      },
    );
    final pending = runner.infer(input, requestId: 'cancelled');
    final rejected = expectLater(
      pending,
      throwsA(isA<AudioAnalysisCancelled>()),
    );
    await entered.future;
    runner.cancelAll();
    late.complete(output());
    await rejected;
    expect(released, true);
  });
  test(
    'malformed contexts are rejected instead of attaching another chunk',
    () async {
      var released = false;
      final runner = AudioVersionDemucsRunner(
        supported: true,
        invoke: (method, args) async {
          if (method == 'releaseOutputs') {
            released = true;
            return null;
          }
          return {
            ...output(),
            'contexts': [
              {
                'clip_id': 'other',
                'freq_path': '/cache/freq',
                'time_path': '/cache/time',
              },
            ],
          };
        },
      );
      await expectLater(
        runner.infer(input, requestId: 'mixed'),
        throwsA(isA<AudioVersionLearnedException>()),
      );
      expect(released, true);
    },
  );
}
