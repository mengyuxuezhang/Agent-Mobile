import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/managed/brand.dart';
import 'package:dsh_app/managed/remote_desktop/chat_feed.dart';
import 'package:dsh_app/managed/remote_desktop/client.dart';
import 'package:dsh_app/managed/remote_desktop/host.dart';
import 'package:dsh_app/managed/remote_desktop/screen.dart';
import 'package:dsh_app/managed/session.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('scan action passes the decoded QR to the managed device session', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = ManagedSession();
    final client = _PairScreenClient();
    const payload = 'agent-remote-v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          managedSessionProvider.overrideWithValue(session),
          desktopRemoteProvider.overrideWithValue(client),
          pairingScannerProvider.overrideWithValue(
            (context, onCode) => TextButton(onPressed: () => onCode(payload), child: const Text('fixture scanner')),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          theme: buildLightTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: ManagedBrand.isConfigured ? const RemoteScreen() : const DesktopRemoteScreen(),
        ),
      ),
    );
    if (ManagedBrand.isConfigured) {
      await tester.pumpAndSettle();
      expect(find.text('登录 DSH Remote'), findsNothing);
      expect(find.textContaining('自建服务器'), findsNothing);
      expect(find.textContaining('liguobao'), findsNothing);
      expect(find.textContaining('DeepSeek'), findsNothing);
      expect(find.text('其他方式'), findsNothing);
      expect(find.text('网页版远程控制台'), findsNothing);
      for (final provider in ['GitHub', '知乎', 'Google']) {
        expect(find.textContaining(provider), findsNothing);
      }
      expect(find.text('精简历史'), findsOneWidget);
      expect(find.textContaining('DSH Remote'), findsNothing);
      await tester.tap(find.text('扫码配对电脑'));
      await tester.pumpAndSettle();
    }
    expect(find.text('请先登录与电脑相同的品牌账号。'), findsOneWidget);
    expect(find.textContaining('DeepSeek'), findsNothing);
    session.token = 'phone-test-session';
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描配对二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fixture scanner'));
    await tester.pumpAndSettle();
    expect(client.code, payload);
    final app = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(app.read(activeHostProvider), const HostRef.desktop('test-pair'));
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('switching hosts keeps each chat selection on its own host', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = ProviderContainer();
    addTearDown(app.dispose);
    final hosts = app.read(activeHostProvider.notifier);
    final chats = app.read(currentSessionProvider.notifier);
    const desktop = HostRef.desktop('paired-desktop');

    chats.select('phone-chat');
    hosts.select(desktop);
    expect(app.read(currentSessionProvider), isNull);

    chats.select('desktop-chat');
    hosts.select(HostRef.local);
    expect(app.read(currentSessionProvider), 'phone-chat');
    hosts.select(desktop);
    expect(app.read(currentSessionProvider), 'desktop-chat');

    await hosts.forget((host) => host == desktop);
    expect(app.read(activeHostProvider), HostRef.local);
    expect(app.read(currentSessionProvider), 'phone-chat');
  });

  testWidgets('managed remote settings show the active computer name and heartbeat status', (tester) async {
    if (!ManagedBrand.isConfigured) return;
    const office = HostRef.desktop('office-test', name: 'Office PC');
    SharedPreferences.setMockInitialValues({ActiveHostController.prefsKey: office.encode()});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          managedSignedInProvider.overrideWithValue(true),
          desktopDevicesProvider.overrideWith((ref) => Stream.value([(id: office.id, name: office.name)])),
          desktopOnlineProvider(office.id).overrideWith((ref) => Stream.value(true)),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          theme: buildLightTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const RemoteScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Using “Office PC”'), findsOneWidget);
    expect(find.text(appL10n.remoteOnline), findsOneWidget);
  });

  test('grouped manual code and scanned QR claim the same pairing', () async {
    final entropy = List<int>.filled(16, 7);
    final key = (await Sha256().hash([...utf8.encode('agent-remote-manual-v1\u0000'), ...entropy])).bytes;
    String encoded(List<int> value) => base64Url.encode(value).replaceAll('=', '');
    final manual = RegExp('.{1,4}').allMatches(encoded(entropy)).map((group) => group.group(0)).join(' ');
    final submitted = <String>[];
    final client = DesktopRemoteClient(
      MockClient((request) async {
        submitted.add((jsonDecode(request.body) as RemoteJson)['fingerprint'] as String);
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {'pairId': '2576a4b4-4b6d-4ad5-9bb8-cb494623198d'},
          }),
          200,
        );
      }),
      Uri.parse('https://example.test/api/'),
      'example-brand',
      () => 'existing-phone-login',
    );
    await client.pair(manual);
    await client.pair('agent-remote-v1:${encoded(key)}');
    expect(submitted, hasLength(2));
    expect(submitted.first, submitted.last);
  });

  test('paces live reads across chat and inventory requests and identifies a busy relay', () async {
    var now = Duration.zero;
    var busy = false;
    var expired = false;
    http.Response success(RemoteJson data) => http.Response(jsonEncode({'success': true, 'data': data}), 200);
    final client = DesktopRemoteClient(
      MockClient((request) async {
        if (request.url.path.endsWith('/claims')) {
          return success({'pairId': '2576a4b4-4b6d-4ad5-9bb8-cb494623198d'});
        }
        if (busy) return http.Response('Temporarily busy', 429);
        if (request.method == 'POST') return success({'accepted': true});
        return success({'online': !expired, 'expired': true});
      }),
      Uri.parse('https://example.test/api/'),
      'example-brand',
      () => 'phone',
      monotonicTime: () => now,
    );
    Future<void> timedOut(String method) => expectLater(
      client.request(method),
      throwsA(isA<DesktopRemoteException>().having((e) => e.code, 'code', 'REQUEST_TIMEOUT')),
    );

    await client.pair('agent-remote-v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    await timedOut('chat/watch');
    expect(client.watchDelay(), const Duration(milliseconds: 2100));

    now += const Duration(seconds: 3);
    for (var i = 0; i < 25; i++) {
      await timedOut('sessions/recent');
    }
    expect(client.watchDelay(), const Duration(milliseconds: 42500));
    now = const Duration(milliseconds: 45500);
    expect(client.watchDelay(), Duration.zero);

    busy = true;
    await expectLater(
      client.request('chat/watch'),
      throwsA(isA<DesktopRemoteException>().having((e) => e.code, 'code', 'RELAY_BUSY')),
    );
    busy = false;
    expired = true;
    await expectLater(
      client.request('chat/watch'),
      throwsA(isA<DesktopRemoteException>().having((e) => e.code, 'code', 'DESKTOP_OFFLINE')),
    );
    expect(client.connected, true);
  });

  test('restores multiple named computers under the same account after login changes', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const office = '2576a4b4-4b6d-4ad5-9bb8-cb494623198d';
    const home = '2576a4b4-4b6d-4ad5-9bb8-cb494623198e';
    var token = 'first-login';
    var claims = 0;
    final transport = MockClient((request) async {
      final segments = request.url.pathSegments;
      final data = switch (segments.last) {
        'claims' =>
          ++claims == 1 ? {'pairId': office, 'deviceName': 'Office PC'} : {'pairId': home, 'deviceName': 'Home PC'},
        'status' => {'online': segments[segments.length - 2] == office},
        'disconnect' => {'revoked': true},
        _ => throw StateError('Unexpected request: ${request.url}'),
      };
      return http.Response(jsonEncode({'success': true, 'data': data}), 200);
    });
    DesktopRemoteClient start() => DesktopRemoteClient(
      transport,
      Uri.parse('https://example.test/api/'),
      'brand',
      () => token,
      storage: const AppSecureStorage(),
      accountId: (token) async => token == 'other-login' ? 'other' : 'owner',
    );
    final initial = start();
    for (final value in [1, 2]) {
      final code = base64Url.encode(List<int>.filled(32, value)).replaceAll('=', '');
      await initial.pair('agent-remote-v1:$code');
    }
    token = 'renewed-login';
    final restored = start();
    await restored.restore();
    expect(restored.devices, [(id: office, name: 'Office PC'), (id: home, name: 'Home PC')]);
    expect(await restored.online(office), isTrue);
    expect(await restored.online(home), isFalse);
    await restored.revokeDevice(office);
    final reduced = start();
    await reduced.restore();
    expect(reduced.devices.single.id, home);
    token = 'other-login';
    await reduced.restore();
    expect(reduced.devices, isEmpty);
    expect(claims, 2);
  });

  test('shows remote Ask in the native chat state and sends its answer back to the selected computer', () async {
    final remote = _QuestionRemote();
    final host = DesktopHostClient(remote, 'office');
    final views = <ChatState>[];
    final feed = DesktopChatFeed(host, 'chat', views.add);
    addTearDown(() async {
      feed.close();
      await host.close();
    });
    expect(await feed.refresh(), isTrue);
    expect(await feed.refresh(), isTrue);
    final request = views.last.questions.single;
    expect(request.questions.single.options.single.label, 'Markdown');
    expect(
      await feed.answer(request, [
        const QuestionAnswer('0', selected: ['Markdown']),
      ]),
      isTrue,
    );
    expect(remote.answer, {
      'workspaceId': 'work',
      'sessionId': 'chat',
      'interactionId': 'ask',
      'answers': [
        {
          'index': 0,
          'selected': ['Markdown'],
        },
      ],
    });
  });

  test('binds the encrypted request to the paired account and discards it after login changes', () async {
    const pairId = '2576a4b4-4b6d-4ad5-9bb8-cb494623198d';
    final bytes = List<int>.filled(32, 7);
    final key = SecretKey(bytes);
    final pairingCode = base64Url.encode(bytes).replaceAll('=', '');
    final aes = AesGcm.with256bits();
    var token = 'existing-phone-login';
    var calls = 0;
    late String requestId;
    http.Response result(Map<String, Object?> data) => http.Response(jsonEncode({'success': true, 'data': data}), 200);

    final transport = MockClient((request) async {
      calls++;
      expect(request.headers['authorization'], 'Bearer existing-phone-login');
      expect(request.headers['x-agent-project-id'], 'example-brand');
      expect(request.followRedirects, false);
      expect(request.url.path, startsWith('/api/client/remote-desktop/v1/'));
      if (request.url.path.endsWith('/claims')) {
        final hash = await Sha256().hash(bytes);
        final fingerprint = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(jsonDecode(request.body), {'fingerprint': fingerprint});
        return result({'pairId': pairId});
      }
      if (request.method == 'POST') {
        final envelope = jsonDecode(request.body) as RemoteJson;
        requestId = envelope['requestId'] as String;
        final wire = base64Url.decode(base64Url.normalize(envelope['ciphertext'] as String));
        final box = SecretBox.fromConcatenation(wire, nonceLength: 12, macLength: 16);
        final plaintext = await aes.decrypt(
          box,
          secretKey: key,
          aad: utf8.encode('agent-remote-v1:$pairId:$requestId:request'),
        );
        expect(jsonDecode(utf8.decode(plaintext)), {
          'version': 1,
          'requestId': requestId,
          'method': 'chat/send',
          'text': 'A private message',
        });
        return result({'accepted': true});
      }
      expect(request.url.pathSegments.last, requestId);
      final encrypted = await aes.encrypt(
        utf8.encode(jsonEncode({'version': 1, 'requestId': requestId, 'ok': true, 'method': 'chat/send'})),
        secretKey: key,
        aad: utf8.encode('agent-remote-v1:$pairId:$requestId:result'),
      );
      return result({'online': true, 'ciphertext': base64Url.encode(encrypted.concatenation()).replaceAll('=', '')});
    });
    final client = DesktopRemoteClient(transport, Uri.parse('https://example.test/api/'), 'example-brand', () => token);
    await client.pair('agent-remote-v1:$pairingCode');
    expect(client.connected, true);
    await expectLater(client.request('chat/send', {'text': 'A private message'}), completion(containsPair('ok', true)));
    token = 'another-account';
    expect(client.connected, false);
    await expectLater(
      client.request('workspaces/list'),
      throwsA(isA<DesktopRemoteException>().having((e) => e.code, 'code', 'DEVICE_UNAVAILABLE')),
    );
    expect(calls, 3);
  });
}

class _QuestionRemote extends DesktopRemoteClient {
  _QuestionRemote()
    : super(
        MockClient((_) async => http.Response('', 500)),
        Uri.parse('https://example.test/api/'),
        'fixture',
        () => 'login',
      );

  RemoteJson? answer;

  @override
  Future<RemoteJson> request(String method, [RemoteJson fields = const {}, String? deviceId]) async {
    expect(deviceId, 'office');
    switch (method) {
      case 'workspaces/list':
        return {
          'questionCards': true,
          'workspaces': [
            {'id': 'work', 'name': 'Work'},
          ],
        };
      case 'sessions/list':
        return {
          'sessions': [
            {'id': 'chat', 'title': 'Chat', 'updatedAt': '2026-11-24T00:00:00Z', 'messageCount': 1},
          ],
        };
      case 'chat/open':
        return {
          'chat': {'status': 'running'},
        };
      case 'chat/watch':
        expect(fields['questionCards'], true);
        return {
          'chat': {
            'status': 'running',
            'questions': [
              {
                'id': 'ask',
                'questions': [
                  {
                    'id': '0',
                    'question': 'Choose a format',
                    'options': [
                      {'label': 'Markdown'},
                    ],
                  },
                ],
              },
            ],
          },
        };
      case 'chat/answer':
        answer = fields;
        return {};
      default:
        throw StateError('Unexpected method: $method');
    }
  }
}

class _PairScreenClient extends DesktopRemoteClient {
  _PairScreenClient()
    : super(
        MockClient((_) async => http.Response('', 500)),
        Uri.parse('https://example.test/api/'),
        'fixture',
        () => 'phone-test-session',
      );

  String? code;

  @override
  String? get pairId => code == null ? null : 'test-pair';

  @override
  List<DesktopDevice> get devices => code == null ? [] : [(id: 'test-pair', name: null)];

  @override
  Future<void> pair(String value) async {
    code = value;
  }

  @override
  Future<RemoteJson> request(String method, [RemoteJson fields = const {}, String? deviceId]) async {
    expect(method, 'workspaces/list');
    return {'workspaces': []};
  }
}
