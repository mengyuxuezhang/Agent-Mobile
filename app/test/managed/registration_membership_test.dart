import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/managed/account_page.dart';
import 'package:dsh_app/managed/client.dart';
import 'package:dsh_app/managed/membership_page.dart';
import 'package:dsh_app/managed/registration_page.dart';
import 'package:dsh_app/managed/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ManagedFixture extends ManagedClient {
  _ManagedFixture() : super(MockClient((_) async => http.Response('', 500)), appVersion: '0.1.0');

  ({String username, String email})? verificationRequest;
  String? registrationCode;
  int catalogReads = 0;
  int challenges = 0;
  int loginAttempts = 0;

  @override
  Future<JsonObject> captcha() async {
    challenges++;
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="36"><rect width="100" height="36"/></svg>';
    return {
      'challengeId': 'challenge-$challenges',
      'imageDataUrl': 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}',
    };
  }

  @override
  Future<String> login(String username, String password, String challengeId, String answer) async {
    expect(username, 'fixture.user');
    expect(password, 'test-password');
    expect(challengeId, 'challenge-$challenges');
    expect(answer, 'ABCDE');
    if (++loginAttempts == 1) throw const ManagedApiError(400, '验证码不正确或已失效，请刷新后重试');
    return 'fixture-session';
  }

  @override
  Future<void> requestRegistrationCode({required String username, required String email}) async {
    verificationRequest = (username: username, email: email);
  }

  @override
  Future<String> register({
    required String username,
    required String email,
    required String password,
    required String code,
  }) async {
    registrationCode = code;
    return 'fixture-session';
  }

  @override
  Future<JsonObject> account(String token) async => {
    'user': {
      'id': 'fixture-user',
      'membership': {'cardName': catalogReads > 1 ? '新会员' : '体验会员'},
    },
  };

  @override
  Future<JsonObject> membershipStore(String token) async {
    catalogReads++;
    return {
      'userId': 'fixture-user',
      'cards': [
        {
          'name': '试用套餐',
          'description': '品牌后台仅维护中文',
          'package': {'price': 19.9, 'durationDays': 30},
        },
      ],
      'paymentMethods': [
        {'provider': 'alipay', 'mode': 'page'},
      ],
    };
  }
}

class _LoginSession extends ManagedSession {
  final _api = _ManagedFixture();

  @override
  _ManagedFixture get client => _api;
}

Widget _app(Widget home) => MaterialApp(
  locale: AppLocale.zhCN,
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: AppLocale.supported,
  home: home,
);

void main() {
  testWidgets('login refreshes an expired challenge and completes without a model setup step', (tester) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _LoginSession();
    addTearDown(session.dispose);
    bool? finished;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [managedSessionProvider.overrideWithValue(session)],
        child: _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  finished = await Navigator.of(context)
                      .push<bool>(MaterialPageRoute(builder: (_) => const ManagedAccountPage(finishOnSignIn: true)));
                },
                child: const Text('打开登录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开登录'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    final submit = find.widgetWithText(FilledButton, '登录');
    await tester.enterText(fields.at(0), 'fixture.user');
    await tester.enterText(fields.at(1), 'test-password');
    await tester.enterText(fields.at(2), 'ABCDE');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(session.client.challenges, 2);
    expect(find.text('验证码错误或已失效，请输入新的验证码。'), findsOneWidget);
    await tester.enterText(fields.at(2), 'ABCDE');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(session.signedIn.value, isTrue);
  });

  testWidgets('registration verifies the current email and returns the shared account session', (tester) async {
    final client = _ManagedFixture();
    String? session;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                session = await Navigator.of(context)
                    .push<String>(MaterialPageRoute(builder: (_) => ManagedRegistrationPage(client: client)));
              },
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'fixture.user');
    await tester.enterText(fields.at(1), 'fixture@example.test');
    await tester.tap(find.text('发送邮箱验证码'));
    await tester.pumpAndSettle();
    expect(client.verificationRequest, (username: 'fixture.user', email: 'fixture@example.test'));
    await tester.enterText(fields.at(2), '123456');
    await tester.enterText(fields.at(3), 'test-password');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '注册账号'));
    await tester.tap(find.widgetWithText(FilledButton, '注册账号'));
    await tester.pumpAndSettle();
    expect(client.registrationCode, '123456');
    expect(session, 'fixture-session');
  });

  testWidgets('membership shows backend text and refreshes after desktop payment', (tester) async {
    final client = _ManagedFixture();
    await tester.pumpWidget(
      _app(ManagedMembershipPage(client: client, token: 'fixture-session', userId: 'fixture-user')),
    );
    await tester.pumpAndSettle();
    expect(find.text('会员：体验会员'), findsOneWidget);
    expect(find.text('品牌后台仅维护中文\n有效期 30 天'), findsOneWidget);
    expect(find.textContaining('电脑端使用同一账号'), findsOneWidget);
    await tester.tap(find.text('刷新权益'));
    await tester.pumpAndSettle();
    expect(find.text('会员：新会员'), findsOneWidget);
  });
}
