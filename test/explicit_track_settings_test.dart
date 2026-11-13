import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

void main() {
  testWidgets('uncensored-first preference can be changed from Audio Quality', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        extensionProvider.overrideWith(_Extensions.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DownloadSettingsPage(),
        ),
      ),
    );
    const title = 'Prefer uncensored versions';
    await tester.scrollUntilVisible(find.text(title), 300);
    await tester.pumpAndSettle();
    final item = tester.widget<SettingsSwitchItem>(
      find.byWidgetPredicate(
        (widget) => widget is SettingsSwitchItem && widget.title == title,
      ),
    );
    expect(item.value, isTrue);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).preferExplicitTracks, isFalse);
  });
}
