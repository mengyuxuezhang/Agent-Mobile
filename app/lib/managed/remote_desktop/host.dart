import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../session.dart';
import 'client.dart';
import 'options.dart';

final desktopDevicesProvider = StreamProvider<List<DesktopDevice>>((ref) async* {
  final signedIn = ref.watch(managedSignedInProvider);
  final remote = ref.watch(desktopRemoteProvider);
  if (!signedIn) {
    yield const [];
    return;
  }
  await remote.restore();
  yield remote.devices;
  yield* remote.linkChanges.stream.map((_) => remote.devices);
});

final desktopOnlineProvider = StreamProvider.autoDispose.family<bool?, String>((ref, id) async* {
  final remote = ref.watch(desktopRemoteProvider);
  yield await remote.online(id);
  yield* Stream<void>.periodic(const Duration(seconds: 8)).asyncMap((_) => remote.online(id));
});

/// Presents the desktop relay's inventory to the shared mobile session drawer.
class DesktopHostClient extends DshClient {
  DesktopHostClient(this.remote, [this.pairId]) : super.withCarrier(_DesktopCarrier());
  final String? pairId;
  final DesktopRemoteClient remote;
  Future<RemoteJson> request(String method, [RemoteJson fields = const {}]) => remote.request(method, fields, pairId);
  final _targets = <String, String>{};
  final _titles = <String, String>{};
  final _options = <String?, DesktopOptions>{};
  final _running = <String, bool>{};
  final _workspaceUpdates = StreamController<WorkspaceUpdate>.broadcast();
  List<Workspace> _workspaces = [];
  bool _hasInventory = false;
  bool questionCards = false;
  Future<List<SessionSummary>>? _inventory;

  DesktopOptions options(String? sessionId) =>
      _options[sessionId] ?? (model: null, expert: null, mode: null, skills: const {});

  void setOptions(String? sessionId, DesktopOptions value) => _options[sessionId] = value;

  Future<void> ensureTarget(String id) async {
    if (!_targets.containsKey(id)) await listSessions();
  }

  RemoteJson target(String id) => {
    'workspaceId': _targets[id] ?? (throw const DesktopRemoteException('SESSION_UNAVAILABLE')),
    'sessionId': id,
  };

  String? title(String id) => _titles[id];
  void markRunning(String id, bool value) => _running[id] = value;

  @override
  Future<List<SessionSummary>> listSessions() async {
    if (_inventory case final pending?) return pending;
    final pending = _readInventory();
    _inventory = pending;
    try {
      return await pending;
    } finally {
      _inventory = null;
    }
  }

  Future<List<SessionSummary>> _readInventory() async {
    final inventory = await request('workspaces/list');
    questionCards = inventory['questionCards'] == true;
    final workspaces = desktopItems(inventory['workspaces']);
    final sessions = <SessionSummary>[];
    void add(RemoteJson row, String workspaceId) {
      final id = row['id'] as String;
      final title = row['title'] as String;
      _targets[id] = workspaceId;
      _titles[id] = title;
      sessions.add(
        SessionSummary(
          sessionId: id,
          updatedAt: DateTime.parse(row['updatedAt'] as String),
          running: _running[id] ?? false,
          blank: row['messageCount'] == 0,
          agentAvailable: true,
          projections: SessionProjections(0, {'title': title, 'workspaceId': workspaceId}),
        ),
      );
    }

    if (inventory['overview'] == true) {
      String? before;
      final seen = <String>{};
      do {
        final page = await request('sessions/recent', {'before': ?before});
        for (final row in desktopItems(page['sessions'])) {
          add(row, row['workspaceId'] as String);
        }
        before = page['before'] as String?;
      } while (before != null && seen.add(before));
    } else {
      for (final workspace in workspaces) {
        final id = workspace['id'] as String;
        final page = await request('sessions/list', {'workspaceId': id});
        for (final row in desktopItems(page['sessions'])) {
          add(row, id);
        }
      }
    }
    _workspaces = [
      for (final workspace in workspaces)
        Workspace(
          workspaceId: workspace['id'] as String,
          path: '',
          title: workspace['name'] as String,
          sessionIds: [
            for (final row in sessions)
              if (_targets[row.sessionId] == workspace['id']) row.sessionId,
          ],
        ),
    ];
    _hasInventory = true;
    if (!_workspaceUpdates.isClosed) _workspaceUpdates.add(_workspaceFrame);
    return sessions;
  }

  WorkspaceBaseline get _workspaceFrame => WorkspaceBaseline(_workspaces, const [], const []);

  @override
  Stream<WorkspaceUpdate> watchWorkspaces() async* {
    if (!_hasInventory) await listSessions();
    yield _workspaceFrame;
    yield* _workspaceUpdates.stream;
  }

  @override
  Future<void> close() async {
    unawaited(_workspaceUpdates.close());
    await super.close();
  }

  @override
  Future<SessionCreated> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
    String? sessionId,
  }) async {
    final picks = options(null);
    final result = await request('sessions/create', {
      'workspaceId': ?workspaceId,
      'modelId': ?picks.model,
      'agentId': ?picks.expert,
    });
    final id = result['sessionId'] as String;
    final workspace = result['workspaceId'] as String? ?? workspaceId;
    if (workspace == null) throw const DesktopRemoteException('WORKSPACE_UNAVAILABLE');
    _targets[id] = workspace;
    setOptions(id, picks);
    if (identical(_options[null], picks)) _options.remove(null);
    return SessionCreated(id, null);
  }

  @override
  Future<List<({String sessionId, String snippet})>> searchSessions(String query) async => [
    for (final row in await listSessions())
      if (row.title?.toLowerCase().contains(query.toLowerCase()) == true)
        (sessionId: row.sessionId, snippet: row.title!),
  ];

  @override
  Future<({List<({String sessionId, String snippet})> items, bool hasMore})> searchSessionsPage(String query) async =>
      (items: await searchSessions(query), hasMore: false);
}

class _DesktopCarrier extends DshCarrier {
  @override
  String get kind => 'managed-desktop';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      const RpcError(DshRemoteException('METHOD_NOT_ALLOWED', 'Unavailable on the desktop relay'));

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async =>
      throw const DshCarrierRefusedException('METHOD_NOT_ALLOWED', 'Managed desktop relay');

  @override
  Future<void> close() async {}
}

List<RemoteJson> desktopItems(Object? value) => value is List ? value.whereType<RemoteJson>().toList() : const [];

String desktopErrorText(Object error) {
  final l10n = appL10n;
  final code = error is DesktopRemoteException ? error.code : error;
  return switch (code) {
    'SIGN_IN' => l10n.desktopRemoteSignIn,
    'INVALID_CODE' || 'PAIRING_UNAVAILABLE' => l10n.desktopRemoteBadCode,
    'DEVICE_UNAVAILABLE' || 'ACCESS_REVOKED' || 'PROJECT_FORBIDDEN' => l10n.desktopRemoteDisconnected,
    'WORKSPACE_UNAVAILABLE' || 'SESSION_UNAVAILABLE' => l10n.desktopRemoteUnavailable,
    'DESKTOP_OFFLINE' => l10n.desktopRemoteOffline,
    'REQUEST_TIMEOUT' => l10n.desktopRemoteTimeout,
    'RELAY_BUSY' => l10n.desktopRemoteRelayBusy,
    'SESSION_BUSY' => l10n.desktopRemoteBusy,
    'LOCAL_CONTROL_REQUIRED' => l10n.desktopRemoteLocalControl,
    'INTERACTION_UNAVAILABLE' => l10n.desktopRemoteApprovalGone,
    'INSUFFICIENT_CREDITS' => l10n.desktopRemoteCredits,
    'MODEL_ERROR' => l10n.desktopRemoteTaskFailed,
    'MESSAGE_TOO_LONG' => l10n.desktopRemoteMessageTooLong,
    _ => l10n.desktopRemoteError,
  };
}
