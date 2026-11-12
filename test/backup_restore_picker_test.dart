import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/backup_restore_page.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/widgets/settings_group.dart';

base class _LocalPlatformFile extends PlatformFile {
  _LocalPlatformFile(this.name, String path) : uri = Uri.file(path);

  @override
  final String name;

  @override
  final Uri uri;

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => File(path!).lengthSync();

  @override
  Future<int?> length() => File(path!).length();

  @override
  Future<Uint8List> readAsBytes() => File(path!).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      File(path!).openRead().map(Uint8List.fromList);
}

class _BackupFilePicker extends FilePickerPlatform {
  bool opened = false;
  PlatformFile? file;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    opened = true;
    // A custom JSON/SFLB filter becomes JSON-only on Android because SFLB
    // has no system MIME mapping.
    expect(type, FileType.any);
    expect(allowedExtensions, isNull);
    return file;
  }
}

class _BlockingSettings extends SettingsNotifier {
  final restoreStarted = Completer<void>();
  final continueRestore = Completer<void>();

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    restoreStarted.complete();
    await continueRestore.future;
  }
}

class _RestoreHistory extends DownloadHistoryNotifier {
  bool _restored = false;

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<void> restoreFromBackupOperation(
    Future<void> Function() restore,
  ) async {
    _restored = true;
  }
}

void main() {
  testWidgets(
    'settings-only preset and empty selection update export controls',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BackupRestorePage(),
          ),
        ),
      );
      await tester.tap(find.text('Settings only'));
      await tester.pumpAndSettle();
      final switches = tester
          .widgetList<SettingsSwitchItem>(find.byType(SettingsSwitchItem))
          .toList();
      expect(switches.map((item) => item.value), [
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(switches.last.onChanged, isNull);
      switches.first.onChanged!(false);
      await tester.pumpAndSettle();
      final export = tester
          .widgetList<SettingsItem>(find.byType(SettingsItem))
          .firstWhere((item) => item.icon == Icons.ios_share);
      expect(export.onTap, isNull);
      expect(
        export.subtitle,
        'Select at least one category to create a backup.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restore does not exclude backups with an unknown MIME type', (
    tester,
  ) async {
    final original = FilePickerPlatform.instance;
    final picker = _BackupFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BackupRestorePage(),
        ),
      ),
    );
    final restore = find.text('Choose backup file');
    await tester.scrollUntilVisible(restore, 300);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(picker.opened, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restore continues after its page is unmounted', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('backup-restore-page-'),
    ))!;
    addTearDown(() async {
      await tester.runAsync(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
    });
    final file = (await tester.runAsync(
      () => BackupService.writeBackupArchive(
        settings: const AppSettings().toJson(),
        loadHistoryPage: (_, _) async => const [],
        collections: const {},
        playlistCoverFiles: const {},
        extensions: const {},
        outputDirectory: root,
        temporaryDirectory: root,
      ),
    ))!;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (call) async =>
              call.method == 'getTemporaryDirectory' ? root.path : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null),
    );
    final original = FilePickerPlatform.instance;
    final picker = _BackupFilePicker()
      ..file = _LocalPlatformFile('backup.sflb', file.path);
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);

    final settings = _BlockingSettings();
    final history = _RestoreHistory();
    final showPage = ValueNotifier(true);
    addTearDown(showPage.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => settings),
          downloadHistoryProvider.overrideWith(() => history),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<bool>(
            valueListenable: showPage,
            builder: (context, visible, _) => visible
                ? const BackupRestorePage()
                : const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('Choose backup file'), 300);
    await tester.tap(find.text('Choose backup file'));
    for (
      var attempt = 0;
      attempt < 40 && find.text('Restore').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('Restore'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pump();
    expect(settings.restoreStarted.isCompleted, isTrue);

    showPage.value = false;
    await tester.pump();
    settings.continueRestore.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));

    expect(history._restored, isTrue);
    expect(tester.takeException(), isNull);
  });
}
