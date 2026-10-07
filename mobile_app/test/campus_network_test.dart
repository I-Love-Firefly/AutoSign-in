import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/campus_network.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/portable_archive.dart';

class PortalFake implements CampusTransport {
  final calls = <String>[];
  final requests = <Map<String, String>>[];
  String? user = 'previous';
  bool stuck = false, mismatch = false, reject = false;
  int alreadyOnlineResponses = 0;
  String activeIp = '10.72.88.93';
  bool changeIp = false, reconnectOnline = false;
  String acId = '1', nasIp = '';
  String? reconnectedAcId, reconnectedNasIp;
  bool malformedConfig = false,
      wrongConfigIp = false,
      failReconnectedConfig = false;
  bool reconnected = false, basTimeout = false;
  String? logoutError;
  List<String> accountIps = [];
  final offlineSequence = <String?>[];
  bool logoutSent = false, wrongPollingIp = false;
  bool macAuth = true;
  bool dmOfflineAck = false;
  String? queryRejectMessage;
  @override
  Future<String> bind() async => '10.72.88.93';
  @override
  Future<String> reconnect() async {
    calls.add('reconnect');
    if (changeIp) activeIp = '10.72.90.5';
    if (reconnectOnline) user = 'other';
    reconnected = true;
    acId = reconnectedAcId ?? acId;
    nasIp = reconnectedNasIp ?? nasIp;
    return activeIp;
  }

  @override
  Future<void> release() async {}
  @override
  Future<String> portalPage() async {
    calls.add('portal');
    if (malformedConfig || (reconnected && failReconnectedConfig)) {
      return '<html>Unavailable</html>';
    }
    return '''<script>var CONFIG = {
      page: 'account', acid: "$acId", ip: "${wrongConfigIp ? '10.0.0.1' : activeIp}",
      nas: "$nasIp", lang: "zh-CN" || 'zh-CN', portal: {"acid":"999","MacAuth":$macAuth},
    };</script>''';
  }

  @override
  Future<Map<String, dynamic>> get(String path, Map<String, String> p) async {
    calls.add(path);
    requests.add({'path': path, ...p});
    switch (path) {
      case '/cgi-bin/rad_user_info':
        final reported =
            logoutSent && !reconnected && offlineSequence.isNotEmpty
            ? offlineSequence.removeAt(0)
            : user;
        final reportedIp = logoutSent && wrongPollingIp ? '10.0.0.1' : activeIp;
        return {
          'error': reported == null ? 'not_online_error' : 'ok',
          if (reported == null) 'client_ip': reportedIp,
          if (reported != null) 'online_ip': reportedIp,
          'user_name': reported,
        };
      case '/v1/srun_portal_online':
        expectSync(p['user_name'], 'example');
        expectSync(p['password'], '5f4dcc3b5aa765d61d8327deb882cf99');
        if (queryRejectMessage != null) {
          return {'code': 1, 'message': queryRejectMessage};
        }
        return {
          'code': 0,
          'data': [
            for (final ip in accountIps) {'user_name': 'example', 'ip': ip},
          ],
        };
      case '/cgi-bin/rad_user_dm':
        expectSync(p['username'], user ?? 'example');
        expectSync(p['unbind'], '1');
        if (logoutError != null) return {'error': logoutError};
        logoutSent = true;
        if (user == null && dmOfflineAck) return {'error': 'not_online_error'};
        if (!stuck) user = null;
        return {'error': 'ok'};
      case '/cgi-bin/get_challenge':
        return {'challenge': '0123456789abcdef'};
      default:
        if (p['action'] == 'logout') {
          expectSync(p['username'], user ?? 'example');
          expectSync(p['ip'], '10.72.88.93');
          expectSync(p['ac_id'], acId);
          if (logoutError != null) return {'error': logoutError};
          logoutSent = true;
          if (!stuck) user = null;
          return {'error': 'not_online_error'};
        }
        expectSync(p['password'], '{MD5}e7d79689770a8226fd5a0c3b00218398');
        expectSync(p['ip'], activeIp);
        expectSync(p['info'], startsWith('{SRBX1}'));
        expectSync(p.values, isNot(contains('password')));
        if (basTimeout) {
          return {
            'error': 'login_error',
            'error_msg': 'CHALLENGE failed, BAS respond timeout.',
          };
        }
        if (alreadyOnlineResponses > 0) {
          alreadyOnlineResponses--;
          return {'error': 'login_error', 'ecode': 'E2620'};
        }
        if (reject) return {'error': 'password_error'};
        user = mismatch ? 'other' : p['username'];
        return {'error': 'ok'};
    }
  }
}

void main() {
  const account = Account(
    'Example',
    'example',
    'cas-secret',
    networkPassword: 'password',
  );
  test('encoding matches current portal JS vector', () {
    expect(
      srunInfo('example payload', '0123456789abcdef'),
      '{SRBX1}wdiqgV+hgTijqrRsIM2TFddd0e+=',
    );
    expect(
      Hmac(
        md5,
        utf8.encode('0123456789abcdef'),
      ).convert(utf8.encode('password')).toString(),
      'e7d79689770a8226fd5a0c3b00218398',
    );
  });
  test('switch logs out and confirms identity before returning', () async {
    final t = PortalFake();
    final stages = <Stage>[];
    await CampusNetwork(
      t,
      pollInterval: Duration.zero,
    ).switchAccount(account, stages.add);
    expect(stages, [
      Stage.networkChecking,
      Stage.networkLogout,
      Stage.networkReconnect,
      Stage.networkLogin,
      Stage.networkVerifying,
    ]);
    expect(t.calls, [
      '/cgi-bin/rad_user_info',
      'portal',
      '/cgi-bin/rad_user_dm',
      '/cgi-bin/rad_user_info',
      '/cgi-bin/rad_user_info',
      'reconnect',
      '/cgi-bin/rad_user_info',
      '/cgi-bin/rad_user_info',
      '/cgi-bin/rad_user_info',
      'portal',
      '/cgi-bin/get_challenge',
      '/cgi-bin/srun_portal',
      '/cgi-bin/rad_user_info',
    ]);
  });
  test('missing password stops before network mutation', () async {
    final t = PortalFake();
    await expectLater(
      CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(const Account('e', 'e', 'p'), (_) {}),
      throwsA(isA<AttendanceError>()),
    );
    expect(t.calls, isEmpty);
  });
  test(
    'MacAuth unbinds the selected current IP even if status is already offline',
    () async {
      final t = PortalFake()
        ..user = null
        ..dmOfflineAck = true;
      await CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {});
      final unbind = t.requests.singleWhere(
        (p) => p['path'] == '/cgi-bin/rad_user_dm',
      );
      expect(unbind['username'], 'example');
      expect(unbind['ip'], '10.72.88.93');
      expect(t.requests.where((p) => p['action'] == 'logout'), isEmpty);
    },
  );
  test(
    'non-MacAuth portal logs out the actual online account with current AC',
    () async {
      final t = PortalFake()
        ..macAuth = false
        ..acId = '2';
      await CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {});
      final logout = t.requests.singleWhere((p) => p['action'] == 'logout');
      expect(logout['username'], 'previous');
      expect(logout['ac_id'], '2');
      expect(t.calls, isNot(contains('/cgi-bin/rad_user_dm')));
    },
  );
  test('online API rejection includes a sanitized reason without credentials', () async {
    final t = PortalFake()
      ..queryRejectMessage =
          'denied example password cas-secret 5f4dcc3b5aa765d61d8327deb882cf99';
    await expectLater(
      CampusNetwork(t).inspectSessions(account),
      throwsA(
        isA<AttendanceError>().having(
          (e) => e.message,
          'reason',
          allOf(
            contains('返回码 1'),
            contains('denied'),
            isNot(contains('password')),
            isNot(contains('cas-secret')),
            isNot(contains('5f4dcc')),
          ),
        ),
      ),
    );
    expect(t.calls, isNot(contains('/cgi-bin/rad_user_dm')));
  });
  test('new Wi-Fi address is used after reconnect', () async {
    final t = PortalFake()..changeIp = true;
    await CampusNetwork(
      t,
      pollInterval: Duration.zero,
    ).switchAccount(account, (_) {});
    expect(t.user, 'example');
    expect(t.activeIp, '10.72.90.5');
  });
  test('unexpected online session after reconnect blocks login', () async {
    final t = PortalFake()..reconnectOnline = true;
    await expectLater(
      CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {}),
      throwsA(isA<AttendanceError>()),
    );
    expect(t.calls, isNot(contains('/cgi-bin/get_challenge')));
  });
  test('already-online response stops instead of guessing delay', () async {
    final t = PortalFake()..alreadyOnlineResponses = 2;
    await expectLater(
      CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {}),
      throwsA(isA<AttendanceError>()),
    );
    expect(t.calls.where((p) => p == '/cgi-bin/get_challenge').length, 1);
    expect(t.user, isNull);
  });
  test(
    'offline device explicitly logs out and verifies before login',
    () async {
      final t = PortalFake()..user = null;
      final stages = <Stage>[];
      await CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, stages.add);
      expect(stages, [
        Stage.networkChecking,
        Stage.networkLogout,
        Stage.networkReconnect,
        Stage.networkLogin,
        Stage.networkVerifying,
      ]);
      expect(t.calls.take(4), [
        '/cgi-bin/rad_user_info',
        'portal',
        '/cgi-bin/rad_user_dm',
        '/cgi-bin/rad_user_info',
      ]);
    },
  );
  test('unconfirmed logout prevents sending new login credentials', () async {
    final t = PortalFake()..stuck = true;
    await expectLater(
      CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {}),
      throwsA(isA<AttendanceError>()),
    );
    expect(t.calls, isNot(contains('/cgi-bin/get_challenge')));
    expect(t.calls, isNot(contains('/cgi-bin/srun_portal')));
  });
  test('wrong identity and rejected password stop flow', () async {
    for (final t in [
      PortalFake()..mismatch = true,
      PortalFake()..reject = true,
    ]) {
      await expectLater(
        CampusNetwork(
          t,
          pollInterval: Duration.zero,
        ).switchAccount(account, (_) {}),
        throwsA(isA<AttendanceError>()),
      );
    }
  });
  test(
    'logout rejection is checked even when IP status says offline',
    () async {
      for (final t in [
        PortalFake()..logoutError = 'sign_error',
        PortalFake()
          ..user = null
          ..logoutError = 'logout_error',
      ]) {
        await expectLater(
          CampusNetwork(
            t,
            pollInterval: Duration.zero,
          ).switchAccount(account, (_) {}),
          throwsA(
            isA<AttendanceError>().having(
              (e) => e.code,
              'code',
              'NETWORK_LOGOUT',
            ),
          ),
        );
        expect(t.calls, isNot(contains('reconnect')));
        expect(t.calls, isNot(contains('/cgi-bin/get_challenge')));
      }
    },
  );
  test(
    'logout requires consecutive matching-IP offline confirmations',
    () async {
      final t = PortalFake()
        ..offlineSequence.addAll([null, 'previous', null, null]);
      await CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {});
      final logoutIndex = t.calls.indexOf('/cgi-bin/rad_user_dm');
      expect(
        t.calls.sublist(logoutIndex + 1, t.calls.indexOf('reconnect')),
        List.filled(4, '/cgi-bin/rad_user_info'),
      );
      final wrong = PortalFake()..wrongPollingIp = true;
      await expectLater(
        CampusNetwork(
          wrong,
          pollInterval: Duration.zero,
        ).switchAccount(account, (_) {}),
        throwsA(
          isA<AttendanceError>().having(
            (e) => e.code,
            'code',
            'NETWORK_ADDRESS',
          ),
        ),
      );
      expect(wrong.calls, isNot(contains('reconnect')));
    },
  );
  test(
    'online session inspection uses account authentication and never logs out',
    () async {
      final t = PortalFake()
        ..user = null
        ..accountIps = ['10.72.90.5', '10.72.99.123'];
      final report = await CampusNetwork(t).inspectSessions(account);
      expect(report.deviceIp, '10.72.88.93');
      expect(report.deviceOnline, isFalse);
      expect(report.accountIps, ['10.72.90.5', '10.72.99.123']);
      expect(t.calls, ['/cgi-bin/rad_user_info', '/v1/srun_portal_online']);
    },
  );
  test(
    'E2620 distinguishes current-IP residue from other or old IP sessions',
    () async {
      for (final ips in [
        ['10.72.88.93'],
        ['10.72.90.5'],
        <String>[],
      ]) {
        final t = PortalFake()
          ..alreadyOnlineResponses = 1
          ..accountIps = ips;
        await expectLater(
          CampusNetwork(
            t,
            pollInterval: Duration.zero,
          ).switchAccount(account, (_) {}),
          throwsA(
            isA<AttendanceError>().having(
              (e) => e.message,
              'diagnostic',
              contains(
                ips.contains(t.activeIp)
                    ? '仍包含当前手机 IP'
                    : ips.isEmpty
                    ? '账号在线列表为空'
                    : '未自动注销',
              ),
            ),
          ),
        );
        expect(
          t.calls.where((path) => path == '/cgi-bin/rad_user_dm').length,
          1,
        );
        expect(t.requests.where((p) => p['action'] == 'login').length, 1);
      }
    },
  );
  test('portal parser reads top-level fields without evaluating scripts', () {
    final config = CampusPortalConfig.parse('''<script>
      var CONFIG = { page: 'account', /* current environment */ acid: "2",
        ip: "10.72.99.123", nas: "10.68.1.2", lang: "zh-CN" || 'zh-CN',
        portal: {"acid": "999", "nested": {"ip": "10.0.0.1"}, "ServiceIP": "https://srun.xmu.edu.my:8800", "MacAuth": true},
      };
    </script>''', '10.72.99.123');
    expect(config.acId, '2');
    expect(config.nasIp, '10.68.1.2');
    expect(config.ip, '10.72.99.123');
    expect(config.macAuth, isTrue);
  });
  test(
    'invalid or ambiguous portal configuration has no default AC fallback',
    () {
      for (final fields in [
        'ip:"10.72.88.93",nas:""',
        'acid:"",ip:"10.72.88.93",nas:""',
        'acid:"0",ip:"10.72.88.93",nas:""',
        'acid:"2",acid:"1",ip:"10.72.88.93",nas:""',
        'portal:{acid:"2",ip:"10.72.88.93",nas:""}',
        'acid:computeAc(),ip:"10.72.88.93",nas:""',
        'acid:"2",ip:"10.72.88.93",nas:"https://example.com"',
        'acid:"2",ip:"10.72.88.93",nas:"256.0.0.1"',
      ]) {
        expect(
          () => CampusPortalConfig.parse(
            '<script>var CONFIG = {$fields};</script>',
            '10.72.88.93',
          ),
          throwsA(isA<AttendanceError>()),
        );
      }
      expect(
        () => CampusPortalConfig.parse(
          '<script>var CONFIG={acid:"2",ip:"10.72.88.93",nas:""};var CONFIG={acid:"1",ip:"10.72.88.93",nas:""};</script>',
          '10.72.88.93',
        ),
        throwsA(isA<AttendanceError>()),
      );
    },
  );
  test('reconnect refreshes AC and NAS in login payload and checksum', () async {
    final t = PortalFake()
      ..user = null
      ..macAuth = false
      ..changeIp = true
      ..reconnectedAcId = '2'
      ..reconnectedNasIp = '10.68.1.2';
    await CampusNetwork(
      t,
      pollInterval: Duration.zero,
    ).switchAccount(account, (_) {});
    final logout = t.requests.singleWhere((p) => p['action'] == 'logout');
    expect(logout['ac_id'], '1');
    final login = t.requests.singleWhere((p) => p['action'] == 'login');
    expect(login['ac_id'], '2');
    expect(login['nas_ip'], '10.68.1.2');
    const token = '0123456789abcdef';
    final info = srunInfo(
      jsonEncode({
        'username': 'example',
        'password': 'password',
        'ip': '10.72.90.5',
        'acid': '2',
        'enc_ver': 'srun_bx1',
      }),
      token,
    );
    expect(login['info'], info);
    expect(
      login['chksum'],
      sha1
          .convert(
            utf8.encode(
              '${token}example${token}e7d79689770a8226fd5a0c3b00218398${token}2${token}10.72.90.5${token}200${token}1$token$info',
            ),
          )
          .toString(),
    );
  });
  test('invalid initial config stops before logout, and invalid refreshed config stops before credentials', () async {
    for (final t in [
      PortalFake()..malformedConfig = true,
      PortalFake()..wrongConfigIp = true,
    ]) {
      await expectLater(
        CampusNetwork(
          t,
          pollInterval: Duration.zero,
        ).switchAccount(account, (_) {}),
        throwsA(isA<AttendanceError>()),
      );
      expect(t.calls, isNot(contains('/cgi-bin/rad_user_dm')));
      expect(t.calls, isNot(contains('/cgi-bin/srun_portal')));
    }
    final t = PortalFake()..failReconnectedConfig = true;
    await expectLater(
      CampusNetwork(
        t,
        pollInterval: Duration.zero,
      ).switchAccount(account, (_) {}),
      throwsA(isA<AttendanceError>()),
    );
    expect(t.calls, contains('reconnect'));
    expect(t.calls, isNot(contains('/cgi-bin/get_challenge')));
  });
  test(
    'BAS timeout reports network service failure instead of password advice',
    () async {
      final t = PortalFake()..basTimeout = true;
      await expectLater(
        CampusNetwork(
          t,
          pollInterval: Duration.zero,
        ).switchAccount(account, (_) {}),
        throwsA(
          isA<AttendanceError>()
              .having((e) => e.code, 'code', 'NETWORK_BAS_TIMEOUT')
              .having(
                (e) => e.message,
                'message',
                allOf(contains('认证设备未及时响应'), isNot(contains('请检查校园网密码'))),
              ),
        ),
      );
    },
  );
  test(
    'separate password survives archive and old accounts remain readable',
    () {
      expect(
        PortableAccounts.decode(PortableAccounts.encode([account]))
            .single
            .networkPassword,
        'password',
      );
      expect(
        Account.fromJson({'name': 'e', 'campusId': 'e', 'password': 'p'})
            .networkPassword,
        '',
      );
    },
  );
}
