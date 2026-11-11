import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/playable_media.dart';

const catalog = Track(
  id: 'deezer:1234',
  source: 'deezer',
  deezerId: '1234',
  name: 'Duality',
  artistName: 'Slipknot',
  artistId: 'artist-1',
  albumName: 'Vol. 3',
  albumId: 'album-2',
  coverUrl: 'https://example.com/cover.jpg',
  isrc: 'USRR10400123',
  duration: 240,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'wave wrapper retains all playback fields and catalog data through JSON',
    () {
      const original = PlayableMedia(
        id: 'cache-file',
        source: '/app/wave/song.flac',
        title: 'Duality',
        artist: 'Slipknot',
        album: 'Vol. 3',
        artUri: 'https://example.com/old.jpg',
        duration: Duration(seconds: 240),
        bitDepth: 24,
        sampleRate: 96000,
        bitrate: 2500,
        format: 'flac',
        explicit: true,
        genre: 'Metal',
        autoplay: true,
      );
      final tagged = original.withWaveSession(
        'artist:Slipknot:Slipknot',
        track: catalog,
      );
      expect(tagged.id, original.id);
      expect(tagged.source, original.source);
      final expected = {
        ...original.toJson(),
        'artUri': catalog.coverUrl,
        'waveSessionKey': 'artist:Slipknot:Slipknot',
        'catalogTrack': catalog.toJson(),
      };
      expect(tagged.toJson(), expected);
      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(tagged.toJson())) as Map,
        ),
      )!;
      expect(restored.toJson(), expected);
      final item = restored.toMediaItem();
      expect(item.extras?['source'], '/app/wave/song.flac');
      expect(item.extras?['waveSessionKey'], 'artist:Slipknot:Slipknot');
      expect(item.artUri.toString(), catalog.coverUrl);
      final storedTrack = Track.fromJson(
        jsonDecode(item.extras!['catalogTrack'] as String)
            as Map<String, dynamic>,
      );
      expect(storedTrack.id, 'deezer:1234');
      expect(storedTrack.isrc, catalog.isrc);
    },
  );

  test(
    'uncatalogued cache file exposes original identity for favorite and save actions',
    () async {
      final media = playableFromTrack(
        catalog,
        '/app/wave/song.flac',
      ).withWaveSession('track:Slipknot:Duality', track: catalog);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final track = await container.read(
        playerCollectionTrackProvider(media.toMediaItem()).future,
      );
      expect(track.toJson(), catalog.toJson());
      expect(track.source, 'deezer');
      expect(track.id, isNot(media.source));
      expect(track.coverUrl, catalog.coverUrl);
    },
  );

  test(
    'changing wave context retains attached catalog and network artwork reference',
    () {
      const original = PlayableMedia(
        id: 'network',
        source: 'network://host/song.flac',
        title: 'Duality',
        artist: 'Slipknot',
        networkArtworkSource: 'network://host/cover.jpg',
        catalogTrack: catalog,
      );
      final changed = original.withWaveSession('personal::Моя волна');
      expect(changed.networkArtworkSource, original.networkArtworkSource);
      expect(changed.catalogTrack, same(catalog));
    },
  );

  test('ordinary playback remains unmarked after roundtrip', () {
    const original = PlayableMedia(
      id: 'library',
      source: '/library/song.flac',
      title: 'Song',
      artist: 'Artist',
    );
    final restored = PlayableMedia.fromJson(original.toJson())!;
    expect(restored.waveSessionKey, isNull);
    expect(restored.catalogTrack, isNull);
    expect(
      restored.toMediaItem().extras!.containsKey('waveSessionKey'),
      isFalse,
    );
    expect(restored.toMediaItem().extras!.containsKey('catalogTrack'), isFalse);
  });
}
