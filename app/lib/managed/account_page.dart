import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../state/app_info.dart';
import 'client.dart';

class ManagedAccountPage extends StatefulWidget {
  const ManagedAccountPage({super.key});

  @override
  State<ManagedAccountPage> createState() => _ManagedAccountPageState();
}

class _ManagedAccountPageState extends State<ManagedAccountPage> {
  final _transport = http.Client();
  late final _client = ManagedClient(_transport, appVersion: AppInfo.version);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _answer = TextEditingController();
  String? _challengeId;
  Uint8List? _captcha;
  String? _token;
  List<JsonObject>? _snapshot;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(_loadCaptcha);
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
      if (!mounted) return;
      setState(() {
        if (error is ManagedApiError && error.status == 401) {
          _token = null;
          _snapshot = null;
        }
        _error = error is ManagedApiError && error.status == 429
            ? '操作过于频繁，请稍后再试。'
            : '请求未完成，请检查输入或网络后重试。';
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
    if (id is! String ||
        data is! String ||
        !data.startsWith(prefix) ||
        data.length > 64000) {
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
    if (challengeId == null ||
        _username.text.trim().isEmpty ||
        _password.text.isEmpty ||
        _answer.text.trim().isEmpty)
      return;
    setState(() {
      _captcha = null;
      _challengeId = null;
    });
    final password = _password.text;
    _password.clear();
    final token = await _client.login(
      _username.text,
      password,
      challengeId,
      _answer.text,
    );
    if (!mounted) return;
    setState(() => _token = token);
    await _refresh();
  }

  Future<void> _refresh() async {
    final token = _token;
    if (token == null) return;
    final snapshot = await Future.wait([
      _client.account(token),
      _client.credits(token),
      _client.models(token),
    ]);
    if (mounted) setState(() => _snapshot = snapshot);
  }

  Future<void> _signOut() async {
    setState(() {
      _token = null;
      _snapshot = null;
    });
    await _loadCaptcha();
  }

  @override
  void dispose() {
    _transport.close();
    _username.dispose();
    _password.dispose();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final user = snapshot?.first['user'];
    final membership = user is JsonObject ? user['membership'] : null;
    final models = snapshot?[2]['models'];
    return Scaffold(
      appBar: AppBar(title: const Text('羽枢账号')),
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
                decoration: const InputDecoration(labelText: '账号'),
              ),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
              ),
              if (_captcha case final bytes?)
                SvgPicture.memory(bytes, height: 48),
              TextButton(
                onPressed: _busy ? null : () => _run(_loadCaptcha),
                child: const Text('刷新验证码'),
              ),
              TextField(
                controller: _answer,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: '图形验证码'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _run(_signIn),
                child: const Text('登录'),
              ),
            ] else ...[
              if (user is JsonObject) ...[
                Text('账号：${user['displayName'] ?? user['username'] ?? '—'}'),
                Text(
                  '会员：${membership is JsonObject ? membership['cardName'] ?? '—' : '—'}',
                ),
                Text(
                  '积分：${snapshot?[1]['creditBalance'] ?? user['creditBalance'] ?? '—'}',
                ),
              ],
              if (models is List) ...[
                const SizedBox(height: 16),
                const Text('已授权模型'),
                for (final model in models.whereType<JsonObject>())
                  Text('${model['name'] ?? model['id'] ?? '—'}'),
              ],
              TextButton(
                onPressed: _busy ? null : () => _run(_refresh),
                child: const Text('刷新权益'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _run(_signOut),
                child: const Text('退出登录'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
