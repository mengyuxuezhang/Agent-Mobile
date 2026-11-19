import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/app_info.dart';
import 'auth_layout.dart';
import 'client.dart';
import 'membership_page.dart';
import 'model_sync.dart';
import 'registration_page.dart';
import 'session.dart';

class ManagedAccountPage extends ConsumerStatefulWidget {
  const ManagedAccountPage({super.key, this.finishOnSignIn = false});

  final bool finishOnSignIn;

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
        _error = switch (error) {
          ManagedApiError(status: 429) => l10n.managedTooManyRequests,
          ManagedApiError(message: '账号或密码不正确') => l10n.managedLoginInvalidCredentials,
          ManagedApiError(message: '验证码不正确或已失效，请刷新后重试') => l10n.managedLoginInvalidCaptcha,
          _ => l10n.managedRequestFailed,
        };
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
    if (_username.text.trim().isEmpty || _password.text.isEmpty || _answer.text.trim().length != 5) {
      setState(() => _error = context.l10n.managedLoginMissingFields);
      return;
    }
    if (challengeId == null) {
      await _loadCaptcha();
      if (mounted) setState(() => _error = context.l10n.managedLoginInvalidCaptcha);
      return;
    }
    setState(() {
      _captcha = null;
      _challengeId = null;
    });
    final String token;
    try {
      token = await _client.login(_username.text, _password.text, challengeId, _answer.text);
    } catch (_) {
      if (mounted) {
        try {
          await _loadCaptcha();
        } catch (_) {
          // Keep the original sign-in error and leave refresh available.
        }
      }
      rethrow;
    }
    if (mounted) await _finishSignIn(token);
  }

  Future<void> _refresh() async {
    final token = _token;
    if (token == null) return;
    final snapshot = await Future.wait([_client.account(token), _client.credits(token), _client.ledger(token)]);
    if (mounted && _token == token) setState(() => _snapshot = snapshot);
  }

  Future<void> _openRegistration() async {
    final token = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (context) => ManagedRegistrationPage(client: _client)));
    if (!mounted || token == null) return;
    await _run(() => _finishSignIn(token));
  }

  Future<void> _finishSignIn(String token) async {
    TextInput.finishAutofillContext();
    _password.clear();
    _answer.clear();
    setState(() => _session.token = token);
    if (widget.finishOnSignIn) {
      Navigator.of(context).pop(true);
      return;
    }
    await _refresh();
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
    if (mounted && _token == token) ref.invalidate(managedModelCatalogProvider);
  }

  Future<void> _signOut() async {
    try {
      await _session.signOut();
    } finally {
      if (mounted) {
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
    if (!ref.watch(managedSignedInProvider)) return _loginForm(context);
    final snapshot = _snapshot;
    final user = snapshot?.first['user'];
    final membership = user is JsonObject ? user['membership'] : null;
    final ledger = snapshot?[2]['items'];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.managedAccountTitle(AppInfo.name))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
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
        ),
      ),
    );
  }

  Widget _loginForm(BuildContext context) {
    final l10n = context.l10n;
    return ManagedAuthLayout(
      title: l10n.managedLoginTitle,
      subtitle: l10n.managedAccountSignInHint,
      footer: TextButton(onPressed: _busy ? null : _openRegistration, child: Text(l10n.managedRegister)),
      children: [
        TextField(
          controller: _username,
          enabled: !_busy,
          autofillHints: const [AutofillHints.username],
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: managedAuthInput(context, l10n.managedUsername, Icons.person_outline),
        ),
        const SizedBox(height: 12),
        ManagedPasswordField(controller: _password, enabled: !_busy, autofillHint: AutofillHints.password),
        const SizedBox(height: 12),
        TextField(
          controller: _answer,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          inputFormatters: [LengthLimitingTextInputFormatter(5)],
          onSubmitted: (_) => _run(_signIn),
          decoration: managedAuthInput(
            context,
            l10n.managedCaptcha,
            Icons.verified_user_outlined,
            suffix: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_captcha case final bytes?) SvgPicture.memory(bytes, width: 84, height: 30),
                IconButton(
                  tooltip: l10n.managedRefreshCaptcha,
                  onPressed: _busy ? null : () => _run(_loadCaptcha),
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
        ),
        if (_error case final message?) ManagedAuthMessage(message),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : () => _run(_signIn),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.managedSignIn),
        ),
      ],
    );
  }
}
