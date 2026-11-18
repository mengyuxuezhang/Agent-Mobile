import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'client.dart';

class ManagedRegistrationPage extends StatefulWidget {
  const ManagedRegistrationPage({super.key, required this.client});

  final ManagedClient client;

  @override
  State<ManagedRegistrationPage> createState() => _ManagedRegistrationPageState();
}

class _ManagedRegistrationPageState extends State<ManagedRegistrationPage> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  static final _validUsername = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.@-]{2,119}$');
  static final _validEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  ({String username, String email})? _sentTo;
  String? _message;
  bool _busy = false;

  Future<void> _submit({required bool sendCode}) async {
    if (_busy) return;
    final l10n = context.l10n;
    final username = _username.text.trim();
    final email = _email.text.trim();
    final identity = (username: username, email: email);
    final code = _code.text.trim();
    final password = _password.text;
    if (!_validUsername.hasMatch(username) || email.length > 190 || !_validEmail.hasMatch(email)) {
      setState(() => _message = l10n.managedRegistrationIdentity);
      return;
    }
    if (!sendCode && (_sentTo != identity || code.length != 6 || password.length < 6)) {
      setState(() => _message = l10n.managedRegistrationCodeAndPassword);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (sendCode) {
        await widget.client.requestRegistrationCode(username: username, email: email);
        if (!mounted) return;
        setState(() {
          _sentTo = identity;
          _code.clear();
          _message = l10n.managedRegistrationSent;
        });
      } else {
        final token = await widget.client.register(username: username, email: email, password: password, code: code);
        if (mounted) Navigator.of(context).pop(token);
      }
    } on ManagedApiError catch (error) {
      if (!mounted) return;
      final message = switch (error.message) {
        '该账号已注册，请直接登录' || '该邮箱已注册，请直接登录或找回密码' => l10n.managedRegistrationExists,
        '邮件服务未配置，请联系管理员' => l10n.managedRegistrationMailUnavailable,
        _ when error.status == 429 || (error.message?.contains('过于频繁') ?? false) => l10n.managedTooManyRequests,
        _ when error.message?.contains('管理员开通') ?? false => l10n.managedRegistrationDisabled,
        _ => l10n.managedRequestFailed,
      };
      setState(() => _message = message);
    } catch (_) {
      if (mounted) setState(() => _message = l10n.managedRequestFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.managedRegister)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(l10n.managedRegistrationIntro),
              if (_busy) const LinearProgressIndicator(),
              TextField(
                controller: _username,
                decoration: InputDecoration(labelText: l10n.managedUsername),
                enabled: !_busy,
                maxLength: 120,
                autocorrect: false,
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: _email,
                decoration: InputDecoration(labelText: l10n.managedRegistrationEmail),
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.next,
              ),
              TextButton(
                onPressed: _busy ? null : () => _submit(sendCode: true),
                child: Text(l10n.managedRegistrationSendCode),
              ),
              TextField(
                controller: _code,
                decoration: InputDecoration(labelText: l10n.managedRegistrationEmailCode),
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.managedPassword),
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [LengthLimitingTextInputFormatter(1024)],
                onSubmitted: (_) => _submit(sendCode: false),
              ),
              const SizedBox(height: 16),
              if (_message case final message?) Text(message, semanticsLabel: message),
              FilledButton(onPressed: _busy ? null : () => _submit(sendCode: false), child: Text(l10n.managedRegister)),
            ],
          ),
        ),
      ),
    );
  }
}
