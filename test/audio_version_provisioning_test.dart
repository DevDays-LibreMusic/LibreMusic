import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';

const wavlmContract = {
  'version': AudioVersionLearnedRunner.modelId,
  'model_sha256': AudioVersionLearnedRunner.modelSha256,
  'input_samples': 192000,
  'normalization': 'runtime',
  'output_frames': 599,
  'output_channels': 768,
};
void main() {
  test(
    'corrupt or missing built-in model stops before decoding or preferences',
    () async {
      var decoded = false, demucsCalled = false;
      final runner = AudioVersionComparisonRunner(
        learned: AudioVersionLearnedRunner(
          supported: true,
          invoke: (method, args) async {
            expect(method, 'prepareModel');
            throw PlatformException(code: 'invalid_model');
          },
        ),
        demucs: AudioVersionDemucsRunner(
          supported: true,
          invoke: (method, args) async {
            demucsCalled = true;
            return null;
          },
        ),
        createWork: () async =>
            throw StateError('must not allocate audio work'),
        decode: (_) async {
          decoded = true;
          return (id: 1, completed: Future.value(true));
        },
      );
      await expectLater(
        runner.compare('/a', '/b'),
        throwsA(
          isA<AudioComparisonException>().having(
            (e) => e.reason,
            'reason',
            AudioComparisonFailure.modelImport,
          ),
        ),
      );
      expect(decoded, false);
      expect(demucsCalled, false);
      runner.dispose();
    },
  );
  test(
    'cancel during bundled provisioning rejects late result and never decodes',
    () async {
      final entered = Completer<void>(), late = Completer<Object?>();
      var cancelled = false, demucsCalled = false;
      final runner = AudioVersionComparisonRunner(
        learned: AudioVersionLearnedRunner(
          supported: true,
          invoke: (method, args) async {
            if (method == 'cancel') {
              cancelled = true;
              return null;
            }
            expect(method, 'prepareModel');
            entered.complete();
            return late.future;
          },
        ),
        demucs: AudioVersionDemucsRunner(
          supported: true,
          invoke: (method, args) async {
            demucsCalled = true;
            return null;
          },
        ),
        createWork: () async =>
            throw StateError('must not allocate audio work'),
      );
      final pending = runner.compare('/a', '/b');
      final rejected = expectLater(
        pending,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await entered.future;
      runner.cancel();
      late.complete({...wavlmContract, 'status': 'available'});
      await rejected;
      expect(cancelled, true);
      expect(demucsCalled, false);
      runner.dispose();
    },
  );
  test(
    'constructing a runner does not access models or initialize inference',
    () {
      var calls = 0;
      final runner = AudioVersionComparisonRunner(
        learned: AudioVersionLearnedRunner(
          supported: true,
          invoke: (method, args) async {
            calls++;
            return null;
          },
        ),
        demucs: AudioVersionDemucsRunner(
          supported: true,
          invoke: (method, args) async {
            calls++;
            return null;
          },
        ),
      );
      expect(calls, 0);
      runner.dispose();
      expect(calls, 0);
    },
  );
}
