import 'dart:async';

enum Stage {
  idle,
  networkChecking,
  networkLogout,
  networkReconnect,
  networkLogin,
  networkVerifying,
  authenticating,
  loginConfig,
  loginTicket,
  navigating,
  identity,
  syncing,
  syncWarning,
  semester,
  discovering,
  choosing,
  opening,
  filling,
  submitting,
  verifying,
  cleaning,
  success,
  failed,
}

const stageLabels = {
  Stage.idle: '等待选择账号',
  Stage.networkChecking: '检查校园网认证状态',
  Stage.networkLogout: '注销当前校园网账号',
  Stage.networkReconnect: '等待忽略并重连 Student Wi-Fi',
  Stage.networkLogin: '登录学生校园网账号',
  Stage.networkVerifying: '核验校园网账号',
  Stage.authenticating: '初始化 CAS 登录会话',
  Stage.loginConfig: '检查登录验证要求',
  Stage.loginTicket: '提交账号并获取登录票据',
  Stage.navigating: '建立教务登录会话',
  Stage.identity: '获取当前学生身份',
  Stage.syncing: '同步教务登录状态',
  Stage.syncWarning: '教务登录状态同步未完成',
  Stage.semester: '获取当前学期',
  Stage.discovering: '正在查找可签到课程',
  Stage.choosing: '选择本次课程',
  Stage.opening: '正在核对课程',
  Stage.filling: '核对签到方式与到场声明',
  Stage.submitting: '正在提交签到',
  Stage.verifying: '正在核验服务器记录',
  Stage.cleaning: '正在清理账号会话',
  Stage.success: '已完成',
  Stage.failed: '流程已停止',
};

class Account {
  final String name, campusId, password;
  final String networkPassword;
  final String acPassword;
  const Account(
    this.name,
    this.campusId,
    this.password, {
    this.networkPassword = '',
    this.acPassword = '',
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'campusId': campusId,
    'password': password,
    if (networkPassword.isNotEmpty) 'networkPassword': networkPassword,
    if (acPassword.isNotEmpty) 'acPassword': acPassword,
  };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    j['name'] as String,
    j['campusId'] as String,
    j['password'] as String,
    networkPassword: j['networkPassword'] as String? ?? '',
    acPassword: j['acPassword'] as String? ?? '',
  );
}

abstract interface class CampusPreparedProvider {}

class AttendanceError implements Exception {
  final String code, message;
  const AttendanceError(this.code, this.message);
  @override
  String toString() => message;
}

class Course {
  final Map<String, dynamic> data;
  Course(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  String value(String key) => data[key]?.toString() ?? '';
  String get id =>
      '${value('settingId')}|${value('arrangeDate')}|${value('startClassTime')}|${value('courseCode')}';
  String get name => value('openGroupName');
  String get code => value('courseCode');
  String get room => value('roomName');
  String get time => '${value('startClassTime')}–${value('endClassTime')}';
  bool get signed => value('attendanceStatus') == '1';
  bool get codeMode => value('attendanceMethod') != '1';
  DateTime? _time(String key) {
    final date = value('arrangeDate').split('T').first.split(' ').first;
    final time = value(key);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        !RegExp(r'^\d{2}:\d{2}(:\d{2})?$').hasMatch(time)) {
      return null;
    }
    return DateTime.tryParse('${date}T$time+08:00');
  }

  bool eligible(DateTime now) {
    final start = _time('startClassTime'), end = _time('endClassTime');
    return start != null &&
        end != null &&
        !now.isBefore(start) &&
        now.isBefore(end) &&
        value('settingId').isNotEmpty &&
        code.isNotEmpty &&
        name.isNotEmpty &&
        value('backGroundColor') == '1' &&
        const ['0', 'pending'].contains(value('attendanceStatus')) &&
        value('studentOtherStatus').isEmpty &&
        value('studentCourseSign') != '2' &&
        !const ['true', '1'].contains(value('teacherMarkedAbsentLocked'));
  }
}

abstract interface class AttendanceProvider {
  Future<void> login(Account account, void Function(Stage) progress);
  Future<List<Course>> courses();
  Future<void> submit(Course course, String attendanceCode);
  Future<bool> verify(Course course);
  Future<void> close();
}

class RunResult {
  final bool success, submitted;
  final String code, message;
  final Course? course;
  const RunResult(
    this.success,
    this.code,
    this.message, {
    this.course,
    this.submitted = false,
  });
}

class AttendanceOrchestrator {
  bool busy = false;
  final AttendanceProvider Function() createProvider;
  final DateTime Function() clock;
  AttendanceOrchestrator(this.createProvider, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  Future<RunResult> run(
    Account account,
    String code, {
    required void Function(Stage) progress,
    required Future<Course?> Function(List<Course>) choose,
    bool inspectOnly = false,
  }) async {
    if (busy) {
      return const RunResult(false, 'BUSY', '请等待当前学生处理完成');
    }
    if (!inspectOnly && code.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(code)) {
      return const RunResult(false, 'INVALID_CODE', '验证码请填写四位数字，或留空');
    }
    busy = true;
    AttendanceProvider? provider;
    var submitted = false;
    var verifying = false;
    try {
      provider = createProvider();
      progress(
        provider is CampusPreparedProvider
            ? Stage.networkChecking
            : Stage.authenticating,
      );
      await provider.login(account, progress);
      progress(Stage.discovering);
      final all = await provider.courses();
      final active = all.where((c) => c.eligible(clock())).toList();
      if (inspectOnly) {
        return RunResult(
          true,
          'INSPECTED',
          '登录成功；查询到 ${all.length} 门当日课程，其中 ${active.length} 门符合签到条件。未提交签到。',
        );
      }
      if (active.isEmpty) {
        throw const AttendanceError('NO_ACTIVE_CLASS', '当前没有可签到课程；未提交签到');
      }
      progress(Stage.choosing);
      final course = active.length == 1 ? active.single : await choose(active);
      if (course == null) {
        throw const AttendanceError('CANCELLED', '已取消课程选择；未提交签到');
      }
      if (!active.any((c) => c.id == course.id)) {
        throw const AttendanceError('INVALID_SELECTION', '课程选择已失效');
      }
      progress(Stage.opening);
      final current = (await provider.courses())
          .where((c) => c.id == course.id && c.eligible(clock()))
          .toList();
      if (current.length != 1) {
        throw const AttendanceError('CLASS_CHANGED', '课程状态已变化；未提交签到');
      }
      final fresh = current.single;
      progress(Stage.filling);
      if (fresh.codeMode && code.isEmpty) {
        throw const AttendanceError(
          'CODE_REQUIRED',
          '该课程要求四位验证码，请返回列表填写后重试；未提交签到',
        );
      }
      progress(Stage.submitting);
      submitted = true;
      await provider.submit(fresh, fresh.codeMode ? code : '');
      verifying = true;
      progress(Stage.verifying);
      if (!await provider.verify(fresh)) {
        throw const AttendanceError('UNKNOWN', '结果未确认，请在学校页面核验后再决定是否重试');
      }
      return RunResult(true, 'SUCCESS', '签到成功', course: fresh, submitted: true);
    } on AttendanceError catch (e) {
      if (submitted &&
          (verifying ||
              !const ['SERVER_REJECTED', 'CLASS_CHANGED'].contains(e.code))) {
        return const RunResult(
          false,
          'UNKNOWN',
          '结果未确认，请在学校页面核验后再决定是否重试',
          submitted: true,
        );
      }
      return RunResult(false, e.code, e.message, submitted: submitted);
    } catch (_) {
      return RunResult(
        false,
        submitted ? 'UNKNOWN' : 'NETWORK_ERROR',
        submitted ? '结果未确认：提交期间连接异常，请在学校页面核验' : '连接失败或服务不可用，请检查网络后重试',
        submitted: submitted,
      );
    } finally {
      progress(Stage.cleaning);
      try {
        await provider?.close();
      } finally {
        busy = false;
      }
    }
  }
}
