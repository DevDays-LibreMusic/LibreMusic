import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/recommendation_provider.dart';
import 'package:mornye/screens/recommendations_screen.dart';
import 'package:mornye/theme/app_theme.dart';

class _Profiles extends RecommendationProfiles {
  @override
  Future<List<RecommendationProfile>> build() async => const [
    RecommendationProfile(id: 'work', name: 'Work'),
  ];
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() {
  testWidgets(
    'profile navigation and invalid input do not start recommendation work',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (Platform.environment.containsKey('REC_SCREENSHOT_DIR')) {
        await tester.runAsync(() async {
          for (final entry in {
            'Inter': 'assets/fonts/InterVariable.ttf',
            'Google Sans Flex': 'assets/fonts/GoogleSansFlex.ttf',
            'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
            'packages/material_symbols_icons/MaterialSymbolsRounded':
                'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
          }.entries) {
            await (FontLoader(
              entry.key,
            )..addFont(rootBundle.load(entry.value))).load();
          }
        });
      }
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recommendationProfilesProvider.overrideWith(_Profiles.new),
            activeRecommendationProfileProvider.overrideWithValue('work'),
            libraryCollectionsProvider.overrideWith(_Collections.new),
          ],
          child: RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const RecommendationsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        final directory = Platform.environment['REC_SCREENSHOT_DIR'];
        if (directory == null) return;
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('profiles');
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Used for Library Autoplay'), findsOneWidget);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(find.text('Recommendation profile'), findsOneWidget);
      await capture('editor');
      await tester.enterText(find.byType(TextField).first, '');
      await tester.tap(find.byTooltip('Save profile'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text(
          'Enter a name and valid non-negative ranges. Minimum must not exceed maximum.',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
