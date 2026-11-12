import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/widgets/collection_header_actions.dart';

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() {
  testWidgets('collection header exposes its play action', (tester) async {
    var played = false;
    const tracks = [
      Track(
        id: 'track',
        name: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [libraryCollectionsProvider.overrideWith(_Collections.new)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CollectionHeaderActions(
              tracks: tracks,
              onLoveAll: () {},
              onPlay: () => played = true,
              downloadIcon: Icons.download,
              onDownloadAll: () {},
              addToPlaylistIcon: Icons.add,
              onAddToPlaylist: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Play'));
    expect(played, isTrue);
  });
}
