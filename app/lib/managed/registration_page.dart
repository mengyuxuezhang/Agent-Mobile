import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'auth_layout.dart';
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
  bool _messageIsError = true;
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
      setState(() {
        _messageIsError = true;
        _message = l10n.managedRegistrationIdentity;
      });
      return;
    }
    if (!sendCode && (_sentTo != identity || code.length != 6 || password.length < 6)) {
      setState(() {
        _messageIsError = true;
        _message = l10n.managedRegistrationCodeAndPassword;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = true;
    });
    try {
      if (sendCode) {
        await widget.client.requestRegistrationCode(username: username, email: email);
        if (!mounted) return;
        setState(() {
          _sentTo = identity;
          _code.clear();
          _message = l10n.managedRegistrationSent;
          _messageIsError = false;
        });
      } else {
        final token = await widget.client.register(username: username, email: email, password: password, code: code);
        if (mounted) {
          TextInput.finishAutofillContext();
          Navigator.of(context).pop(token);
        }
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
      child: ManagedAuthLayout(
        title: l10n.managedRegister,
        subtitle: l10n.managedRegistrationIntro,
        footer: TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.managedBackToLogin),
        ),
        children: [
          TextField(
            controller: _username,
            decoration: managedAuthInput(context, l10n.managedUsername, Icons.person_outline),
            enabled: !_busy,
            autocorrect: false,
            autofillHints: const [AutofillHints.newUsername],
            inputFormatters: [LengthLimitingTextInputFormatter(120)],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            decoration: managedAuthInput(context, l10n.managedRegistrationEmail, Icons.mail_outline),
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            inputFormatters: [LengthLimitingTextInputFormatter(190)],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            decoration: managedAuthInput(
              context,
              l10n.managedRegistrationEmailCode,
              Icons.verified_user_outlined,
              suffix: TextButton(
                onPressed: _busy ? null : () => _submit(sendCode: true),
                child: Text(l10n.managedRegistrationSendCode),
              ),
            ),
            enabled: !_busy,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          ManagedPasswordField(
            controller: _password,
            enabled: !_busy,
            autofillHint: AutofillHints.newPassword,
            onSubmitted: (_) => _submit(sendCode: false),
          ),
          const SizedBox(height: 16),
          if (_message case final message?) ManagedAuthMessage(message, error: _messageIsError),
          FilledButton(
            onPressed: _busy ? null : () => _submit(sendCode: false),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.managedRegister),
          ),
        ],
      ),
    );
  }
}
