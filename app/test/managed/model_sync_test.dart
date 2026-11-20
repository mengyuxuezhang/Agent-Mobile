import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/managed/client.dart';
import 'package:dsh_app/managed/model_sync.dart';
import 'package:dsh_app/managed/model_gateway.dart';
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
  test('official profiles map vision and configured thinking levels from the catalog', () {
    final models = managedModels({
      'models': [
        {
          'id': 'vision',
          'modelType': 'text',
          'capabilities': ['text', 'Image Understanding', 'tool_calls'],
          'reasoning': {
            'enabled': true,
            'efforts': ['none', 'low', 'high', 'unknown'],
          },
        },
        {
          'id': 'text',
          'modelType': 'text',
          'capabilities': ['vision'],
          'supportsVision': false,
        },
        {
          'id': 'generator',
          'modelType': 'image',
          'capabilities': ['image_generation'],
        },
      ],
    });
    expect(models.map((model) => model.id), ['vision', 'text']);
    expect(models.first.toJson()['input'], ['text', 'image']);
    expect(models.first.reasoningEfforts, {'off': 'none', 'low': 'low', 'high': 'high'});
    expect(models.last.acceptsImages(), isFalse);
    expect(models.last.thinks, isFalse);
  });

  test('mobile gateway preserves image and reasoning and omits tools only for models without tools', () async {
    final requests = <Map<String, dynamic>>[];
    final gateway = ManagedModelGateway(
      MockClient((request) async {
        expect(request.headers['x-agent-client-platform'], 'android');
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      }),
      endpoint: Uri.parse('https://fixture.test/api/client/model/v1/chat/completions'),
      projectId: 'project',
      token: 'fixture',
      allowedModels: {'vision-tool', 'vision-only'},
      modelsWithoutTools: {'vision-only'},
    );
    addTearDown(gateway.close);
    final url = await gateway.start();
    final messages = [
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AA=='},
          },
        ],
      },
    ];
    for (final model in ['vision-tool', 'vision-only']) {
      final reply = await http.post(
        url.replace(path: '/v1/chat/completions'),
        headers: {'authorization': 'Bearer ${gateway.key}', 'content-type': 'application/json'},
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'reasoning_effort': 'low',
          'tools': [
            {'type': 'function'},
          ],
          'tool_choice': 'auto',
        }),
      );
      expect(reply.statusCode, 200);
    }
    expect(requests.first['tools'], isNotNull);
    expect(requests.last.containsKey('tools'), isFalse);
    expect(requests.last.containsKey('tool_choice'), isFalse);
    expect(requests.last['messages'], messages);
    expect(requests.last['reasoning_effort'], 'low');
  });

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
