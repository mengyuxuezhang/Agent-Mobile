import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../ui/remote/pairing_page.dart' show pairingScannerProvider;
import '../account_page.dart';
import '../session.dart';
import 'client.dart';
import 'host.dart';

class DesktopRemoteScreen extends ConsumerStatefulWidget {
  const DesktopRemoteScreen({super.key});

  @override
  ConsumerState<DesktopRemoteScreen> createState() => _DesktopRemoteScreenState();
}

class _DesktopRemoteScreenState extends ConsumerState<DesktopRemoteScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  DesktopRemoteClient get _client => ref.read(desktopRemoteProvider);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = desktopErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openHost(String id) {
    ref.read(activeHostProvider.notifier).select(HostRef.desktop(id));
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _pair(String code) async {
    await _client.pair(code);
    if (!mounted) return;
    _code.clear();
    if (_client.pairId case final id?) _openHost(id);
  }

  Future<void> _scan() async {
    final scanner = ref.read(pairingScannerProvider);
    var handled = false;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(context.l10n.desktopRemoteScan)),
          body: SafeArea(
            child: Center(
              child: scanner(context, (value) {
                if (handled || ModalRoute.of(context)?.isCurrent != true) return;
                handled = true;
                Navigator.pop(context, value);
              }),
            ),
          ),
        ),
      ),
    );
    if (mounted && code != null) await _run(() => _pair(code));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final signedIn = ref.watch(managedSignedInProvider);
    ref.watch(desktopPairProvider);
    final pair = signedIn ? _client.pairId : null;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.desktopRemoteTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?) _Feedback(text: error, error: true),
            if (!signedIn) ...[
              _Feedback(text: l10n.desktopRemoteSignIn),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context)
                        .push<void>(MaterialPageRoute(builder: (_) => const ManagedAccountPage(finishOnSignIn: true))),
                child: Text(l10n.desktopRemoteLogin),
              ),
            ] else if (pair == null) ...[
              _Feedback(text: l10n.desktopRemotePairInstructions),
              FilledButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l10n.desktopRemoteScan),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.desktopRemoteCode,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: l10n.desktopRemotePaste,
                    icon: const Icon(Icons.content_paste),
                    onPressed: _busy
                        ? null
                        : () async {
                            final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
                            if (mounted && clipboard?.text != null) _code.text = clipboard!.text!;
                          },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(() => _pair(_code.text)),
                icon: const Icon(Icons.link),
                label: Text(l10n.desktopRemoteConnect),
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.computer),
                title: Text(l10n.desktopRemoteHostName),
                subtitle: Text(l10n.remoteConnected),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _openHost(pair),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final host = ref.read(activeHostProvider.notifier);
                        try {
                          await _client.revoke();
                        } finally {
                          if (mounted) await host.forget((h) => h == HostRef.desktop(pair));
                        }
                      }),
                icon: const Icon(Icons.link_off),
                label: Text(l10n.desktopRemoteDisconnect),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Feedback extends StatelessWidget {
  const _Feedback({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(text, style: TextStyle(color: error ? Theme.of(context).colorScheme.error : null)),
  );
}
