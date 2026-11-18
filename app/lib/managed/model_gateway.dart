import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

String managedRandomId() => base64UrlEncode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

final _random = Random.secure();

/// One local engine lease. The engine only receives a temporary local key.
class ManagedModelGateway {
  ManagedModelGateway(
    this._transport, {
    required this.endpoint,
    required this.projectId,
    required this.token,
    required this.allowedModels,
  });

  final Uri endpoint;
  final String projectId;
  final String token;
  final Set<String> allowedModels;
  final http.Client _transport;
  final key = managedRandomId();
  HttpServer? _server;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_forward(request)));
    return Uri.parse('http://127.0.0.1:${server.port}/v1');
  }

  Future<void> close() async {
    _transport.close();
    await _server?.close(force: true);
  }

  Future<void> _forward(HttpRequest request) async {
    final output = request.response;
    var started = false;
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(output.done.then<void>((_) => cancel(), onError: (Object _) => cancel()));
    try {
      if (request.method != 'POST' || request.uri.path != '/v1/chat/completions') {
        return await _error(output, 404, 'Unsupported model endpoint');
      }
      if (!_matchesKey(request.headers.value(HttpHeaders.authorizationHeader))) {
        return await _error(output, 401, 'Reconnect the YushuHub model service');
      }
      const limit = 20 * 1024 * 1024;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in request.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > limit) {
          return await _error(output, 413, 'Model request is too large');
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final json = jsonDecode(utf8.decode(body));
      if (json is! Map<String, dynamic> || json['model'] is! String) {
        return await _error(output, 400, 'Invalid model request');
      }
      if (!allowedModels.contains(json['model'])) {
        return await _error(output, 403, 'Model is unavailable for this account');
      }

      final upstream = http.AbortableRequest('POST', endpoint, abortTrigger: abort.future)
        ..followRedirects = false
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
          'accept': 'text/event-stream, application/json',
          'x-agent-project-id': projectId,
          'x-request-id': managedRandomId(),
        })
        ..bodyBytes = body;
      final response = await _transport.send(upstream).timeout(const Duration(minutes: 3));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        return await _error(output, 502, 'Unexpected model service redirect');
      }
      final contentType = response.headers['content-type'];
      final mime = contentType?.split(';').first.trim().toLowerCase();
      if (mime != 'application/json' && mime != 'text/event-stream') {
        return await _error(output, 502, 'Unexpected model service response');
      }
      output
        ..statusCode = response.statusCode
        ..bufferOutput = false
        ..headers.set(HttpHeaders.contentTypeHeader, contentType!)
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      for (final name in ['x-request-id', 'x-agent-error-code', 'retry-after']) {
        final value = response.headers[name];
        if (value != null) output.headers.set(name, value);
      }
      // Preserve the SSE and usage frames so DSH handles completion and the
      // same server request owns the usage settlement.
      started = true;
      await output.addStream(response.stream.timeout(const Duration(minutes: 3)));
      await output.close();
    } on FormatException {
      if (!started) await _error(output, 400, 'Invalid request body');
      if (started) await _disconnect(output);
    } on TimeoutException {
      if (!started) await _error(output, 504, 'Model service timed out');
      if (started) await _disconnect(output);
    } catch (_) {
      if (started) {
        await _disconnect(output);
      } else {
        try {
          await _error(output, 502, 'Model service unavailable');
        } catch (_) {
          // The engine may already have closed its connection.
        }
      }
    } finally {
      cancel();
    }
  }

  bool _matchesKey(String? header) {
    final expected = 'Bearer $key';
    if (header == null || header.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= header.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }
}

Future<void> _disconnect(HttpResponse response) async {
  try {
    final socket = await response.detachSocket(writeHeaders: false);
    socket.destroy();
  } catch (_) {
    // It is already closed.
  }
}

Future<void> _error(HttpResponse response, int status, String message) async {
  response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(
      jsonEncode({
        'error': {'message': message},
      }),
    );
  try {
    await response.close();
  } catch (_) {
    // Client disconnected.
  }
}
