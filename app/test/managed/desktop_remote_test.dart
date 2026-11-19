import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/managed/remote_desktop/client.dart';
import 'package:dsh_app/managed/remote_desktop/screen.dart';
import 'package:dsh_app/managed/session.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('scan action passes the decoded QR to the managed device session', (tester) async {
    final session = ManagedSession()..token = 'phone-test-session';
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
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: DesktopRemoteScreen(),
        ),
      ),
    );
    await tester.tap(find.text('扫描配对二维码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fixture scanner'));
    await tester.pumpAndSettle();
    expect(client.code, payload);
    expect(find.text('电脑工作区'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
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
  bool get connected => code != null;

  @override
  Future<void> pair(String value) async {
    code = value;
  }

  @override
  Future<RemoteJson> request(String method, [RemoteJson fields = const {}]) async {
    expect(method, 'workspaces/list');
    return {'workspaces': []};
  }
}
