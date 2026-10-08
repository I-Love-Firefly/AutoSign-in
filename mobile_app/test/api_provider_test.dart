import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/api_provider.dart';
import 'package:attendance_assistant/domain.dart';

import 'domain_test.dart' show course, now, account;

class Call {
  final Uri uri;
  final String method;
  final String? body;
  final Map<String, String> headers;
  Call(this.uri, this.method, this.body, this.headers);
}

class ScriptedTransport implements SessionTransport {
  final calls = <Call>[];
  bool closed = false, needsCaptcha = false, signed = false;
  dynamic acknowledgement = true;
  String? rejection;
  int? syncHttpStatus;
  int pendingReads = 0;
  @override
  Future<HttpReply> send(
    Uri uri, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
  }) async {
    calls.add(Call(uri, method, body, Map.of(headers)));
    dynamic data;
    if (uri.path.endsWith('/login') || uri.path.endsWith('/shiro-cas')) {
      return const HttpReply(200, '<html>ok</html>');
    }
    if (uri.path.endsWith('/login-user/sync-list') && syncHttpStatus != null) {
      return HttpReply(syncHttpStatus!, '{}');
    }
    if (uri.path.endsWith('/loginType')) {
      data = {'isVerifyCode': needsCaptcha ? '1' : '0', 'isTwoVerify': '0'};
    } else if (uri.path.endsWith('/v1/tickets')) {
      return HttpReply(
        201,
        jsonEncode({
          'ticket': 'ST-fake-test-ticket',
          'tgt': 'TGT-fake-test-session',
        }),
      );
    } else if (uri.path.endsWith('/tryLoginUserInfo')) {
      data = {
        'userId': 'fake-student',
        'tokenId': 'fake-token',
        'orgId': 'fake-org',
      };
    } else if (uri.path.endsWith('/selectCurrentXnXq')) {
      data = {'semester': '2026/09'};
    } else if (uri.path.endsWith('/query/opt')) {
      final recordSigned = signed && pendingReads-- <= 0;
      data = {
        'records': [
          course({'attendanceStatus': recordSigned ? '1' : '0'}).data,
        ],
        'total': 1,
      };
    } else if (uri.path.endsWith('/updateStuAttendance')) {
      if (rejection != null) {
        return HttpReply(
          200,
          jsonEncode({
            'meta': {'success': false, 'statusCode': 500, 'message': rejection},
          }),
        );
      }
      data = acknowledgement;
      signed = true;
    } else {
      data = true;
    }
    return HttpReply(
      200,
      jsonEncode({
        'meta': {'success': true, 'statusCode': 200},
        'data': data,
      }),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test(
    'verification waits before first read and tolerates delayed records',
    () async {
      final t = ScriptedTransport();
      final gate = Completer<void>();
      final waits = <Duration>[];
      final p = ApiAttendanceProvider(
        transport: t,
        clock: () => now,
        wait: (duration) {
          waits.add(duration);
          return gate.future;
        },
      );
      await p.login(account, (_) {});
      await p.submit(course(), '1234');
      t.pendingReads = 2;
      final before = t.calls.length;
      final result = p.verify(course());
      expect(t.calls.length, before);
      expect(waits, [const Duration(seconds: 5)]);
      gate.complete();
      expect(await result, isTrue);
      expect(waits, List.filled(3, const Duration(seconds: 5)));
      expect(t.calls.where((c) => c.uri.path.endsWith('/query/opt')).length, 3);
      expect(
        t.calls
            .where((c) => c.uri.path.endsWith('/updateStuAttendance'))
            .length,
        1,
      );
      await p.close();
    },
  );
  test(
    'unpropagated record stops after five reads without resubmitting',
    () async {
      final t = ScriptedTransport();
      final waits = <Duration>[];
      final p = ApiAttendanceProvider(
        transport: t,
        clock: () => now,
        wait: (duration) async {
          waits.add(duration);
        },
      );
      await p.login(account, (_) {});
      await p.submit(course(), '1234');
      t.pendingReads = 10;
      expect(await p.verify(course()), isFalse);
      expect(waits, List.filled(5, const Duration(seconds: 5)));
      expect(t.calls.where((c) => c.uri.path.endsWith('/query/opt')).length, 5);
      expect(
        t.calls
            .where((c) => c.uri.path.endsWith('/updateStuAttendance'))
            .length,
        1,
      );
      await p.close();
    },
  );
  test('network attendance omits quickResponse and verifies record', () async {
    final t = ScriptedTransport();
    final p = ApiAttendanceProvider(transport: t, clock: () => now);
    await p.login(account, (_) {});
    await p.submit(course({'attendanceMethod': '1'}), '');
    final mutation = t.calls.last;
    expect(mutation.uri.path, endsWith('/updateStuAttendance'));
    final payload = jsonDecode(mutation.body!) as Map;
    expect(payload.containsKey('quickResponse'), isFalse);
    expect(payload['studentId'], 'fake-student');
    expect(payload['attendanceStatus'], '1');
    expect(await p.verify(course({'attendanceMethod': '1'})), isTrue);
    await p.close();
  });
  test('provider blocks empty code for a code-required course', () async {
    final t = ScriptedTransport();
    final p = ApiAttendanceProvider(transport: t, clock: () => now);
    await p.login(account, (_) {});
    await expectLater(
      p.submit(course(), ''),
      throwsA(
        isA<AttendanceError>().having((e) => e.code, 'code', 'CODE_REQUIRED'),
      ),
    );
    expect(
      t.calls.where((c) => c.uri.path.endsWith('/updateStuAttendance')),
      isEmpty,
    );
    await p.close();
  });
  final vectors = jsonDecode(
    File('test/fixtures/rsa-vectors.json').readAsStringSync(),
  ) as List;
  for (var i = 0; i < vectors.length; i++) {
    test('CAS RSA matches original browser module vector $i', () {
      expect(encryptCasPassword(vectors[i]['input']), vectors[i]['expected']);
    });
  }
  test('only HTTPS school origins allowed', () {
    for (final uri in [
      'http://acad.xmu.edu.my/mobile/',
      'https://evil.example/',
      'https://acad.xmu.edu.my.evil.example/',
      'https://x@acad.xmu.edu.my/',
      'https://acad.xmu.edu.my:444/',
    ]) {
      expect(IsolatedHttpSession.allowed(Uri.parse(uri)), isFalse);
    }
    expect(
      IsolatedHttpSession.allowed(
        Uri.parse('https://cas.xmu.edu.my/lyuapServer/login'),
      ),
      isTrue,
    );
  });
  test('redirect diagnostic identifies host without exposing ticket query', () {
    final reason = IsolatedHttpSession.blockedAddressReason(
      Uri.parse('https://sso.example.edu/path?ticket=ST-sensitive-test'),
    );
    expect(reason, contains('sso.example.edu'));
    expect(reason, isNot(contains('ST-sensitive-test')));
    expect(
      IsolatedHttpSession.blockedAddressReason(
        Uri.parse('http://other.example/mobile?ticket=ST-hidden'),
      ),
      contains('非 HTTPS'),
    );
    expect(
      IsolatedHttpSession.blockedAddressReason(
        Uri.parse('http://other.example/mobile?ticket=ST-hidden'),
      ),
      isNot(contains('ST-hidden')),
    );
  });
  test(
    'school HTTP callback is upgraded without allowing other HTTP targets',
    () {
      final upgraded = IsolatedHttpSession.secureRedirectTarget(
        Uri.parse('http://acad.xmu.edu.my/mobile/?ticket=ST-test'),
      );
      expect(upgraded.scheme, 'https');
      expect(upgraded.host, 'acad.xmu.edu.my');
      expect(upgraded.queryParameters['ticket'], 'ST-test');
      expect(IsolatedHttpSession.allowed(upgraded), isTrue);
      for (final target in [
        'http://other.example/mobile/',
        'http://acad.xmu.edu.my:8080/mobile/',
        'http://user@acad.xmu.edu.my/mobile/',
        'http://acad.xmu.edu.my.evil.example/mobile/',
      ]) {
        expect(
          IsolatedHttpSession.allowed(
            IsolatedHttpSession.secureRedirectTarget(Uri.parse(target)),
          ),
          isFalse,
        );
      }
    },
  );
  test(
    'real provider constructs observed contract and confirms state',
    () async {
      final t = ScriptedTransport();
      final p = ApiAttendanceProvider(transport: t, clock: () => now);
      await p.login(account, (_) {});
      final auth = t.calls.singleWhere(
        (c) => c.uri.path.endsWith('/v1/tickets'),
      );
      final form = Uri.splitQueryString(auth.body!);
      expect(form['username'], account.campusId);
      expect(form['password'], isNot(account.password));
      expect(form['service'], ApiAttendanceProvider.service);
      final classes = await p.courses();
      final query = t.calls.last;
      expect(query.method, 'POST');
      expect(query.headers['Content-Type'], 'application/json;charset=utf-8');
      expect(
        query.uri.path,
        '/mobile/api/jwxt-ktkq/mobile/attendanceStudent/query/opt',
      );
      expect(jsonDecode(query.body!)['param'], {
        'arrangeDate': '2026-10-05',
        'semesterId': '2026/09',
      });
      expect(query.headers['Authorization'], 'fake-token');
      await p.submit(classes.single, '1234');
      final mutation = t.calls.last;
      final payload = jsonDecode(mutation.body!);
      expect(payload['studentId'], 'fake-student');
      expect(payload['quickResponse'], '1234');
      expect(payload['settingId'], 'session-1');
      expect(await p.verify(classes.single), isTrue);
      await p.close();
      expect(t.closed, isTrue);
      expect(
        t.calls
            .where((c) => c.uri.path.endsWith('/updateStuAttendance'))
            .length,
        1,
      );
      expect(t.calls.where((c) => c.uri.path.endsWith('/uniLogout')).length, 1);
      await expectLater(p.courses(), throwsA(isA<AttendanceError>()));
    },
  );
  test(
    'optional sync rejection warns while required course query still runs',
    () async {
      final t = ScriptedTransport()..syncHttpStatus = 400;
      final p = ApiAttendanceProvider(transport: t, clock: () => now);
      final stages = <Stage>[];
      await p.login(account, stages.add);
      expect(stages, contains(Stage.syncWarning));
      expect(stages.last, Stage.semester);
      expect((await p.courses()).length, 1);
      expect(t.calls.any((c) => c.uri.path.endsWith('/query/opt')), isTrue);
      expect(
        t.calls.any((c) => c.uri.path.endsWith('/updateStuAttendance')),
        isFalse,
      );
      await p.close();
    },
  );
  test('CAS challenge stops before credentials are sent', () async {
    final t = ScriptedTransport()..needsCaptcha = true;
    final p = ApiAttendanceProvider(transport: t);
    await expectLater(
      p.login(account, (_) {}),
      throwsA(
        isA<AttendanceError>().having(
          (e) => e.code,
          'code',
          'INTERACTION_REQUIRED',
        ),
      ),
    );
    expect(t.calls.any((c) => c.uri.path.endsWith('/v1/tickets')), isFalse);
    await p.close();
  });
  test('truthy nonboolean acknowledgement is not success', () async {
    final t = ScriptedTransport()..acknowledgement = 'true';
    final p = ApiAttendanceProvider(transport: t, clock: () => now);
    await p.login(account, (_) {});
    await expectLater(
      p.submit(course(), '1234'),
      throwsA(isA<AttendanceError>()),
    );
    await p.close();
  });
  test(
    'server rejection redacts known password token and attendance code',
    () async {
      final t = ScriptedTransport()
        ..rejection = 'Invalid 1234 fake-token not-a-real-password';
      final p = ApiAttendanceProvider(transport: t, clock: () => now);
      await p.login(account, (_) {});
      try {
        await p.submit(course(), '1234');
        fail('must reject');
      } on AttendanceError catch (e) {
        expect(e.message, isNot(contains('1234')));
        expect(e.message, isNot(contains('fake-token')));
        expect(e.message, isNot(contains(account.password)));
      }
      await p.close();
    },
  );
  test('malformed nonJSON response fails closed', () {
    expect(
      () => const HttpReply(200, '<html>login</html>').json,
      throwsA(isA<AttendanceError>()),
    );
  });
}
