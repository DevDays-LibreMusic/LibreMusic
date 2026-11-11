import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:synchronized/synchronized.dart';

class LastfmAppCredentials {
  const LastfmAppCredentials({
    required this.apiKey,
    required this.sharedSecret,
  });

  const LastfmAppCredentials.fromEnvironment()
    : apiKey = const String.fromEnvironment('LASTFM_API_KEY'),
      sharedSecret = const String.fromEnvironment('LASTFM_API_SECRET');

  final String apiKey;
  final String sharedSecret;
  bool get configured =>
      apiKey.trim().isNotEmpty && sharedSecret.trim().isNotEmpty;
}

class LastfmListeningTrack {
  const LastfmListeningTrack({
    required this.title,
    required this.artist,
    this.album = '',
    this.duration = Duration.zero,
  });

  final String title;
  final String artist;
  final String album;
  final Duration duration;

  bool get valid => title.trim().isNotEmpty && artist.trim().isNotEmpty;
  String get key =>
      '${artist.trim().toLowerCase()}\u0000${title.trim().toLowerCase()}';

  bool qualifies(Duration listened) =>
      valid &&
      duration > const Duration(seconds: 30) &&
      listened.inMilliseconds >=
          (duration.inMilliseconds ~/ 2).clamp(0, 240000);

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration.inMilliseconds,
  };

  factory LastfmListeningTrack.fromJson(Map<String, dynamic> json) =>
      LastfmListeningTrack(
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String? ?? '',
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
      );

  Map<String, String> get parameters => {
    'track': title.trim(),
    'artist': artist.trim(),
    if (album.trim().isNotEmpty) 'album': album.trim(),
    if (duration > Duration.zero) 'duration': '${duration.inSeconds}',
  };
}

class LastfmSession {
  const LastfmSession({required this.username, required this.key});
  final String username;
  final String key;
}

enum LastfmAccountErrorKind {
  notConfigured,
  authorizationPending,
  tokenExpired,
  sessionExpired,
  applicationRejected,
  network,
  temporarilyUnavailable,
  rejected,
  invalidResponse,
  storage,
}

class LastfmAccountException implements Exception {
  const LastfmAccountException(this.kind, {this.code});
  final LastfmAccountErrorKind kind;
  final int? code;

  bool get retryable => {
    LastfmAccountErrorKind.network,
    LastfmAccountErrorKind.temporarilyUnavailable,
    LastfmAccountErrorKind.invalidResponse,
  }.contains(kind);

  String message({bool russian = true}) => switch (kind) {
    LastfmAccountErrorKind.notConfigured =>
      russian
          ? 'В этой сборке не настроено подключение Last.fm.'
          : 'Last.fm connection is not configured in this build.',
    LastfmAccountErrorKind.authorizationPending =>
      russian
          ? 'Подтвердите подключение в браузере и вернитесь в приложение.'
          : 'Approve the connection in your browser and return to the app.',
    LastfmAccountErrorKind.tokenExpired =>
      russian
          ? 'Ссылка подключения истекла. Начните подключение заново.'
          : 'The connection link expired. Start connecting again.',
    LastfmAccountErrorKind.sessionExpired =>
      russian
          ? 'Подключите Last.fm повторно. Музыка продолжит играть.'
          : 'Reconnect Last.fm. Your music will keep playing.',
    LastfmAccountErrorKind.applicationRejected =>
      russian
          ? 'Last.fm отклонил настройки приложения. Требуется обновление сборки.'
          : 'Last.fm rejected the app credentials. An updated build is needed.',
    LastfmAccountErrorKind.network =>
      russian
          ? 'Нет связи с Last.fm. История будет отправлена позже.'
          : 'Cannot reach Last.fm. Listening history will be sent later.',
    LastfmAccountErrorKind.temporarilyUnavailable =>
      russian
          ? 'Last.fm временно недоступен. Повторим отправку позже.'
          : 'Last.fm is temporarily unavailable. We will retry later.',
    LastfmAccountErrorKind.rejected =>
      russian
          ? 'Last.fm не принял запись. Остальная история сохранена.'
          : 'Last.fm rejected an entry. The rest of your history is saved.',
    LastfmAccountErrorKind.invalidResponse =>
      russian
          ? 'Не удалось прочитать ответ Last.fm. Повторим позже.'
          : 'Could not read the Last.fm response. We will retry later.',
    LastfmAccountErrorKind.storage =>
      russian
          ? 'Не удалось сохранить настройки Last.fm на устройстве.'
          : 'Could not save Last.fm settings on this device.',
  };

  @override
  String toString() => 'LastfmAccountException(${kind.name}, code=$code)';
}

class LastfmScrobbleResult {
  const LastfmScrobbleResult({required this.accepted, this.ignoredCode = 0});
  final bool accepted;
  final int ignoredCode;
  bool get retryLater => ignoredCode == 4 || ignoredCode == 5;
}

/// Last.fm's signed desktop authorization flow also works in a mobile browser.
/// Only application credentials are supplied by the build; sessions stay local.
class LastfmAccountService {
  LastfmAccountService({
    required this.credentials,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.minimumInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final LastfmAppCredentials credentials;
  final http.Client _client;
  final Duration timeout;
  final Duration minimumInterval;
  final _requestLock = Lock();
  final _requestClock = Stopwatch()..start();
  Duration? _lastRequest;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _client.close();
  }

  Uri authorizationUri(String token) => Uri.https('www.last.fm', '/api/auth/', {
    'api_key': credentials.apiKey,
    'token': token,
  });

  Future<String> requestToken() async {
    final json = await _request('auth.getToken');
    final token = json['token'];
    if (token is! String || token.isEmpty) throw _invalidResponse;
    return token;
  }

  Future<LastfmSession> exchangeToken(String token) async {
    final json = await _request(
      'auth.getSession',
      parameters: {'token': token},
    );
    final session = json['session'];
    if (session is! Map ||
        session['name'] is! String ||
        (session['name'] as String).isEmpty ||
        session['key'] is! String ||
        (session['key'] as String).isEmpty) {
      throw _invalidResponse;
    }
    return LastfmSession(
      username: session['name'] as String,
      key: session['key'] as String,
    );
  }

  Future<void> nowPlaying(
    LastfmSession session,
    LastfmListeningTrack track,
  ) async {
    await _request(
      'track.updateNowPlaying',
      session: session,
      parameters: track.parameters,
    );
  }

  Future<void> setLoved(
    LastfmSession session,
    LastfmListeningTrack track,
    bool loved,
  ) async {
    await _request(
      loved ? 'track.love' : 'track.unlove',
      session: session,
      parameters: {'artist': track.artist.trim(), 'track': track.title.trim()},
    );
  }

  Future<LastfmScrobbleResult> scrobble(
    LastfmSession session,
    LastfmListeningTrack track, {
    required DateTime startedAt,
    required bool chosenByUser,
  }) async {
    final json = await _request(
      'track.scrobble',
      session: session,
      parameters: {
        ...track.parameters,
        'timestamp': '${startedAt.toUtc().millisecondsSinceEpoch ~/ 1000}',
        'chosenByUser': chosenByUser ? '1' : '0',
      },
    );
    final result = json['scrobbles'];
    if (result is! Map || result['@attr'] is! Map) throw _invalidResponse;
    final attributes = result['@attr'] as Map;
    final accepted = int.tryParse('${attributes['accepted']}');
    final ignored = int.tryParse('${attributes['ignored']}');
    if (accepted == 1 && ignored == 0) {
      return const LastfmScrobbleResult(accepted: true);
    }
    if (accepted == 0 && ignored == 1) {
      final scrobble = result['scrobble'];
      final entry = scrobble is List && scrobble.length == 1
          ? scrobble.single
          : scrobble;
      if (entry is Map && entry['ignoredMessage'] is Map) {
        final message = entry['ignoredMessage'] as Map;
        final code = int.tryParse('${message['code']}');
        if (code != null && code >= 1 && code <= 5) {
          return LastfmScrobbleResult(accepted: false, ignoredCode: code);
        }
      }
    }
    throw _invalidResponse;
  }

  static const _invalidResponse = LastfmAccountException(
    LastfmAccountErrorKind.invalidResponse,
  );

  Future<Map<String, dynamic>> _request(
    String method, {
    LastfmSession? session,
    Map<String, String> parameters = const {},
  }) => _requestLock.synchronized(() async {
    if (!credentials.configured) {
      throw const LastfmAccountException(LastfmAccountErrorKind.notConfigured);
    }
    final last = _lastRequest;
    if (last != null) {
      final wait = minimumInterval - (_requestClock.elapsed - last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    if (_disposed) {
      throw const LastfmAccountException(LastfmAccountErrorKind.network);
    }
    _lastRequest = _requestClock.elapsed;
    return _performRequest(method, session: session, parameters: parameters);
  });

  Future<Map<String, dynamic>> _performRequest(
    String method, {
    LastfmSession? session,
    Map<String, String> parameters = const {},
  }) async {
    if (!credentials.configured) {
      throw const LastfmAccountException(LastfmAccountErrorKind.notConfigured);
    }
    final values = <String, String>{
      ...parameters,
      'method': method,
      'api_key': credentials.apiKey,
      if (session != null) 'sk': session.key,
    };
    final keys = values.keys.toList()..sort();
    final signature = keys.map((key) => '$key${values[key]}').join();
    values['api_sig'] = md5
        .convert(utf8.encode('$signature${credentials.sharedSecret}'))
        .toString();
    values['format'] = 'json';
    http.Response response;
    try {
      const headers = {'User-Agent': 'Mornye/Lastfm'};
      response = await _client
          .post(
            Uri.https('ws.audioscrobbler.com', '/2.0/'),
            headers: headers,
            body: values,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const LastfmAccountException(LastfmAccountErrorKind.network);
    } on IOException {
      throw const LastfmAccountException(LastfmAccountErrorKind.network);
    } on http.ClientException {
      throw const LastfmAccountException(LastfmAccountErrorKind.network);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw const LastfmAccountException(
          LastfmAccountErrorKind.temporarilyUnavailable,
        );
      }
      throw _invalidResponse;
    }
    if (decoded is! Map<String, dynamic>) throw _invalidResponse;
    final error = int.tryParse('${decoded['error']}');
    if (error != null) {
      throw LastfmAccountException(switch (error) {
        14 => LastfmAccountErrorKind.authorizationPending,
        15 => LastfmAccountErrorKind.tokenExpired,
        9 => LastfmAccountErrorKind.sessionExpired,
        4 || 10 || 13 || 26 => LastfmAccountErrorKind.applicationRejected,
        8 || 11 || 16 || 29 => LastfmAccountErrorKind.temporarilyUnavailable,
        _ => LastfmAccountErrorKind.rejected,
      }, code: error);
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw const LastfmAccountException(
        LastfmAccountErrorKind.temporarilyUnavailable,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const LastfmAccountException(LastfmAccountErrorKind.rejected);
    }
    return decoded;
  }
}
