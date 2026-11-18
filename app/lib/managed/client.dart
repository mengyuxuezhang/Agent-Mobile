import 'dart:convert';

import 'package:http/http.dart' as http;

import 'brand.dart';

typedef JsonObject = Map<String, dynamic>;

class ManagedApiError implements Exception {
  const ManagedApiError(this.status, [this.message]);
  final int status;
  final String? message;
}

class ManagedClient {
  ManagedClient(this._http, {required this.appVersion});
  final String appVersion;
  final http.Client _http;

  Future<JsonObject> captcha() => _request('client/auth/login-captcha');

  JsonObject get _source => {
    'sourceProjectId': ManagedBrand.projectId,
    'appVersion': appVersion,
    'deviceName': 'Android',
  };

  Future<void> requestRegistrationCode({required String username, required String email}) async {
    await _request(
      'client/auth/registration-code/request',
      body: {'username': username, 'email': email, 'channel': 'email', ..._source},
    );
  }

  Future<String> register({
    required String username,
    required String email,
    required String password,
    required String code,
  }) async {
    final session = await _request(
      'client/auth/register',
      body: {
        'username': username,
        'email': email,
        'password': password,
        'verificationCode': code,
        'code': code,
        ..._source,
      },
    );
    return _sessionToken(session);
  }

  Future<String> login(String username, String password, String challengeId, String answer) async {
    final session = await _request(
      'client/auth/login',
      body: {
        'username': username.trim(),
        'password': password,
        'challengeId': challengeId,
        'captchaAnswer': answer.trim(),
        ..._source,
      },
    );
    return _sessionToken(session);
  }

  String _sessionToken(JsonObject session) {
    final token = session['token'];
    if (token is! String || token.isEmpty) throw const FormatException('Missing token');
    return token;
  }

  Future<JsonObject> account(String token) => _request('client/auth/me', token: token);
  Future<JsonObject> credits(String token) => _request('client/credits/me', token: token);
  Future<JsonObject> models(String token) => _request('client/model/models', token: token);
  Future<JsonObject> membershipStore(String token) => _request('client/membership-store', token: token);

  Future<JsonObject> ledger(String token) => _request('client/credits/ledger?page=1&pageSize=5', token: token);

  Future<JsonObject> _request(String route, {String? token, JsonObject? body}) async {
    final request = http.Request(body == null ? 'GET' : 'POST', ManagedBrand.api.resolve(route))
      ..followRedirects = false
      ..headers['accept'] = 'application/json';
    if (token != null) {
      request.headers['authorization'] = 'Bearer $token';
      request.headers['x-agent-project-id'] = ManagedBrand.projectId;
    }
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _http.send(request).then(http.Response.fromStream).timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      if (response.bodyBytes.length <= 8192) {
        try {
          final error = jsonDecode(utf8.decode(response.bodyBytes));
          if (error is JsonObject && error['error'] is String) message = error['error'] as String;
        } on FormatException {
          // Upstream proxies can return a non-JSON error document.
        }
      }
      throw ManagedApiError(response.statusCode, message);
    }
    final envelope = jsonDecode(utf8.decode(response.bodyBytes));
    if (envelope is! JsonObject || envelope['success'] != true || envelope['data'] is! JsonObject) {
      throw const FormatException('Invalid API response');
    }
    return envelope['data'] as JsonObject;
  }
}
