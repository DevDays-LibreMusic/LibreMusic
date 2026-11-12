import 'dart:async';
import 'dart:convert';

import 'package:synchronized/synchronized.dart';
import 'package:mornye/services/lastfm_account_service.dart';
import 'package:mornye/utils/logger.dart';

abstract interface class LastfmAccountStorage {
  Future<String?> readSession();
  Future<void> writeSession(String? value);
  Future<String?> readData();
  Future<void> writeData(String value);
}

class LastfmAccountState {
  const LastfmAccountState({
    required this.appConfigured,
    this.loading = false,
    this.username,
    this.connected = false,
    this.authorizationPending = false,
    this.needsReauthentication = false,
    this.scrobblingEnabled = true,
    this.nowPlayingEnabled = true,
    this.loveSyncEnabled = true,
    this.pendingCount = 0,
    this.error,
  });

  final bool appConfigured;
  final bool loading;
  final String? username;
  final bool connected;
  final bool authorizationPending;
  final bool needsReauthentication;
  final bool scrobblingEnabled;
  final bool nowPlayingEnabled;
  final bool loveSyncEnabled;
  final int pendingCount;
  final LastfmAccountException? error;
}

class _PendingEntry {
  const _PendingEntry({
    required this.id,
    required this.owner,
    required this.track,
    required this.startedAt,
    this.loved,
    this.chosenByUser = false,
  });

  final String id;
  final String owner;
  final LastfmListeningTrack track;
  final DateTime startedAt;
  final bool? loved;
  final bool chosenByUser;
  bool get isScrobble => loved == null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner': owner,
    'track': track.toJson(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'loved': loved,
    'chosenByUser': chosenByUser,
  };

  factory _PendingEntry.fromJson(Map<String, dynamic> json) => _PendingEntry(
    id: json['id'] as String,
    owner: json['owner'] as String,
    track: LastfmListeningTrack.fromJson(
      Map<String, dynamic>.from(json['track'] as Map),
    ),
    startedAt: DateTime.parse(json['startedAt'] as String),
    loved: json['loved'] as bool?,
    chosenByUser: json['chosenByUser'] as bool? ?? false,
  );
}

/// Serializes account changes and sends durable, account-bound listening events.
/// The player supplies actual audible time, never the seek position.
class LastfmAccountController {
  LastfmAccountController({
    required LastfmAccountService service,
    required LastfmAccountStorage storage,
    DateTime Function()? now,
    Duration retryInterval = const Duration(minutes: 1),
  }) : _service = service,
       _storage = storage,
       _now = now ?? DateTime.now {
    _state = LastfmAccountState(
      appConfigured: service.credentials.configured,
      loading: true,
    );
    ready = _load();
    if (retryInterval > Duration.zero) {
      _retryTimer = Timer.periodic(retryInterval, (_) => unawaited(flush()));
    }
  }

  final LastfmAccountService _service;
  final LastfmAccountStorage _storage;
  final DateTime Function() _now;
  final _lock = Lock();
  final _events = StreamController<LastfmAccountState>.broadcast();
  final _log = AppLogger('LastfmAccount');
  late final Future<void> ready;
  late LastfmAccountState _state;
  LastfmAccountState get state => _state;

  Stream<LastfmAccountState> get states => Stream.multi((sink) {
    sink.add(_state);
    final subscription = _events.stream.listen(
      sink.add,
      onError: sink.addError,
      onDone: sink.close,
    );
    sink.onCancel = subscription.cancel;
  });

  LastfmSession? _session;
  String? _pendingToken;
  int _authorizationGeneration = 0;
  bool _reauth = false;
  bool _scrobblingEnabled = true;
  bool _nowPlayingEnabled = true;
  bool _loveSyncEnabled = true;
  List<_PendingEntry> _pending = [];
  Map<String, int> _delivered = {};
  LastfmAccountException? _error;
  Timer? _retryTimer;
  bool _disposed = false;
  bool _flushing = false;
  DateTime? _retryAfter;

  Future<void> _load() async {
    try {
      final sessionText = await _storage.readSession();
      if (sessionText != null) {
        final data = jsonDecode(sessionText) as Map<String, dynamic>;
        if (data['apiKey'] == _service.credentials.apiKey) {
          final username = data['username'] as String?;
          final key = data['sessionKey'] as String?;
          if (username != null &&
              username.isNotEmpty &&
              key != null &&
              key.isNotEmpty) {
            _session = LastfmSession(username: username, key: key);
          }
          _pendingToken = data['pendingToken'] as String?;
        }
      }
      final dataText = await _storage.readData();
      if (dataText != null) {
        final data = jsonDecode(dataText) as Map<String, dynamic>;
        _scrobblingEnabled = data['scrobblingEnabled'] as bool? ?? true;
        _nowPlayingEnabled = data['nowPlayingEnabled'] as bool? ?? true;
        _loveSyncEnabled = data['loveSyncEnabled'] as bool? ?? true;
        final owner = _session?.username.toLowerCase();
        if (owner != null && data['owner'] == owner) {
          _reauth = data['reauth'] as bool? ?? false;
          _pending = (data['pending'] as List? ?? [])
              .map(
                (entry) => _PendingEntry.fromJson(
                  Map<String, dynamic>.from(entry as Map),
                ),
              )
              .where((entry) => entry.owner == owner)
              .toList();
          _delivered = Map<String, int>.from(data['delivered'] as Map? ?? {});
        }
      }
    } on Object {
      _error = const LastfmAccountException(LastfmAccountErrorKind.storage);
      _log.e('stage=load kind=storage');
    }
    _emit();
    if (!_disposed) unawaited(flush());
  }

  Future<void> _persistSession() => _storage.writeSession(
    _session == null && _pendingToken == null
        ? null
        : jsonEncode({
            'apiKey': _service.credentials.apiKey,
            'username': _session?.username,
            'sessionKey': _session?.key,
            'pendingToken': _pendingToken,
          }),
  );

  void _trimHistory() {
    final oldest = _now()
        .subtract(const Duration(days: 14))
        .millisecondsSinceEpoch;
    _delivered.removeWhere((_, timestamp) => timestamp < oldest);
    _pending.removeWhere(
      (entry) => entry.startedAt.millisecondsSinceEpoch < oldest,
    );
    if (_pending.length > 2000) _pending.removeRange(0, _pending.length - 2000);
  }

  Future<void> _persistData() async {
    _trimHistory();
    await _storage.writeData(
      jsonEncode({
        'owner': _session?.username.toLowerCase(),
        'scrobblingEnabled': _scrobblingEnabled,
        'nowPlayingEnabled': _nowPlayingEnabled,
        'loveSyncEnabled': _loveSyncEnabled,
        'reauth': _reauth,
        'pending': _pending.map((entry) => entry.toJson()).toList(),
        'delivered': _delivered,
      }),
    );
  }

  void _emit() {
    if (_disposed) return;
    _state = LastfmAccountState(
      appConfigured: _service.credentials.configured,
      username: _session?.username,
      connected: _session != null && !_reauth,
      authorizationPending: _pendingToken != null,
      needsReauthentication: _reauth,
      scrobblingEnabled: _scrobblingEnabled,
      nowPlayingEnabled: _nowPlayingEnabled,
      loveSyncEnabled: _loveSyncEnabled,
      pendingCount: _pending.length,
      error: _error,
    );
    _events.add(_state);
  }

  void _report(Object error, String stage) {
    _error = error is LastfmAccountException
        ? error
        : const LastfmAccountException(LastfmAccountErrorKind.storage);
    _log.e('stage=$stage kind=${_error!.kind.name} code=${_error!.code}');
    _emit();
  }

  Future<Uri?> beginAuthorization() async {
    final generation = ++_authorizationGeneration;
    await ready;
    return _lock.synchronized(() async {
      if (_disposed) return null;
      try {
        final token = await _service.requestToken();
        if (_disposed || generation != _authorizationGeneration) return null;
        _pendingToken = token;
        await _persistSession();
        _error = null;
        _emit();
        return _service.authorizationUri(token);
      } on Object catch (error) {
        _report(error, 'begin_authorization');
        return null;
      }
    });
  }

  Future<bool> completeAuthorization() async {
    final generation = _authorizationGeneration;
    await ready;
    final connected = await _lock.synchronized(() async {
      if (_disposed || _pendingToken == null) return false;
      try {
        final session = await _service.exchangeToken(_pendingToken!);
        if (_disposed || generation != _authorizationGeneration) return false;
        if (_session?.username.toLowerCase() !=
            session.username.toLowerCase()) {
          _pending = [];
          _delivered = {};
        }
        final previousSession = _session;
        _session = session;
        _pendingToken = null;
        _reauth = false;
        _retryAfter = null;
        await _persistSession();
        if (_disposed || generation != _authorizationGeneration) {
          _session = previousSession;
          await _persistSession();
          return false;
        }
        await _persistData();
        _error = null;
        _emit();
        return true;
      } on Object catch (error) {
        _report(error, 'complete_authorization');
        return false;
      }
    });
    if (connected) unawaited(flush());
    return connected;
  }

  Future<void> cancelAuthorization() async {
    _authorizationGeneration++;
    await ready;
    await _lock.synchronized(() async {
      if (_disposed) return;
      try {
        _pendingToken = null;
        await _persistSession();
        _error = null;
        _emit();
      } on Object catch (error) {
        _report(error, 'cancel_authorization');
      }
    });
  }

  Future<void> disconnect() async {
    _authorizationGeneration++;
    await ready;
    await _lock.synchronized(() async {
      if (_disposed) return;
      try {
        await _storage.writeSession(null);
        _session = null;
        _pendingToken = null;
        _pending = [];
        _delivered = {};
        _reauth = false;
        _retryAfter = null;
        await _persistData();
        _error = null;
        _emit();
      } on Object catch (error) {
        _report(error, 'disconnect');
      }
    });
  }

  Future<void> setScrobblingEnabled(bool enabled) =>
      _setPreference(() => _scrobblingEnabled = enabled);
  Future<void> setNowPlayingEnabled(bool enabled) =>
      _setPreference(() => _nowPlayingEnabled = enabled);
  Future<void> setLoveSyncEnabled(bool enabled) =>
      _setPreference(() => _loveSyncEnabled = enabled);

  Future<void> _setPreference(void Function() update) async {
    await ready;
    await _lock.synchronized(() async {
      if (_disposed) return;
      try {
        update();
        await _persistData();
        _emit();
      } on Object catch (error) {
        _report(error, 'settings');
      }
    });
    unawaited(flush());
  }

  /// The caller uses one playId for an actual playback occurrence and supplies
  /// elapsed audible time. Calling this repeatedly cannot enqueue it twice.
  Future<void> recordListening({
    required String playId,
    required LastfmListeningTrack track,
    required DateTime startedAt,
    required Duration listened,
    bool chosenByUser = false,
  }) async {
    if (!track.qualifies(listened) || playId.isEmpty) return;
    await ready;
    await _lock.synchronized(() async {
      if (_disposed || _session == null || !_scrobblingEnabled) return;
      final owner = _session!.username.toLowerCase();
      final id = 'scrobble:$playId';
      if (_delivered.containsKey(id) ||
          _pending.any((entry) => entry.id == id)) {
        return;
      }
      if (startedAt.isAfter(_now()) ||
          startedAt.isBefore(_now().subtract(const Duration(days: 14)))) {
        return;
      }
      final entry = _PendingEntry(
        id: id,
        owner: owner,
        track: track,
        startedAt: startedAt.toUtc(),
        chosenByUser: chosenByUser,
      );
      try {
        _pending.add(entry);
        await _persistData();
        _emit();
      } on Object catch (error) {
        _pending.remove(entry);
        _report(error, 'queue_scrobble');
      }
    });
    unawaited(flush());
  }

  Future<void> setLoved(LastfmListeningTrack track, bool loved) async {
    if (!track.valid) return;
    await ready;
    await _lock.synchronized(() async {
      if (_disposed || _session == null || !_loveSyncEnabled) return;
      final oldPending = List<_PendingEntry>.of(_pending);
      try {
        final id = 'love:${track.key}';
        _pending.removeWhere((entry) => entry.id == id);
        _pending.add(
          _PendingEntry(
            id: id,
            owner: _session!.username.toLowerCase(),
            track: track,
            startedAt: _now().toUtc(),
            loved: loved,
          ),
        );
        await _persistData();
        _emit();
      } on Object catch (error) {
        _pending = oldPending;
        _report(error, 'queue_love');
      }
    });
    unawaited(flush());
  }

  /// Now-playing is ephemeral: offline failures must never be replayed later.
  Future<void> nowPlaying(LastfmListeningTrack track) async {
    if (!track.valid) return;
    await ready;
    await _lock.synchronized(() async {
      if (_disposed ||
          _session == null ||
          _reauth ||
          !_scrobblingEnabled ||
          !_nowPlayingEnabled) {
        return;
      }
      try {
        await _service.nowPlaying(_session!, track);
      } on LastfmAccountException catch (error) {
        if (error.kind == LastfmAccountErrorKind.sessionExpired) {
          _reauth = true;
          try {
            await _persistData();
          } on Object {
            _log.e('stage=now_playing_session kind=storage');
          }
        }
        _report(error, 'now_playing');
      }
    });
  }

  Future<void> flush() async {
    await ready;
    if (_disposed || _flushing) return;
    _flushing = true;
    try {
      while (!_disposed) {
        final keepGoing = await _lock.synchronized(_sendNext);
        if (!keepGoing) break;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _sendNext() async {
    if (_disposed ||
        _session == null ||
        _reauth ||
        !_service.credentials.configured ||
        (_retryAfter != null && _now().isBefore(_retryAfter!))) {
      return false;
    }
    _trimHistory();
    final entries = _pending.where(
      (entry) =>
          entry.owner == _session!.username.toLowerCase() &&
          (entry.isScrobble ? _scrobblingEnabled : _loveSyncEnabled),
    );
    if (entries.isEmpty) return false;
    final entry = entries.first;
    try {
      if (entry.isScrobble) {
        final result = await _service.scrobble(
          _session!,
          entry.track,
          startedAt: entry.startedAt,
          chosenByUser: entry.chosenByUser,
        );
        if (result.retryLater) {
          _retryAfter = _now().add(
            result.ignoredCode == 5
                ? const Duration(hours: 24)
                : const Duration(minutes: 5),
          );
          _error = const LastfmAccountException(
            LastfmAccountErrorKind.temporarilyUnavailable,
          );
          _emit();
          return false;
        }
        _error = result.accepted
            ? null
            : const LastfmAccountException(LastfmAccountErrorKind.rejected);
        _delivered[entry.id] = _now().millisecondsSinceEpoch;
      } else {
        await _service.setLoved(_session!, entry.track, entry.loved!);
        _error = null;
      }
      _pending.remove(entry);
      await _persistData();
      _retryAfter = null;
      _emit();
      return true;
    } on LastfmAccountException catch (error) {
      if (error.kind == LastfmAccountErrorKind.sessionExpired) {
        _reauth = true;
      } else if (error.kind == LastfmAccountErrorKind.rejected) {
        _pending.remove(entry);
        if (entry.isScrobble) {
          _delivered[entry.id] = _now().millisecondsSinceEpoch;
        }
      } else if (error.retryable) {
        _retryAfter = _now().add(const Duration(minutes: 1));
      }
      try {
        await _persistData();
      } on Object {
        _log.e('stage=flush_error kind=storage');
      }
      _report(error, 'flush');
      return error.kind == LastfmAccountErrorKind.rejected;
    } on Object catch (error) {
      _report(error, 'flush');
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _service.dispose();
    unawaited(_events.close());
  }
}
