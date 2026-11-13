import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/audio_version_demucs.dart';
import 'package:mornye/services/audio_version_learned.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only the calibrated, content-confirmed comparison may produce A or B.
/// Unknown (including mixed direction or identity mismatch) never writes a rule.
enum AudioSourcePreferenceVerdict { a, b, unknown }

/// Identity supplied by a direct, verified provider download, never a title match.
class AudioProviderSource {
  const AudioProviderSource(
    this.providerId,
    this.itemId, {
    this.materializedDigest,
  });
  final String providerId, itemId;
  final String? materializedDigest;
  String get key => 'provider:${jsonEncode([providerId, itemId])}';
}

class AudioSourcePair {
  const AudioSourcePair(this.sourceA, this.sourceB, this.digestA, this.digestB);
  final String sourceA, sourceB, digestA, digestB;
}

/// Local-file preferences are scoped to the exact bytes of BOTH compared files.
/// No artist/title, explicit metadata, URL or provider identity implies a match.
class AudioSourcePreference {
  AudioSourcePreference({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = AudioSourcePreference();
  static const algorithmVersion = 'local-content-direction-v1';
  static const _key = 'audio_source_preferences_v1';
  final Future<SharedPreferences> Function() _preferences;

  static File? _file(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null || (uri.scheme.isNotEmpty && uri.scheme != 'file')) {
      return null;
    }
    return uri.scheme == 'file' ? File.fromUri(uri) : File(source);
  }

  static Future<String?> _digest(String source) async {
    try {
      final file = _file(source);
      if (file == null) return null;
      return (await sha256.bind(file.openRead()).first).toString();
    } catch (_) {
      return null;
    }
  }

  /// Capture before analysis, then save revalidates after analysis. SAF/provider
  /// streams require an immutable retained source binding before supporting them.
  Future<AudioSourcePair?> capture(String sourceA, String sourceB) async {
    if (sourceA == sourceB) return null;
    final a = await _digest(sourceA);
    final b = await _digest(sourceB);
    if (a == null || b == null) return null;
    return AudioSourcePair(sourceA, sourceB, a, b);
  }

  Future<bool> _matches(AudioSourcePair pair) async =>
      await _digest(pair.sourceA) == pair.digestA &&
      await _digest(pair.sourceB) == pair.digestB;

  Future<Map<String, dynamic>> _read(SharedPreferences prefs) async {
    try {
      return jsonDecode(prefs.getString(_key) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// User action only. Saving never interrupts an already active playback deck.
  Future<bool> saveConfirmed(
    AudioSourcePair pair,
    AudioSourcePreferenceVerdict verdict, {
    required String directionModelSha256,
    required String contentModelSha256,
    AudioProviderSource? providerA,
    AudioProviderSource? providerB,
  }) async {
    if ((providerA != null || providerB != null) &&
        (providerA?.materializedDigest != pair.digestA ||
            providerB?.materializedDigest != pair.digestB)) {
      return false;
    }
    if (directionModelSha256 != AudioVersionDemucsRunner.modelSha256 ||
        contentModelSha256 != AudioVersionLearnedRunner.modelSha256 ||
        verdict == AudioSourcePreferenceVerdict.unknown ||
        !await _matches(pair)) {
      return false;
    }
    final prefs = await _preferences();
    final rules = await _read(prefs);
    final rule = {
      'a': pair.sourceA,
      'b': pair.sourceB,
      'hashA': pair.digestA,
      'hashB': pair.digestB,
      'preferred': verdict == AudioSourcePreferenceVerdict.a
          ? pair.sourceA
          : pair.sourceB,
      'version': algorithmVersion,
      if (providerA != null && providerB != null)
        'providerKeys': [providerA.key, providerB.key],
      'directionModel': directionModelSha256,
      'contentModel': contentModelSha256,
    };
    // Both entries refer to the same pair, making swapped inputs symmetric.
    rules[pair.sourceA] = rule;
    rules[pair.sourceB] = rule;
    if (providerA != null && providerB != null) {
      rules[providerA.key] = rule;
      rules[providerB.key] = rule;
    }
    return prefs.setString(_key, jsonEncode(rules));
  }

  /// Return null on any invalidation/unavailability so normal resolution wins.
  Future<String?> preferredSource(String source) => _preferred(source);

  Future<String?> preferredProviderSource(String providerId, String itemId) =>
      _preferred(AudioProviderSource(providerId, itemId).key, provider: true);

  Future<String?> _preferred(String source, {bool provider = false}) async {
    try {
      final prefs = await _preferences();
      final rules = await _read(prefs);
      final raw = rules[source];
      if (raw is! Map ||
          raw['version'] != algorithmVersion ||
          raw['directionModel'] != AudioVersionDemucsRunner.modelSha256 ||
          raw['contentModel'] != AudioVersionLearnedRunner.modelSha256) {
        return null;
      }
      final pair = AudioSourcePair(
        raw['a'] as String,
        raw['b'] as String,
        raw['hashA'] as String,
        raw['hashB'] as String,
      );
      final preferred = raw['preferred'] as String;
      if ((provider
              ? !(raw['providerKeys'] is List &&
                    (raw['providerKeys'] as List).contains(source))
              : (source != pair.sourceA && source != pair.sourceB)) ||
          (preferred != pair.sourceA && preferred != pair.sourceB) ||
          !await _matches(pair)) {
        return null;
      }
      return preferred;
    } catch (_) {
      return null;
    }
  }
}
