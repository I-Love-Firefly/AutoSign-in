import 'package:attendance_assistant/api_provider.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/enterprise_network.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.xmum.attendance_assistant/http');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Map<String, dynamic> Function(MethodCall) response;

  setUp(() {
    calls.clear();
    response = (_) => {'status': 200, 'body': 'ok'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'close' ? null : response(call);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'iOS attendance is Wi-Fi only and each account session is isolated',
    () async {
      final first = IsolatedHttpSession(useNativeIos: true);
      final second = IsolatedHttpSession(useNativeIos: true);
      final url = Uri.parse('https://acad.xmu.edu.my/mobile/');
      await first.send(url);
      await second.send(url);
      final a = calls[0].arguments as Map, b = calls[1].arguments as Map;
      expect(a['wifiOnly'], true);
      expect(a['session'], isNot(b['session']));
      await first.close();
      expect(calls.last.arguments['session'], a['session']);
      await expectLater(first.send(url), throwsA(isA<AttendanceError>()));
      await second.close();
    },
  );

  test(
    'AC timetable uses a separate session without attendance Wi-Fi requirement',
    () async {
      final session = IsolatedHttpSession(
        useNativeIos: true,
        allowedHosts: {'ac.xmu.edu.my'},
      );
      await session.send(Uri.parse('https://ac.xmu.edu.my/index.php'));
      expect(calls.single.arguments['wifiOnly'], false);
      expect(calls.single.arguments['allowedHosts'], ['ac.xmu.edu.my']);
      await session.close();
    },
  );

  test('native redirects keep HTTPS upgrade and strip POST secrets', () async {
    response = (_) => calls.where((c) => c.method == 'send').length == 1
        ? {
            'status': 302,
            'body': '',
            'location': 'http://acad.xmu.edu.my/mobile/shiro-cas',
          }
        : {'status': 200, 'body': 'done'};
    final session = IsolatedHttpSession(useNativeIos: true);
    await session.send(
      Uri.parse('https://cas.xmu.edu.my/login'),
      method: 'POST',
      body: 'fictional-password',
      headers: {'Authorization': 'fictional-token'},
    );
    expect(calls.length, 2);
    expect(
      calls[1].arguments['url'],
      'https://acad.xmu.edu.my/mobile/shiro-cas',
    );
    expect(calls[1].arguments['method'], 'GET');
    expect(calls[1].arguments['body'], null);
    expect(calls[1].arguments['headers'], isEmpty);
    await session.close();
  });

  test('POST 307 is never resent on iOS', () async {
    response = (_) => {'status': 307, 'body': '', 'location': '/retry'};
    final session = IsolatedHttpSession(useNativeIos: true);
    await expectLater(
      session.send(
        Uri.parse('https://acad.xmu.edu.my/submit'),
        method: 'POST',
        body: 'fictional',
      ),
      throwsA(isA<AttendanceError>()),
    );
    expect(calls.length, 1);
    await session.close();
  });

  test(
    'unapproved redirect destination is blocked before a second native call',
    () async {
      response = (_) => {
        'status': 302,
        'body': '',
        'location': 'https://untrusted.example/login',
      };
      final session = IsolatedHttpSession(useNativeIos: true);
      await expectLater(
        session.send(Uri.parse('https://cas.xmu.edu.my/login')),
        throwsA(isA<AttendanceError>()),
      );
      expect(calls.length, 1);
      await session.close();
    },
  );

  test('iOS requires native approval evidence even if the IP/connection is unchanged', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      confirmedEnterpriseConnection({'handle': 1}, 1, manual: false),
      false,
    );
    expect(
      confirmedEnterpriseConnection(
        {'handle': 1, 'evidence': 'ios-system-approved'},
        1,
        manual: false,
      ),
      true,
    );
    expect(
      confirmedEnterpriseConnection(
        {'handle': 1, 'evidence': 'ios-system-approved'},
        1,
        manual: true,
      ),
      false,
    );
    expect(
      confirmedEnterpriseConnection(
        {'handle': 1, 'evidence': 'ios-settings-return'},
        1,
        manual: true,
      ),
      true,
    );
  });

  test('Android still requires a new network handle', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      confirmedEnterpriseConnection(
        {'handle': 1, 'evidence': 'ios-system-approved'},
        1,
        manual: false,
      ),
      false,
    );
    expect(
      confirmedEnterpriseConnection({'handle': 2}, 1, manual: false),
      true,
    );
    expect(
      confirmedEnterpriseConnection({'handle': -1}, 1, manual: false),
      false,
    );
  });
}
