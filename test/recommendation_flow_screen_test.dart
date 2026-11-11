import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/recommendation_profile.dart';
import 'package:mornye/providers/recommendation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/recommendation_flow_screen.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/recommendations/recommendation_engine.dart';
import 'package:mornye/services/recommendations/recommendation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'support/fixed_settings.dart';

class _Profiles extends RecommendationProfiles {
  @override
  Future<List<RecommendationProfile>> build() async => [];
}

class _Service extends RecommendationService {
  final requests = <RecommendationProfile>[];
  final responses = <Completer<RecommendationResult>>[];
  @override
  Future<RecommendationResult> generate(
    RecommendationProfile profile, {
    bool includeLocal = true,
    int limit = 20,
    List<PlayableMedia> session = const [],
    Set<String> excludedSources = const {},
    Future<List<AutoplaySignal>> Function(List<PlayableMedia>)? loadSignals,
    bool Function()? cancelled,
  }) {
    requests.add(profile);
    final response = Completer<RecommendationResult>();
    responses.add(response);
    return response.future;
  }
}

RecommendationResult result(String title) => RecommendationResult([
  RecommendationPick(
    RecommendationCandidate(
      PlayableMedia(
        id: title,
        source: '/music/$title.mp3',
        title: title,
        artist: 'Artist',
      ),
    ),
    const {},
  ),
], matched: 1);

void main() {
  testWidgets('filters combine, stale results cannot replace newer selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (Platform.environment.containsKey('REC_FLOW_SCREENSHOT')) {
      await tester.runAsync(() async {
        for (final entry in {
          'Inter': 'assets/fonts/InterVariable.ttf',
          'Google Sans Flex': 'assets/fonts/GoogleSansFlex.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(
            entry.key,
          )..addFont(rootBundle.load(entry.value))).load();
        }
      });
    }
    final service = _Service();
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recommendationProfilesProvider.overrideWith(_Profiles.new),
          recommendationServiceProvider.overrideWithValue(service),
          recommendationGenresProvider.overrideWith(
            (ref) async => ['classical', 'rock'],
          ),
          settingsProvider.overrideWith(() => FixedSettingsNotifier()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: captureKey,
            child: const RecommendationFlowScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    service.responses[0].complete(result('Initial'));
    await tester.pumpAndSettle();
    final screenshot = Platform.environment['REC_FLOW_SCREENSHOT'];
    if (screenshot != null) {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(screenshot).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('Calm'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.requests.last.moods, ['calm']);
    await tester.ensureVisible(find.text('classical'));
    await tester.tap(find.text('classical'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.requests.last.genres, ['classical']);
    expect(service.requests.last.moods, ['calm']);
    service.responses[2].complete(result('Newest'));
    await tester.pumpAndSettle();
    service.responses[1].complete(result('Stale'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Newest'));
    expect(find.text('Stale'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
