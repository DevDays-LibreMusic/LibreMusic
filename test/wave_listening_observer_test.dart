import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/wave_listening_observer.dart';

const song = MediaItem(
  id: 'song',
  title: 'Duality',
  artist: 'Slipknot',
  duration: Duration(seconds: 80),
);
const otherSong = MediaItem(
  id: 'other',
  title: 'Система',
  artist: 'Егор Летов',
  duration: Duration(seconds: 80),
);
PlaybackState playing({
  bool isPlaying = true,
  AudioProcessingState processing = AudioProcessingState.ready,
  int index = 0,
  Duration position = Duration.zero,
}) => PlaybackState(
  playing: isPlaying,
  processingState: processing,
  queueIndex: index,
  updatePosition: position,
);

void main() {
  late WaveListeningObserver observer;
  setUp(() {
    observer = WaveListeningObserver(now: () => DateTime.utc(2026, 11, 11));
  });

  WaveListeningUpdate sample(
    int seconds, {
    MediaItem? item = song,
    PlaybackState? state,
    bool newOccurrence = false,
    bool chosenByUser = false,
  }) => observer.observe(
    item,
    state ?? playing(),
    Duration(seconds: seconds),
    newOccurrence: newOccurrence,
    chosenByUser: chosenByUser,
  );

  test('loading or failed media never becomes a listening occurrence', () {
    expect(
      sample(
        0,
        state: playing(processing: AudioProcessingState.loading),
      ).current,
      isNull,
    );
    expect(
      sample(
        10,
        state: playing(processing: AudioProcessingState.error),
      ).nowPlaying,
      isNull,
    );
    final update = sample(11, item: null, state: playing(isPlaying: false));
    expect(update.finished, isNull);
    expect(update.scrobbles, isEmpty);
  });

  test('starts at actual ready playback and announces it only once', () {
    sample(0, state: playing(processing: AudioProcessingState.loading));
    final ready = sample(4);
    expect(ready.nowPlaying?.track.title, 'Duality');
    expect(ready.current?.listened, Duration.zero);
    expect(sample(5).nowPlaying, isNull);
    expect(sample(6).current?.listened, const Duration(seconds: 2));
  });

  test('seeking changes position but never adds listened duration', () {
    sample(0);
    sample(1, state: playing(position: const Duration(seconds: 70)));
    final result = sample(2, state: playing(position: Duration.zero));
    expect(result.current?.listened, const Duration(seconds: 2));
    expect(result.scrobbles, isEmpty);
  });

  test('pause and buffering intervals are excluded', () {
    sample(0);
    sample(1, state: playing(isPlaying: false));
    sample(2, state: playing(isPlaying: false));
    sample(3, state: playing(processing: AudioProcessingState.buffering));
    sample(4);
    expect(sample(5).current?.listened, const Duration(seconds: 2));
  });

  test(
    'same-id late duration metadata preserves occurrence and qualifies it',
    () {
      const unknown = MediaItem(
        id: 'song',
        title: 'Duality',
        artist: 'Slipknot',
      );
      final initial = sample(0, item: unknown);
      for (var i = 1; i <= 40; i++) {
        expect(sample(i, item: unknown).scrobbles, isEmpty);
      }
      final known = sample(40);
      expect(known.current?.playId, initial.current?.playId);
      expect(known.current?.track.duration, const Duration(seconds: 80));
      expect(known.scrobbles, hasLength(1));
      expect(sample(41).scrobbles, isEmpty);
    },
  );

  test('qualified event is emitted once per occurrence', () {
    sample(0);
    var emitted = 0;
    for (var i = 1; i <= 60; i++) {
      emitted += sample(i).scrobbles.length;
    }
    final ended = sample(61, item: otherSong, state: playing(index: 1));
    expect(ended.finished?.listened, const Duration(seconds: 61));
    expect(ended.current?.listened, Duration.zero);
    expect(emitted, 1);
    expect(ended.scrobbles, isEmpty);
  });

  test('final interval can qualify previous song before switching', () {
    sample(0);
    for (var i = 1; i < 40; i++) {
      sample(i);
    }
    final changed = sample(40, item: otherSong, state: playing(index: 1));
    expect(changed.scrobbles.single.track.title, 'Duality');
    expect(changed.finished?.listened, const Duration(seconds: 40));
    expect(changed.nowPlaying?.track.title, 'Система');
  });

  test('explicit replay of same song creates distinct occurrence', () {
    final initial = sample(0);
    sample(1);
    final replay = sample(2, newOccurrence: true);
    expect(replay.current?.playId, isNot(initial.current?.playId));
    expect(replay.finished?.listened, const Duration(seconds: 2));
    expect(replay.current?.listened, Duration.zero);
  });

  test('same song in next queue row creates distinct occurrence', () {
    final initial = sample(0);
    final repeated = sample(1, state: playing(index: 1));
    expect(repeated.current?.playId, isNot(initial.current?.playId));
    expect(repeated.finished?.track.title, 'Duality');
  });

  test(
    'completion then replay creates distinct occurrence even at same queue row',
    () {
      final initial = sample(0);
      sample(
        1,
        state: playing(
          isPlaying: false,
          processing: AudioProcessingState.completed,
        ),
      );
      final replay = sample(2);
      expect(replay.current?.playId, isNot(initial.current?.playId));
      expect(replay.nowPlaying, isNotNull);
    },
  );

  test('pause/resume keeps occurrence and refreshes now-playing', () {
    final initial = sample(0);
    sample(1, state: playing(isPlaying: false));
    final resumed = sample(20);
    expect(resumed.current?.playId, initial.current?.playId);
    expect(resumed.current?.listened, const Duration(seconds: 1));
    expect(resumed.nowPlaying?.playId, initial.current?.playId);
  });

  test(
    'long unobserved interval is capped rather than invented as listening',
    () {
      sample(0);
      final delayed = sample(120);
      expect(delayed.current?.listened, const Duration(seconds: 5));
      expect(delayed.scrobbles, isEmpty);
    },
  );

  test('clock rollback cannot subtract elapsed listening', () {
    sample(10);
    sample(11);
    expect(sample(9).current?.listened, const Duration(seconds: 1));
  });

  test(
    'choice belongs to occurrence and does not change when wave context changes',
    () {
      sample(0, chosenByUser: true);
      expect(sample(1, chosenByUser: false).current?.chosenByUser, isTrue);
    },
  );
  test('account change at threshold discards previous account listening', () {
    observer.observe(song, playing(), Duration.zero, owner: 'A');
    for (var second = 1; second < 40; second++) {
      observer.observe(song, playing(), Duration(seconds: second), owner: 'A');
    }
    final changed = observer.observe(
      song,
      playing(),
      const Duration(seconds: 40),
      owner: 'B',
    );
    expect(changed.scrobbles, isEmpty);
    expect(changed.finished, isNull);
    expect(changed.current?.listened, Duration.zero);
    final disconnected = observer.observe(
      song,
      playing(),
      const Duration(seconds: 41),
    );
    expect(disconnected.current?.listened, Duration.zero);
  });

  test(
    'enabling now playing announces current song without resetting time',
    () {
      observer.observe(
        song,
        playing(),
        Duration.zero,
        nowPlayingEnabled: false,
      );
      final muted = observer.observe(
        song,
        playing(),
        const Duration(seconds: 3),
        nowPlayingEnabled: false,
      );
      expect(muted.nowPlaying, isNull);
      final enabled = observer.observe(
        song,
        playing(),
        const Duration(seconds: 4),
      );
      expect(enabled.nowPlaying?.playId, muted.current?.playId);
      expect(enabled.current?.listened, const Duration(seconds: 4));
    },
  );
}
