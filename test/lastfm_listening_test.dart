import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/wave_listening_observer.dart';
import 'package:mornye/services/lastfm_account_service.dart';

void main() {
  late Duration elapsed;
  late WaveListeningObserver listening;
  MediaItem? currentItem;
  PlaybackState? currentState;
  var enabled = true;
  var unknownArtist = 'Unknown artist';
  late List<LastfmListeningTrack> announcements;
  late List<(LastfmListeningTrack, DateTime)> scrobbles;
  final start = DateTime.utc(2026, 11, 1, 12);
  MediaItem track({
    int instance = 1,
    int? seconds = 240,
    String artist = 'Artist',
  }) => MediaItem(
    id: 'file:///private/song.flac',
    title: 'Song',
    artist: artist,
    album: 'Album',
    duration: seconds == null ? null : Duration(seconds: seconds),
    extras: {'playbackInstance': instance},
  );
  PlaybackState state({
    bool playing = true,
    bool buffering = false,
    int position = 0,
  }) => PlaybackState(
    playing: playing,
    processingState: buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready,
    updatePosition: Duration(seconds: position),
  );

  setUp(() {
    elapsed = Duration.zero;
    announcements = [];
    scrobbles = [];
    listening = WaveListeningObserver(
      maxSampleGap: const Duration(days: 1),
      now: () => start.add(elapsed),
    );
    currentItem = null;
    currentState = null;
    enabled = true;
    unknownArtist = 'Unknown artist';
  });

  void tick() {
    final result = listening.observe(
      currentItem,
      currentState,
      elapsed,
      enabled: enabled,
      unknownArtist: unknownArtist,
    );
    if (result.nowPlaying case final occurrence?) {
      announcements.add(occurrence.track);
    }
    for (final occurrence in result.scrobbles) {
      scrobbles.add((occurrence.track, occurrence.startedAt));
    }
  }

  void update(
    MediaItem item,
    PlaybackState state, {
    required bool enabledValue,
    String unknownArtistValue = 'Unknown artist',
  }) {
    currentItem = item;
    currentState = state;
    enabled = enabledValue;
    unknownArtist = unknownArtistValue;
    tick();
  }

  test('scrobbles at half duration once, with original UTC start time', () {
    update(track(), state(), enabledValue: true);
    expect(announcements, hasLength(1));
    elapsed = const Duration(seconds: 119);
    tick();
    expect(scrobbles, isEmpty);
    elapsed = const Duration(seconds: 120);
    tick();
    expect(scrobbles.single.$2, start);
    expect(scrobbles.single.$1.parameters, {
      'track': 'Song',
      'artist': 'Artist',
      'album': 'Album',
      'duration': '240',
    });
    elapsed = const Duration(minutes: 10);
    tick();
    expect(scrobbles, hasLength(1));
  });

  test('seeking does not add listening time or begin another play', () {
    update(track(), state(), enabledValue: true);
    elapsed = const Duration(seconds: 10);
    update(track(), state(position: 230), enabledValue: true);
    expect(scrobbles, isEmpty);
    elapsed = const Duration(seconds: 20);
    update(track(), state(position: 0), enabledValue: true);
    expect(announcements, hasLength(1));
    elapsed = const Duration(seconds: 120);
    tick();
    expect(scrobbles, hasLength(1));
  });

  test(
    'pause and buffering stop accrual; resume keeps the listening total',
    () {
      update(track(), state(), enabledValue: true);
      elapsed = const Duration(seconds: 40);
      update(track(), state(playing: false), enabledValue: true);
      elapsed = const Duration(minutes: 10);
      update(track(), state(buffering: true), enabledValue: true);
      elapsed += const Duration(seconds: 30);
      update(track(), state(), enabledValue: true);
      elapsed += const Duration(seconds: 79);
      tick();
      expect(scrobbles, isEmpty);
      elapsed += const Duration(seconds: 1);
      tick();
      expect(scrobbles, hasLength(1));
      expect(scrobbles.single.$2, start);
      expect(announcements, hasLength(2));
    },
  );

  test('short songs are excluded; long songs qualify after four minutes', () {
    update(track(seconds: 30), state(), enabledValue: true);
    elapsed = const Duration(minutes: 10);
    tick();
    expect(scrobbles, isEmpty);
    update(track(instance: 2, seconds: 900), state(), enabledValue: true);
    elapsed += const Duration(seconds: 239);
    tick();
    expect(scrobbles, isEmpty);
    elapsed += const Duration(seconds: 1);
    tick();
    expect(scrobbles, hasLength(1));
  });

  test('metadata updates preserve a play and late duration can qualify it', () {
    update(track(seconds: null), state(), enabledValue: true);
    elapsed = const Duration(seconds: 120);
    update(track(), state(), enabledValue: true);
    expect(scrobbles, hasLength(1));
    update(
      track().copyWith(title: 'Edited title'),
      state(),
      enabledValue: true,
    );
    elapsed += const Duration(seconds: 120);
    tick();
    expect(scrobbles, hasLength(1));
    expect(announcements, hasLength(1));
  });

  test('repeat-one is a separate listen even with the same media ID', () {
    update(track(), state(), enabledValue: true);
    elapsed = const Duration(seconds: 120);
    tick();
    update(track(instance: 2), state(), enabledValue: true);
    elapsed += const Duration(seconds: 120);
    tick();
    expect(scrobbles, hasLength(2));
    expect(scrobbles.last.$2, start.add(const Duration(seconds: 120)));
    expect(announcements, hasLength(2));
  });

  test('restored paused position and disabled time are not scrobbled', () {
    update(track(), state(playing: false, position: 200), enabledValue: true);
    elapsed = const Duration(minutes: 20);
    update(track(), state(position: 200), enabledValue: false);
    elapsed += const Duration(minutes: 10);
    update(track(), state(position: 200), enabledValue: true);
    expect(scrobbles, isEmpty);
    elapsed += const Duration(seconds: 120);
    tick();
    expect(scrobbles.single.$2, start.add(const Duration(minutes: 30)));
    update(track(), state(), enabledValue: false);
    update(track(), state(), enabledValue: true);
    elapsed += const Duration(seconds: 120);
    tick();
    expect(scrobbles, hasLength(1));
  });

  test('missing and localized unknown metadata never leaves the player', () {
    update(track(artist: ''), state(), enabledValue: true);
    elapsed = const Duration(minutes: 5);
    tick();
    update(
      track(artist: 'Artis tidak dikenal'),
      state(),
      enabledValue: true,
      unknownArtistValue: 'Artis tidak dikenal',
    );
    elapsed += const Duration(minutes: 5);
    tick();
    expect(announcements, isEmpty);
    expect(scrobbles, isEmpty);
  });
}
