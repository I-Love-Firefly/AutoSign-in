import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/domain.dart';

final now = DateTime.parse('2026-10-05T14:30:00+08:00');
Course course([Map<String, dynamic> overrides = const {}]) => Course({
  'settingId': 'session-1',
  'courseCode': 'SOF202',
  'openGroupName': 'Database',
  'arrangeDate': '2026-10-05',
  'startClassTime': '14:00:00',
  'endClassTime': '16:00:00',
  'backGroundColor': '1',
  'attendanceStatus': '0',
  'studentOtherStatus': null,
  'attendanceMethod': '0',
  ...overrides,
});

class FakeProvider implements AttendanceProvider {
  List<Course> list = [course()];
  List<Course>? second;
  int calls = 0, submissions = 0, closes = 0;
  String? submittedCode;
  bool confirmed = true;
  Object? loginError, submitError, verifyError;
  Completer<void>? gate;
  @override
  Future<void> login(Account a, void Function(Stage) p) async {
    if (gate != null) {
      await gate!.future;
    }
    if (loginError != null) {
      throw loginError!;
    }
  }

  @override
  Future<List<Course>> courses() async =>
      ++calls > 1 && second != null ? second! : list;
  @override
  Future<void> submit(Course c, String code) async {
    submissions++;
    submittedCode = code;
    if (submitError != null) {
      throw submitError!;
    }
  }

  @override
  Future<bool> verify(Course c) async {
    if (verifyError != null) {
      throw verifyError!;
    }
    return confirmed;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

const account = Account('Test', 'TEST-001', 'not-a-real-password');
Future<RunResult> run(
  FakeProvider p, {
  String code = '1234',
  Future<Course?> Function(List<Course>)? choose,
  bool inspect = false,
}) => AttendanceOrchestrator(() => p, clock: () => now).run(
  account,
  code,
  progress: (_) {},
  choose: choose ?? (c) async => c.first,
  inspectOnly: inspect,
);
void main() {
  test('eligible only during Malaysian class window', () {
    expect(course().eligible(now), isTrue);
    expect(
      course().eligible(DateTime.parse('2026-10-05T13:59:59+08:00')),
      isFalse,
    );
    expect(
      course().eligible(DateTime.parse('2026-10-05T16:00:00+08:00')),
      isFalse,
    );
  });
  for (final entry in <String, dynamic>{
    'attendanceStatus': null,
    'backGroundColor': '2',
    'teacherMarkedAbsentLocked': true,
    'studentOtherStatus': '3',
    'studentCourseSign': '2',
    'settingId': '',
    'startClassTime': 'bad',
  }.entries) {
    test(
      'reject invalid ${entry.key}',
      () => expect(course({entry.key: entry.value}).eligible(now), isFalse),
    );
  }
  test(
    'already signed excluded',
    () => expect(course({'attendanceStatus': '1'}).eligible(now), isFalse),
  );
  test('single course submits once and verifies', () async {
    final p = FakeProvider();
    final r = await run(p);
    expect(r.code, 'SUCCESS');
    expect(p.submissions, 1);
    expect(p.closes, 1);
  });
  test('empty course list never submits', () async {
    final p = FakeProvider()..list = [];
    expect((await run(p)).code, 'NO_ACTIVE_CLASS');
    expect(p.submissions, 0);
    expect(p.closes, 1);
  });
  test('multiple courses must ask, cancellation does not submit', () async {
    final p = FakeProvider()
      ..list = [
        course(),
        course({'settingId': 'session-2'}),
      ];
    var asked = false;
    final r = await run(
      p,
      choose: (c) async {
        asked = true;
        return null;
      },
    );
    expect(asked, isTrue);
    expect(r.code, 'CANCELLED');
    expect(p.submissions, 0);
  });
  test('changed state before submit prevents mutation', () async {
    final p = FakeProvider()
      ..second = [
        course({'attendanceStatus': '1'}),
      ];
    expect((await run(p)).code, 'CLASS_CHANGED');
    expect(p.submissions, 0);
  });
  test('network attendance submits without a code', () async {
    final p = FakeProvider()
      ..list = [
        course({'attendanceMethod': '1'}),
      ];
    expect((await run(p, code: '')).code, 'SUCCESS');
    expect(p.submissions, 1);
    expect(p.submittedCode, '');
    expect(p.closes, 1);
  });
  test('network attendance ignores code from a previous class', () async {
    final p = FakeProvider()
      ..list = [
        course({'attendanceMethod': '1'}),
      ];
    expect((await run(p)).code, 'SUCCESS');
    expect(p.submittedCode, '');
  });
  test(
    'code-required class stops before submission if code is empty',
    () async {
      final p = FakeProvider();
      expect((await run(p, code: '')).code, 'CODE_REQUIRED');
      expect(p.submissions, 0);
      expect(p.closes, 1);
    },
  );
  test('fresh course method governs whether code is required', () async {
    final p = FakeProvider()
      ..list = [
        course({'attendanceMethod': '1'}),
      ]
      ..second = [course()];
    expect((await run(p, code: '')).code, 'CODE_REQUIRED');
    expect(p.submissions, 0);
  });
  test('invalid code never authenticates', () async {
    final p = FakeProvider();
    expect((await run(p, code: '12a4')).code, 'INVALID_CODE');
    expect(p.calls, 0);
  });
  test('login failure cleans session', () async {
    final p = FakeProvider()
      ..loginError = const AttendanceError('AUTH_FAILED', 'failure');
    expect((await run(p)).code, 'AUTH_FAILED');
    expect(p.closes, 1);
  });
  test('submit timeout unknown and no retry', () async {
    final p = FakeProvider()
      ..submitError = const AttendanceError('NETWORK_ERROR', 'timeout');
    expect((await run(p)).code, 'UNKNOWN');
    expect(p.submissions, 1);
    expect(p.closes, 1);
  });
  test('explicit rejection never succeeds', () async {
    final p = FakeProvider()
      ..submitError = const AttendanceError('SERVER_REJECTED', 'Invalid code');
    expect((await run(p)).code, 'SERVER_REJECTED');
    expect(p.submissions, 1);
  });
  test('acknowledged but unverified not success', () async {
    final p = FakeProvider()..confirmed = false;
    expect((await run(p)).code, 'UNKNOWN');
  });
  test('verification auth failure result unknown', () async {
    final p = FakeProvider()
      ..verifyError = const AttendanceError('AUTH_FAILED', 'expired');
    expect((await run(p)).code, 'UNKNOWN');
  });
  test('inspect succeeds with no active class and never submits', () async {
    final p = FakeProvider()..list = [];
    expect((await run(p, code: '', inspect: true)).code, 'INSPECTED');
    expect(p.submissions, 0);
    expect(p.closes, 1);
  });
  test('concurrent run rejected and next run gets new provider', () async {
    final first = FakeProvider()..gate = Completer<void>();
    final second = FakeProvider();
    var count = 0;
    final f = AttendanceOrchestrator(
      () => ++count == 1 ? first : second,
      clock: () => now,
    );
    final pending = f.run(
      account,
      '1234',
      progress: (_) {},
      choose: (c) async => c.first,
    );
    final concurrent = await f.run(
      account,
      '1234',
      progress: (_) {},
      choose: (c) async => c.first,
    );
    expect(concurrent.code, 'BUSY');
    first.gate!.complete();
    await pending;
    await f.run(
      account,
      '1234',
      progress: (_) {},
      choose: (c) async => c.first,
    );
    expect(count, 2);
    expect(first.closes, 1);
    expect(second.closes, 1);
  });
}
