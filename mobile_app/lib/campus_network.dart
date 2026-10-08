import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;

import 'domain.dart';

abstract class CampusTransport {
  Future<String> bind();
  Future<String> reconnect();
  Future<String> portalPage();
  Future<Map<String, dynamic>> get(String path, Map<String, String> params);
  Future<void> release();
}

class AndroidCampusTransport implements CampusTransport {
  static const channel = MethodChannel('com.xmum.attendance_assistant/network');
  @override
  Future<String> bind() async =>
      await channel.invokeMethod<String>('bind') ?? '';
  @override
  Future<String> reconnect() async =>
      await channel.invokeMethod<String>('reconnect') ?? '';
  @override
  Future<String> portalPage() async =>
      await channel.invokeMethod<String>('portal') ?? '';
  Future<Map<String, dynamic>> connectionState() async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('state') ?? {},
      );
  @override
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> params,
  ) async {
    final text = await channel.invokeMethod<String>('get', {
      'path': path,
      'params': params,
    });
    if (text == null) {
      throw const AttendanceError('NETWORK_SCHEMA', '校园网服务返回格式不受支持');
    }
    try {
      final body = path == '/v1/srun_portal_online'
          ? text
          : text.startsWith('campusFlow(') && text.endsWith(')')
          ? text.substring(11, text.length - 1)
          : throw const FormatException();
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) throw const FormatException();
      return data;
    } on FormatException {
      throw const AttendanceError('NETWORK_SCHEMA', '校园网服务返回格式不受支持');
    }
  }

  @override
  Future<void> release() => channel.invokeMethod<void>('release');
}

class CampusSessionReport {
  final String deviceIp;
  final bool deviceOnline;
  final List<String> accountIps;
  const CampusSessionReport(this.deviceIp, this.deviceOnline, this.accountIps);
}

class CampusPortalConfig {
  final String acId, nasIp, ip;
  final bool macAuth;
  const CampusPortalConfig(
    this.acId,
    this.nasIp,
    this.ip, {
    required this.macAuth,
  });

  static AttendanceError get _invalid =>
      const AttendanceError('NETWORK_CONFIG', '无法读取当前校园网认证参数，请在学校认证页面核验后重试');

  static String _withoutComments(String source) {
    final output = StringBuffer();
    String? quote;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (quote != null) {
        output.write(c);
        if (c == r'\' && i + 1 < source.length) {
          output.write(source[++i]);
        } else if (c == quote) {
          quote = null;
        }
      } else if (c == '"' || c == "'" || c == '`') {
        quote = c;
        output.write(c);
      } else if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
        final end = source.indexOf('\n', i + 2);
        if (end < 0) break;
        i = end;
        output.write('\n');
      } else if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
        final end = source.indexOf('*/', i + 2);
        if (end < 0) throw _invalid;
        i = end + 1;
        output.write(' ');
      } else {
        output.write(c);
      }
    }
    return output.toString();
  }

  // Read data from the inline CONFIG object without executing school JavaScript.
  // Only top-level fields count; nested objects, strings and comments are skipped.
  static CampusPortalConfig parse(String source, String expectedIp) {
    final configs = <Map<String, String>>[];
    for (final script
        in html.parse(source).querySelectorAll('script:not([src])')) {
      final text = _withoutComments(script.text);
      final declarations = RegExp(r'\b(?:var|let|const)\s+CONFIG\s*=\s*\{')
          .allMatches(text);
      for (final declaration in declarations) {
        final fields = <String, String>{};
        var start = declaration.end, depth = 1;
        String? quote;
        var closed = false;
        for (var i = start; i < text.length; i++) {
          final c = text[i];
          if (quote != null) {
            if (c == r'\') {
              i++;
            } else if (c == quote) {
              quote = null;
            }
            continue;
          }
          if (c == '"' || c == "'" || c == '`') {
            quote = c;
            continue;
          }
          if (c == '/' && i + 1 < text.length) {
            if (text[i + 1] == '/') {
              final end = text.indexOf('\n', i + 2);
              if (end < 0) throw _invalid;
              i = end;
              continue;
            }
            if (text[i + 1] == '*') {
              final end = text.indexOf('*/', i + 2);
              if (end < 0) throw _invalid;
              i = end + 1;
              continue;
            }
          }
          if (c == '{' || c == '[' || c == '(') depth++;
          if (c == '}' || c == ']' || c == ')') depth--;
          if ((c == ',' && depth == 1) || depth == 0) {
            final field = text.substring(start, i).trim();
            final match = RegExp(
              r'''^(acid|nas|ip)\s*:\s*(?:"([^"\\]*)"|'([^'\\]*)'|([0-9]+))\s*$''',
            ).firstMatch(field);
            if (match != null) {
              if (fields.containsKey(match[1])) throw _invalid;
              fields[match[1]!] = match[2] ?? match[3] ?? match[4]!;
            } else if (RegExp(r'^(acid|nas|ip)\s*:').hasMatch(field)) {
              throw _invalid;
            } else if (RegExp(r'^portal\s*:').hasMatch(field)) {
              if (fields.containsKey('macAuth')) throw _invalid;
              try {
                final portal = jsonDecode(
                  field.substring(field.indexOf(':') + 1),
                );
                if (portal is! Map || portal['MacAuth'] is! bool) {
                  throw _invalid;
                }
                fields['macAuth'] = '${portal['MacAuth']}';
              } on FormatException {
                throw _invalid;
              }
            }
            start = i + 1;
          }
          if (depth == 0) {
            closed = true;
            break;
          }
        }
        if (!closed) throw _invalid;
        configs.add(fields);
      }
    }
    if (configs.length != 1) throw _invalid;
    final fields = configs.single;
    final acId = fields['acid'], nasIp = fields['nas'], ip = fields['ip'];
    bool ipv4(String value) =>
        RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$').hasMatch(value) &&
        value.split('.').every((part) => int.parse(part) <= 255);
    if (acId == null ||
        !RegExp(r'^[1-9]\d{0,9}$').hasMatch(acId) ||
        nasIp == null ||
        (nasIp.isNotEmpty && !ipv4(nasIp)) ||
        ip == null ||
        !ipv4(ip) ||
        fields['macAuth'] == null) {
      throw _invalid;
    }
    if (ip != expectedIp) {
      throw const AttendanceError(
        'NETWORK_CONFIG_ADDRESS',
        '认证页面的设备地址与当前 Wi-Fi 不一致，请重新连接 Student 后重试',
      );
    }
    return CampusPortalConfig(
      acId,
      nasIp,
      ip,
      macAuth: fields['macAuth'] == 'true',
    );
  }
}

// Reproduces the observed portal's JS code-unit packing and custom Base64.
String srunInfo(String text, String token) {
  List<int> pack(String s, bool length) {
    final a = s.codeUnits;
    final v = <int>[];
    for (var i = 0; i < a.length; i += 4) {
      var word = 0;
      for (var j = 0; j < 4 && i + j < a.length; j++) {
        word |= a[i + j] << (j * 8);
      }
      v.add(word & 0xffffffff);
    }
    if (length) v.add(a.length);
    return v;
  }

  final v = pack(text, true), k = pack(token, false);
  while (k.length < 4) {
    k.add(0);
  }
  var z = v.last, d = 0;
  final n = v.length - 1;
  for (var q = (6 + 52 / v.length).floor(); q > 0; q--) {
    d = (d + 0x9e3779b9) & 0xffffffff;
    final e = (d >> 2) & 3;
    for (var p = 0; p <= n; p++) {
      final y = v[p < n ? p + 1 : 0];
      var m = (z >> 5) ^ (y << 2);
      m += (y >> 3) ^ (z << 4) ^ (d ^ y);
      m += k[(p & 3) ^ e] ^ z;
      z = v[p] = (v[p] + m) & 0xffffffff;
    }
  }
  final bytes = <int>[
    for (final w in v)
      for (var j = 0; j < 4; j++) (w >> (8 * j)) & 255,
  ];
  const normal =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const custom =
      'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA';
  return '{SRBX1}${base64Encode(bytes).split('').map((c) => c == '=' ? c : custom[normal.indexOf(c)]).join()}';
}

class CampusNetwork {
  final CampusTransport transport;
  final Duration pollInterval;
  CampusNetwork(
    this.transport, {
    this.pollInterval = const Duration(seconds: 1),
  });
  Future<Map<String, dynamic>> status(String ip) =>
      transport.get('/cgi-bin/rad_user_info', {'ip': ip});
  void _checkAddress(Map<String, dynamic> status, String ip) {
    if ((status['client_ip'] ?? status['online_ip']) != ip) {
      throw const AttendanceError(
        'NETWORK_ADDRESS',
        '校园网返回的设备地址不匹配，请确认连接 Student 网络',
      );
    }
  }

  Future<List<String>> _accountIps(Account account) async {
    if (account.networkPassword.isEmpty) {
      throw const AttendanceError('NETWORK_PASSWORD_MISSING', '请先填写校园网密码');
    }
    final result = await transport.get('/v1/srun_portal_online', {
      'user_name': account.campusId,
      // This is the school's online-device API contract, over HTTPS only.
      'password': md5.convert(utf8.encode(account.networkPassword)).toString(),
    });
    final rows = result['data'];
    if (result['code'] != 0 || rows is! List || rows.length > 100) {
      var detail = result['message'] is String
          ? result['message'] as String
          : '';
      for (final secret in [
        account.campusId,
        account.password,
        account.networkPassword,
        account.acPassword,
        md5.convert(utf8.encode(account.networkPassword)).toString(),
      ]) {
        if (secret.isNotEmpty) {
          detail = detail
              .replaceAll(secret, '[已隐藏]')
              .replaceAll(Uri.encodeComponent(secret), '[已隐藏]');
        }
      }
      detail = detail.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ');
      if (detail.length > 160) detail = detail.substring(0, 160);
      final code = result['code'] is int ? '，返回码 ${result['code']}' : '';
      throw AttendanceError(
        'NETWORK_ONLINE_QUERY',
        '学校未提供账号在线会话列表$code${detail.isEmpty ? '' : '：$detail'}。请在学校认证网页或自助服务核验',
      );
    }
    final ips = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row['ip'] is! String ||
          InternetAddress.tryParse(row['ip']) == null ||
          row['user_name'] is! String ||
          '${row['user_name']}'.toLowerCase() !=
              account.campusId.toLowerCase()) {
        throw const AttendanceError('NETWORK_ONLINE_QUERY', '学校返回的在线会话记录无法核验');
      }
      ips.add(row['ip']);
    }
    return ips.toList();
  }

  Future<CampusSessionReport> inspectSessions(Account account) async {
    final ip = await transport.bind();
    final current = await status(ip);
    _checkAddress(current, ip);
    if (current['error'] != 'ok' && current['error'] != 'not_online_error') {
      throw const AttendanceError('NETWORK_STATUS', '校园网状态异常，无法查询会话');
    }
    return CampusSessionReport(
      ip,
      current['error'] == 'ok',
      await _accountIps(account),
    );
  }

  void _checkLogout(Map<String, dynamic> result) {
    final error = result['error'];
    final code = '${result['ecode'] ?? ''}';
    // E6503 explicitly means no online account; E6502 is ambiguous and rejected.
    if (error == 'ok' ||
        error == 'not_online_error' ||
        (error == 'login_error' &&
            result['error_msg'] == 'You are not online.') ||
        (error == 'logout_error' && code == 'E6503')) {
      return;
    }
    final safe = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
    final codes = [
      if (error is String && safe.hasMatch(error)) error,
      if (safe.hasMatch(code)) code,
    ].join(' / ');
    throw AttendanceError(
      'NETWORK_LOGOUT',
      '校园网注销接口未确认成功${codes.isEmpty ? '' : '（$codes）'}，已停止；请在学校认证网页核验当前设备的会话',
    );
  }

  Future<void> switchAccount(
    Account account,
    void Function(Stage) progress,
  ) async {
    progress(Stage.networkChecking);
    if (account.networkPassword.isEmpty) {
      throw const AttendanceError(
        'NETWORK_PASSWORD_MISSING',
        '请先编辑学生账号，填写独立的校园网密码',
      );
    }
    var ip = await transport.bind();
    var current = await status(ip);
    _checkAddress(current, ip);
    var config = CampusPortalConfig.parse(await transport.portalPage(), ip);
    progress(Stage.networkLogout);
    if (current['error'] != 'ok' && current['error'] != 'not_online_error') {
      throw const AttendanceError('NETWORK_STATUS', '校园网状态异常，无法确认已离线');
    }
    if (current['error'] == 'ok') {
      final username = current['user_name'];
      if (username is! String || username.isEmpty) {
        throw const AttendanceError('NETWORK_IDENTITY', '无法识别当前校园网账号，已停止切换');
      }
      final domain = current['domain'];
      if (domain != null && domain is! String) {
        throw const AttendanceError('NETWORK_IDENTITY', '当前校园网账号的域信息无法核验');
      }
      if (config.macAuth) {
        final time = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
        final sign = sha1
            // The literal 1 here is the unbind flag, not an AC identifier.
            .convert(utf8.encode('$time$username${ip}1$time'))
            .toString();
        final logout = await transport.get('/cgi-bin/rad_user_dm', {
          'username': username,
          'ip': ip,
          'time': time,
          'unbind': '1',
          'sign': sign,
        });
        if (logout['error'] != 'ok') {
          throw const AttendanceError(
            'NETWORK_UNBIND_NOT_CONFIRMED',
            '学校未确认当前账号的设备绑定已解除，已停止；不会使用目标学生账号代替当前账号注销',
          );
        }
      }
      // MAC unbind acknowledgement alone is not the AC/BAS logout. Both
      // requests target the actual account read from this phone's online state.
      final fullUsername = domain is String && domain.isNotEmpty
          ? '$username@$domain'
          : username;
      final logout = await transport.get('/cgi-bin/srun_portal', {
        'action': 'logout',
        'username': fullUsername,
        'ip': ip,
        'ac_id': config.acId,
      });
      _checkLogout(logout);
    }
    // If already offline, there is no verified current account to mutate.
    // In particular, B must never be substituted for an unknown old account A.
    current = await _wait(ip, false);
    if (current['error'] != 'not_online_error') {
      throw const AttendanceError('NETWORK_STATUS', '校园网状态异常，无法确认已离线');
    }
    progress(Stage.networkReconnect);
    // Native reconnect confirms only a fresh stable Wi-Fi link. Android's
    // captive-portal prompt is not proof of the school's authentication state.
    ip = await transport.reconnect();
    current = await status(ip);
    _checkAddress(current, ip);
    if (current['error'] != 'not_online_error') {
      final actual = current['user_name'];
      final safeAccount =
          actual is String &&
              RegExp(r'^[A-Za-z0-9@._-]{1,100}$').hasMatch(actual)
          ? '（$actual）'
          : '';
      throw AttendanceError(
        'NETWORK_RECONNECTED_ONLINE',
        '重连后仍有校园网账号$safeAccount在线，旧会话或设备绑定尚未清除，已停止；不会继续登录目标账号或提交签到',
      );
    }
    await _wait(ip, false);
    progress(Stage.networkLogin);
    config = CampusPortalConfig.parse(await transport.portalPage(), ip);
    await _login(account, ip, config);
    progress(Stage.networkVerifying);
    final online = await _wait(ip, true);
    _checkAddress(online, ip);
    if ('${online['user_name']}'.toLowerCase() !=
        account.campusId.toLowerCase()) {
      throw const AttendanceError(
        'NETWORK_IDENTITY',
        '校园网在线账号与所选学生不一致，已停止签到流程',
      );
    }
  }

  Future<void> _login(
    Account account,
    String ip,
    CampusPortalConfig config,
  ) async {
    final challenge = await transport.get('/cgi-bin/get_challenge', {
      'username': account.campusId,
      'ip': ip,
    });
    final token = challenge['challenge'];
    if (token is! String || token.isEmpty) {
      throw const AttendanceError(
        'NETWORK_CHALLENGE',
        '校园网未返回登录挑战值，请在认证网页检查验证码或账号限制',
      );
    }
    final digest = Hmac(
      md5,
      utf8.encode(token),
    ).convert(utf8.encode(account.networkPassword)).toString();
    final info = srunInfo(
      jsonEncode({
        'username': account.campusId,
        'password': account.networkPassword,
        'ip': ip,
        'acid': config.acId,
        'enc_ver': 'srun_bx1',
      }),
      token,
    );
    final checksum = sha1
        .convert(
          utf8.encode(
            '$token${account.campusId}$token$digest$token${config.acId}$token$ip${token}200${token}1$token$info',
          ),
        )
        .toString();
    final result = await transport.get('/cgi-bin/srun_portal', {
      'action': 'login',
      'username': account.campusId,
      'password': '{MD5}$digest',
      'info': info,
      'chksum': checksum,
      'ac_id': config.acId,
      'ip': ip,
      'n': '200',
      'type': '1',
      'os': 'Android',
      'name': 'Android',
      'nas_ip': config.nasIp,
      'double_stack': '0',
    });
    if (result['error'] == 'ok' &&
        result['suc_msg'] == 'ip_already_online_error') {
      throw const AttendanceError(
        'NETWORK_IP_ALREADY_ONLINE',
        '学校返回当前 IP 已在线，没有确认目标账号登录成功，已停止；请核验旧账号会话',
      );
    }
    if (result['error'] != 'ok') {
      final error = '${result['error'] ?? 'unknown'}';
      final safe = RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(error)
          ? error
          : 'unknown';
      var detail = ['error_msg', 'res', 'ecode']
          .where((key) => result[key] != null)
          .map((key) => '${result[key]}')
          .join('；');
      for (final secret in [
        account.password,
        account.networkPassword,
        account.campusId,
        token,
        digest,
        info,
        checksum,
      ]) {
        if (secret.isNotEmpty) {
          detail = detail
              .replaceAll(secret, '[已隐藏]')
              .replaceAll(Uri.encodeComponent(secret), '[已隐藏]');
        }
      }
      detail = detail.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ');
      if (detail.length > 240) detail = detail.substring(0, 240);
      final alreadyOnline =
          '${result['ecode']}' == 'E2620' || detail.contains('E2620');
      final basTimeout = RegExp(
        r'BAS\s+respond\s+timeout',
        caseSensitive: false,
      ).hasMatch(detail);
      String? sessionDetail;
      if (alreadyOnline) {
        try {
          final ips = await _accountIps(account);
          sessionDetail = ips.contains(ip)
              ? '学校账号会话表仍包含当前手机 IP（$ip），当前设备会话尚未完全清除。请在学校网页注销该 IP 的会话后重新连接 Student'
              : ips.isEmpty
              ? '当前手机 IP（$ip）已离线，账号在线列表为空，但登录仍被拒绝；学校认证状态不一致，请在原网页核验'
              : '当前手机 IP（$ip）已离线；该账号仍有 ${ips.length} 条在线会话：${ips.join('、')}。这些可能是其他设备或旧 IP 会话，未自动注销；请在学校在线设备管理中核验允许的在线数量及残留会话';
        } catch (_) {
          sessionDetail = '当前设备已离线，但无法取得账号在线会话列表，请在学校认证网页的在线设备管理中核验';
        }
      }
      final advice = alreadyOnline
          ? sessionDetail!
          : basTimeout
          ? '当前接入点的校园网认证设备未及时响应。请重新连接 Student 后重试；持续失败时在学校认证网页核验或向学校网络服务报修'
          : '请检查校园网密码、验证码或同时在线设备限制';
      throw AttendanceError(
        alreadyOnline
            ? 'NETWORK_ALREADY_ONLINE'
            : basTimeout
            ? 'NETWORK_BAS_TIMEOUT'
            : 'NETWORK_LOGIN',
        '校园网登录失败（$safe）${detail.isEmpty ? '' : '：$detail'}。$advice',
      );
    }
  }

  Future<Map<String, dynamic>> _wait(String ip, bool online) async {
    var confirmed = 0;
    for (var i = 0; i < 20; i++) {
      final s = await status(ip);
      _checkAddress(s, ip);
      if (s['error'] == (online ? 'ok' : 'not_online_error')) {
        confirmed++;
        if (online || confirmed >= 2) return s;
      } else {
        confirmed = 0;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw AttendanceError(
      'NETWORK_VERIFY',
      online ? '未能确认校园网登录成功' : '未能确认校园网注销成功',
    );
  }
}

class NetworkAttendanceProvider
    implements AttendanceProvider, CampusPreparedProvider {
  final AttendanceProvider inner;
  final CampusNetwork network;
  NetworkAttendanceProvider(this.inner, {CampusNetwork? network})
    : network = network ?? CampusNetwork(AndroidCampusTransport());
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    try {
      await network.switchAccount(account, progress);
      progress(Stage.authenticating);
      await inner.login(account, progress);
    } on PlatformException catch (e) {
      throw AttendanceError(e.code, e.message ?? '校园网请求失败');
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
      await network.transport.release();
    }
  }
}
