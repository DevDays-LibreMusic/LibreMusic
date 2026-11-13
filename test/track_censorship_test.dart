import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/track_censorship.dart';
import 'package:mornye/services/track_search_ranking.dart';
import 'package:mornye/utils/string_utils.dart';

Track _track(
  String id, {
  String name = 'Song',
  String artist = 'Artist',
  bool? explicit,
  String? quality,
  String? itemType,
}) => Track(
  id: id,
  name: name,
  artistName: artist,
  albumName: 'Album',
  duration: 200,
  explicit: explicit,
  audioQuality: quality,
  itemType: itemType,
);

void main() {
  test('metadata distinguishes explicit, non-explicit and unknown', () {
    expect(
      Track.fromBackendMap({'name': 'Song', 'explicit': true}).censorship,
      TrackCensorship.explicit,
    );
    expect(
      Track.fromBackendMap({'name': 'Song', 'explicit': false}).censorship,
      TrackCensorship.clean,
    );
    expect(
      Track.fromBackendMap({'name': 'Song'}).censorship,
      TrackCensorship.unknown,
    );
    for (final track in [
      _track('explicit', explicit: true),
      _track('clean', explicit: false),
      _track('unknown'),
    ]) {
      expect(Track.fromJson(track.toJson()).censorship, track.censorship);
    }
  });

  test('parser does not turn unknown source values into clean metadata', () {
    expect(parseExplicitFlag(0), isFalse);
    expect(parseExplicitFlag(1), isTrue);
    expect(parseExplicitFlag(2), isNull);
    expect(parseExplicitFlag('false'), isFalse);
    expect(parseExplicitFlag('explicit'), isTrue);
    expect(parseExplicitFlag('unknown'), isNull);
  });

  test('title fallback uses only deliberate version markers', () {
    for (final name in [
      'Song (Clean)',
      'Song [Edited]',
      'Song - Censored Version',
    ]) {
      expect(_track('clean', name: name).censorship, TrackCensorship.clean);
    }
    for (final name in ['Song (Explicit)', 'Song [Uncensored]']) {
      expect(
        _track('explicit', name: name).censorship,
        TrackCensorship.explicit,
      );
    }
    for (final name in [
      'Clean',
      'Clean Up Your Act',
      'Explicitly Yours',
      'Censorship Song',
    ]) {
      expect(_track('unknown', name: name).censorship, TrackCensorship.unknown);
    }
    expect(
      _track('metadata', name: 'Song (Clean)', explicit: true).censorship,
      TrackCensorship.explicit,
    );
  });

  test(
    'default ranks uncensored versions first without losing relevance order',
    () {
      final explicit = _track('explicit', explicit: true, quality: 'HI_RES');
      final clean = _track('clean', explicit: false, quality: 'LOSSLESS');
      final unknown = _track('unknown');
      final otherClean = _track('other', name: 'Another Song', explicit: false);
      final ranked = rankTrackSearchResults([
        explicit,
        otherClean,
        unknown,
        clean,
      ]);
      expect(ranked.map((track) => track.id), [
        'explicit',
        'other',
        'unknown',
        'clean',
      ]);
      expect(ranked, hasLength(4));
    },
  );

  test(
    'quality-first setting and unknown fallback remain explicit choices',
    () {
      final explicit = _track('explicit', explicit: true, quality: 'HI_RES');
      final clean = _track('clean', explicit: false, quality: 'LOSSLESS');
      final unknown = _track('unknown');
      expect(
        rankTrackSearchResults([
          clean,
          unknown,
          explicit,
        ], preferExplicit: false).map((track) => track.id),
        ['explicit', 'clean', 'unknown'],
      );
      expect(rankTrackSearchResults([unknown, explicit]).first, same(explicit));
    },
  );

  test(
    'live, remix and collection results are not folded into studio versions',
    () {
      final studio = _track('studio', explicit: true);
      final live = _track('live', name: 'Song (Live)', explicit: false);
      final remix = _track('remix', name: 'Song (Remix)', explicit: false);
      final album = _track(
        'album',
        artist: '',
        itemType: 'album',
        explicit: false,
      );
      expect(
        rankTrackSearchResults([studio, live, remix, album]).map((t) => t.id),
        ['studio', 'live', 'remix', 'album'],
      );
    },
  );

  test('setting defaults to uncensored-first and survives JSON', () {
    const initial = AppSettings();
    expect(initial.preferExplicitTracks, isTrue);
    final changed = initial.copyWith(preferExplicitTracks: false);
    expect(
      AppSettings.fromJson(changed.toJson()).preferExplicitTracks,
      isFalse,
    );
    expect(AppSettings.fromJson(const {}).preferExplicitTracks, isTrue);
  });
}
