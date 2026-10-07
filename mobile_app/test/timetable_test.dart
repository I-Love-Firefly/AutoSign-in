import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/api_provider.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/timetable.dart';

const account = Account(
  'Test',
  'TEST-001',
  'attendance',
  acPassword: 'a&b + 密码',
);
const loginHtml =
    '<form id="form1" action="/index.php?c=Login&a=login" method="post"><input name="username"><input name="password"><select name="user_lb"><option value="Student">Student</option></select></form>';
String identityHtml([String id = 'TEST-001']) =>
    '<table><tr><th>Student ID.</th><td>$id</td><td></td></tr></table>';
String courseHtml({
  String semester = '202609',
  String timing = 'Tuesday 5.00pm-7.00pm(A1#105)(Week 1-14)',
  String weeks = '1-14',
}) =>
    '<select id="tm_id"><option value="$semester" selected>$semester</option></select><table><tr><th>No.</th><th>Course Code</th><th>Course Name (by group)</th><th>Time &amp; Venue</th><th>Teaching Week</th></tr><tr><td>1</td><td>SOF201</td><td>Operating Systems (Lab)</td><td>$timing</td><td>$weeks</td></tr></table>';
final now = DateTime.parse('2026-10-06T17:30:00+08:00');
StudentTimetable table([String semester = '202609']) =>
    TimetableParser.parse(courseHtml(semester: semester), 'TEST-001', now);

class FakeAcTransport implements SessionTransport {
  final calls = <({Uri uri, String method, String? body})>[];
  String identityId = 'TEST-001';
  bool rejected = false, closed = false;
  @override
  Future<HttpReply> send(
    Uri uri, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
  }) async {
    calls.add((uri: uri, method: method, body: body));
    if (uri == AcTimetableFetcher.loginPage) {
      return const HttpReply(200, loginHtml);
    }
    if (uri == AcTimetableFetcher.identity) {
      return HttpReply(200, rejected ? loginHtml : identityHtml(identityId));
    }
    if (uri == AcTimetableFetcher.courses) return HttpReply(200, courseHtml());
    return const HttpReply(200, 'ok');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeFetcher implements TimetableFetcher {
  int calls = 0;
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<StudentTimetable> fetch(
    Account a,
    void Function(String) progress,
  ) async {
    calls++;
    if (gate != null) await gate!.future;
    if (fail) throw const AttendanceError('AC_AUTH_FAILED', '测试密码错误');
    return table();
  }
}

Future<void> idle(TimetableController c) async {
  for (var i = 0; i < 20 && c.running; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(c.running, isFalse);
}

void main() {
  test('parses timetable fields, week ranges and noon correctly', () {
    final t = table();
    expect(t.semester, '202609');
    expect(t.lessons.single.venue, 'A1#105');
    expect(t.lessons.single.start, 17 * 60);
    expect(t.lessons.single.weeks.length, 14);
    final noon = TimetableParser.parse(
      courseHtml(timing: 'Monday 11.00am-1.00pm(A2#G07)(Week 1-14)'),
      'TEST-001',
      now,
    );
    expect(noon.lessons.single.start, 660);
    expect(noon.lessons.single.end, 780);
    final midnight = TimetableParser.parse(
      courseHtml(timing: 'Monday 12.00am-1.00am(A2#G07)(Week 1-14)'),
      'TEST-001',
      now,
    );
    expect(midnight.lessons.single.start, 0);
  });
  test(
    'Malaysian time and exact inclusive start/exclusive end govern reminder',
    () {
      expect(table().current(DateTime.utc(2026, 10, 6, 9)).length, 1);
      expect(table().current(DateTime.utc(2026, 10, 6, 11)), isEmpty);
      expect(table().current(DateTime.utc(2026, 10, 6, 8, 59)), isEmpty);
      expect(table().current(DateTime.utc(2026, 10, 5, 9, 30)), isEmpty);
    },
  );
  test(
    'official Sunday week anchor and teaching-week restrictions are enforced',
    () {
      expect(
        table().teachingWeek(DateTime.parse('2026-09-27T08:00:00+08:00')),
        1,
      );
      expect(table().teachingWeek(now), 2);
      final limited = TimetableParser.parse(
        courseHtml(weeks: '1', timing: 'Tuesday 5.00pm-7.00pm(A1#105)(Week 1)'),
        'TEST-001',
        now,
      );
      expect(limited.current(now), isEmpty);
      expect(
        table().current(DateTime.parse('2027-01-05T17:30:00+08:00')),
        isEmpty,
      );
      expect(table('202702').teachingWeek(now), isNull);
      expect(table('202702').current(now), isEmpty);
    },
  );
  test('multiple meetings and odd/even teaching weeks are retained', () {
    final t = TimetableParser.parse(
      courseHtml(
        timing: 'Tuesday 5.00pm-7.00pm(A1#105)(Week 1-14 Even)<br>Thursday 8.00am-10.00am(A1#109)(Week 1-14 Odd)',
      ),
      'TEST-001',
      now,
    );
    expect(t.lessons.length, 2);
    expect(t.lessons.first.weeks, [2, 4, 6, 8, 10, 12, 14]);
    expect(t.lessons.last.weeks, [1, 3, 5, 7, 9, 11, 13]);
  });
  test(
    'malformed or partially understood timetable is never silently accepted',
    () {
      for (final timing in [
        'Tuesday 5.00pm-4.00pm(A1#105)(Week 1-14)',
        'Tuesday unknown',
        'Tuesday 5.00pm-7.00pm(A1#105)(Week 1-14) unexpected',
      ]) {
        expect(
          () => TimetableParser.parse(
            courseHtml(timing: timing),
            'TEST-001',
            now,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('native login contract encodes secrets only in body and logs out own session', () async {
    final transport = FakeAcTransport();
    final fetcher = AcTimetableFetcher(
      createTransport: () => transport,
      clock: () => now,
    );
    final result = await fetcher.fetch(account, (_) {});
    final call = transport.calls.singleWhere(
      (c) => c.uri == AcTimetableFetcher.login,
    );
    expect(call.method, 'POST');
    expect(Uri.splitQueryString(call.body!), {
      'username': account.campusId,
      'password': account.acPassword,
      'user_lb': 'Student',
    });
    expect(call.uri.queryParameters, {'c': 'Login', 'a': 'login'});
    expect(result.campusId, account.campusId);
    expect(transport.calls.last.uri, AcTimetableFetcher.logout);
    expect(transport.closed, isTrue);
  });
  test(
    'wrong identity or rejected login does not read another student timetable',
    () async {
      for (final rejected in [false, true]) {
        final transport = FakeAcTransport()
          ..identityId = 'OTHER'
          ..rejected = rejected;
        await expectLater(
          AcTimetableFetcher(createTransport: () => transport)
              .fetch(account, (_) {}),
          throwsA(isA<AttendanceError>()),
        );
        expect(
          transport.calls.where((c) => c.uri == AcTimetableFetcher.courses),
          isEmpty,
        );
        expect(transport.closed, isTrue);
      }
    },
  );
  test(
    'AC session cannot send cookies or body to CAS or arbitrary hosts',
    () async {
      final session = IsolatedHttpSession(
        allowedHosts: const {'ac.xmu.edu.my'},
      );
      for (final url in [
        'https://cas.xmu.edu.my/',
        'https://evil.example/',
        'http://ac.xmu.edu.my/',
      ]) {
        await expectLater(
          session.send(Uri.parse(url)),
          throwsA(isA<AttendanceError>()),
        );
      }
      await session.close();
    },
  );
  test(
    'cache persists and survives restart without a network request',
    () async {
      final store = MemoryTimetableStore(), fetcher = FakeFetcher();
      final c = TimetableController(store: store, fetcher: fetcher);
      await c.initialize([account]);
      await idle(c);
      expect(store.schedules['test-001']!.current(now).length, 1);
      final roundTrip = StudentTimetable.fromJson(table().toJson());
      expect(roundTrip.current(now).single.venue, 'A1#105');
      c.dispose();
      final next = TimetableController(store: store, fetcher: fetcher);
      await next.initialize([account]);
      await idle(next);
      expect(fetcher.calls, 1);
      expect(next.schedules['test-001']!.lessons.length, 1);
      next.dispose();
    },
  );
  test('password edit refreshes; failure retains previous cache; delete removes cache', () async {
    final store = MemoryTimetableStore(), fetcher = FakeFetcher();
    final c = TimetableController(store: store, fetcher: fetcher);
    await c.initialize([account]);
    await idle(c);
    fetcher.fail = true;
    c.updateAccounts([
      const Account('Test', 'TEST-001', 'attendance', acPassword: 'changed'),
    ]);
    await idle(c);
    expect(fetcher.calls, 2);
    expect(c.errors['test-001'], '测试密码错误');
    expect(c.schedules['test-001']!.lessons.length, 1);
    c.updateAccounts([]);
    await Future<void>.delayed(Duration.zero);
    expect(c.schedules, isEmpty);
    expect(store.schedules, isEmpty);
    c.dispose();
  });
  test(
    'removed account cannot be recreated by an in-flight response',
    () async {
      final fetcher = FakeFetcher()..gate = Completer<void>();
      final c = TimetableController(
        store: MemoryTimetableStore(),
        fetcher: fetcher,
      );
      await c.initialize([account]);
      c.updateAccounts([]);
      fetcher.gate!.complete();
      await idle(c);
      expect(c.schedules, isEmpty);
      c.dispose();
    },
  );
}
