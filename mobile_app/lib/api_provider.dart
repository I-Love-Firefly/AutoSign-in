import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/services.dart';

import 'domain.dart';

class HttpReply {
  final int status;
  final String body;
  const HttpReply(this.status, this.body);
  Map<String, dynamic> get json {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      /* Report a fixed, non-sensitive diagnostic. */
    }
    throw const AttendanceError(
      'SCHEMA_CHANGED',
      '服务器未返回预期数据，可能需要重新登录或页面接口已更新',
    );
  }
}

abstract interface class SessionTransport {
  Future<HttpReply> send(
    Uri uri, {
    String method,
    String? body,
    Map<String, String> headers,
  });
  Future<void> close();
}

class IsolatedHttpSession implements SessionTransport {
  final Set<String> allowedHosts;
  final bool _nativeIos;
  static int _nextSession = 0;
  final String _sessionId = 'school-${_nextSession++}';
  static const _channel = MethodChannel('com.xmum.attendance_assistant/http');
  bool _nativeStarted = false;
  IsolatedHttpSession({
    Set<String> allowedHosts = const {'cas.xmu.edu.my', 'acad.xmu.edu.my'},
    bool? useNativeIos,
  }) : allowedHosts = Set.unmodifiable(allowedHosts),
       _nativeIos = useNativeIos ?? Platform.isIOS;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 18);
  final CookieJar _cookies = CookieJar();
  bool _closed = false;
  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.port == 443) &&
      const ['cas.xmu.edu.my', 'acad.xmu.edu.my'].contains(uri.host);
  static Uri secureRedirectTarget(Uri target) {
    // The school's CAS exchange can advertise an HTTP callback behind a proxy.
    // Upgrade only the two known school origins; never send a request over HTTP.
    if (target.scheme == 'http' &&
        target.port == 80 &&
        target.userInfo.isEmpty &&
        const ['cas.xmu.edu.my', 'acad.xmu.edu.my'].contains(target.host)) {
      return target.replace(scheme: 'https', port: 443);
    }
    return target;
  }

  static String blockedAddressReason(Uri uri) {
    if (uri.scheme != 'https') {
      return '登录跳转要求使用非 HTTPS 地址（${uri.host}），流程已停止';
    }
    if (uri.userInfo.isNotEmpty) return '登录跳转地址包含用户信息，流程已停止';
    if (uri.port != 443) return '登录跳转要求使用非标准端口，流程已停止';
    return '登录跳转到未允许的站点 ${uri.host}，流程已停止';
  }

  @override
  Future<HttpReply> send(
    Uri uri, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
  }) async {
    try {
      return await _send(
        uri,
        method,
        body,
        headers,
      ).timeout(const Duration(seconds: 35));
    } on TimeoutException {
      _closed = true;
      _client.close(force: true);
      if (_nativeStarted) {
        await _channel.invokeMethod<void>('close', {'session': _sessionId});
      }
      throw const AttendanceError('NETWORK_ERROR', '网络请求超时');
    }
  }

  Future<HttpReply> _send(
    Uri uri,
    String method,
    String? body,
    Map<String, String> headers,
  ) async {
    for (var hop = 0; hop < 10; hop++) {
      if (_closed) {
        throw const AttendanceError('UNEXPECTED_REDIRECT', '登录会话已关闭，流程已停止');
      }
      if (!(uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          uri.port == 443 &&
          allowedHosts.contains(uri.host))) {
        throw AttendanceError('UNEXPECTED_REDIRECT', blockedAddressReason(uri));
      }
      late final int status;
      late final String text;
      String? location;
      if (_nativeIos) {
        _nativeStarted = true;
        try {
          final reply = await _channel.invokeMapMethod<String, dynamic>(
            'send',
            {
              'session': _sessionId,
              'url': uri.toString(),
              'method': method,
              'body': body,
              'headers': headers,
              'allowedHosts': allowedHosts.toList(),
              'wifiOnly': allowedHosts.contains('acad.xmu.edu.my'),
            },
          );
          if (reply?['status'] is! int || reply?['body'] is! String) {
            throw const AttendanceError('SCHEMA_CHANGED', '网络响应格式不受支持');
          }
          status = reply!['status'] as int;
          text = reply['body'] as String;
          location = reply['location'] as String?;
        } on PlatformException catch (e) {
          throw AttendanceError(e.code, e.message ?? '学校网络请求失败');
        }
      } else {
        final request = await _client.openUrl(method, uri);
        request.followRedirects = false;
        request.headers.set('Accept', 'application/json, text/plain, */*');
        request.headers.set('User-Agent', 'XMUMAttendanceAssistant/0.8');
        headers.forEach(request.headers.set);
        request.cookies.addAll(await _cookies.loadForRequest(uri));
        if (body != null) request.write(body);
        final response = await request.close();
        await _cookies.saveFromResponse(uri, response.cookies);
        text = await utf8.decoder.bind(response).join();
        status = response.statusCode;
        location = response.headers.value(HttpHeaders.locationHeader);
      }
      if (const [301, 302, 303, 307, 308].contains(status)) {
        if (location == null) {
          throw const AttendanceError('SCHEMA_CHANGED', '登录跳转缺少目标地址');
        }
        final next = secureRedirectTarget(uri.resolve(location));
        // Never forward a password, Authorization, or POST payload across redirects.
        if (method != 'GET' || next.host != uri.host) {
          headers = {};
        }
        if (method != 'GET' && const [307, 308].contains(status)) {
          throw const AttendanceError(
            'UNEXPECTED_REDIRECT',
            '服务器要求重发登录或提交数据，已停止自动重发',
          );
        }
        method = 'GET';
        body = null;
        uri = next;
        continue;
      }
      if (status >= 500) {
        throw const AttendanceError('SERVICE_UNAVAILABLE', '学校服务暂时不可用');
      }
      return HttpReply(status, text);
    }
    throw const AttendanceError('AUTH_FAILED', '登录跳转次数过多');
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
    await _cookies.deleteAll();
    if (_nativeStarted) {
      await _channel.invokeMethod<void>('close', {'session': _sessionId});
    }
  }
}

/// Compatibility with the publicly served CAS RSA routine (little-endian,
/// zero-padded 126-byte blocks). This is the site's protocol, not new crypto.
String encryptCasPassword(String password) {
  const modulus =
      '00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136eaeb670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431604bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117e7b1';
  final n = BigInt.parse(modulus, radix: 16), exponent = BigInt.from(65537);
  final units = password.replaceAll(RegExp(r'\s+'), '').codeUnits;
  if (units.isEmpty || units.any((c) => c > 255)) {
    throw const AttendanceError('UNSUPPORTED_PASSWORD', '密码字符格式需通过学校页面核验');
  }
  final blockSize = 2 * ((n.bitLength - 1) ~/ 16);
  final result = <String>[];
  for (var offset = 0; offset < units.length; offset += blockSize) {
    var value = BigInt.zero;
    for (var j = 0; j < blockSize && offset + j < units.length; j++) {
      value += BigInt.from(units[offset + j]) << (j * 8);
    }
    final encoded = value.modPow(exponent, n).toRadixString(16);
    result.add(encoded.padLeft(((encoded.length + 3) ~/ 4) * 4, '0'));
  }
  return result.join(' ');
}

class ApiAttendanceProvider implements AttendanceProvider {
  final SessionTransport transport;
  final DateTime Function() clock;
  final Future<void> Function(Duration) wait;
  Map<String, dynamic> _user = {};
  final List<String> _secrets = [];
  String? _tgt;
  String? _semester;
  ApiAttendanceProvider({
    SessionTransport? transport,
    DateTime Function()? clock,
    Future<void> Function(Duration)? wait,
  }) : transport = transport ?? IsolatedHttpSession(),
       clock = clock ?? DateTime.now,
       wait = wait ?? ((duration) => Future<void>.delayed(duration));
  static final base = Uri.parse('https://acad.xmu.edu.my/mobile/');
  static const service = 'https://acad.xmu.edu.my/mobile/shiro-cas';
  static const queryPath = 'api/jwxt-ktkq/mobile/attendanceStudent/query/opt';
  static const submitPath =
      'api/jwxt-ktkq/mobile/attendanceStudent/updateStuAttendance';
  Map<String, String> get _headers => {
    'originFlag': '1',
    'gatewayAppId': 'ly-cea-mlxyjw-mobile',
    'X-Requested-With': 'XMLHttpRequest',
    'Content-Type': 'application/json;charset=utf-8',
    if (_user['tokenId'] != null) 'Authorization': '${_user['tokenId']}',
    for (final field in {
      'userId': 'loginUserId',
      'orgId': 'loginUserOrgId',
      'userName': 'loginUserName',
      'departmentId': 'loginUserDepId',
      'departmentName': 'loginUserDepName',
    }.entries)
      if (_user[field.key] != null)
        field.value: Uri.encodeComponent('${_user[field.key]}'),
  };
  String _message(dynamic value, String fallback) {
    var text = value is String ? value : fallback;
    if (const ['ok', 'success', ''].contains(text.trim().toLowerCase())) {
      text = fallback;
    }
    for (final secret in _secrets.where((s) => s.isNotEmpty)) {
      text = text
          .replaceAll(secret, '[已隐藏]')
          .replaceAll(Uri.encodeComponent(secret), '[已隐藏]');
    }
    text = text.replaceAll(
      RegExp(r'(ST-|TGT-|Bearer\s+)\S+', caseSensitive: false),
      '[认证信息已隐藏]',
    );
    return text.length > 240 ? fallback : text;
  }

  Map<String, dynamic> _accepted(HttpReply response) {
    if (response.status == 401 || response.status == 403) {
      throw const AttendanceError('AUTH_FAILED', '登录已失效或当前账号无权限');
    }
    if (response.status < 200 || response.status >= 300) {
      throw AttendanceError(
        'SERVER_REJECTED',
        '学校服务拒绝请求（HTTP ${response.status}），请在原页面核验',
      );
    }
    final j = response.json, meta = response.json['meta'];
    if (meta is! Map ||
        (meta['statusCode']?.toString() != '200' && meta['success'] != true) ||
        meta['success'] == false) {
      throw AttendanceError(
        'SERVER_REJECTED',
        _message(meta is Map ? meta['message'] : null, '学校服务拒绝请求'),
      );
    }
    return j;
  }

  Future<Map<String, dynamic>> _api(
    String path, {
    String method = 'GET',
    dynamic data,
    Map<String, String> query = const {},
  }) async {
    final uri = base
        .resolve(path)
        .replace(
          queryParameters: {
            ...query,
            '_t': '${clock().millisecondsSinceEpoch ~/ 1000}',
          },
        );
    return _accepted(
      await transport.send(
        uri,
        method: method,
        body: method == 'POST' ? (data == null ? '' : jsonEncode(data)) : null,
        headers: _headers,
      ),
    );
  }

  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    _secrets.add(account.password);
    await transport.send(
      Uri.parse('https://cas.xmu.edu.my/lyuapServer/login')
          .replace(queryParameters: {'service': service}),
    );
    progress(Stage.loginConfig);
    final configReply = await transport.send(
      Uri.parse('https://cas.xmu.edu.my/lyuapServer/loginType'),
    );
    final config = _accepted(configReply)['data'];
    if (config is! Map) {
      throw const AttendanceError('SCHEMA_CHANGED', 'CAS 登录配置格式已变化');
    }
    if (config['isVerifyCode']?.toString() == '1' ||
        config['isTwoVerify']?.toString() == '1') {
      throw const AttendanceError(
        'INTERACTION_REQUIRED',
        '学校要求验证码或二次验证，请在学校页面完成登录',
      );
    }
    final password = encryptCasPassword(account.password);
    _secrets.add(password);
    progress(Stage.loginTicket);
    final response = await transport.send(
      Uri.parse('https://cas.xmu.edu.my/lyuapServer/v1/tickets'),
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
      body: Uri(
        queryParameters: {
          'username': account.campusId.replaceAll(RegExp(r'\s+'), ''),
          'password': password,
          'service': service,
        },
      ).query,
    );
    final auth = response.json;
    final nested = auth['data'];
    if (nested is Map && nested['code'] != null) {
      final errorCode = nested['code'].toString();
      const messages = {
        'PASSERROR': '账号或密码错误',
        'NOUSER': '该账号不存在',
        'USERLOCK': '账号被锁定，请联系学校',
        'USERNOTONLY': '账号不唯一，请在学校页面处理',
        'CODEFALSE': 'CAS 要求图形验证码',
        'NOAUTHORIZATION': '该账号无权访问教务系统',
        'NOREGISTER': '该账号尚未开通服务',
      };
      throw AttendanceError(
        'AUTH_FAILED',
        messages[errorCode] ?? '学校要求额外登录步骤（绑定、验证或修改密码），请在学校页面完成',
      );
    }
    final ticket = auth['ticket'];
    if (response.status != 200 && response.status != 201 ||
        ticket is! String ||
        !ticket.startsWith('ST-')) {
      throw const AttendanceError('AUTH_FAILED', '登录未获得有效教务票据，请检查账号或在学校页面完成验证');
    }
    _secrets.add(ticket);
    _tgt = auth['tgt'] is String ? auth['tgt'] as String : null;
    if (_tgt != null) {
      _secrets.add(_tgt!);
    }
    progress(Stage.navigating);
    await transport.send(
      Uri.parse(service).replace(queryParameters: {'ticket': ticket}),
    );
    progress(Stage.identity);
    final identity = (await _api('tryLoginUserInfo', method: 'POST'))['data'];
    if (identity is! Map ||
        identity['userId'] == null ||
        identity['tokenId'] == null) {
      throw const AttendanceError('AUTH_FAILED', '未能建立教务登录会话');
    }
    _user = Map<String, dynamic>.from(identity);
    _secrets.add('${_user['tokenId']}');
    progress(Stage.syncing);
    try {
      await _api(
        'api/jwxt-jcsj/login-user/sync-list',
        method: 'POST',
        data: [_user['loginId'] ?? _user['userId']],
        query: {
          'type': 'login',
          'loginStatus': 'success',
          'systemName': 'Credit System Comprehensive Educational Management System - Mobile',
        },
      );
    } on AttendanceError catch (error) {
      // The original mobile tryLoginUserInfo path warns on a failed sync and
      // continues. Keep mandatory semester/course requests as the permission gate.
      if (error.code != 'SERVER_REJECTED') rethrow;
      progress(Stage.syncWarning);
    }
    progress(Stage.semester);
    final semester = (await _api(
      'api/jwxt-jcsj/common/semester/selectCurrentXnXq',
    ))['data'];
    if (semester is! Map || semester['semester'] == null) {
      throw const AttendanceError('SCHEMA_CHANGED', '无法确认当前学期');
    }
    _semester = semester['semester'].toString();
  }

  @override
  Future<List<Course>> courses() async {
    if (_user.isEmpty || _semester == null) {
      throw const AttendanceError('AUTH_FAILED', '请先登录');
    }
    final malaysia = clock().toUtc().add(const Duration(hours: 8));
    final date = malaysia.toIso8601String().substring(0, 10);
    final data = (await _api(
      queryPath,
      method: 'POST',
      data: {
        'pageNo': 1,
        'pageSize': 1000,
        'param': {'arrangeDate': date, 'semesterId': _semester},
      },
    ))['data'];
    if (data is! Map ||
        data['records'] is! List ||
        (data['total'] is num && data['total'] > 1000)) {
      throw const AttendanceError('SCHEMA_CHANGED', '课程列表格式已变化或数据不完整，已停止');
    }
    return (data['records'] as List).map((e) {
      if (e is! Map) {
        throw const AttendanceError('SCHEMA_CHANGED', '课程记录格式异常');
      }
      return Course(Map<String, dynamic>.from(e));
    }).toList();
  }

  @override
  Future<void> submit(Course course, String attendanceCode) async {
    if (!course.eligible(clock()) || _user['userId'] == null) {
      throw const AttendanceError('CLASS_CHANGED', '验证码或课程状态不满足要求，未提交');
    }
    if (course.codeMode && !RegExp(r'^\d{4}$').hasMatch(attendanceCode)) {
      throw const AttendanceError('CODE_REQUIRED', '该课程要求四位数字验证码，未提交');
    }
    if (course.codeMode) _secrets.add(attendanceCode);
    final reply = await _api(
      submitPath,
      method: 'POST',
      data: {
        'settingId': course.data['settingId'],
        'roomNumber': course.data['roomNumber'],
        'studentId': _user['userId'],
        if (course.codeMode) 'quickResponse': attendanceCode,
        'attendanceStatus': '1',
        'modifySource': '移动端学生签到',
      },
    );
    if (reply['data'] != true) {
      throw AttendanceError(
        'SERVER_REJECTED',
        _message((reply['meta'] as Map?)?['message'], '服务器未确认签到成功'),
      );
    }
  }

  @override
  Future<bool> verify(Course course) async {
    // Allow the school record to propagate before the first read and each poll.
    // Only re-read the record; never repeat the attendance submission.
    for (var i = 0; i < 5; i++) {
      await wait(const Duration(seconds: 5));
      final found = (await courses()).where((c) => c.id == course.id).toList();
      if (found.length == 1 && found.single.signed) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> close() async {
    try {
      if (_user.isNotEmpty) {
        try {
          await transport.send(base.resolve('logout'), headers: _headers);
        } catch (_) {
          /* Local destruction still required. */
        }
      }
      if (_tgt != null) {
        try {
          await transport.send(
            Uri.parse('https://cas.xmu.edu.my/lyuapServer/uniLogout')
                .replace(queryParameters: {'tgt': _tgt!}),
          );
        } catch (_) {
          /* Do not retain credentials after failure. */
        }
      }
    } finally {
      _user.clear();
      _secrets.clear();
      _semester = null;
      _tgt = null;
      await transport.close();
    }
  }
}
