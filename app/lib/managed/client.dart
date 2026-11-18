import 'dart:convert';

import 'package:http/http.dart' as http;

import 'brand.dart';

typedef JsonObject = Map<String, dynamic>;

class ManagedApiError implements Exception {
  const ManagedApiError(this.status);
  final int status;
}

class ManagedClient {
  ManagedClient(this._http, {required this.appVersion});
  final String appVersion;
  final http.Client _http;

  Future<JsonObject> captcha() => _request('client/auth/login-captcha');

  Future<String> login(
    String username,
    String password,
    String challengeId,
    String answer,
  ) async {
    final session = await _request(
      'client/auth/login',
      body: {
        'username': username.trim(),
        'password': password,
        'challengeId': challengeId,
        'captchaAnswer': answer.trim(),
        'sourceProjectId': ManagedBrand.projectId,
        'appVersion': appVersion,
        'deviceName': 'Android',
      },
    );
    final token = session['token'];
    if (token is! String || token.isEmpty)
      throw const FormatException('Missing token');
    return token;
  }

  Future<JsonObject> account(String token) =>
      _request('client/auth/me', token: token);
  Future<JsonObject> credits(String token) =>
      _request('client/credits/me', token: token);
  Future<JsonObject> models(String token) =>
      _request('client/model/models', token: token);

  Future<JsonObject> _request(
    String route, {
    String? token,
    JsonObject? body,
  }) async {
    final request =
        http.Request(
            body == null ? 'GET' : 'POST',
            ManagedBrand.api.resolve(route),
          )
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
    final response = await _http
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw ManagedApiError(response.statusCode);
    final envelope = jsonDecode(utf8.decode(response.bodyBytes));
    if (envelope is! JsonObject ||
        envelope['success'] != true ||
        envelope['data'] is! JsonObject) {
      throw const FormatException('Invalid API response');
    }
    return envelope['data'] as JsonObject;
  }
}
