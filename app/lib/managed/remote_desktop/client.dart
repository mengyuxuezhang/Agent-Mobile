import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../brand.dart';
import '../session.dart';

typedef RemoteJson = Map<String, dynamic>;

final desktopRemoteProvider = Provider<DesktopRemoteClient>((ref) {
  final session = ref.watch(managedSessionProvider);
  final transport = http.Client();
  ref.onDispose(transport.close);
  return DesktopRemoteClient(transport, ManagedBrand.api, ManagedBrand.projectId, () => session.token);
});

class DesktopRemoteException implements Exception {
  const DesktopRemoteException(this.code);
  final String code;
}

class DesktopRemoteClient {
  DesktopRemoteClient(this._http, Uri api, this._project, this._token)
    : _root = api.resolve('client/remote-desktop/v1/');

  final http.Client _http;
  final Uri _root;
  final String _project;
  final String? Function() _token;
  final _cipher = AesGcm.with256bits();
  static final _random = Random.secure();
  static const _prefix = 'agent-remote-v1';
  ({String id, SecretKey key, String token})? _link;

  bool get connected {
    if (_link?.token != _token()) _link = null;
    return _link != null;
  }

  void disconnect() => _link = null;

  Future<void> revoke() async {
    final link = _link;
    disconnect();
    if (link != null) await _call('POST', 'pairs/${link.id}/disconnect', link.token);
  }

  Future<void> pair(String code) async {
    final auth = _auth();
    final value = code.replaceAll(RegExp(r'\s+'), '');
    final manual = RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value);
    if (!manual && !RegExp(r'^agent-remote-v1:[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw const DesktopRemoteException('INVALID_CODE');
    }
    final encoded = manual ? value : value.substring(_prefix.length + 1);
    final decoded = base64Url.decode(base64Url.normalize(encoded));
    if (base64Url.encode(decoded).replaceAll('=', '') != encoded) {
      throw const DesktopRemoteException('INVALID_CODE');
    }
    final bytes = manual
        ? (await Sha256().hash([...utf8.encode('agent-remote-manual-v1\u0000'), ...decoded])).bytes
        : decoded;
    final digest = await Sha256().hash(bytes);
    final fingerprint = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final result = await _call('POST', 'claims', auth, {'fingerprint': fingerprint});
    final id = result['pairId'];
    if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
      throw const DesktopRemoteException('INVALID_RESPONSE');
    }
    _link = (id: id, key: SecretKey(bytes), token: auth);
  }

  Future<RemoteJson> request(String method, [RemoteJson fields = const {}]) async {
    final auth = _auth();
    final link = _link;
    if (link == null || link.token != auth) {
      disconnect();
      throw const DesktopRemoteException('DEVICE_UNAVAILABLE');
    }
    final requestId = _requestId();
    final value = utf8.encode(jsonEncode({...fields, 'version': 1, 'requestId': requestId, 'method': method}));
    final requestAad = utf8.encode('$_prefix:${link.id}:$requestId:request');
    final box = await _cipher.encrypt(value, secretKey: link.key, aad: requestAad);
    final ciphertext = base64Url.encode(box.concatenation()).replaceAll('=', '');
    final path = 'pairs/${link.id}/requests';
    try {
      await _call('POST', path, auth, {'requestId': requestId, 'ciphertext': ciphertext});
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < const Duration(seconds: 39)) {
        if (_link != link || auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
        final result = await _call('GET', '$path/$requestId', auth);
        final payload = result['ciphertext'];
        if (payload is String) {
          if (payload.length > 256 * 1024) throw const DesktopRemoteException('INVALID_RESPONSE');
          final packet = base64Url.decode(base64Url.normalize(payload));
          final resultBox = SecretBox.fromConcatenation(packet, nonceLength: 12, macLength: 16);
          final resultAad = utf8.encode('$_prefix:${link.id}:$requestId:result');
          final plaintext = await _cipher.decrypt(resultBox, secretKey: link.key, aad: resultAad);
          if (_link != link || auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
          final data = jsonDecode(utf8.decode(plaintext));
          if (data is! RemoteJson || data['version'] != 1 || data['requestId'] != requestId) {
            throw const DesktopRemoteException('INVALID_RESPONSE');
          }
          if (data['ok'] != true) throw DesktopRemoteException(data['code'] as String? ?? 'REMOTE_ERROR');
          if (data['method'] != method) throw const DesktopRemoteException('INVALID_RESPONSE');
          return data;
        }
        if (result['expired'] == true || result['online'] == false) {
          throw const DesktopRemoteException('DESKTOP_OFFLINE');
        }
        await Future<void>.delayed(Duration(milliseconds: method == 'chat/watch' ? 280 : 700));
      }
      throw const DesktopRemoteException('REQUEST_TIMEOUT');
    } on DesktopRemoteException catch (error) {
      if (error.code == 'DEVICE_UNAVAILABLE' || error.code == 'ACCESS_REVOKED') {
        if (_link == link) disconnect();
      }
      rethrow;
    }
  }

  String _auth() => _token() ?? (throw const DesktopRemoteException('SIGN_IN'));

  Future<RemoteJson> _call(String method, String path, String token, [RemoteJson? body]) async {
    if (_token() != token) throw const DesktopRemoteException('ACCESS_REVOKED');
    final request = http.Request(method, _root.resolve(path))
      ..followRedirects = false
      ..headers.addAll({'authorization': 'Bearer $token', 'x-agent-project-id': _project});
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await (() async => http.Response.fromStream(
      await _http.send(request),
    ))().timeout(const Duration(seconds: 7));
    if (_token() != token) throw const DesktopRemoteException('ACCESS_REVOKED');
    final json = jsonDecode(response.body);
    if (response.statusCode == 401) throw const DesktopRemoteException('SIGN_IN');
    if (json is! RemoteJson) throw const DesktopRemoteException('INVALID_RESPONSE');
    if (response.statusCode != 200 || json['success'] != true || json['data'] is! RemoteJson) {
      throw DesktopRemoteException(json['code'] as String? ?? 'RELAY_UNAVAILABLE');
    }
    return json['data'] as RemoteJson;
  }

  static String _requestId() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
