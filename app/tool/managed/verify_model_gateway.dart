import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dsh_app/managed/model_gateway.dart';

Future<void> main() async {
  var upstreamCalls = 0;
  var settleRequests = <String>{};
  const streamed =
      'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
      'data: {"choices":[],"usage":{"total_tokens":3}}\n\n'
      'data: [DONE]\n\n';
  final transport = MockClient((request) async {
    upstreamCalls++;
    expect(request.url.host == 'example.invalid', 'model service origin');
    expect(!request.followRedirects, 'redirect disabled');
    expect(request.headers['authorization'] == 'Bearer mock-account-session', 'upstream user token');
    expect(request.headers['x-agent-project-id'] == 'sample-brand', 'same brand');
    final id = request.headers['x-request-id'];
    expect(id != null && settleRequests.add(id), 'unique billing request id');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['model'] == 'no-credits') {
      return http.Response(
        '{"error":{"message":"insufficient credits"}}',
        402,
        headers: {'content-type': 'application/json', 'x-agent-error-code': 'ADMIN_CREDITS_EXHAUSTED'},
      );
    }
    expect(body['stream'] == true && (body['tools'] as List).length == 1, 'original engine payload');
    return http.Response(streamed, 200, headers: {'content-type': 'text/event-stream'});
  });
  final gateway = ManagedModelGateway(
    transport,
    endpoint: Uri.https('example.invalid', '/api/client/model/v1/chat/completions'),
    projectId: 'sample-brand',
    token: 'mock-account-session',
    allowedModels: {'available', 'no-credits'},
  );
  final base = await gateway.start();
  final client = http.Client();
  Future<http.Response> chat(String model, {String? key}) => client.post(
    base.replace(path: '${base.path}/chat/completions'),
    headers: {'authorization': 'Bearer ${key ?? gateway.key}', 'content-type': 'application/json'},
    body: jsonEncode({
      'model': model,
      'stream': true,
      'tools': [
        {'type': 'function'},
      ],
    }),
  );
  try {
    expect((await chat('available', key: 'invalid')).statusCode == 401, 'anonymous request rejected');
    expect((await chat('other')).statusCode == 403, 'unlisted model rejected');
    expect(upstreamCalls == 0, 'local rejection cannot incur billing');
    final result = await chat('available');
    expect(result.statusCode == 200 && result.body == streamed, 'SSE, usage and completion forwarded');
    final rejected = await chat('no-credits');
    expect(
      rejected.statusCode == 402 && rejected.headers['x-agent-error-code'] == 'ADMIN_CREDITS_EXHAUSTED',
      'billing refusal forwarded',
    );
    expect(upstreamCalls == 2, 'each request forwarded once');
  } finally {
    client.close();
    await gateway.close();
  }
}

void expect(bool condition, String context) {
  if (!condition) throw StateError(context);
}
