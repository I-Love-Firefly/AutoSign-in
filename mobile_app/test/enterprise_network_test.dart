import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/campus_network.dart';
import 'package:attendance_assistant/enterprise_network.dart';

const account = Account('test', 'example', 'cas', networkPassword: 'wifi');

class EnterpriseFake implements EnterpriseTransport {
  String mode = 'student5g';
  final calls = <String>[];
  Object? prepareError;
  Object? legacyError;
  int result = 0;
  Map<String, dynamic> link = {
    'ip': '10.0.0.10',
    'handle': 2,
    'ssid': 'Student-5G',
    'enterprise': true,
  };
  @override
  Future<void> checkLegacy() async {
    if (legacyError != null) throw legacyError!;
  }

  @override
  Future<Map<String, dynamic>> preferences() async => {'mode': mode};
  @override
  Future<void> permissions() async {
    calls.add('permissions');
  }

  @override
  Future<int> currentHandle() async => 1;
  @override
  Future<Map<String, dynamic>> prepare(Account a) async {
    calls.add('prepare');
    if (prepareError != null) throw prepareError!;
    return {'previousHandle': 1, 'result': result};
  }

  @override
  Future<Map<String, dynamic>> connect(int p, {required bool manual}) async {
    calls.add(manual ? 'manual' : 'connect');
    return link;
  }

  @override
  Future<Map<String, dynamic>> state() async => link;
  @override
  Future<void> release() async {
    calls.add('release');
  }
}

class CampusFake implements CampusTransport {
  final paths = <String>[];
  String user = 'example', ip = '10.0.0.10';
  int releases = 0;
  @override
  Future<String> bind() async => ip;
  @override
  Future<String> reconnect() async =>
      throw StateError('portal reconnect must not be used');
  @override
  Future<String> portalPage() async =>
      throw StateError('portal config must not be used');
  @override
  Future<Map<String, dynamic>> get(String path, Map<String, String> p) async {
    paths.add(path);
    return {'error': 'ok', 'online_ip': ip, 'user_name': user};
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

class InnerFake implements AttendanceProvider {
  int logins = 0, closes = 0;
  @override
  Future<void> login(Account a, void Function(Stage) p) async {
    logins++;
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course c, String code) async =>
      throw StateError('no attendance submission');
  @override
  Future<bool> verify(Course c) async => false;
  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  test('system confirmation, fresh link and two identity checks precede academic login', () async {
    final e = EnterpriseFake(), c = CampusFake(), inner = InnerFake();
    final stages = <Stage>[];
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: c,
      identityPollInterval: Duration.zero,
    );
    await p.login(account, stages.add);
    await p.close();
    expect(e.calls, ['permissions', 'prepare', 'connect', 'release']);
    expect(c.paths, ['/cgi-bin/rad_user_info', '/cgi-bin/rad_user_info']);
    expect(inner.logins, 1);
    expect(inner.closes, 1);
    expect(c.releases, 1);
    expect(stages, [
      Stage.networkConfiguring,
      Stage.networkApproval,
      Stage.networkEnterpriseReconnect,
      Stage.networkVerifying,
      Stage.authenticating,
    ]);
  });
  test(
    'manual mode never prepares or changes credentials through portal',
    () async {
      final e = EnterpriseFake()..mode = 'manual5g';
      final c = CampusFake();
      await Student5gNetwork(
        e,
        c,
        interval: Duration.zero,
      ).switchAccount(account, (_) {}, manual: true);
      expect(e.calls, ['permissions', 'manual']);
      expect(c.paths, everyElement('/cgi-bin/rad_user_info'));
    },
  );
  test(
    'cancelled confirmation blocks academic login and allows cleanup',
    () async {
      final e = EnterpriseFake()
        ..prepareError = PlatformException(
          code: 'ENTERPRISE_CANCELLED',
          message: 'cancelled',
        );
      final inner = InnerFake();
      final c = CampusFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: c,
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        p.login(account, (_) {}),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'ENTERPRISE_CANCELLED',
          ),
        ),
      );
      await p.close();
      expect(inner.logins, 0);
      expect(e.calls, isNot(contains('connect')));
      expect(c.releases, 1);
    },
  );
  test(
    'saved configuration alone cannot credit another network account',
    () async {
      final e = EnterpriseFake();
      final c = CampusFake()..user = 'other';
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: c,
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        p.login(account, (_) {}),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'ENTERPRISE_IDENTITY',
          ),
        ),
      );
      expect(inner.logins, 0);
      expect(c.paths, everyElement('/cgi-bin/rad_user_info'));
    },
  );
  test(
    'missing Wi-Fi password stops before configuration or permission request',
    () async {
      final e = EnterpriseFake();
      await expectLater(
        Student5gNetwork(e, CampusFake()).switchAccount(
          const Account('test', 'example', 'cas'),
          (_) {},
          manual: false,
        ),
        throwsA(isA<AttendanceError>()),
      );
      expect(e.calls, isEmpty);
    },
  );
  test('open Student or unchanged handle cannot proceed', () async {
    for (final values in [
      {'ssid': 'Student'},
      {'handle': 1},
      {'enterprise': false},
    ]) {
      final e = EnterpriseFake();
      e.link.addAll(values);
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: CampusFake(),
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        p.login(account, (_) {}),
        throwsA(isA<AttendanceError>()),
      );
      expect(inner.logins, 0);
    }
  });
  test('system save rejection cannot proceed to reconnect', () async {
    final e = EnterpriseFake()..result = 1;
    await expectLater(
      Student5gNetwork(
        e,
        CampusFake(),
      ).switchAccount(account, (_) {}, manual: false),
      throwsA(isA<AttendanceError>()),
    );
    expect(e.calls, isNot(contains('connect')));
  });
  test('address mismatch blocks academic login', () async {
    final e = EnterpriseFake();
    final c = CampusFake()..ip = '10.0.0.11';
    final inner = InnerFake();
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: c,
      identityPollInterval: Duration.zero,
    );
    await expectLater(
      p.login(account, (_) {}),
      throwsA(
        isA<AttendanceError>().having((x) => x.code, 'code', 'NETWORK_ADDRESS'),
      ),
    );
    expect(inner.logins, 0);
  });
  test(
    'legacy mode blocks an enterprise connection before portal requests',
    () async {
      final e = EnterpriseFake()
        ..mode = 'student'
        ..legacyError = PlatformException(code: 'LEGACY_NETWORK_TYPE');
      final c = CampusFake();
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(inner, enterprise: e, campus: c);
      await expectLater(
        p.login(account, (_) {}),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'LEGACY_NETWORK_TYPE',
          ),
        ),
      );
      expect(c.paths, isEmpty);
      expect(inner.logins, 0);
    },
  );
}
