import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/app_info.dart';
import '../state/models_state.dart';
import '../state/providers_state.dart';
import 'client.dart';
import 'membership_page.dart';
import 'registration_page.dart';
import 'session.dart';

class ManagedAccountPage extends ConsumerStatefulWidget {
  const ManagedAccountPage({super.key, this.finishOnConnection = false});

  final bool finishOnConnection;

  @override
  ConsumerState<ManagedAccountPage> createState() => _ManagedAccountPageState();
}

class _ManagedAccountPageState extends ConsumerState<ManagedAccountPage> {
  late final _session = ref.read(managedSessionProvider);
  ManagedClient get _client => _session.client;
  String? get _token => _session.token;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _answer = TextEditingController();
  String? _challengeId;
  Uint8List? _captcha;
  List<JsonObject>? _snapshot;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(_token == null ? _loadCaptcha : _refresh);
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
      if (error is ManagedApiError && error.status == 401) {
        try {
          await _session.signOut();
        } catch (_) {
          // The account lease was closed before removing the engine entry.
        }
        if (mounted) setState(() => _snapshot = null);
      }
      if (!mounted) return;
      setState(() {
        final l10n = context.l10n;
        _error = error is ManagedApiError && error.status == 429
            ? l10n.managedTooManyRequests
            : l10n.managedRequestFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadCaptcha() async {
    final challenge = await _client.captcha();
    final id = challenge['challengeId'];
    final data = challenge['imageDataUrl'];
    const prefix = 'data:image/svg+xml;base64,';
    if (id is! String || data is! String || !data.startsWith(prefix) || data.length > 64000) {
      throw const FormatException('Invalid challenge');
    }
    final bytes = base64Decode(data.substring(prefix.length));
    if (!mounted) return;
    setState(() {
      _challengeId = id;
      _captcha = bytes;
      _answer.clear();
    });
  }

  Future<void> _signIn() async {
    final challengeId = _challengeId;
    if (challengeId == null || _username.text.trim().isEmpty || _password.text.isEmpty || _answer.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _captcha = null;
      _challengeId = null;
    });
    final password = _password.text;
    _password.clear();
    final token = await _client.login(_username.text, password, challengeId, _answer.text);
    if (!mounted) return;
    setState(() => _session.token = token);
    await _refresh();
  }

  Future<void> _refresh() async {
    final token = _token;
    if (token == null) return;
    final snapshot = await Future.wait([
      _client.account(token),
      _client.credits(token),
      _client.models(token),
      _client.ledger(token),
    ]);
    if (mounted && _token == token) setState(() => _snapshot = snapshot);
  }

  Future<void> _openRegistration() async {
    final token = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (context) => ManagedRegistrationPage(client: _client)));
    if (!mounted || token == null) return;
    _password.clear();
    _answer.clear();
    setState(() => _session.token = token);
    await _run(_refresh);
  }

  Future<void> _openMembership(String userId) async {
    final token = _token;
    if (token == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => ManagedMembershipPage(client: _client, token: token, userId: userId),
      ),
    );
    if (mounted && _token == token) await _run(_refresh);
  }

  Future<void> _connectModels() async {
    final engine = ref.read(providerBackendProvider);
    final catalog = _snapshot?[2];
    if (engine == null || !engine.isLocal || catalog == null) {
      setState(() => _error = context.l10n.managedLocalEngineRequired);
      return;
    }
    await _session.connectModels(engine, catalog);
    if (!mounted) return;
    ref.invalidate(modelCatalogProvider);
    if (widget.finishOnConnection) Navigator.of(context).pop(true);
  }

  Future<void> _signOut() async {
    try {
      await _session.signOut();
    } finally {
      if (mounted) {
        ref.invalidate(modelCatalogProvider);
        setState(() => _snapshot = null);
      }
    }
    if (mounted) await _loadCaptcha();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final snapshot = _snapshot;
    final user = snapshot?.first['user'];
    final membership = user is JsonObject ? user['membership'] : null;
    final models = snapshot?[2]['models'];
    final ledger = snapshot?[3]['items'];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.managedAccountTitle(AppInfo.name))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            if (_token == null) ...[
              TextField(
                controller: _username,
                enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.managedUsername),
              ),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                decoration: InputDecoration(labelText: l10n.managedPassword),
              ),
              if (_captcha case final bytes?) SvgPicture.memory(bytes, height: 48),
              TextButton(onPressed: _busy ? null : () => _run(_loadCaptcha), child: Text(l10n.managedRefreshCaptcha)),
              TextField(
                controller: _answer,
                enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.managedCaptcha),
              ),
              FilledButton(onPressed: _busy ? null : () => _run(_signIn), child: Text(l10n.managedSignIn)),
              TextButton(onPressed: _busy ? null : _openRegistration, child: Text(l10n.managedRegister)),
            ] else ...[
              if (user is JsonObject) ...[
                Text(l10n.managedAccountValue('${user['displayName'] ?? user['username'] ?? '—'}')),
                Text(l10n.managedMembershipValue('${membership is JsonObject ? membership['cardName'] ?? '—' : '—'}')),
                Text(l10n.managedCreditValue('${snapshot?[1]['creditBalance'] ?? user['creditBalance'] ?? '—'}')),
                if (user['id'] is String)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _openMembership(user['id'] as String),
                    child: Text(l10n.managedMembershipStore),
                  ),
              ],
              if (models is List) ...[
                const SizedBox(height: 16),
                Text(l10n.managedAuthorizedModels),
                for (final model in models.whereType<JsonObject>()) Text('${model['name'] ?? model['id'] ?? '—'}'),
              ],
              if (snapshot != null)
                FilledButton(
                  onPressed: _busy ? null : () => _run(_connectModels),
                  child: Text(l10n.managedConnectModels),
                ),
              if (_session.modelsConnected) Text(l10n.managedModelsConnected),
              if (ledger is List && ledger.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l10n.managedRecentCredits),
                for (final row in ledger.whereType<JsonObject>().take(5))
                  Text(
                    '${row['createdAt'] ?? ''}  ${row['modelName'] ?? row['changeType'] ?? ''}  ${row['pointsDelta'] ?? '—'}',
                  ),
              ],
              TextButton(onPressed: _busy ? null : () => _run(_refresh), child: Text(l10n.managedRefreshBenefits)),
              TextButton(onPressed: _busy ? null : () => _run(_signOut), child: Text(l10n.managedSignOut)),
            ],
          ],
        ),
      ),
    );
  }
}
