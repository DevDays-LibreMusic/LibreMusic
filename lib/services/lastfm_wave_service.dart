import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mornye/utils/logger.dart';

import 'package:http/http.dart' as http;

class LastfmWaveTrack {
  const LastfmWaveTrack({
    required this.title,
    required this.artist,
    this.artworkUrl,
  });

  final String title;
  final String artist;
  final String? artworkUrl;

  factory LastfmWaveTrack.fromJson(Map<String, dynamic> json) =>
      LastfmWaveTrack(
        title: json['title'] as String,
        artist: json['artist'] as String,
        artworkUrl: json['artworkUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    if (artworkUrl != null) 'artworkUrl': artworkUrl,
  };

  String get key => '${_normalize(artist)}\u0000${_normalize(title)}';
}

enum LastfmWaveErrorKind {
  invalidInput,
  invalidKey,
  notFound,
  rateLimited,
  accessDenied,
  unavailable,
  unexpectedResponse,
  timeout,
  network,
  tls,
  api,
  client,
}

class LastfmWaveException implements Exception {
  const LastfmWaveException(
    this.message, {
    this.code,
    this.kind = LastfmWaveErrorKind.api,
    this.method,
    this.httpStatus,
    this.jsonResponse,
    this.responseType,
  });

  final String message;
  final int? code;
  final LastfmWaveErrorKind kind;
  final String? method;
  final int? httpStatus;
  final bool? jsonResponse;

  /// Fixed classification, never a server-provided header or body.
  final String? responseType;

  String get diagnostic => [
    'Last.fm',
    'method=${method == 'user.getTopTracks' || method == 'track.getSimilar' ? method : 'unknown'}',
    'kind=${kind.name}',
    if (httpStatus != null) 'http=$httpStatus',
    if (code != null) 'api=$code',
    if (jsonResponse != null) 'json=$jsonResponse',
    if ({'json', 'html', 'other'}.contains(responseType))
      'response=$responseType',
  ].join(' ');

  String localizedMessage({required bool russian}) => !russian
      ? message
      : switch (kind) {
          LastfmWaveErrorKind.invalidInput =>
            'Укажите имя пользователя и API key Last.fm.',
          LastfmWaveErrorKind.invalidKey =>
            'Last.fm отклонил API key. Проверьте ключ в настройках волны.',
          LastfmWaveErrorKind.notFound =>
            'Last.fm не нашёл профиль или трек. Проверьте имя пользователя.',
          LastfmWaveErrorKind.rateLimited =>
            'Last.fm ограничил частоту запросов. Подождите и повторите.',
          LastfmWaveErrorKind.accessDenied =>
            'Last.fm отказал в доступе. Проверьте соединение и доступ к API.',
          LastfmWaveErrorKind.unavailable =>
            'Last.fm сообщил об ошибке сервиса. Повторите запрос позже.',
          LastfmWaveErrorKind.unexpectedResponse =>
            'Last.fm вернул неожиданный ответ. Это не означает, что история пуста.',
          LastfmWaveErrorKind.timeout =>
            'Last.fm не ответил вовремя. Проверьте соединение и повторите.',
          LastfmWaveErrorKind.network =>
            'Не удалось соединиться с Last.fm. Проверьте сеть и повторите.',
          LastfmWaveErrorKind.tls =>
            'Не удалось установить защищённое соединение с Last.fm. Проверьте дату устройства и сеть.',
          LastfmWaveErrorKind.api =>
            'Last.fm отклонил запрос. Код ошибки доступен в диагностике.',
          LastfmWaveErrorKind.client =>
            'Не удалось загрузить волну. Повторите запрос; диагностика доступна ниже.',
        };

  @override
  String toString() => '$message ($diagnostic)';
}

final _log = AppLogger('LastfmWave');
LastfmWaveException _logged(LastfmWaveException error) {
  // Never log the request URI, response body, key or raw transport exception.
  _log.e(error.diagnostic);
  return error;
}

String _normalize(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Metadata recommendations only: audio is resolved by the app's providers.
/// Uses public profile data; neither a Last.fm password nor a session is needed.
class LastfmWaveService {
  LastfmWaveService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  void dispose() => _client.close();

  Future<List<LastfmWaveTrack>> recommend({
    required String username,
    required String apiKey,
  }) async {
    username = username.trim();
    apiKey = apiKey.trim();
    if (username.isEmpty || apiKey.isEmpty) {
      throw const LastfmWaveException(
        'Enter a Last.fm username and API key.',
        kind: LastfmWaveErrorKind.invalidInput,
      );
    }
    Future<List<LastfmWaveTrack>> topTracks(String period) async => _tracks(
      await _request(apiKey, {
        'method': 'user.getTopTracks',
        'user': username,
        'period': period,
        'limit': '20',
      }),
      'toptracks',
    );

    var favorites = await topTracks('1month');
    if (favorites.isEmpty) favorites = await topTracks('overall');
    if (favorites.isEmpty) return [];

    final seeds = <LastfmWaveTrack>[];
    final seedArtists = <String>{};
    for (final track in favorites) {
      if (seedArtists.add(_normalize(track.artist))) seeds.add(track);
      if (seeds.length == 5) break;
    }
    for (final track in favorites) {
      if (seeds.length == 5) break;
      if (!seeds.any((seed) => seed.key == track.key)) seeds.add(track);
    }

    final groups = <List<LastfmWaveTrack>>[];
    LastfmWaveException? failure;
    var successfulRequests = 0;
    // Sequential requests bound API pressure and make the result deterministic.
    // Even large profiles cost at most seven requests (two charts + five seeds).
    for (final seed in seeds) {
      try {
        groups.add(
          _tracks(
            await _request(apiKey, {
              'method': 'track.getSimilar',
              'artist': seed.artist,
              'track': seed.title,
              'autocorrect': '1',
              'limit': '12',
            }),
            'similartracks',
          ),
        );
        successfulRequests++;
      } on LastfmWaveException catch (error) {
        // Bad keys and throttling affect every seed: stop rather than retrying.
        if ({4, 10, 26, 29}.contains(error.code)) rethrow;
        failure = error;
        // A track absent from Last.fm's similarity catalogue is a valid miss.
        if (error.code == 6 || error.code == 7) successfulRequests++;
      }
    }
    if (successfulRequests == 0 && failure != null) throw failure;

    final result = <LastfmWaveTrack>[];
    final seen = <String>{};
    final artistCounts = <String, int>{};
    void add(LastfmWaveTrack track) {
      final artist = _normalize(track.artist);
      if (result.length == 20 ||
          seen.contains(track.key) ||
          (artistCounts[artist] ?? 0) >= 3) {
        return;
      }
      seen.add(track.key);
      artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
      result.add(track);
    }

    // Interleave seeds instead of letting the first artist fill the whole wave.
    for (var position = 0; position < 12; position++) {
      for (final group in groups) {
        if (position < group.length) add(group[position]);
      }
    }
    // Familiar tracks keep a sparse similarity catalogue useful.
    for (final track in favorites) {
      add(track);
    }
    return List.unmodifiable(result);
  }

  Future<List<LastfmWaveTrack>> profileTracks(
    String apiKey,
    String username, {
    bool loved = false,
  }) async => _tracks(
    await _request(apiKey, {
      'method': loved ? 'user.getLovedTracks' : 'user.getTopTracks',
      'user': username,
      'limit': '100',
      if (!loved) 'period': 'overall',
    }),
    loved ? 'lovedtracks' : 'toptracks',
  );

  Future<List<LastfmWaveTrack>> similarTracks(
    String apiKey,
    LastfmWaveTrack track,
  ) async => _tracks(
    await _request(apiKey, {
      'method': 'track.getSimilar',
      'artist': track.artist,
      'track': track.title,
      'autocorrect': '1',
      'limit': '50',
    }),
    'similartracks',
  );

  Future<List<LastfmWaveTrack>> artistTracks(
    String apiKey,
    String artist,
  ) async => _tracks(
    await _request(apiKey, {
      'method': 'artist.getTopTracks',
      'artist': artist,
      'autocorrect': '1',
      'limit': '30',
    }),
    'toptracks',
  );

  Future<List<String>> similarArtists(String apiKey, String artist) async {
    final data = await _request(apiKey, {
      'method': 'artist.getSimilar',
      'artist': artist,
      'autocorrect': '1',
      'limit': '8',
    });
    final group = data['similarartists'];
    final raw = group is Map<String, dynamic> ? group['artist'] : null;
    if (raw is! List) return [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => e['name'])
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  Future<List<String>> searchArtists(String apiKey, String query) async {
    final data = await _request(apiKey, {
      'method': 'artist.search',
      'artist': query,
      'limit': '12',
    });
    final results = data['results'];
    final group = results is Map<String, dynamic>
        ? results['artistmatches']
        : null;
    final raw = group is Map<String, dynamic> ? group['artist'] : null;
    if (raw is! List) return [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => e['name'])
        .whereType<String>()
        .toList();
  }

  Future<List<LastfmWaveTrack>> genreTracks(
    String apiKey,
    String genre, {
    int page = 1,
  }) async => _tracks(
    await _request(apiKey, {
      'method': 'tag.getTopTracks',
      'tag': genre,
      'limit': '50',
      'page': '$page',
    }),
    'tracks',
  );

  Future<Map<String, dynamic>> _request(
    String apiKey,
    Map<String, String> parameters,
  ) async {
    final method = parameters['method'];
    try {
      final response = await _client
          .get(
            Uri.https('ws.audioscrobbler.com', '/2.0/', {
              ...parameters,
              'api_key': apiKey,
              'format': 'json',
            }),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'Mornye/5.3 LastfmWave',
            },
          )
          .timeout(const Duration(seconds: 12));
      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) data = decoded;
      } on FormatException {
        // Some gateways return HTML even for an API request. Do not echo it.
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final responseType = contentType.contains('json')
          ? 'json'
          : contentType.contains('html')
          ? 'html'
          : 'other';
      LastfmWaveException failure(
        LastfmWaveErrorKind kind,
        String message, {
        int? code,
      }) => LastfmWaveException(
        message,
        kind: kind,
        code: code,
        method: method,
        httpStatus: response.statusCode,
        jsonResponse: data != null,
        responseType: responseType,
      );
      // API codes are useful even when Last.fm sends a non-200 HTTP response.
      final code = int.tryParse('${data?['error']}');
      if (code != null) {
        final kind = switch (code) {
          6 || 7 => LastfmWaveErrorKind.notFound,
          4 || 10 || 26 => LastfmWaveErrorKind.invalidKey,
          29 => LastfmWaveErrorKind.rateLimited,
          8 || 11 || 16 => LastfmWaveErrorKind.unavailable,
          _ => LastfmWaveErrorKind.api,
        };
        throw failure(kind, switch (kind) {
          LastfmWaveErrorKind.notFound =>
            'Last.fm could not find this profile or track. Check the username.',
          LastfmWaveErrorKind.invalidKey =>
            'Last.fm rejected the API key. Check it in wave settings.',
          LastfmWaveErrorKind.rateLimited =>
            'Last.fm is limiting requests. Wait before trying again.',
          LastfmWaveErrorKind.unavailable =>
            'Last.fm reported a service error. Try again later.',
          _ => 'Last.fm rejected the request. See the diagnostic code below.',
        }, code: code);
      }
      if (response.statusCode == 429) {
        throw failure(
          LastfmWaveErrorKind.rateLimited,
          'Last.fm is limiting requests. Wait before trying again.',
          code: 29,
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw failure(
          LastfmWaveErrorKind.accessDenied,
          'Last.fm denied access. Check your connection and API access.',
        );
      }
      if (response.statusCode != 200) {
        throw failure(
          LastfmWaveErrorKind.unavailable,
          'Last.fm returned an HTTP error. Try again later.',
        );
      }
      if (data == null) {
        throw failure(
          LastfmWaveErrorKind.unexpectedResponse,
          'Last.fm returned an unexpected response. This does not mean your history is empty.',
        );
      }
      return data;
    } on LastfmWaveException catch (error) {
      throw _logged(error);
    } on TimeoutException {
      throw _logged(
        LastfmWaveException(
          'Last.fm did not respond. Check your connection and try again.',
          kind: LastfmWaveErrorKind.timeout,
          method: method,
        ),
      );
    } on HandshakeException {
      throw _logged(
        LastfmWaveException(
          'Could not establish a secure connection to Last.fm. Check your device date and network.',
          kind: LastfmWaveErrorKind.tls,
          method: method,
        ),
      );
    } on SocketException {
      throw _logged(
        LastfmWaveException(
          'Cannot reach Last.fm. Check your connection and try again.',
          kind: LastfmWaveErrorKind.network,
          method: method,
        ),
      );
    } on http.ClientException {
      throw _logged(
        LastfmWaveException(
          'Cannot reach Last.fm. Check your connection and try again.',
          kind: LastfmWaveErrorKind.network,
          method: method,
        ),
      );
    }
  }

  List<LastfmWaveTrack> _tracks(Map<String, dynamic> data, String container) {
    final group = data[container];
    if (group is! Map) {
      throw _logged(
        LastfmWaveException(
          'Last.fm returned an unexpected response.',
          kind: LastfmWaveErrorKind.unexpectedResponse,
          method: container == 'toptracks'
              ? 'user.getTopTracks'
              : 'track.getSimilar',
          httpStatus: 200,
          jsonResponse: true,
        ),
      );
    }
    final raw = group['track'];
    if (raw is! List && raw is! Map) {
      throw _logged(
        LastfmWaveException(
          'Last.fm returned an unexpected response.',
          kind: LastfmWaveErrorKind.unexpectedResponse,
          method: container == 'toptracks'
              ? 'user.getTopTracks'
              : 'track.getSimilar',
          httpStatus: 200,
          jsonResponse: true,
        ),
      );
    }
    final entries = raw is List
        ? raw
        : (raw is Map ? [raw] : const <Object?>[]);
    final result = <LastfmWaveTrack>[];
    for (final item in entries) {
      if (item is! Map) continue;
      final title = item['name'];
      final rawArtist = item['artist'];
      final artist = rawArtist is Map ? rawArtist['name'] : rawArtist;
      if (title is! String ||
          title.trim().isEmpty ||
          artist is! String ||
          artist.trim().isEmpty) {
        continue;
      }
      String? artwork;
      final images = item['image'];
      if (images is List) {
        for (final image in images) {
          final url = image is Map ? image['#text'] : null;
          final uri = url is String ? Uri.tryParse(url) : null;
          if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
            artwork = url as String;
          }
        }
      }
      result.add(
        LastfmWaveTrack(
          title: title.trim(),
          artist: artist.trim(),
          artworkUrl: artwork,
        ),
      );
    }
    if (entries.isNotEmpty && result.isEmpty) {
      throw _logged(
        LastfmWaveException(
          'Last.fm returned malformed track data.',
          kind: LastfmWaveErrorKind.unexpectedResponse,
          method: container == 'toptracks'
              ? 'user.getTopTracks'
              : 'track.getSimilar',
          httpStatus: 200,
          jsonResponse: true,
        ),
      );
    }
    return result;
  }
}
