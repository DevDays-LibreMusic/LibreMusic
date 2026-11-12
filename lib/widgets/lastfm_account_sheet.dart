import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/providers/lastfm_account_provider.dart';

Future<void> showLastfmAccount(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SafeArea(
        child: SingleChildScrollView(child: LastfmAccountPanel()),
      ),
    );

class LastfmAccountPanel extends ConsumerStatefulWidget {
  const LastfmAccountPanel({super.key});
  @override
  ConsumerState<LastfmAccountPanel> createState() => _LastfmAccountPanelState();
}

class _LastfmAccountPanelState extends ConsumerState<LastfmAccountPanel> {
  bool _busy = false;
  String? _launchError;
  String t(String ru, String en) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru : en;
  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _launchError = null;
    });
    try {
      final uri = await ref.read(lastfmAccountProvider).beginAuthorization();
      if (uri != null &&
          !await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        setState(
          () => _launchError = t(
            'Не удалось открыть браузер. Попробуй ещё раз.',
            'Could not open the browser. Please try again.',
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _launchError = t(
            'Не удалось начать подключение. Попробуй ещё раз.',
            'Could not start connecting. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(lastfmAccountProvider);
    final state =
        ref.watch(lastfmAccountStateProvider).value ?? controller.state;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Last.fm', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(
            state.connected
                ? t(
                    'Подключён аккаунт: ${state.username}',
                    'Connected as ${state.username}',
                  )
                : t(
                    'Подключи аккаунт, чтобы использовать свою историю и сохранять новые прослушивания.',
                    'Connect your account to use your listening history and save new listens.',
                  ),
          ),
          if (state.loading || _busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          if (!state.appConfigured)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                t(
                  'В этой сборке подключение Last.fm ещё не настроено.',
                  'Last.fm connection is not configured in this build.',
                ),
              ),
            ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                state.error!.message(
                  russian: Localizations.localeOf(context).languageCode == 'ru',
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_launchError != null) Text(_launchError!),
          if (!state.connected || state.needsReauthentication) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: !state.appConfigured || _busy || state.loading
                  ? null
                  : _connect,
              icon: const Icon(Icons.open_in_new),
              label: Text(t('Подключить Last.fm', 'Connect Last.fm')),
            ),
          ],
          if (state.authorizationPending)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await controller.completeAuthorization();
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(
                t('Я подтвердил подключение', 'I have approved the connection'),
              ),
            ),
          if (state.connected) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                t('Отправлять прослушивания', 'Send listening history'),
              ),
              value: state.scrobblingEnabled,
              onChanged: controller.setScrobblingEnabled,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('Показывать текущий трек', 'Share now playing')),
              value: state.nowPlayingEnabled,
              onChanged: controller.setNowPlayingEnabled,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('Синхронизировать лайки', 'Sync likes')),
              value: state.loveSyncEnabled,
              onChanged: controller.setLoveSyncEnabled,
            ),
            if (state.pendingCount > 0)
              Text(
                t(
                  'Ожидают отправки: ${state.pendingCount}',
                  'Waiting to sync: ${state.pendingCount}',
                ),
              ),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: Text(t('Отключить Last.fm?', 'Disconnect Last.fm?')),
                    content: Text(
                      t(
                        'Неотправленные записи больше не будут отправляться. Библиотека и сохранённая музыка останутся.',
                        'Pending entries will no longer be sent. Your library and saved music will remain.',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: Text(t('Отмена', 'Cancel')),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: Text(t('Отключить', 'Disconnect')),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) await controller.disconnect();
              },
              child: Text(t('Отключить аккаунт', 'Disconnect account')),
            ),
          ],
        ],
      ),
    );
  }
}
