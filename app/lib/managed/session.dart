import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../state/app_info.dart';
import '../state/provider_backend.dart';
import 'brand.dart';
import 'client.dart';
import 'model_gateway.dart';

final managedSessionProvider = Provider<ManagedSession>((ref) {
  final session = ManagedSession();
  ref.onDispose(session.dispose);
  return session;
});

class ManagedSession {
  final _transport = http.Client();
  late final client = ManagedClient(_transport, appVersion: AppInfo.version);
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
  bool get modelsConnected => _gateway != null;

  Future<void> connectModels(ProviderBackend engine, JsonObject catalog) async {
    final accountToken = token;
    if (accountToken == null || !engine.isLocal) {
      throw StateError('A signed-in account and local engine are required');
    }
    final models = managedModels(catalog);
    if (models.isEmpty) throw StateError('No available chat models');
    final settings = await engine.read();
    if (token != accountToken) throw StateError('Account changed');
    if (settings == null) throw StateError('DSH model adapter is unavailable');
    final gateway = ManagedModelGateway(
      http.Client(),
      endpoint: ManagedBrand.api.resolve('client/model/v1/chat/completions'),
      projectId: ManagedBrand.projectId,
      token: accountToken,
      allowedModels: models.map((model) => model.id).toSet(),
    );
    try {
      final url = await gateway.start();
      await engine.storeKey(_keyRef, gateway.key);
      final existing = settings.profiles.any((profile) => profile.route == modelRoute);
      if (existing) {
        await engine.update(
          modelRoute,
          displayName: 'YushuHub',
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
            displayName: 'YushuHub',
            api: ProviderApi.openaiCompletions.wire,
            baseUrl: url.toString(),
            apiKeyEnv: _keyRef,
            models: models,
          ),
        );
      }
      if (token != accountToken) throw StateError('Account changed');
    } catch (_) {
      await gateway.close();
      rethrow;
    }
    final previous = _gateway;
    _gateway = gateway;
    _engine = engine;
    await previous?.close();
  }

  Future<void> signOut() async {
    token = null;
    final gateway = _gateway;
    final engine = _engine;
    _gateway = null;
    _engine = null;
    await gateway?.close();
    if (engine != null) {
      // Remove the persistent engine entry when possible. Once the local
      // gateway is closed, any stale entry has no access to the user account.
      try {
        await engine.clearKey(_keyRef).timeout(const Duration(seconds: 3));
      } finally {
        await engine.remove(modelRoute).timeout(const Duration(seconds: 3));
      }
    }
  }

  void dispose() {
    _token = null;
    signedIn.dispose();
    _transport.close();
    final gateway = _gateway;
    _gateway = null;
    if (gateway != null) unawaited(gateway.close());
  }
}

List<ProviderModelSpec> managedModels(JsonObject catalog) {
  final raw = catalog['models'];
  if (raw is! List) return const [];
  final unique = <String, ProviderModelSpec>{};
  for (final model in raw.whereType<JsonObject>()) {
    final id = model['id'];
    if (id is! String || id.isEmpty || model['modelType'] != 'text' || model['configured'] == false) continue;
    final rawContext = int.tryParse('${model['contextWindow']}');
    final vision = model['supportsVision'] == true;
    unique.putIfAbsent(
      id,
      () => ProviderModelSpec(
        id: id,
        name: model['name'] is String ? model['name'] as String : null,
        contextWindow: rawContext != null && rawContext > 0 ? rawContext : null,
        input: vision ? const ['text', 'image'] : const ['text'],
      ),
    );
  }
  return unique.values.toList(growable: false);
}
