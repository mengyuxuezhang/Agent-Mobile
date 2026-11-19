import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/models_state.dart';
import '../state/providers_state.dart';
import 'client.dart';
import 'session.dart';

final managedModelCatalogProvider = FutureProvider<JsonObject?>((ref) async {
  if (!ref.watch(managedSignedInProvider)) return null;
  final session = ref.watch(managedSessionProvider);
  final token = session.token;
  if (token == null) return null;
  try {
    return await session.client.models(token);
  } on ManagedApiError catch (error) {
    if (error.status == 401 && ref.mounted && session.token == token) {
      await session.signOut();
    }
    rethrow;
  }
});

/// Kept alive by the app so login and a later local-engine reconnect both bind
/// the same project catalog, regardless of which page is open.
final managedModelSyncProvider = FutureProvider<void>((ref) async {
  final session = ref.watch(managedSessionProvider);
  final catalog = ref.watch(managedModelCatalogProvider);
  final engine = ref.watch(providerBackendProvider);
  final token = session.token;
  if (token == null || engine == null || !engine.isLocal || catalog.isLoading || catalog.hasError) return;
  final models = catalog.value;
  if (models == null) return;
  var current = true;
  ref.onDispose(() => current = false);
  await session.connectModels(engine, models, token, () => current);
  if (current && ref.mounted) ref.invalidate(modelCatalogProvider);
});
