import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/managed/client.dart';
import 'package:dsh_app/managed/model_sync.dart';
import 'package:dsh_app/managed/session.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _AccountApi extends ManagedClient {
  _AccountApi() : super(MockClient((_) async => http.Response('', 500)), appVersion: '0.1.0');

  int catalogReads = 0;

  @override
  Future<JsonObject> models(String token) async {
    catalogReads++;
    expect(token, 'test-session');
    return {
      'models': [
        {'id': 'project-chat', 'modelType': 'text'},
      ],
    };
  }
}

class _Session extends ManagedSession {
  final _api = _AccountApi();

  @override
  _AccountApi get client => _api;

  final attached = <ProviderBackend>[];

  @override
  Future<void> connectModels(
    ProviderBackend engine,
    JsonObject catalog,
    String accountToken,
    bool Function() current,
  ) async {
    expect(current(), isTrue);
    expect(accountToken, 'test-session');
    expect(managedModels(catalog).single.id, 'project-chat');
    attached.add(engine);
  }
}

class _Engine implements ProviderBackend {
  _Engine({required this.isLocal});

  @override
  final bool isLocal;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EngineState extends Notifier<ProviderBackend?> {
  @override
  ProviderBackend? build() => null;

  void use(ProviderBackend? engine) => state = engine;
}

final _engineState = NotifierProvider<_EngineState, ProviderBackend?>(_EngineState.new);

void main() {
  test('the project picker only exposes official models', () {
    final catalog = projectModelCatalog(
      ModelCatalog.fromJson({
        'routableProviders': ['deepseek-official', ManagedSession.modelRoute],
        'groups': [
          {
            'id': 'deepseek-official',
            'models': [
              {'id': 'unmanaged'},
            ],
          },
          {
            'id': ManagedSession.modelRoute,
            'name': 'YushuHub',
            'models': [
              {'id': 'project-chat'},
            ],
          },
        ],
      }),
    );
    expect(catalog.routableProviders, [ManagedSession.modelRoute]);
    expect(catalog.groups.single.name, '官方');
    expect(catalog.models.single.id, 'project-chat');
  });

  test('login loads models once and attaches them when the local engine connects and reconnects', () async {
    final session = _Session();
    final container = ProviderContainer(
      overrides: [
        managedSessionProvider.overrideWithValue(session),
        providerBackendProvider.overrideWith((ref) => ref.watch(_engineState)),
      ],
    );
    addTearDown(session.dispose);
    addTearDown(container.dispose);
    container.listen(managedModelSyncProvider, (_, _) {});
    await container.read(managedModelSyncProvider.future);
    expect(session.client.catalogReads, 0);

    session.token = 'test-session';
    await container.pump();
    await container.read(managedModelCatalogProvider.future);
    expect(session.client.catalogReads, 1);
    expect(session.attached, isEmpty);

    final engines = container.read(_engineState.notifier);
    engines.use(_Engine(isLocal: false));
    await container.read(managedModelSyncProvider.future);
    expect(session.attached, isEmpty);

    final local = _Engine(isLocal: true);
    engines.use(local);
    await container.read(managedModelSyncProvider.future);
    expect(session.attached, [local]);

    engines.use(null);
    await container.read(managedModelSyncProvider.future);
    final restarted = _Engine(isLocal: true);
    engines.use(restarted);
    await container.read(managedModelSyncProvider.future);
    expect(session.attached, [local, restarted]);
    expect(session.client.catalogReads, 1);

    await session.signOut();
    await container.pump();
    expect(await container.read(managedModelCatalogProvider.future), isNull);
  });
}
