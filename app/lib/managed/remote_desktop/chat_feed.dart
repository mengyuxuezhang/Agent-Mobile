import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../../state/chat_state.dart';
import 'client.dart';
import 'host.dart';

/// Converts relayed desktop snapshots into the state consumed by the native chat.
class DesktopChatFeed {
  DesktopChatFeed(this.client, this.id, this.publish);
  final DesktopHostClient client;
  final String id;
  final void Function(ChatState) publish;
  final _older = <String, RemoteJson>{};
  final _messageIds = <String, int>{};
  final _fullText = <String, String>{};
  final _fullReads = <String>{};
  final _ready = Completer<bool>();
  RemoteJson? _snapshot;
  ChatState _view = const ChatState(syncing: true);
  Timer? _timer;
  bool _closed = false;
  bool _reading = false;
  bool _foreground = true;
  bool _opening = true;
  bool _paging = false;
  bool _paged = false;
  bool _acting = false;
  int _readFailures = 0;
  final _readGap = Stopwatch();
  static const _busyGrace = Duration(seconds: 15);
  int _oldestSeq = 0;
  int _newestSeq = 0;
  String? _before;

  bool get goalAvailable => _snapshot?['goalAvailable'] == true;
  String? get executionMode => _snapshot?['executionMode'] as String?;
  String? get goalStatus => _snapshot?['goalStatus'] as String?;
  bool get canUseDefaultPermissions => _snapshot?['canUseDefaultPermissions'] == true;

  void foreground(bool visible) {
    _foreground = visible;
    if (visible) {
      unawaited(refresh());
    } else {
      _timer?.cancel();
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    if (!_ready.isCompleted) _ready.complete(false);
  }

  Future<bool> waitForSync() async {
    if (!_ready.isCompleted) {
      await _ready.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
    }
    return !_closed && _view.controlReady;
  }

  Future<bool> refresh() async {
    if (_closed || !_foreground || _reading) return false;
    _timer?.cancel();
    final delay = _opening ? Duration.zero : client.remote.chatWatchDelay;
    if (delay > Duration.zero) {
      _schedule(delay);
      return false;
    }
    _reading = true;
    var retryDelay = Duration.zero;
    try {
      if (_opening) await client.ensureTarget(id);
      if (_closed) return false;
      final result = await client.remote.request(_opening ? 'chat/open' : 'chat/watch', {
        ...client.target(id),
        if (!_opening) 'revision': ?(_snapshot?['revision'] as String?),
      });
      if (_closed) return false;
      _opening = false;
      _readFailures = 0;
      _readGap
        ..reset()
        ..start();
      if (result['chat'] case final RemoteJson chat) {
        _snapshot = chat;
        _emit();
      } else if (_view.streamLost || _view.stopping) {
        _emit();
      }
      if (!_ready.isCompleted) _ready.complete(true);
      return true;
    } catch (error) {
      _readFailures++;
      final busy = error is DesktopRemoteException && error.code == 'RELAY_BUSY';
      if (busy) retryDelay = const Duration(seconds: 4);
      final canRetry =
          !_opening && client.remote.connected && !(error is DesktopRemoteException && error.code == 'DESKTOP_OFFLINE');
      // A busy relay can still be carrying a live desktop turn.
      final showFailure = busy ? _readGap.elapsed >= _busyGrace : _readFailures > 1;
      if (!_closed && (!canRetry || showFailure)) {
        _view = _view.copyWith(loading: false, streamLost: true, syncError: desktopErrorText(error));
        publish(_view);
      }
      return false;
    } finally {
      _reading = false;
      final delay = _view.streamLost ? const Duration(seconds: 3) : const Duration(milliseconds: 100);
      _schedule(retryDelay > delay ? retryDelay : delay);
    }
  }

  void _schedule(Duration delay) {
    if (!_closed && _foreground && client.remote.connected) {
      _timer = Timer(delay, refresh);
    }
  }

  void _emit() {
    final snapshot = _snapshot;
    if (snapshot == null || _closed) return;
    final rows = {..._older};
    for (final row in desktopItems(snapshot['messages'])) {
      rows[row['id'] as String] = row;
    }
    final items = <ChatItem>[];
    for (final row in rows.values) {
      final messageId = row['id'] as String;
      final text = _fullText[messageId] ?? row['text'] as String;
      final seq = _messageIds.putIfAbsent(messageId, () => ++_newestSeq);
      if (row['truncated'] == true && row['complete'] == true && _fullReads.add(messageId)) {
        unawaited(_readFullText(messageId));
      }
      if (row['role'] == 'user') {
        items.add(
          UserChatItem(
            seq: seq,
            time: DateTime.fromMillisecondsSinceEpoch(0),
            text: text,
            images: const [],
            files: const [],
          ),
        );
      } else if (row['role'] == 'assistant') {
        final complete = row['complete'] == true;
        items.add(
          AssistantChatItem(id: messageId, text: text, reasoning: '', streaming: !complete, isFinalAnswer: complete),
        );
      }
    }
    for (final tool in desktopItems(snapshot['tools'])) {
      items.add(
        ToolChatItem(
          callId: tool['id'] as String,
          name: tool['title'] as String,
          arguments: '',
          status: switch (tool['status']) {
            'completed' => ToolStatus.succeeded,
            'failed' => ToolStatus.failed,
            _ => ToolStatus.running,
          },
        ),
      );
    }

    final running = snapshot['status'] == 'running' || snapshot['status'] == 'retrying';
    client.markRunning(id, running);
    _view = ChatState(
      error: _view.error,
      items: items,
      loading: false,
      syncing: false,
      streamLost: false,
      syncError: null,
      running: running,
      stopping: false,
      connection: DshConnectionState.connected,
      title: client.title(id),
      model: switch (snapshot['modelId']) {
        final String model => ModelSelection(provider: 'desktop', model: model),
        _ => null,
      },
      hasMoreHistory: (_paged ? _before : snapshot['before']) != null,
      loadingOlder: _paging,
      approvals: [
        for (final approval in desktopItems(snapshot['approvals']))
          ApprovalRequest(
            eventId: approval['id'] as String,
            sessionId: id,
            toolName: approval['title'] as String,
            reason: approval['description'] as String,
            raw: {...approval, 'managedDesktop': true},
          ),
      ],
      notice: snapshot['desktopInteraction'] == true ? appL10n.desktopRemoteOnComputer : null,
    );
    if (snapshot['error'] case final String code) {
      _view = _view.copyWith(error: desktopErrorText(DesktopRemoteException(code)));
    }
    publish(_view);
  }

  Future<void> _readFullText(String messageId) async {
    try {
      int? offset = 0;
      final text = StringBuffer();
      while (!_closed && offset != null) {
        final result = await client.remote.request('chat/message', {
          ...client.target(id),
          'messageId': messageId,
          'offset': offset,
        });
        text.write(result['text'] as String);
        final next = result['nextOffset'] as int?;
        if (next != null && next <= offset) return;
        offset = next;
      }
      if (!_closed) {
        _fullText[messageId] = text.toString();
        _emit();
      }
    } catch (_) {
      // The usable prefix remains on screen if the message expired or went offline.
    }
  }

  Future<void> loadOlder() async {
    final cursor = _paged ? _before : _snapshot?['before'] as String?;
    if (_paging || cursor == null || _closed) return;
    _paging = true;
    _emit();
    try {
      final result = await client.remote.request('chat/state', {...client.target(id), 'before': cursor});
      if (_closed) return;
      final page = result['chat'] as RemoteJson;
      final previous = Map<String, RemoteJson>.of(_older);
      final rows = desktopItems(page['messages']);
      for (final row in rows.reversed) {
        _messageIds.putIfAbsent(row['id'] as String, () => --_oldestSeq);
      }
      _older
        ..clear()
        ..addEntries(rows.map((row) => MapEntry(row['id'] as String, row)))
        ..addAll(previous);
      _before = page['before'] as String?;
      _paged = true;
    } catch (error) {
      if (!_closed) publish(_view = _view.copyWith(error: desktopErrorText(error)));
    } finally {
      _paging = false;
      _emit();
    }
  }

  Future<bool> act(String method, [RemoteJson fields = const {}]) async {
    if (_closed || _acting || !_view.controlReady) return false;
    _acting = true;
    publish(_view = _view.copyWith(clearError: true, stopping: method == 'chat/stop'));
    try {
      await client.remote.request(method, {...client.target(id), ...fields});
      if (!_closed) unawaited(refresh());
      return true;
    } catch (error) {
      if (!_closed) publish(_view = _view.copyWith(error: desktopErrorText(error), stopping: false));
      return false;
    } finally {
      _acting = false;
    }
  }

  Future<bool> send(String text) {
    if (_view.running || text.trim().isEmpty) return Future.value(false);
    if (text.length > 16000) {
      publish(_view = _view.copyWith(error: appL10n.desktopRemoteMessageTooLong));
      return Future.value(false);
    }
    final picks = client.options(id);
    return act('chat/send', {
      'text': text,
      'mode': ?picks.mode,
      if (picks.skills.isNotEmpty) 'skillIds': picks.skills.toList(),
    });
  }

  void dismissError() => publish(_view = _view.copyWith(clearError: true));

  Future<void> decide(ApprovalRequest request, String? optionId) async {
    final choices = desktopItems(request.raw['choices']);
    final full = choices.any((option) => option['id'] == optionId && option['kind'] == 'fullAccess');
    await act('chat/decide', {
      'interactionId': request.eventId,
      'optionId': ?optionId,
      if (full) 'confirmFullAccess': true,
    });
  }
}
