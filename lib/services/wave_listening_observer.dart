import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/lastfm_account_service.dart';

class WaveListeningOccurrence {
  const WaveListeningOccurrence({
    required this.playId,
    required this.track,
    required this.startedAt,
    required this.listened,
    required this.chosenByUser,
  });

  final String playId;
  final LastfmListeningTrack track;
  final DateTime startedAt;
  final Duration listened;
  final bool chosenByUser;
  bool get qualifies => track.qualifies(listened);
}

class WaveListeningUpdate {
  const WaveListeningUpdate({
    this.current,
    this.nowPlaying,
    this.finished,
    this.scrobbles = const [],
  });

  final WaveListeningOccurrence? current;
  final WaveListeningOccurrence? nowPlaying;
  final WaveListeningOccurrence? finished;

  /// Newly qualified occurrences. Durable delivery and retries belong to the
  /// account controller; [current] can also be offered to its deduplicated queue.
  final List<WaveListeningOccurrence> scrobbles;
}

/// Observes coherent player snapshots. Position is deliberately not used as
/// elapsed listening time: seeking must not manufacture a scrobble.
class WaveListeningObserver {
  WaveListeningObserver({
    DateTime Function()? now,
    this.maxSampleGap = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration maxSampleGap;
  MediaItem? _item;
  PlaybackState? _playback;
  Duration? _sampleAt;
  Duration _listened = Duration.zero;
  DateTime? _startedAt;
  String? _playId;
  int _serial = 0;
  int? _queueIndex;
  bool _chosenByUser = false;
  bool _announced = false;
  bool _qualified = false;
  bool _ended = false;
  String? _owner;

  WaveListeningOccurrence? get current {
    final item = _item;
    final started = _startedAt;
    final id = _playId;
    if (item == null || started == null || id == null) return null;
    return WaveListeningOccurrence(
      playId: id,
      track: LastfmListeningTrack(
        title: item.title,
        artist: item.artist ?? '',
        album: item.album ?? '',
        duration: item.duration ?? Duration.zero,
      ),
      startedAt: started,
      listened: _listened,
      chosenByUser: _chosenByUser,
    );
  }

  WaveListeningUpdate observe(
    MediaItem? item,
    PlaybackState? playback,
    Duration monotonic, {
    bool newOccurrence = false,
    bool enabled = true,
    String? owner,
    bool nowPlayingEnabled = true,
    bool chosenByUser = false,
    String unknownTitle = 'Unknown title',
    String unknownArtist = 'Unknown artist',
  }) {
    if (owner != _owner) {
      // Account transitions must never finalize the previous owner's play.
      _owner = owner;
      _item = null;
      _playback = null;
      _sampleAt = null;
      _listened = Duration.zero;
      _startedAt = null;
      _playId = null;
      _queueIndex = null;
      _announced = false;
      _qualified = false;
      _ended = false;
    }
    if (!nowPlayingEnabled) _announced = false;
    if (item?.title.trim() == unknownTitle ||
        item?.artist?.trim() == unknownArtist) {
      item = null;
    }
    if (!enabled) playback = playback?.copyWith(playing: false);
    final scrobbles = <WaveListeningOccurrence>[];
    final last = _sampleAt;
    if (last != null && monotonic >= last && _audible(_playback)) {
      final elapsed = monotonic - last;
      _listened += elapsed > maxSampleGap ? maxSampleGap : elapsed;
    }
    _sampleAt = monotonic;

    final identityChanged =
        item?.id != _item?.id ||
        item?.extras?['playbackInstance'] != _item?.extras?['playbackInstance'];
    final queueChanged =
        item != null &&
        _item != null &&
        _queueIndex != null &&
        playback?.queueIndex != null &&
        _queueIndex != playback?.queueIndex;
    final replayed = _ended && _audible(playback);
    WaveListeningOccurrence? finished;
    if (identityChanged || queueChanged || newOccurrence || replayed) {
      finished = current;
      _qualify(scrobbles);
      _listened = Duration.zero;
      _startedAt = null;
      _playId = null;
      _announced = false;
      _qualified = false;
      _ended = false;
      _chosenByUser = chosenByUser;
    }

    // Replacing metadata for the same occurrence is essential when the engine
    // learns the duration after playback has started.
    _item = item;
    _playback = playback;
    _queueIndex = playback?.queueIndex;
    if (playback?.playing != true) _announced = false;
    WaveListeningOccurrence? nowPlaying;
    if (item != null && _audible(playback)) {
      if (_startedAt == null) {
        _startedAt = _now().toUtc();
        _playId =
            '${_startedAt!.microsecondsSinceEpoch}:${++_serial}:${item.id}';
        _chosenByUser = chosenByUser;
      }
      if (nowPlayingEnabled && !_announced && current!.track.valid) {
        _announced = true;
        nowPlaying = current;
      }
    }
    if (playback?.processingState == AudioProcessingState.completed ||
        playback?.processingState == AudioProcessingState.idle) {
      _ended = true;
    }
    _qualify(scrobbles);
    return WaveListeningUpdate(
      current: current,
      nowPlaying: nowPlaying,
      finished: finished,
      scrobbles: scrobbles,
    );
  }

  void _qualify(List<WaveListeningOccurrence> result) {
    final occurrence = current;
    if (!_qualified && occurrence != null && occurrence.qualifies) {
      _qualified = true;
      result.add(occurrence);
    }
  }

  bool _audible(PlaybackState? playback) =>
      playback?.playing == true &&
      (playback?.speed ?? 0) > 0 &&
      playback?.processingState == AudioProcessingState.ready &&
      _item != null;
}
