import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_source_preference.dart';
import 'package:mornye/services/audio_version_comparison.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';

void main() {
  for (final votes in [
    ['A', 'A'],
    ['B', 'B'],
    ['A', 'B'],
    ['A', null],
  ]) {
    test('content verification and vocal evidence aggregate $votes', () async {
      final work = await Directory.systemTemp.createTemp(
        'comparison-pipeline-',
      );
      final operations = <String>[];
      final decodes = <List<String>>[];
      var releases = 0, direction = 0;
      final wavlm = AudioVersionLearnedRunner(
        supported: true,
        invoke: (method, args) async {
          final contract = {
            'version': AudioVersionLearnedRunner.modelId,
            'model_sha256': AudioVersionLearnedRunner.modelSha256,
            'input_samples': 192000,
            'normalization': 'runtime',
            'output_frames': 599,
            'output_channels': 768,
          };
          if (method == 'status') return {...contract, 'status': 'available'};
          if (method == 'releaseOutputs') {
            releases++;
            return null;
          }
          return {
            ...contract,
            'status': 'verified',
            'output_id': '00000000-0000-4000-8000-000000000001',
            'contexts': [
              for (final c
                  in (args['clips'] as List).cast<Map<String, Object?>>())
                {
                  'clip_id': c['clip_id'],
                  'embedding_a': '/cache/w-${c['clip_id']}-a',
                  'embedding_b': '/cache/w-${c['clip_id']}-b',
                },
            ],
          };
        },
      );
      final demucs = AudioVersionDemucsRunner(
        supported: true,
        invoke: (method, args) async {
          final contract = {
            'version': AudioVersionDemucsRunner.modelId,
            'model_sha256': AudioVersionDemucsRunner.modelSha256,
          };
          if (method == 'status') return {...contract, 'status': 'available'};
          if (method == 'releaseOutputs') {
            releases++;
            return null;
          }
          return {
            ...contract,
            'status': 'verified',
            'output_id': '00000000-0000-4000-8000-000000000002',
            // Deliberately return reversed chunks: the merger must restore order.
            'contexts': [
              for (final c
                  in ((args['clips'] as List).cast<Map<String, Object?>>())
                      .reversed)
                {
                  'clip_id': c['clip_id'],
                  'freq_path': '/cache/f-${c['clip_id']}',
                  'time_path': '/cache/t-${c['clip_id']}',
                },
            ],
          };
        },
      );
      final runner = AudioVersionComparisonRunner(
        learned: wavlm,
        demucs: demucs,
        capturePair: (_, _) async =>
            const AudioSourcePair('/a', '/b', 'hash-a', 'hash-b'),
        createWork: () async => work,
        byteLength: (path) async =>
            path.contains('-mix.') ? 529200 * 8 : 16000 * 4 * 40,
        decode: (args) async {
          decodes.add(args);
          if (args.last.contains('-mix.')) {
            await File(args.last).writeAsBytes([]);
          }
          return (id: decodes.length, completed: Future.value(true));
        },
        native: (args, {required requestId}) async {
          final op = args['operation'] as String;
          operations.add(op);
          switch (op) {
            case 'audio_version_compare':
              return {
                'version': 'audio-version-dsp-v1',
                'status': 'model_verification_required',
                'preferred_side': null,
                'absolute_uncensored_status': 'unknown',
                'source_a_sha256': 'decoded-pcm-a',
                'source_b_sha256': 'decoded-pcm-b',
                'duration_b': 40,
                'alignment': {'offset': .5},
                'candidates': [
                  for (final start in [8.0, 20.0])
                    {
                      'start_a': start + .5,
                      'end_a': start + 1.5,
                      'start_b': start,
                      'end_b': start + 1,
                    },
                ],
              };
            case 'audio_version_prepare_clip':
              return {
                'normalization': 'runtime',
                'samples': 192000,
                'model_sha256': AudioVersionLearnedRunner.modelSha256,
              };
            case 'audio_version_verify_context':
              return {
                'model_sha256': AudioVersionLearnedRunner.modelSha256,
                'preferred_side': null,
                'absolute_uncensored_status': 'unknown',
                'status': 'confirmed_content_change',
                'events': [
                  for (final e
                      in (args['events'] as List).cast<Map<String, Object?>>())
                    {...e, 'confirmed': true},
                ],
              };
            case 'audio_version_demucs_prepare':
              for (final key in ['wave_path', 'spec_path']) {
                await File(args[key] as String).writeAsBytes([]);
              }
              return {
                'samples': 529200,
                'segment': 343980,
                'stride': 257985,
                'mean': 0,
                'std': 1,
                'model_sha256': AudioVersionDemucsRunner.modelSha256,
              };
            case 'audio_version_demucs_finish':
            case 'audio_version_demucs_merge':
              if (op.endsWith('merge')) {
                final chunks = (args['chunks'] as List).cast<String>();
                expect(chunks[0], endsWith('-0-stems.f32le'));
                expect(chunks[2], endsWith('-2-stems.f32le'));
              }
              await File(args['output_path'] as String).writeAsBytes([]);
              return {'status': 'complete'};
            case 'audio_version_demucs_direction':
              final side = votes[direction++];
              return {
                'model_sha256': AudioVersionDemucsRunner.modelSha256,
                'preferred_side': side,
                'assessment': side == null
                    ? 'undetermined'
                    : 'relative_vocal_loss_supported',
                'absolute_uncensored_status': 'unknown',
              };
            default:
              throw StateError(op);
          }
        },
      );
      try {
        final result = await runner.compare('/a', '/b');
        final consistent = votes[0] == votes[1];
        expect(result.data['preferred_side'], consistent ? votes[0] : null);
        expect(
          result.data['direction_status'],
          consistent
              ? 'consistent_vocal_loss'
              : votes[1] == null
              ? 'unknown'
              : 'mixed',
        );
        expect(result.data['absolute_uncensored_status'], 'unknown');
        expect(result.sourcePair?.digestA, 'hash-a');
        expect(result.data['source_a_sha256'], 'decoded-pcm-a');
        expect(
          result.sourcePair?.digestA,
          isNot(result.data['source_a_sha256']),
        );
        expect(releases, 5); // One WavLM session and two sides for each event.
        expect(
          operations.where((o) => o == 'audio_version_demucs_direction').length,
          2,
        );
        expect(decodes.length, 6);
        for (final args in decodes.skip(2)) {
          expect(
            args[args.indexOf('-protocol_whitelist') + 1],
            'file,saf,fd,pipe',
          );
          expect(
            args[args.indexOf('-af') + 1],
            contains('atrim=end_sample=529200'),
          );
        }
        expect(await work.exists(), false);
      } finally {
        runner.dispose();
        if (await work.exists()) await work.delete(recursive: true);
      }
    });
  }
}
