import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../secrets/secure_storage.dart';
import '../brand.dart';
import '../session.dart';

typedef RemoteJson = Map<String, dynamic>;
typedef DesktopDevice = ({String id, String? name});
typedef _DesktopLink = ({String id, SecretKey key, String token, String? name});

class _RequestPacing {
  final submissions = Queue<Duration>();
  Duration? lastWatch;

  void prune(Duration now, Duration retention) {
    while (submissions.isNotEmpty && now - submissions.first >= retention) {
      submissions.removeFirst();
    }
  }
}

final desktopRemoteProvider = Provider<DesktopRemoteClient>((ref) {
  final session = ref.watch(managedSessionProvider);
  final transport = http.Client();
  final client = DesktopRemoteClient(
    transport,
    ManagedBrand.api,
    ManagedBrand.projectId,
    () => session.token,
    onUnauthorized: session.rejectToken,
    storage: const AppSecureStorage(),
    accountId: (token) async {
      final state = await session.client.account(token);
      final user = state['user'];
      if (user is! RemoteJson || user['id'] is! String) throw const DesktopRemoteException('SIGN_IN');
      return user['id'] as String;
    },
  );
  ref.onDispose(() {
    transport.close();
    unawaited(client.linkChanges.close());
  });
  return client;
});

class DesktopRemoteException implements Exception {
  const DesktopRemoteException(this.code);
  final String code;
}

class DesktopRemoteClient {
  DesktopRemoteClient(
    this._http,
    Uri api,
    this._project,
    this._token, {
    Duration Function()? monotonicTime,
    this.onUnauthorized,
    this.storage,
    this.accountId,
  }) : _root = api.resolve('client/remote-desktop/v1/'),
       _now = monotonicTime ?? _monotonicTime();

  static Duration Function() _monotonicTime() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final http.Client _http;
  final Uri _root;
  final String _project;
  final String? Function() _token;
  final Future<void> Function(String token)? onUnauthorized;
  final AppSecureStorage? storage;
  final Future<String> Function(String token)? accountId;
  final _cipher = AesGcm.with256bits();
  final Duration Function() _now;
  final _pacing = <String, _RequestPacing>{};

  // The relay retains even completed jobs for 45 seconds and admits 32 per
  // pair. Spread watch reads out and reserve slots for sends and approvals.
  static const _retention = Duration(seconds: 45, milliseconds: 500);
  static const _watchInterval = Duration(milliseconds: 2100);
  static const _watchBudget = 26;

  Duration watchDelay([String? deviceId]) {
    final pacing = _pacing[deviceId ?? pairId];
    if (pacing == null) return Duration.zero;
    final now = _now();
    pacing.prune(now, _retention);
    final nextWatch = (pacing.lastWatch ?? -_watchInterval) + _watchInterval;
    final submissions = pacing.submissions;
    final nextSlot = submissions.length >= _watchBudget
        ? submissions.elementAt(submissions.length - _watchBudget) + _retention
        : Duration.zero;
    final next = nextWatch > nextSlot ? nextWatch : nextSlot;
    return next > now ? next - now : Duration.zero;
  }

  static final _random = Random.secure();
  static const _prefix = 'agent-remote-v1';
  final _links = <String, _DesktopLink>{};
  String? _selected;
  String? _loadedToken;
  String? _savedScope;
  Future<void> _pairUpdates = Future.value();

  Future<void> _updatePairs(Future<void> Function() update) {
    final result = _pairUpdates.then((_) => update());
    _pairUpdates = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<String> _storageKey(String token) async {
    final identity = await accountId?.call(token) ?? token;
    final digest = await Sha256().hash(utf8.encode(identity));
    return 'desktop-pairs:$_root:$_project:${base64Url.encode(digest.bytes)}';
  }

  List<DesktopDevice> get devices => [
    for (final link in _links.values)
      if (link.token == _token()) (id: link.id, name: link.name),
  ];

  Future<void> restore() async {
    final token = _token();
    if (token == null || _loadedToken == token) return;
    final scope = storage == null ? null : await _storageKey(token);
    final saved = scope == null ? null : await storage!.read(key: scope);
    if (_token() != token || _loadedToken == token) return;
    final data = saved == null ? const [] : jsonDecode(saved) as List<dynamic>;
    _links
      ..clear()
      ..addEntries(
        data.whereType<RemoteJson>().map((item) {
          final id = item['id'] as String;
          return MapEntry(id, (
            id: id,
            key: SecretKey(base64Url.decode(item['key'] as String)),
            token: token,
            name: item['name'] as String?,
          ));
        }),
      );
    _selected = _links.keys.lastOrNull;
    _loadedToken = token;
    _savedScope = scope;
  }

  Future<void> _save(String token, Map<String, _DesktopLink> links) async {
    if (storage == null) return;
    final value = jsonEncode([
      for (final link in links.values)
        {'id': link.id, 'name': link.name, 'key': base64Url.encode(await link.key.extractBytes())},
    ]);
    if (_token() != token) throw const DesktopRemoteException('ACCESS_REVOKED');
    final scope = _loadedToken == token ? _savedScope : null;
    if (scope == null) throw const DesktopRemoteException('ACCESS_REVOKED');
    await storage!.write(key: scope, value: value);
  }

  Future<bool?> online(String id) async {
    if (!devices.any((device) => device.id == id)) return false;
    try {
      return (await _call('GET', 'pairs/$id/status', _auth()))['online'] as bool?;
    } on DesktopRemoteException catch (error) {
      return error.code == 'DEVICE_UNAVAILABLE' ? false : null;
    } on Exception {
      return null;
    }
  }

  final linkChanges = StreamController<void>.broadcast();

  String? get pairId => _links[_selected]?.token == _token() ? _selected : null;
  bool get connected => pairId != null;

  void disconnect() {
    if (_links.isEmpty) return;
    _links.clear();
    _loadedToken = null;
    _savedScope = null;
    _selected = null;
    _pacing.clear();
    if (!linkChanges.isClosed) linkChanges.add(null);
  }

  Future<void> revokeDevice(String id) async {
    final link = _links[id];
    if (link == null || link.token != _token()) return;
    try {
      await _call('POST', 'pairs/${link.id}/disconnect', link.token);
    } on DesktopRemoteException catch (error) {
      if (error.code != 'DEVICE_UNAVAILABLE') rethrow;
    }
    await _updatePairs(() async {
      if (_token() != link.token) return;
      final next = Map.of(_links)..remove(id);
      await _save(link.token, next);
      if (_token() != link.token) return;
      _links.remove(id);
      _pacing.remove(id);
      if (_selected == id) _selected = _links.keys.lastOrNull;
      if (!linkChanges.isClosed) linkChanges.add(null);
    });
  }

  Future<void> revoke() async {
    if (pairId case final id?) await revokeDevice(id);
  }

  Future<void> pair(String code) async {
    final auth = _auth();
    await restore();
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
    final result = await _call('POST', 'claims', auth, {
      'fingerprint': fingerprint,
      if (storage != null) 'persistent': true,
    });
    final id = result['pairId'];
    if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
      throw const DesktopRemoteException('INVALID_RESPONSE');
    }
    final link = (id: id, key: SecretKey(bytes), token: auth, name: result['deviceName'] as String?);
    await _updatePairs(() async {
      await _save(auth, {..._links, id: link});
      if (auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
      _links[id] = link;
      _selected = id;
      if (!linkChanges.isClosed) linkChanges.add(null);
    });
  }

  Future<RemoteJson> request(String method, [RemoteJson fields = const {}, String? deviceId]) async {
    final auth = _auth();
    final link = _links[deviceId ?? pairId];
    if (link == null || link.token != auth) {
      throw const DesktopRemoteException('DEVICE_UNAVAILABLE');
    }
    final requestId = _requestId();
    final value = utf8.encode(jsonEncode({...fields, 'version': 1, 'requestId': requestId, 'method': method}));
    final requestAad = utf8.encode('$_prefix:${link.id}:$requestId:request');
    final box = await _cipher.encrypt(value, secretKey: link.key, aad: requestAad);
    final ciphertext = base64Url.encode(box.concatenation()).replaceAll('=', '');
    final path = 'pairs/${link.id}/requests';
    if (_links[link.id] != link || auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
    final submittedAt = _now();
    final pacing = _pacing.putIfAbsent(link.id, _RequestPacing.new);
    pacing.prune(submittedAt, _retention);
    pacing.submissions.addLast(submittedAt);
    if (method == 'chat/watch') pacing.lastWatch = submittedAt;
    {
      await _call('POST', path, auth, {'requestId': requestId, 'ciphertext': ciphertext});
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < const Duration(seconds: 39)) {
        if (_links[link.id] != link || auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
        final result = await _call('GET', '$path/$requestId', auth);
        final payload = result['ciphertext'];
        if (payload is String) {
          if (payload.length > 256 * 1024) throw const DesktopRemoteException('INVALID_RESPONSE');
          final packet = base64Url.decode(base64Url.normalize(payload));
          final resultBox = SecretBox.fromConcatenation(packet, nonceLength: 12, macLength: 16);
          final resultAad = utf8.encode('$_prefix:${link.id}:$requestId:result');
          final plaintext = await _cipher.decrypt(resultBox, secretKey: link.key, aad: resultAad);
          if (_links[link.id] != link || auth != _token()) throw const DesktopRemoteException('ACCESS_REVOKED');
          final data = jsonDecode(utf8.decode(plaintext));
          if (data is! RemoteJson || data['version'] != 1 || data['requestId'] != requestId) {
            throw const DesktopRemoteException('INVALID_RESPONSE');
          }
          if (data['ok'] != true) throw DesktopRemoteException(data['code'] as String? ?? 'REMOTE_ERROR');
          if (data['method'] != method) throw const DesktopRemoteException('INVALID_RESPONSE');
          return data;
        }
        if (result['online'] == false) throw const DesktopRemoteException('DESKTOP_OFFLINE');
        if (result['expired'] == true) throw const DesktopRemoteException('REQUEST_TIMEOUT');
        await Future<void>.delayed(Duration(milliseconds: method == 'chat/watch' ? 280 : 700));
      }
      throw const DesktopRemoteException('REQUEST_TIMEOUT');
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
    if (response.statusCode == 401) {
      await onUnauthorized?.call(token);
      throw const DesktopRemoteException('SIGN_IN');
    }
    if (response.statusCode == 429) throw const DesktopRemoteException('RELAY_BUSY');
    final json = jsonDecode(response.body);
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
