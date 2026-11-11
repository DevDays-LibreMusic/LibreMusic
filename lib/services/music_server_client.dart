import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/services/secure_storage_options.dart';

class MusicServerException implements Exception {
  const MusicServerException(this.code);
  final String code;
  @override
  String toString() => 'Music server: $code';
}

/// Stores only the server address and session, never audio or signed media URLs.
class MusicServerClient {
  MusicServerClient({
    http.Client? client,
    Future<String?> Function()? readSession,
    Future<void> Function(String?)? writeSession,
  }) : _client = client ?? http.Client(),
       _readSession = readSession ?? (() => _storage.read(key: _key)),
       _writeSession =
           writeSession ??
           ((value) => value == null
               ? _storage.delete(key: _key)
               : _storage.write(key: _key, value: value));

  static final instance = MusicServerClient();
  static const _key = 'music_server_session_v1';
  static const _storage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  static const scheme = 'musicserver';
  final http.Client _client;
  final Future<String?> Function() _readSession;
  final Future<void> Function(String?) _writeSession;
  Uri? _base;
  String _access = '', _refresh = '', _user = '';
  Future<void>? _loading, _refreshing;
  Future<void> _persistence = Future.value();
  int _generation = 0;

  bool get connected => _base != null && _refresh.isNotEmpty;
  String get address => _base?.toString() ?? '';
  String get identity =>
      sha256.convert(utf8.encode('$address/$_user')).toString();
  static bool owns(String source) => Uri.tryParse(source)?.scheme == scheme;

  static Uri validateAddress(String address) {
    final uri = Uri.parse(address.trim());
    final loopback =
        uri.host == 'localhost' ||
        (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
    if ((uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const MusicServerException('invalid_address');
    }
    return uri.replace(path: '');
  }

  Future<void> restore() => _loading ??= _restore();
  Future<void> _restore() async {
    final generation = _generation;
    final saved = await _readSession();
    if (saved == null || generation != _generation) return;
    try {
      final value = jsonDecode(saved) as Map<String, dynamic>;
      if (value['version'] != 1) return;
      _base = validateAddress(value['address'] as String);
      _refresh = value['refresh_token'] as String;
      _user = value['user_id'] as String;
    } catch (_) {
      _base = null;
      _refresh = '';
      _user = '';
    }
  }

  Future<void> _save() {
    final value = connected
        ? jsonEncode({
            'version': 1,
            'address': address,
            'refresh_token': _refresh,
            'user_id': _user,
          })
        : null;
    final next = _persistence
        .catchError((Object _) {})
        .then((_) => _writeSession(value));
    _persistence = next;
    return next;
  }

  Future<Map<String, dynamic>> _send(
    Uri base,
    String method,
    String path, {
    Map<String, dynamic>? body,
    String token = '',
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const MusicServerException('response_too_large');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode == 401) {
      throw const MusicServerException('unauthorized');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MusicServerException('http_${response.statusCode}');
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> login(String address, String username, String password) async {
    await restore();
    final base = validateAddress(address);
    final generation = ++_generation;
    final value = await _send(
      base,
      'POST',
      '/v1/auth/login',
      body: {'username': username.trim(), 'password': password},
    );
    if (generation != _generation) return;
    _base = base;
    _access = value['access_token'] as String;
    _refresh = value['refresh_token'] as String;
    _user = value['user_id'] as String;
    await _save();
  }

  Future<void> _refreshAccess() =>
      _refreshing ??= _rotate().whenComplete(() => _refreshing = null);
  Future<void> _rotate() async {
    final generation = _generation;
    final value = await _send(
      _base!,
      'POST',
      '/v1/auth/refresh',
      body: {'refresh_token': _refresh},
    );
    if (generation != _generation) {
      throw const MusicServerException('session_changed');
    }
    _access = value['access_token'] as String;
    _refresh = value['refresh_token'] as String;
    await _save();
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    await restore();
    if (!connected) throw const MusicServerException('not_connected');
    final generation = _generation;
    if (_access.isEmpty) await _refreshAccess();
    final access = _access;
    Map<String, dynamic> value;
    try {
      value = await _send(_base!, method, path, body: body, token: access);
    } on MusicServerException catch (error) {
      if (error.code != 'unauthorized' || generation != _generation) rethrow;
      if (_access == access) await _refreshAccess();
      value = await _send(_base!, method, path, body: body, token: _access);
    }
    if (generation != _generation) {
      throw const MusicServerException('session_changed');
    }
    return value;
  }

  Future<void> logout() async {
    try {
      if (connected) await request('POST', '/v1/auth/logout');
    } finally {
      ++_generation;
      _base = null;
      _access = '';
      _refresh = '';
      _user = '';
      await _save();
    }
  }

  String source(String id) =>
      Uri(scheme: scheme, host: identity, path: '/$id').toString();

  /// Whether [source] is a durable asset reference owned by the restored
  /// account. This does not create a playback ticket or contact the server.
  Future<bool> canResolveSource(String source) async {
    await restore();
    final uri = Uri.tryParse(source);
    return connected &&
        uri?.scheme == scheme &&
        uri?.host == identity &&
        uri?.pathSegments.length == 1 &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(uri!.pathSegments.single);
  }

  Future<String> resolve(String source) async {
    await restore();
    final uri = Uri.parse(source);
    if (!connected ||
        uri.scheme != scheme ||
        uri.host != identity ||
        uri.pathSegments.length != 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.pathSegments.single)) {
      throw const MusicServerException('source_unavailable');
    }
    final ticket = await request(
      'POST',
      '/v1/assets/${uri.pathSegments.single}/playback-ticket',
    );
    final path = ticket['path'] as String;
    if (!RegExp(r'^/v1/media/[a-f0-9]{64}$').hasMatch(path)) {
      throw const MusicServerException('invalid_ticket');
    }
    return _base!.resolve(path).toString();
  }
}
