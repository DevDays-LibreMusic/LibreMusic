import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/discovery.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discovery_aggregation.dart';

final now = DateTime.utc(2026, 11, 12);
Track track(
  String id, {
  String name = 'Song',
  String artist = 'Artist',
  String? isrc,
  String source = 'a',
  bool? explicit,
  int duration = 180,
  String? date,
  String? itemType,
}) => Track(
  id: id,
  name: name,
  artistName: artist,
  albumName: 'Album',
  duration: duration,
  source: source,
  isrc: isrc,
  explicit: explicit,
  releaseDate: date,
  itemType: itemType,
);
DiscoveryRanking ranking(String id, List<Track> tracks, {String? family}) =>
    DiscoveryRanking(
      sourceId: id,
      family: family ?? id,
      feed: DiscoveryFeed(
        entries: [
          for (var i = 0; i < tracks.length; i++)
            DiscoveryEntry(
              track: tracks[i],
              position: i + 1,
              genres: [id == 'a' ? 'Hip-Hop' : 'Hip-Hop/Rap'],
            ),
        ],
        fetchedAt: now,
        region: 'us',
        sourceName: id,
      ),
    );
void main() {
  test('consensus fuses normalized metadata and retains native origins', () {
    final result = aggregateDiscovery(
      [
        ranking('a', [track('a1', name: 'Song!'), track('a2', name: 'Other')]),
        ranking('b', [track('b1', name: 'song', source: 'b')]),
      ],
      DiscoveryKind.trends,
      now: now,
    );
    expect(result.length, 2);
    expect(result.first.origins.length, 2);
    expect(result.first.origins.map((o) => o.nativeId), ['a1', 'b1']);
    expect(result.first.genres, ['Hip-Hop/Rap']);
    expect(result.first.rankScore, 2);
    expect(result.first.position, 1);
  });
  test(
    'different ISRCs, versions, durations and explicit flags stay separate',
    () {
      for (final other in [
        track('b', source: 'b', isrc: 'OTHER'),
        track('b', source: 'b', name: 'Song (Live)', isrc: 'SAME'),
        track('b', source: 'b', duration: 220, isrc: 'SAME'),
        track('b', source: 'b', explicit: false, isrc: 'SAME'),
      ]) {
        expect(
          sameDiscoveryRecording(
            track('a', isrc: 'SAME', explicit: true),
            other,
          ),
          isFalse,
        );
      }
      expect(
        sameDiscoveryRecording(
          track('a', name: 'Song (X Remix)', isrc: 'SAME'),
          track('b', source: 'b', name: 'Song (Y Remix)', isrc: 'SAME'),
        ),
        isFalse,
      );
    },
  );
  test(
    'unknown explicit metadata cannot bridge clean and explicit recordings',
    () {
      final result = aggregateDiscovery(
        [
          ranking('a', [track('a', explicit: true)]),
          ranking('b', [track('b', source: 'b')]),
          ranking('c', [track('c', source: 'c', explicit: false)]),
        ],
        DiscoveryKind.trends,
        now: now,
      );
      expect(result.length, 2);
    },
  );
  test('albums cannot merge with tracks; unrelated artists stay separate', () {
    expect(
      sameDiscoveryRecording(
        track('a'),
        track('b', source: 'b', itemType: 'album'),
      ),
      isFalse,
    );
    expect(
      sameDiscoveryRecording(
        track('a'),
        track('b', source: 'b', artist: 'Other'),
      ),
      isFalse,
    );
  });
  test(
    'correlated charts only get one vote and repeated rows cannot boost',
    () {
      final result = aggregateDiscovery(
        [
          ranking('a', [track('a'), track('a')], family: 'apple'),
          ranking('b', [track('b', source: 'b')], family: 'apple'),
        ],
        DiscoveryKind.trends,
        now: now,
      );
      expect(result.length, 1);
      expect(result.single.rankScore, 1);
    },
  );
  test(
    'releases use exact recent dates; future and old catalog additions excluded',
    () {
      final result = aggregateDiscovery(
        [
          ranking('a', [
            track('old', name: 'Old', date: '2020-01-01'),
            track('future', name: 'Future', date: '2026-11-13'),
            track('year', name: 'Year', date: '2026'),
            track('invalid', name: 'Invalid', date: '2026-02-31'),
            track('valid', name: 'Fresh', date: '2026-11-10'),
          ]),
        ],
        DiscoveryKind.newReleases,
        now: now,
      );
      expect(result.map((e) => e.track.id), ['valid']);
    },
  );
  test('diversity interleaves artists without dropping entries', () {
    final result = aggregateDiscovery(
      [
        ranking('a', [
          for (var i = 0; i < 6; i++) track('$i', name: 'Song $i'),
          track('other', artist: 'Other'),
        ]),
      ],
      DiscoveryKind.trends,
      now: now,
    );
    expect(result.length, 7);
    expect(result[2].track.artistName, 'Other');
  });
  test(
    'new songs surface among higher ranked albums without changing scores',
    () {
      final albums = [
        for (var i = 0; i < 6; i++)
          track(
            'album$i',
            name: 'Album $i',
            artist: 'Artist $i',
            itemType: 'album',
            date: '2026-11-12',
          ),
      ];
      final songs = [
        track('song1', name: 'New song', artist: 'Singer', date: '2026-11-12'),
        track(
          'song2',
          name: 'Another song',
          artist: 'Singer 2',
          date: '2026-11-12',
        ),
      ];
      final input = [
        ranking('a', [...albums, ...songs]),
      ];
      final releases = aggregateDiscovery(
        input,
        DiscoveryKind.newReleases,
        now: now,
      );
      expect(releases.map((e) => e.track.id), [
        'album0',
        'album1',
        'song1',
        'album2',
        'album3',
        'song2',
        'album4',
        'album5',
      ]);
      expect(releases[2].rankScore, closeTo(61 / 67, 0.00001));
      final trends = aggregateDiscovery(input, DiscoveryKind.trends, now: now);
      expect(trends.take(6).every((e) => e.track.isAlbumItem), isTrue);
    },
  );
  test(
    'release type diversity also surfaces albums and keeps single type feeds',
    () {
      final songs = [
        for (var i = 0; i < 5; i++)
          track(
            's$i',
            name: 'Song $i',
            artist: 'Artist $i',
            date: '2026-11-12',
          ),
      ];
      final mixed = aggregateDiscovery(
        [
          ranking('a', [
            ...songs,
            track(
              'album',
              name: 'Album',
              artist: 'Album Artist',
              itemType: 'album',
              date: '2026-11-12',
            ),
          ]),
        ],
        DiscoveryKind.newReleases,
        now: now,
      );
      expect(mixed[2].track.id, 'album');
      expect(mixed.length, 6);
      final onlySongs = aggregateDiscovery(
        [ranking('a', songs)],
        DiscoveryKind.newReleases,
        now: now,
      );
      expect(onlySongs.map((e) => e.track.id), songs.map((t) => t.id));
    },
  );
  test('merged metadata retains Deezer resolver identity and source links', () {
    final result = aggregateDiscovery(
      [
        ranking('apple-music', [
          track(
            'apple-id',
            source: 'apple-music',
            isrc: 'ISRC',
            explicit: true,
          ),
        ]),
        ranking('deezer', [track('42', source: 'deezer')]),
      ],
      DiscoveryKind.trends,
      now: now,
    );
    expect(result.single.track.source, 'apple-music');
    expect(result.single.track.deezerId, '42');
    expect(
      result.single.origins.last.sourceUrl,
      'https://www.deezer.com/track/42',
    );
  });

  test(
    'selected provider receives native identity after merge and cache reload',
    () {
      final merged = aggregateDiscovery(
        [
          ranking('deezer', [track('42', source: 'deezer', explicit: true)]),
          ranking('yandex-music', [
            track('987', source: 'yandex-music', duration: 0),
          ]),
        ],
        DiscoveryKind.trends,
        now: now,
      ).single;
      final restored = DiscoveryEntry.fromJson(merged.toJson());
      final selected = discoveryTrackForService(
        restored.track,
        restored.origins,
        'yandex-music',
      );
      expect(selected.source, 'yandex-music');
      expect(selected.id, '987');
      expect(selected.duration, 180);
      expect(
        discoveryTrackForService(
          restored.track,
          restored.origins,
          'unknown',
        ).source,
        'deezer',
      );
    },
  );

  test('JSON retains provenance and source failures', () {
    final feed = DiscoveryFeed(
      entries: aggregateDiscovery(
        [
          ranking('a', [track('a')]),
        ],
        DiscoveryKind.trends,
        now: now,
      ),
      fetchedAt: now,
      region: 'mixed',
      sourceName: 'Unified',
      sources: const [
        DiscoverySourceStatus(
          sourceId: 'a',
          sourceName: 'A',
          region: 'us',
          isStale: true,
        ),
        DiscoverySourceStatus(
          sourceId: 'b',
          sourceName: 'B',
          region: 'auto',
          isUnavailable: true,
        ),
      ],
    );
    final restored = DiscoveryFeed.fromJson(feed.toJson());
    expect(restored.entries.single.origins.single.nativeId, 'a');
    expect(restored.entries.single.rankScore, 1);
    expect(restored.sources.last.isUnavailable, isTrue);
  });
}
