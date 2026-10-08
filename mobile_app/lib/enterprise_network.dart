import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'campus_network.dart';
import 'domain.dart';

abstract class EnterpriseTransport {
  Future<Map<String, dynamic>> preferences();
  Future<void> permissions();
  Future<int> currentHandle();
  Future<Map<String, dynamic>> prepare(Account account);
  Future<Map<String, dynamic>> connect(int previous, {required bool manual});
  Future<Map<String, dynamic>> state();
  Future<void> release();
  Future<void> checkLegacy() async {}
}

class NativeEnterpriseTransport implements EnterpriseTransport {
  static const channel = MethodChannel(
    'com.xmum.attendance_assistant/enterprise',
  );
  Future<Map<String, dynamic>> _map(
    String method, [
    Map<String, dynamic>? args,
  ]) async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>(method, args) ?? {},
  );
  @override
  Future<Map<String, dynamic>> preferences() => _map('preferences');
  @override
  Future<void> checkLegacy() => channel.invokeMethod('legacyGuard');
  static Future<void> saveSettings(String mode, String phase2) =>
      channel.invokeMethod('setPreferences', {'mode': mode, 'phase2': phase2});
  @override
  Future<void> permissions() => channel.invokeMethod('permissions');
  @override
  Future<int> currentHandle() async =>
      (await channel.invokeMethod<num>('currentHandle'))?.toInt() ?? -1;
  @override
  Future<Map<String, dynamic>> prepare(Account account) => _map('prepare', {
    'username': account.campusId.trim(),
    'password': account.networkPassword,
  });
  @override
  Future<Map<String, dynamic>> connect(int previous, {required bool manual}) =>
      _map('connect', {'previousHandle': previous, 'manual': manual});
  @override
  Future<Map<String, dynamic>> state() => _map('state');
  @override
  Future<void> release() => channel.invokeMethod('release');
}

// Keep the previous public name for existing Android integrations.
typedef AndroidEnterpriseTransport = NativeEnterpriseTransport;

bool confirmedEnterpriseConnection(
  Map<String, dynamic> link,
  int previous, {
  required bool manual,
}) {
  if (link['handle'] is! num || (link['handle'] as num) < 0) return false;
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    // iOS exposes no Android network handle. Native code reports a real
    // configuration approval or an observed trip to Settings instead.
    return link['evidence'] ==
        (manual ? 'ios-settings-return' : 'ios-system-approved');
  }
  return link['handle'] != previous;
}

class Student5gNetwork {
  final EnterpriseTransport enterprise;
  final CampusTransport campus;
  final Duration interval;
  Student5gNetwork(
    this.enterprise,
    this.campus, {
    this.interval = const Duration(seconds: 1),
  });
  Future<void> switchAccount(
    Account account,
    void Function(Stage) progress, {
    required bool manual,
  }) async {
    if (account.networkPassword.isEmpty) {
      throw const AttendanceError(
        'NETWORK_PASSWORD_MISSING',
        '请先在编辑账号中填写校园网密码',
      );
    }
    progress(Stage.networkConfiguring);
    await enterprise.permissions();
    var previous = await enterprise.currentHandle();
    if (!manual) {
      progress(Stage.networkApproval);
      final saved = await enterprise.prepare(account);
      if (saved['previousHandle'] is! num ||
          ![0, 2].contains(saved['result'])) {
        throw const AttendanceError(
          'ENTERPRISE_SAVE_FAILED',
          '系统未确认 Student-5G 配置，已停止',
        );
      }
      previous = (saved['previousHandle'] as num).toInt();
    }
    progress(Stage.networkEnterpriseReconnect);
    final link = await enterprise.connect(previous, manual: manual);
    final ip = link['ip'];
    if (ip is! String ||
        !ip.startsWith('10.') ||
        link['ssid'] != 'Student-5G' ||
        link['enterprise'] != true ||
        !confirmedEnterpriseConnection(link, previous, manual: manual)) {
      throw const AttendanceError(
        'ENTERPRISE_CONNECTION',
        '未确认新的 Student-5G 企业网络连接，已停止',
      );
    }
    if (await campus.bind() != ip) {
      throw const AttendanceError('NETWORK_ADDRESS', '连接地址已变化，请重新开始流程');
    }
    progress(Stage.networkVerifying);
    var confirmations = 0;
    String? lastUser;
    for (var i = 0; i < 20; i++) {
      final now = await enterprise.state();
      if (now['handle'] != link['handle'] ||
          now['ip'] != ip ||
          now['ssid'] != 'Student-5G' ||
          now['enterprise'] != true) {
        throw const AttendanceError(
          'ENTERPRISE_CONNECTION_CHANGED',
          'Student-5G 连接已变化，已停止',
        );
      }
      final status = await campus.get('/cgi-bin/rad_user_info', {'ip': ip});
      if ((status['client_ip'] ?? status['online_ip']) != ip) {
        throw const AttendanceError('NETWORK_ADDRESS', '学校返回的设备地址不匹配，已停止');
      }
      if (status['error'] != 'ok' && status['error'] != 'not_online_error') {
        throw const AttendanceError(
          'ENTERPRISE_STATUS',
          '学校未提供可核验的网络身份，已停止；请在官方页面核验',
        );
      }
      lastUser = status['user_name'] is String
          ? status['user_name'] as String
          : null;
      if (status['error'] == 'ok' &&
          lastUser?.toLowerCase() == account.campusId.trim().toLowerCase()) {
        if (++confirmations >= 2) return;
      } else {
        confirmations = 0;
      }
      if (i < 19) await Future<void>.delayed(interval);
    }
    final actual =
        lastUser != null &&
            RegExp(r'^[A-Za-z0-9@._-]{1,100}$').hasMatch(lastUser)
        ? '，当前学校记录账号为 $lastUser'
        : '';
    throw AttendanceError(
      'ENTERPRISE_IDENTITY',
      '未确认校园网账号与所选学生一致$actual。请检查系统保存的身份、密码和认证设置；未继续教务登录或签到',
    );
  }
}

class AdaptiveNetworkProvider
    implements AttendanceProvider, CampusPreparedProvider {
  final AttendanceProvider inner;
  final EnterpriseTransport enterprise;
  final CampusTransport campus;
  bool _useEnterprise = false;
  final Duration identityPollInterval;
  AdaptiveNetworkProvider(
    this.inner, {
    EnterpriseTransport? enterprise,
    CampusTransport? campus,
    this.identityPollInterval = const Duration(seconds: 1),
  }) : enterprise = enterprise ?? NativeEnterpriseTransport(),
       campus = campus ?? NativeCampusTransport();
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    try {
      final mode = (await enterprise.preferences())['mode'];
      if (mode == 'student') {
        await enterprise.permissions();
        await enterprise.checkLegacy();
        await CampusNetwork(campus).switchAccount(account, progress);
      } else if (mode == 'student5g' || mode == 'manual5g') {
        _useEnterprise = true;
        await Student5gNetwork(
          enterprise,
          campus,
          interval: identityPollInterval,
        ).switchAccount(account, progress, manual: mode == 'manual5g');
      } else {
        throw const AttendanceError('ENTERPRISE_SETTINGS', '校园网方式不受支持，请重新设置');
      }
      progress(Stage.authenticating);
      await inner.login(account, progress);
    } on PlatformException catch (e) {
      // Native messages never echo credentials or complete request URLs.
      throw AttendanceError(e.code, e.message ?? '校园网切换失败');
    }
  }

  @override
  Future<List<Course>> courses() => inner.courses();
  @override
  Future<void> submit(Course course, String code) => inner.submit(course, code);
  @override
  Future<bool> verify(Course course) => inner.verify(course);
  @override
  Future<void> close() async {
    try {
      await inner.close();
    } finally {
      try {
        await campus.release();
      } finally {
        if (_useEnterprise) await enterprise.release();
      }
    }
  }
}
