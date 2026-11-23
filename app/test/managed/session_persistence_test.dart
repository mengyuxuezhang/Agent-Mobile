import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/managed/client.dart';
import 'package:dsh_app/managed/session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _key = 'managed-session:test';
final _api = Uri.parse('https://brand.example/api/');
final _ok = http.Response(
  jsonEncode({
    'success': true,
    'data': {
      'user': {'id': 'test'},
    },
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterSecureStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'managed_session'));
  });

  ManagedSession session(Future<http.Response> Function(http.Request) handler) {
    final value = ManagedSession(storageKey: _key, transport: MockClient(handler), api: _api);
    addTearDown(value.dispose);
    return value;
  }

  test('writes sign-in and verifies it before restoring to a fresh session', () async {
    final first = session((_) async => _ok);
    await first.signIn('saved');
    expect(await storage.read(key: _key), 'saved');

    final reply = Completer<http.Response>();
    var calls = 0;
    final second = session((request) {
      calls++;
      expect(request.url.path, '/api/client/auth/me');
      expect(request.headers['authorization'], 'Bearer saved');
      return reply.future;
    });
    final original = second.restore();
    final duplicate = second.restore();
    expect(second.signedIn.value, isFalse);
    reply.complete(_ok);
    await Future.wait([original, duplicate]);
    expect(calls, 1);
    expect(second.signedIn.value, isTrue);
    expect(second.token, 'saved');
  });

  test('retains encrypted credentials on an outage and retries the same session', () async {
    await storage.write(key: _key, value: 'saved');
    var reachable = false;
    final current = session((_) async => reachable ? _ok : http.Response('', 503));
    await current.restore();
    expect(current.restoreState.value, ManagedRestoreState.unavailable);
    expect(current.signedIn.value, isFalse);
    expect(await storage.read(key: _key), 'saved');
    reachable = true;
    await current.restore();
    expect(current.signedIn.value, isTrue);
  });

  test('discards an expired or revoked credential during startup', () async {
    await storage.write(key: _key, value: 'expired');
    final current = session((_) async => http.Response('', 401));
    await current.restore();
    expect(current.restoreState.value, ManagedRestoreState.finished);
    expect(current.signedIn.value, isFalse);
    expect(await storage.read(key: _key), isNull);
  });

  test('explicit sign-out clears the saved credential and prevents restart authentication', () async {
    final first = session((_) async => _ok);
    await first.signIn('saved');
    await first.signOut();
    expect(first.token, isNull);
    expect(await storage.read(key: _key), isNull);

    final next = session((_) async => throw StateError('A signed-out session must not call the server.'));
    await next.restore();
    expect(next.restoreState.value, ManagedRestoreState.finished);
    expect(next.signedIn.value, isFalse);
  });

  test('a 401 while using the account signs out only the rejected token', () async {
    final reply = Completer<http.Response>();
    final received = Completer<void>();
    final current = session((req) async {
      if (req.headers['authorization'] == 'Bearer first') {
        received.complete();
        return reply.future;
      }
      return http.Response('', 401);
    });
    await current.signIn('first');
    final pending = expectLater(current.client.credits('first'), throwsA(isA<ManagedApiError>()));
    await received.future;
    await current.signIn('replacement');
    reply.complete(http.Response('', 401));
    await pending;
    expect(current.token, 'replacement');
    expect(await storage.read(key: _key), 'replacement');

    await expectLater(current.client.credits('replacement'), throwsA(isA<ManagedApiError>()));
    expect(current.token, isNull);
    expect(await storage.read(key: _key), isNull);
  });

  test('a late restoration cannot resurrect a signed-out credential', () async {
    await storage.write(key: _key, value: 'saved');
    final reply = Completer<http.Response>();
    final validating = Completer<void>();
    final current = session((_) {
      validating.complete();
      return reply.future;
    });
    final restoring = current.restore();
    await validating.future;
    await current.signOut();
    reply.complete(_ok);
    await restoring;
    expect(current.signedIn.value, isFalse);
    expect(await storage.read(key: _key), isNull);
  });
}
