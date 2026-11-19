import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../lib/managed/remote_desktop/client.dart';

void main() {
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
