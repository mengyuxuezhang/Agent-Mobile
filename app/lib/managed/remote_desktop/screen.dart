import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../ui/remote/pairing_page.dart' show pairingScannerProvider;
import '../account_page.dart';
import '../session.dart';
import 'client.dart';

class DesktopRemoteScreen extends ConsumerStatefulWidget {
  const DesktopRemoteScreen({super.key});

  @override
  ConsumerState<DesktopRemoteScreen> createState() => _DesktopRemoteScreenState();
}

class _DesktopRemoteScreenState extends ConsumerState<DesktopRemoteScreen> {
  final _code = TextEditingController();
  List<RemoteJson> _workspaces = [];
  List<RemoteJson> _sessions = [];
  List<RemoteJson> _recent = [];
  String? _recentCursor;
  bool _overview = false;
  RemoteJson? _workspace;
  bool _busy = false;
  String? _error;

  DesktopRemoteClient get _client => ref.read(desktopRemoteProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _client.connected) _run(_loadWorkspaces);
    });
  }

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
      if (mounted) setState(() => _error = _errorCode(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadWorkspaces() async {
    final result = await _client.request('workspaces/list');
    if (!mounted) return;
    setState(() {
      _workspaces = _items(result['workspaces']);
      _overview = result['overview'] == true;
      _recent = [];
      _recentCursor = null;
    });
    if (_overview) await _loadRecent();
  }

  Future<void> _pair(String code) async {
    await _client.pair(code);
    if (!mounted) return;
    _code.clear();
    setState(() {
      _workspace = null;
      _workspaces = [];
      _sessions = [];
      _recent = [];
      _recentCursor = null;
      _overview = false;
    });
    await _loadWorkspaces();
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

  Future<void> _loadRecent([String? cursor]) async {
    final result = await _client.request('sessions/recent', {'before': ?cursor});
    if (!mounted) return;
    setState(() {
      final rows = _items(result['sessions']);
      _recent = cursor == null
          ? rows
          : {
              for (final item in [..._recent, ...rows]) item['id']: item,
            }.values.toList();
      _recentCursor = result['before'] as String?;
    });
  }

  Future<void> _loadSessions(RemoteJson workspace) async {
    final result = await _client.request('sessions/list', {'workspaceId': workspace['id']});
    if (mounted) {
      setState(() {
        _workspace = workspace;
        _sessions = _items(result['sessions']);
      });
    }
  }

  Future<void> _open(String workspaceId, String sessionId, String title) async {
    final result = await _client.request('chat/open', {'workspaceId': workspaceId, 'sessionId': sessionId});
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _DesktopChatScreen(
          workspaceId: workspaceId,
          sessionId: sessionId,
          title: title,
          initial: result['chat'] as RemoteJson,
        ),
      ),
    );
    if (!mounted || !_client.connected) return;
    final workspace = _workspace;
    if (workspace == null) {
      await _loadWorkspaces();
    } else {
      await _loadSessions(workspace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final signedIn = ref.watch(managedSignedInProvider);
    final linked = signedIn && _client.connected;
    final workspace = linked ? _workspace : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(workspace?['name'] as String? ?? l10n.desktopRemoteTitle),
        actions: [
          if (linked)
            IconButton(
              tooltip: l10n.desktopRemoteRefresh,
              onPressed: _busy
                  ? null
                  : () => _run(workspace == null ? _loadWorkspaces : () => _loadSessions(workspace)),
              icon: const Icon(Icons.refresh),
            ),
          if (linked)
            IconButton(
              tooltip: l10n.desktopRemoteDisconnect,
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await _client.revoke();
                      if (mounted) {
                        setState(() {
                          _workspace = null;
                          _workspaces = [];
                          _sessions = [];
                          _recent = [];
                          _recentCursor = null;
                          _overview = false;
                        });
                      }
                    }),
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) _Feedback(text: _message(context, _error!), error: true),
            if (!signedIn) ...[
              _Feedback(text: l10n.desktopRemoteSignIn),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context)
                        .push<void>(MaterialPageRoute(builder: (_) => const ManagedAccountPage(finishOnSignIn: true))),
                child: Text(l10n.desktopRemoteLogin),
              ),
            ] else if (!linked) ...[
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
            ] else if (workspace == null) ...[
              if (_overview) ...[
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final result = await _client.request('sessions/create');
                          if (mounted) {
                            await _open(
                              result['workspaceId'] as String,
                              result['sessionId'] as String,
                              l10n.desktopRemoteNewChat,
                            );
                          }
                        }),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.desktopRemoteNewChat),
                ),
              ],
              ExpansionTile(
                initiallyExpanded: !_overview,
                title: Text(l10n.desktopRemoteWorkspaces),
                children: [
                  if (_workspaces.isEmpty && !_busy) _Feedback(text: l10n.desktopRemoteEmptyWorkspaces),
                  for (final item in _workspaces)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(item['name'] as String),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _run(() => _loadSessions(item)),
                    ),
                ],
              ),
              if (_overview) ...[
                _Feedback(text: l10n.desktopRemoteRecentChats),
                if (_recent.isEmpty && !_busy) _Feedback(text: l10n.desktopRemoteEmptyRecent),
                for (final item in _recent)
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(item['title'] as String),
                    subtitle: Text(item['workspaceName'] as String),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy
                        ? null
                        : () => _run(
                            () => _open(item['workspaceId'] as String, item['id'] as String, item['title'] as String),
                          ),
                  ),
                if (_recentCursor != null)
                  TextButton(
                    onPressed: _busy ? null : () => _run(() => _loadRecent(_recentCursor)),
                    child: Text(l10n.desktopRemoteMore),
                  ),
              ],
            ] else ...[
              TextButton.icon(
                onPressed: _busy ? null : () => setState(() => _workspace = null),
                icon: const Icon(Icons.arrow_back),
                label: Text(l10n.desktopRemoteWorkspaces),
              ),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final result = await _client.request('sessions/create', {'workspaceId': workspace['id']});
                        if (mounted) {
                          await _open(
                            workspace['id'] as String,
                            result['sessionId'] as String,
                            l10n.desktopRemoteNewChat,
                          );
                        }
                      }),
                icon: const Icon(Icons.add),
                label: Text(l10n.desktopRemoteNewChat),
              ),
              if (_sessions.isEmpty && !_busy) _Feedback(text: l10n.desktopRemoteEmptyChats),
              for (final item in _sessions)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(item['title'] as String),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () =>
                            _run(() => _open(workspace['id'] as String, item['id'] as String, item['title'] as String)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DesktopChatScreen extends ConsumerStatefulWidget {
  const _DesktopChatScreen({
    required this.workspaceId,
    required this.sessionId,
    required this.title,
    required this.initial,
  });

  final String workspaceId;
  final String sessionId;
  final String title;
  final RemoteJson initial;

  @override
  ConsumerState<_DesktopChatScreen> createState() => _DesktopChatScreenState();
}

class _DesktopChatScreenState extends ConsumerState<_DesktopChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  late RemoteJson _chat = widget.initial;
  final _older = <String, RemoteJson>{};
  String? _before;
  bool _paged = false;
  bool _reading = false;
  bool _sending = false;
  bool _paging = false;
  bool _visible = true;
  String? _readError;
  String? _actionError;
  Timer? _timer;

  DesktopRemoteClient get _client => ref.read(desktopRemoteProvider);
  RemoteJson get _target => {'workspaceId': widget.workspaceId, 'sessionId': widget.sessionId};
  bool get _running => _chat['status'] == 'running' || _chat['status'] == 'retrying';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (_visible) {
      unawaited(_refresh());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted || !_visible) return;
    _timer = Timer(Duration(seconds: _running ? 2 : 4), () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (!mounted || !_visible || _reading) return;
    if (!_client.connected) {
      setState(() => _readError = 'ACCESS_REVOKED');
      return;
    }
    _reading = true;
    try {
      final payload = await _client.request('chat/state', _target);
      if (mounted) {
        setState(() {
          _chat = payload['chat'] as RemoteJson;
          _readError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _readError = _errorCode(error));
    } finally {
      _reading = false;
      _schedule();
    }
  }

  Future<void> _loadEarlier(String cursor) async {
    if (_paging) return;
    setState(() {
      _paging = true;
      _actionError = null;
    });
    try {
      final payload = await _client.request('chat/state', {..._target, 'before': cursor});
      final page = payload['chat'] as RemoteJson;
      if (mounted) {
        setState(() {
          final newer = Map<String, RemoteJson>.from(_older);
          _older.clear();
          for (final item in _items(page['messages'])) {
            _older[item['id'] as String] = item;
          }
          _older.addAll(newer);
          _before = page['before'] as String?;
          _paged = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _actionError = _errorCode(error));
    } finally {
      if (mounted) setState(() => _paging = false);
    }
  }

  Future<void> _call(String method, [RemoteJson fields = const {}]) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _actionError = null;
    });
    try {
      await _client.request(method, {..._target, ...fields});
      if (mounted && method == 'chat/send' && _input.text.trim() == fields['text']) _input.clear();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _actionError = _errorCode(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _useDefaultPermissions() async {
    final l10n = context.l10n;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.desktopRemoteDefaultPermissions),
        content: Text(l10n.desktopRemoteDefaultPermissionsDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.desktopRemoteDefaultPermissions),
          ),
        ],
      ),
    );
    if (mounted && accepted == true) await _call('chat/use-default-permissions');
  }

  void _openMessage(String id) {
    final client = _client;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => _LongMessage(
          load: (offset) => client.request('chat/message', {..._target, 'messageId': id, 'offset': offset}),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final signedIn = ref.watch(managedSignedInProvider);
    final connected = signedIn && _client.connected;
    final messages = {..._older};
    for (final item in _items(_chat['messages'])) {
      messages[item['id'] as String] = item;
    }
    final cursor = _paged ? _before : _chat['before'] as String?;
    final error = _actionError ?? _readError ?? _chat['error'] as String?;
    final needsDefaultPermissions = _chat['canUseDefaultPermissions'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_running && connected)
            IconButton(
              tooltip: l10n.desktopRemoteStop,
              onPressed: _sending ? null : () => _call('chat/stop'),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: !connected
            ? _Feedback(text: l10n.desktopRemoteDisconnected)
            : Column(
                children: [
                  if (_running) const LinearProgressIndicator(),
                  if (needsDefaultPermissions)
                    TextButton(
                      onPressed: _running || _sending ? null : _useDefaultPermissions,
                      child: Text(l10n.desktopRemoteDefaultPermissions),
                    ),
                  if (error != null) _Feedback(text: _message(context, error), error: true),
                  Expanded(
                    child: ListView(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      children: [
                        if (_chat['desktopInteraction'] == true) _Feedback(text: l10n.desktopRemoteOnComputer),
                        for (final approval in _items(_chat['approvals']))
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(approval['title'] as String, style: Theme.of(context).textTheme.titleMedium),
                                  if ((approval['description'] as String).isNotEmpty)
                                    SelectableText(approval['description'] as String),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      for (final option in _items(approval['choices']))
                                        OutlinedButton(
                                          onPressed: _sending
                                              ? null
                                              : () => _call('chat/decide', {
                                                  'interactionId': approval['id'],
                                                  'optionId': option['id'],
                                                }),
                                          child: Text(option['name'] as String),
                                        ),
                                      TextButton(
                                        onPressed: _sending
                                            ? null
                                            : () => _call('chat/decide', {'interactionId': approval['id']}),
                                        child: Text(l10n.desktopRemoteDecline),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        for (final tool in _items(_chat['tools']).reversed)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.build_outlined, size: 18),
                            title: Text(tool['title'] as String),
                            subtitle: Text(switch (tool['status']) {
                              'completed' => l10n.desktopRemoteDone,
                              'failed' => l10n.desktopRemoteTaskFailed,
                              _ => l10n.desktopRemoteRunning,
                            }),
                          ),
                        for (final item in messages.values.toList().reversed)
                          _Message(
                            item: item,
                            open: item['truncated'] == true ? () => _openMessage(item['id'] as String) : null,
                          ),
                        if (cursor != null)
                          TextButton(
                            onPressed: _paging ? null : () => _loadEarlier(cursor),
                            child: Text(l10n.desktopRemoteHistory),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 16000,
                            decoration: InputDecoration(
                              hintText: l10n.desktopRemoteWrite,
                              border: const OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: l10n.desktopRemoteSend,
                          onPressed: _running || _sending || needsDefaultPermissions
                              ? null
                              : () {
                                  final text = _input.text.trim();
                                  if (text.isNotEmpty) unawaited(_call('chat/send', {'text': text}));
                                },
                          icon: const Icon(Icons.arrow_upward),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.item, this.open});
  final RemoteJson item;
  final VoidCallback? open;

  @override
  Widget build(BuildContext context) {
    final user = item['role'] == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: user ? scheme.primaryContainer : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(item['text'] as String),
            if (open != null) TextButton(onPressed: open, child: Text(context.l10n.desktopRemoteFullMessage)),
          ],
        ),
      ),
    );
  }
}

class _LongMessage extends StatefulWidget {
  const _LongMessage({required this.load});
  final Future<RemoteJson> Function(int offset) load;

  @override
  State<_LongMessage> createState() => _LongMessageState();
}

class _LongMessageState extends State<_LongMessage> {
  final _text = StringBuffer();
  int? _next = 0;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final offset = _next;
    if (offset == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chunk = await widget.load(offset);
      if (mounted) {
        setState(() {
          _text.write(chunk['text'] as String);
          _next = chunk['nextOffset'] as int?;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorCode(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.desktopRemoteFullMessage),
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) _Feedback(text: _message(context, _error!), error: true),
        SelectableText(_text.toString()),
      ],
    ),
    actions: [
      if (_next != null) TextButton(onPressed: _loading ? null : _load, child: Text(context.l10n.desktopRemoteMore)),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(MaterialLocalizations.of(context).closeButtonLabel),
      ),
    ],
  );
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

List<RemoteJson> _items(dynamic raw) => raw is List ? raw.whereType<RemoteJson>().toList() : [];
String _errorCode(Object error) => error is DesktopRemoteException ? error.code : 'RELAY_UNAVAILABLE';
String _message(BuildContext context, String code) {
  final l10n = context.l10n;
  return switch (code) {
    'SIGN_IN' => l10n.desktopRemoteSignIn,
    'INVALID_CODE' || 'PAIRING_UNAVAILABLE' => l10n.desktopRemoteBadCode,
    'DEVICE_UNAVAILABLE' || 'ACCESS_REVOKED' || 'PROJECT_FORBIDDEN' => l10n.desktopRemoteDisconnected,
    'WORKSPACE_UNAVAILABLE' || 'SESSION_UNAVAILABLE' => l10n.desktopRemoteUnavailable,
    'DESKTOP_OFFLINE' => l10n.desktopRemoteOffline,
    'REQUEST_TIMEOUT' => l10n.desktopRemoteTimeout,
    'SESSION_BUSY' => l10n.desktopRemoteBusy,
    'LOCAL_CONTROL_REQUIRED' => l10n.desktopRemoteLocalControl,
    'INTERACTION_UNAVAILABLE' => l10n.desktopRemoteApprovalGone,
    'INSUFFICIENT_CREDITS' => l10n.desktopRemoteCredits,
    'MODEL_ERROR' => l10n.desktopRemoteTaskFailed,
    _ => l10n.desktopRemoteError,
  };
}
