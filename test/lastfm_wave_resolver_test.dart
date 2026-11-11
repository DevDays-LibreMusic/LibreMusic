import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/lastfm_wave_resolver.dart';
import 'package:mornye/services/lastfm_wave_service.dart';

void main() {
  test(
    'real Deezer extension fixture recovers Duality and stylized Korn safely',
    () async {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/lastfm_wave/deezer_search_20261111.json',
                ).readAsStringSync(),
              )
              as List;
      for (final raw in fixture) {
        final row = raw as Map<String, dynamic>;
        final requested = LastfmWaveTrack(
          title: row['title'] as String,
          artist: row['artist'] as String,
        );
        final calls = <String>[];
        final result = await searchWaveCandidates(requested, (query) async {
          calls.add(query);
          final search = (row['searches'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere((s) => s['query'] == query);
          return (search['rows'] as List)
              .cast<Map<String, dynamic>>()
              .map(
                (r) => Track.fromBackendMap(
                  Map<String, dynamic>.from(r),
                  source: 'deezer',
                ),
              )
              .toList();
        });
        expect(
          result.single.artistName,
          requested.artist == 'Korn' ? 'KoЯn' : requested.artist,
        );
        expect(waveMatchKey(result.single.name), waveMatchKey(requested.title));
        expect(result.single.source, 'deezer');
        expect(calls.length, requested.title == 'Duality' ? 2 : 1);
        if (requested.title == 'Duality') {
          expect(result.single.id, 'deezer:3819908');
        }
      }
    },
  );
  test(
    'fallback retains strict artist and recording versions and stops at two queries',
    () async {
      var calls = 0;
      final result = await searchWaveCandidates(
        const LastfmWaveTrack(title: 'Duality', artist: 'Slipknot'),
        (_) async {
          calls++;
          return [
            const Track(
              id: 'live',
              name: 'Duality (Live)',
              artistName: 'Slipknot',
              albumName: '',
              duration: 250,
            ),
            const Track(
              id: 'cover',
              name: 'Duality',
              artistName: 'Cover Band',
              albumName: '',
              duration: 250,
            ),
          ];
        },
      );
      expect(calls, 2);
      expect(result, isEmpty);
    },
  );
  test('provider failure does not trigger a fallback request', () async {
    var calls = 0;
    await expectLater(
      searchWaveCandidates(
        const LastfmWaveTrack(title: 'Duality', artist: 'Slipknot'),
        (_) async {
          calls++;
          throw const SocketException('offline');
        },
      ),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 1);
  });
  const recommendation = LastfmWaveTrack(
    title: 'Get Lucky',
    artist: 'Daft Punk',
  );
  Track track(String name, {String artist = 'Daft Punk', String? itemType}) =>
      Track(
        id: 'provider-track',
        name: name,
        artistName: artist,
        albumName: '',
        duration: 248,
        source: 'deezer',
        itemType: itemType,
      );
  test('matches a provider recording and retains its native identity', () {
    final match = track('  GET  LUCKY ');
    expect(matchWaveTrack(recommendation, [match]), same(match));
    expect(match.source, 'deezer');
  });
  test('rejects different versions, covers, and collections', () {
    expect(
      matchWaveTrack(recommendation, [
        track('Get Lucky (Live)'),
        track('Get Lucky - Remix'),
        track('Get Lucky', artist: 'Cover Band'),
        track('Get Lucky', itemType: 'album'),
      ]),
      isNull,
    );
  });
  test('does not accidentally substitute a studio track for a live seed', () {
    expect(
      matchWaveTrack(
        const LastfmWaveTrack(title: 'Get Lucky (Live)', artist: 'Daft Punk'),
        [track('Get Lucky')],
      ),
      isNull,
    );
  });
  test('bounds lookups and retains matches after a provider failure', () async {
    var calls = 0;
    final candidates = List.generate(
      20,
      (i) => LastfmWaveTrack(title: 'Song $i', artist: 'Artist'),
    );
    final result = await resolveWaveBatch(candidates, (candidate) async {
      calls++;
      if (candidate.title == 'Song 1') throw Exception('offline');
      return [track(candidate.title, artist: candidate.artist)];
    });
    expect(calls, 5);
    expect(result.failures, 1);
    expect(result.tracks.map((t) => t.name), [
      'Song 0',
      'Song 2',
      'Song 3',
      'Song 4',
    ]);
  });
}
