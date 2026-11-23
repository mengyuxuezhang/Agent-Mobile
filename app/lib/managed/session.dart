import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../secrets/secure_storage.dart';
import '../state/app_info.dart';
import '../state/provider_backend.dart';
import 'brand.dart';
import 'client.dart';
import 'model_gateway.dart';

final managedSessionProvider = Provider<ManagedSession>((ref) {
  final session = ManagedSession(
    storageKey: ManagedBrand.isConfigured ? 'managed-session:${ManagedBrand.api}:${ManagedBrand.projectId}' : null,
  );
  ref.onDispose(session.dispose);
  return session;
});

final managedSignedInProvider = Provider<bool>((ref) {
  final session = ref.watch(managedSessionProvider);
  final listener = ref.invalidateSelf;
  session.signedIn.addListener(listener);
  ref.onDispose(() => session.signedIn.removeListener(listener));
  return session.signedIn.value;
});

enum ManagedRestoreState { checking, unavailable, finished }

final managedRestoreStateProvider = Provider<ManagedRestoreState>((ref) {
  final restoreState = ref.watch(managedSessionProvider).restoreState;
  final listener = ref.invalidateSelf;
  restoreState.addListener(listener);
  ref.onDispose(() => restoreState.removeListener(listener));
  return restoreState.value;
});

class ManagedSession {
  ManagedSession({
    String? storageKey,
    this._storage = const AppSecureStorage(
      FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'managed_session')),
    ),
    http.Client? transport,
    this._api,
  }) : _storageKey = storageKey,
       _transport = transport ?? http.Client(),
       restoreState = ValueNotifier(storageKey == null ? ManagedRestoreState.finished : ManagedRestoreState.checking);

  final String? _storageKey;
  final AppSecureStorage _storage;
  final http.Client _transport;
  final Uri? _api;
  late final client = ManagedClient(_transport, appVersion: AppInfo.version, api: _api, onUnauthorized: rejectToken);
  final ValueNotifier<ManagedRestoreState> restoreState;
  Future<void>? _restoring;
  Future<void> _credentialUpdates = Future.value();
  int _revision = 0;
  bool _disposed = false;

  Future<void> _updateCredentials(Future<void> Function() update) {
    final result = _credentialUpdates.then((_) => update());
    _credentialUpdates = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> restore() {
    if (_disposed || restoreState.value == ManagedRestoreState.finished) return Future.value();
    return _restoring ??= _restore().whenComplete(() => _restoring = null);
  }

  Future<void> _restore() async {
    final revision = _revision;
    final key = _storageKey!;
    bool current() => !_disposed && revision == _revision;
    restoreState.value = ManagedRestoreState.checking;
    try {
      final saved = await _storage.read(key: key);
      if (!current()) return;
      if (saved != null) {
        try {
          final account = await client.account(saved);
          if (account['user'] case {'id': final String id} when id.isNotEmpty) {
            if (current()) token = saved;
          } else {
            throw const FormatException('Invalid account response');
          }
        } on ManagedApiError catch (error) {
          if (error.status != 401) rethrow;
          await _updateCredentials(() async {
            if (current()) await _storage.delete(key: key);
          });
        }
      }
      if (current()) restoreState.value = ManagedRestoreState.finished;
    } catch (_) {
      if (current()) restoreState.value = ManagedRestoreState.unavailable;
    }
  }

  Future<void> signIn(String value) => _updateCredentials(() async {
    if (_disposed) return;
    if (_storageKey case final key?) await _storage.write(key: key, value: value);
    if (_disposed) return;
    _revision++;
    token = value;
    restoreState.value = ManagedRestoreState.finished;
  });

  /// A delayed reply from one login must never sign out a replacement login.
  Future<void> rejectToken(String value) async {
    try {
      await _signOut(expected: value);
    } catch (_) {
      // The API no longer accepts this token. Recheck the stored copy at launch
      // if deleting it failed, and let the caller report the original 401.
    }
  }

  static const modelRoute = 'yushuhub-managed';
  static final _keyRef = deriveProviderKeyRef(modelRoute);
  String? _token;
  final signedIn = ValueNotifier(false);
  String? get token => _token;
  set token(String? value) {
    _token = value;
    signedIn.value = value != null;
  }

  ManagedModelGateway? _gateway;
  ProviderBackend? _engine;
  Future<void> _engineUpdates = Future.value();

  Future<void> _updateEngine(Future<void> Function() action) {
    final result = _engineUpdates.then((_) => action());
    _engineUpdates = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> connectModels(
    ProviderBackend engine,
    JsonObject catalog,
    String accountToken,
    bool Function() current,
  ) => _updateEngine(() => _connectModels(engine, catalog, accountToken, current));

  Future<void> _connectModels(
    ProviderBackend engine,
    JsonObject catalog,
    String accountToken,
    bool Function() current,
  ) async {
    if (token != accountToken || !current() || !engine.isLocal) return;
    final entries = _managedModelEntries(catalog);
    final models = entries.map((entry) => entry.spec).toList(growable: false);
    final settings = await engine.read();
    if (token != accountToken || !current()) return;
    if (settings == null) throw StateError('DSH model adapter is unavailable');
    _engine = engine;
    final existing = settings.profiles.any((profile) => profile.route == modelRoute);
    if (models.isEmpty) {
      final previous = _gateway;
      _gateway = null;
      await previous?.close();
      if (existing) await engine.remove(modelRoute, expectedRevision: settings.revision);
      return;
    }
    final gateway = ManagedModelGateway(
      http.Client(),
      endpoint: ManagedBrand.api.resolve('client/model/v1/chat/completions'),
      projectId: ManagedBrand.projectId,
      token: accountToken,
      allowedModels: models.map((model) => model.id).toSet(),
      onSessionRejected: () => rejectToken(accountToken),
      modelsWithoutTools: entries.where((entry) => entry.withoutTools).map((entry) => entry.spec.id).toSet(),
    );
    try {
      final url = await gateway.start();
      if (token != accountToken || !current()) {
        await gateway.close();
        return;
      }
      await engine.storeKey(_keyRef, gateway.key);
      if (existing) {
        await engine.update(
          modelRoute,
          displayName: appL10n.managedOfficial,
          api: ProviderApi.openaiCompletions,
          baseUrl: url.toString(),
          apiKeyEnv: _keyRef,
          models: models,
          headers: const {},
          expectedRevision: settings.revision,
        );
      } else {
        await engine.create(
          ProviderProfile(
            route: modelRoute,
            displayName: appL10n.managedOfficial,
            api: ProviderApi.openaiCompletions.wire,
            baseUrl: url.toString(),
            apiKeyEnv: _keyRef,
            models: models,
          ),
        );
      }
      if (token != accountToken) {
        await gateway.close();
        return;
      }
    } catch (_) {
      await gateway.close();
      rethrow;
    }
    final previous = _gateway;
    _gateway = gateway;
    await previous?.close();
  }

  Future<void> signOut() => _signOut();

  Future<void> _signOut({String? expected}) => _updateCredentials(() async {
    if (_disposed || (expected != null && token != expected)) return;
    try {
      if (_storageKey case final key?) await _storage.delete(key: key);
    } catch (_) {
      if (expected == null) rethrow;
    }
    if (_disposed) return;
    _revision++;
    token = null;
    restoreState.value = ManagedRestoreState.finished;
    final gateway = _gateway;
    _gateway = null;
    final closing = gateway?.close();
    return _updateEngine(() async {
      final engine = _engine;
      _engine = null;
      await closing;
      if (engine == null) return;
      // Remove the persistent engine entry when possible. Once the local
      // gateway is closed, any stale entry has no access to the user account.
      try {
        await engine.clearKey(_keyRef).timeout(const Duration(seconds: 3));
      } finally {
        await engine.remove(modelRoute).timeout(const Duration(seconds: 3));
      }
    });
  });

  void dispose() {
    _disposed = true;
    _token = null;
    restoreState.dispose();
    signedIn.dispose();
    _transport.close();
    final gateway = _gateway;
    _gateway = null;
    if (gateway != null) unawaited(gateway.close());
  }
}

List<ProviderModelSpec> managedModels(JsonObject catalog) =>
    _managedModelEntries(catalog).map((entry) => entry.spec).toList(growable: false);

typedef _ManagedModelEntry = ({ProviderModelSpec spec, bool withoutTools});

List<_ManagedModelEntry> _managedModelEntries(JsonObject catalog) {
  final raw = catalog['models'];
  if (raw is! List) return const [];
  final unique = <String, _ManagedModelEntry>{};
  for (final model in raw.whereType<JsonObject>()) {
    final id = model['id'];
    if (id is! String || id.isEmpty || model['modelType'] != 'text' || model['configured'] == false) continue;
    final rawContext = int.tryParse('${model['contextWindow']}');
    final capabilities = (model['capabilities'] is List ? model['capabilities'] as List : const [])
        .whereType<String>()
        .map((tag) => tag.trim().toLowerCase().replaceAll(RegExp(r'[-\s]+'), '_'))
        .where((tag) => tag.isNotEmpty)
        .toSet();
    final visionFlag = model['supportsVision'];
    final vision = visionFlag is bool
        ? visionFlag
        : capabilities.any(const {'vision', 'image_understanding', 'image_input', 'multimodal'}.contains);
    final tools = model['supportsTools'];
    final supportsTools = tools is bool
        ? tools
        : capabilities.isEmpty
        ? null
        : capabilities.any(const {'tool_calls', 'tools', 'tool', 'function_calling'}.contains);
    final reasoning = model['reasoning'];
    final efforts = reasoning is Map && reasoning['enabled'] == true && model['supportsReasoning'] != false
        ? reasoning['efforts']
        : null;
    final levels = <String, String>{
      if (efforts is List)
        for (final effort in efforts.whereType<String>())
          if (effort == 'none' || (piAiThinkingLevels.contains(effort) && effort != 'off' && effort != 'max'))
            (effort == 'none' ? 'off' : effort): effort,
    };
    unique.putIfAbsent(
      id,
      () => (
        withoutTools: supportsTools == false,
        spec: ProviderModelSpec(
          id: id,
          name: model['name'] is String ? model['name'] as String : null,
          contextWindow: rawContext != null && rawContext > 0 ? rawContext : null,
          input: vision ? const ['text', 'image'] : const ['text'],
          extra: {'reasoningEfforts': levels.keys.any((level) => level != 'off') ? levels : false},
        ),
      ),
    );
  }
  return unique.values.toList(growable: false);
}
