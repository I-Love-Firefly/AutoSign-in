import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'api_provider.dart';
import 'domain.dart';

DateTime malaysiaTime(DateTime time) =>
    time.toUtc().add(const Duration(hours: 8));
String minuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class Lesson {
  final String code, name, venue;
  final int weekday, start, end;
  final List<int> weeks;
  const Lesson({
    required this.code,
    required this.name,
    required this.venue,
    required this.weekday,
    required this.start,
    required this.end,
    required this.weeks,
  });
  String get time => '${minuteLabel(start)}–${minuteLabel(end)}';
  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'venue': venue,
    'weekday': weekday,
    'start': start,
    'end': end,
    'weeks': weeks,
  };
  factory Lesson.fromJson(Map<String, dynamic> data) {
    final lesson = Lesson(
      code: data['code'] as String,
      name: data['name'] as String,
      venue: data['venue'] as String,
      weekday: data['weekday'] as int,
      start: data['start'] as int,
      end: data['end'] as int,
      weeks: (data['weeks'] as List).cast<int>(),
    );
    if (lesson.code.isEmpty ||
        lesson.name.isEmpty ||
        lesson.venue.isEmpty ||
        lesson.weekday < 1 ||
        lesson.weekday > 7 ||
        lesson.start < 0 ||
        lesson.end > 1440 ||
        lesson.end <= lesson.start ||
        lesson.weeks.isEmpty ||
        lesson.weeks.any((w) => w < 1 || w > 53)) {
      throw const FormatException('课表数据无效');
    }
    return lesson;
  }
}

class StudentTimetable {
  final String campusId, semester;
  final DateTime fetchedAt;
  final List<Lesson> lessons;
  // Sunday starts week 1 in the school's published undergraduate calendar.
  // Unknown terms remain explicit, rather than inventing a start date.
  static const calendarSource =
      'https://www.xmu.edu.my/sites/default/files/2025-08/2026-Undergraduate-Academic-Calendar.jpg';
  static final weekOne = {'202609': DateTime.utc(2026, 9, 27)};
  StudentTimetable({
    required this.campusId,
    required this.semester,
    required this.fetchedAt,
    required List<Lesson> lessons,
  }) : lessons = List.unmodifiable(lessons);
  int? teachingWeek(DateTime now) {
    final start = weekOne[semester];
    if (start == null) return null;
    final local = malaysiaTime(now);
    final day = DateTime.utc(local.year, local.month, local.day);
    final days = day.difference(start).inDays;
    return days < 0 ? 0 : days ~/ 7 + 1;
  }

  List<Lesson> current(DateTime now) {
    final week = teachingWeek(now);
    if (week == null) return [];
    final local = malaysiaTime(now), minute = local.hour * 60 + local.minute;
    return lessons
        .where(
          (l) =>
              l.weekday == local.weekday &&
              l.weeks.contains(week) &&
              minute >= l.start &&
              minute < l.end,
        )
        .toList();
  }

  Map<String, dynamic> toJson() => {
    'campusId': campusId,
    'semester': semester,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'lessons': lessons.map((l) => l.toJson()).toList(),
  };
  factory StudentTimetable.fromJson(Map<String, dynamic> data) =>
      StudentTimetable(
        campusId: data['campusId'] as String,
        semester: data['semester'] as String,
        fetchedAt: DateTime.parse(data['fetchedAt'] as String),
        lessons: (data['lessons'] as List)
            .map((l) => Lesson.fromJson(Map<String, dynamic>.from(l)))
            .toList(),
      );
}

class TimetableParser {
  static String _text(dom.Element element) =>
      element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  static String studentId(String source) {
    final doc = html.parse(source);
    for (final row in doc.querySelectorAll('tr')) {
      final cells = row.children
          .where((c) => c.localName == 'td' || c.localName == 'th')
          .toList();
      if (cells.length >= 2 &&
          _text(cells[0]).replaceAll(RegExp(r'[\s.]'), '').toLowerCase() ==
              'studentid') {
        return _text(cells[1]);
      }
    }
    throw const AttendanceError('AC_AUTH_FAILED', 'AC 登录未成功，请检查AC系统密码或在原页面核验');
  }

  static int _minute(String value) {
    final match = RegExp(
      r'^(\d{1,2})[.:](\d{2})\s*([ap]m)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) throw const FormatException('课程时间格式不受支持');
    final hour = int.parse(match[1]!), minute = int.parse(match[2]!);
    if (hour < 1 || hour > 12 || minute > 59) {
      throw const FormatException('课程时间无效');
    }
    return (hour % 12 + (match[3]!.toLowerCase() == 'pm' ? 12 : 0)) * 60 +
        minute;
  }

  static List<int> _weeks(String value) {
    final odd = RegExp(r'\bOdd\b', caseSensitive: false).hasMatch(value);
    final even = RegExp(r'\bEven\b', caseSensitive: false).hasMatch(value);
    if (odd && even) throw const FormatException('教学周格式无效');
    var cleaned = value
        .replaceAll(
          RegExp(r'\b(Odd|Even|Week|Weeks)\b', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[\s()]'), '');
    if (cleaned.isEmpty && (odd || even)) cleaned = '1-53';
    final result = <int>{};
    for (final token in cleaned.split(RegExp(r'[,;，]'))) {
      final m = RegExp(r'^(\d{1,2})(?:[-–](\d{1,2}))?$').firstMatch(token);
      if (m == null) throw const FormatException('教学周格式不受支持');
      final first = int.parse(m[1]!), last = int.parse(m[2] ?? m[1]!);
      if (first < 1 || last > 53 || first > last) {
        throw const FormatException('教学周范围无效');
      }
      for (var w = first; w <= last; w++) {
        if ((!odd || w.isOdd) && (!even || w.isEven)) result.add(w);
      }
    }
    if (result.isEmpty) throw const FormatException('教学周为空');
    return result.toList()..sort();
  }

  static StudentTimetable parse(String source, String campusId, DateTime now) {
    final doc = html.parse(source);
    final selected = doc.querySelector('#tm_id option[selected]');
    final semester = selected?.attributes['value'] ?? '';
    if (!RegExp(r'^\d{6}$').hasMatch(semester)) {
      throw const FormatException('未找到当前学期');
    }
    dom.Element? table;
    for (final t in doc.querySelectorAll('table')) {
      final headers = t.querySelectorAll('th').map(_text).toList();
      if (headers.contains('Course Code') &&
          headers.contains('Course Name (by group)') &&
          headers.contains('Time & Venue') &&
          headers.contains('Teaching Week')) {
        table = t;
        break;
      }
    }
    if (table == null) throw const FormatException('课程列表结构已变化');
    final headers = table.querySelectorAll('th').map(_text).toList();
    final days = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    final timing = RegExp(
      r'(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(\d{1,2}[.:]\d{2}\s*[ap]m)\s*[-–]\s*(\d{1,2}[.:]\d{2}\s*[ap]m)\s*\(([^)]+)\)\s*\(\s*Weeks?\s+([^)]+)\)',
      caseSensitive: false,
    );
    final lessons = <Lesson>[];
    for (final row in table.querySelectorAll('tr')) {
      final cells = row.querySelectorAll('td');
      if (cells.isEmpty) continue;
      if (cells.length != headers.length) {
        throw const FormatException('课程字段数量已变化');
      }
      String field(String title) => _text(cells[headers.indexOf(title)]);
      final code = field('Course Code'), name = field('Course Name (by group)');
      final raw = field('Time & Venue');
      final matches = timing.allMatches(raw).toList();
      if (code.isEmpty ||
          name.isEmpty ||
          matches.isEmpty ||
          raw
              .replaceAll(timing, '')
              .replaceAll(RegExp(r'[\s,;，；]'), '')
              .isNotEmpty) {
        throw const FormatException('课程时间或地点无法完整解析');
      }
      final rowWeeks = _weeks(field('Teaching Week'));
      for (final match in matches) {
        final start = _minute(match[2]!), end = _minute(match[3]!);
        final weeks = _weeks(match[5]!).where(rowWeeks.contains).toList();
        if (end <= start || weeks.isEmpty || match[4]!.trim().isEmpty) {
          throw const FormatException('课程时间或教学周无效');
        }
        lessons.add(
          Lesson(
            code: code,
            name: name,
            venue: match[4]!.trim(),
            weekday: days.indexOf(match[1]!.toLowerCase()) + 1,
            start: start,
            end: end,
            weeks: weeks,
          ),
        );
      }
      if (lessons.length > 2000) throw const FormatException('课程数量超过上限');
    }
    lessons.sort(
      (a, b) => a.weekday == b.weekday
          ? a.start.compareTo(b.start)
          : a.weekday.compareTo(b.weekday),
    );
    return StudentTimetable(
      campusId: campusId,
      semester: semester,
      fetchedAt: now,
      lessons: lessons,
    );
  }
}

abstract interface class TimetableFetcher {
  Future<StudentTimetable> fetch(
    Account account,
    void Function(String) progress,
  );
}

class AcTimetableFetcher implements TimetableFetcher {
  final SessionTransport Function() createTransport;
  final DateTime Function() clock;
  AcTimetableFetcher({
    SessionTransport Function()? createTransport,
    DateTime Function()? clock,
  }) : createTransport =
           createTransport ??
           (() => IsolatedHttpSession(allowedHosts: const {'ac.xmu.edu.my'})),
       clock = clock ?? DateTime.now;
  static final loginPage = Uri.parse('https://ac.xmu.edu.my/index.php');
  static final login = Uri.parse(
    'https://ac.xmu.edu.my/index.php?c=Login&a=login',
  );
  static final identity = Uri.parse(
    'https://ac.xmu.edu.my/student/index.php?c=Default&a=inf',
  );
  static final courses = Uri.parse(
    'https://ac.xmu.edu.my/student/index.php?c=Default&a=Wdkc',
  );
  static final logout = Uri.parse(
    'https://ac.xmu.edu.my/student/index.php?c=Default&a=logout',
  );
  @override
  Future<StudentTimetable> fetch(
    Account account,
    void Function(String) progress,
  ) async {
    if (account.acPassword.isEmpty) {
      throw const AttendanceError('AC_PASSWORD_MISSING', '请在编辑账号中填写AC系统密码');
    }
    final transport = createTransport();
    var attempted = false;
    Future<String> read(Uri uri, {String method = 'GET', String? body}) async {
      final reply = await transport.send(
        uri,
        method: method,
        body: body,
        headers: const {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'text/html',
        },
      );
      if (reply.status != 200) {
        throw const AttendanceError('AC_SERVICE', 'AC 服务拒绝请求，请稍后重试或在原页面核验');
      }
      return reply.body;
    }

    try {
      progress('正在登录AC系统');
      final doc = html.parse(await read(loginPage));
      final form = doc.querySelector('form#form1');
      if (form == null ||
          form.attributes['method']?.toLowerCase() != 'post' ||
          loginPage.resolve(form.attributes['action'] ?? '') != login ||
          form.querySelector('input[name=username]') == null ||
          form.querySelector('input[name=password]') == null ||
          form.querySelector('select[name=user_lb] option[value=Student]') ==
              null ||
          form.querySelector('input[type=hidden]') != null) {
        throw const AttendanceError('AC_LOGIN_CHANGED', 'AC 登录表单已变化，请在原页面核验');
      }
      attempted = true;
      await read(
        login,
        method: 'POST',
        body: Uri(
          queryParameters: {
            'username': account.campusId,
            'password': account.acPassword,
            'user_lb': 'Student',
          },
        ).query,
      );
      progress('正在核对学生身份');
      if (TimetableParser.studentId(await read(identity)).toLowerCase() !=
          account.campusId.toLowerCase()) {
        throw const AttendanceError(
          'AC_IDENTITY_MISMATCH',
          'AC 返回的学生身份与所选账号不一致，未保存课表',
        );
      }
      progress('正在读取课程表');
      return TimetableParser.parse(
        await read(courses),
        account.campusId,
        clock(),
      );
    } on FormatException {
      throw const AttendanceError('AC_TIMETABLE_SCHEMA', '课程表格式无法完整识别，原有课表保留');
    } finally {
      try {
        if (attempted) {
          try {
            await transport.send(logout);
          } catch (_) {}
        }
      } finally {
        await transport.close();
      }
    }
  }
}

abstract interface class TimetableStore {
  Future<Map<String, StudentTimetable>> load();
  Future<void> save(Map<String, StudentTimetable> schedules);
}

class SecureTimetableStore implements TimetableStore {
  final FlutterSecureStorage storage;
  SecureTimetableStore({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
          );
  static const key = 'xmum_timetables_v1';
  @override
  Future<Map<String, StudentTimetable>> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map;
    return decoded.map(
      (id, value) => MapEntry(
        id.toString(),
        StudentTimetable.fromJson(Map<String, dynamic>.from(value)),
      ),
    );
  }

  @override
  Future<void> save(Map<String, StudentTimetable> schedules) => storage.write(
    key: key,
    value: jsonEncode(schedules.map((id, t) => MapEntry(id, t.toJson()))),
  );
}

class MemoryTimetableStore implements TimetableStore {
  Map<String, StudentTimetable> schedules = {};
  @override
  Future<Map<String, StudentTimetable>> load() async => Map.of(schedules);
  @override
  Future<void> save(Map<String, StudentTimetable> schedules) async {
    this.schedules = Map.of(schedules);
  }
}

class TimetableController extends ChangeNotifier {
  final TimetableStore store;
  final TimetableFetcher fetcher;
  final Map<String, StudentTimetable> schedules = {};
  final Map<String, String> statuses = {}, errors = {};
  Map<String, Account> _accounts = {};
  final List<String> _queue = [];
  bool running = false, loaded = false, _disposed = false;
  String? storageError, currentId;
  Future<void> _writes = Future.value();
  TimetableController({required this.store, required this.fetcher});
  String id(Account a) => a.campusId.toLowerCase();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize(List<Account> accounts) async {
    try {
      final cached = await store.load();
      if (_disposed) return;
      schedules.addAll(cached);
      loaded = true;
      storageError = null;
      updateAccounts(accounts);
    } catch (_) {
      storageError = '无法读取本地课表，暂不覆盖已有数据';
      _emit();
    }
  }

  Future<void> _save() {
    final write = _writes
        .catchError((_) {})
        .then((_) => store.save(Map.of(schedules)));
    _writes = write;
    return write;
  }

  void updateAccounts(List<Account> accounts) {
    final previous = _accounts;
    _accounts = {for (final a in accounts) id(a): a};
    if (!loaded) return;
    final removed = schedules.keys
        .where((key) => !_accounts.containsKey(key))
        .toList();
    for (final key in removed) {
      schedules.remove(key);
      errors.remove(key);
      statuses.remove(key);
    }
    if (removed.isNotEmpty) {
      _save().catchError((_) {
        storageError = '清理已删除账号的课表失败，请重试';
        _emit();
      });
    }
    for (final a in accounts) {
      final key = id(a);
      if (a.acPassword.isNotEmpty &&
          (!schedules.containsKey(key) ||
              (previous.containsKey(key) &&
                  previous[key]?.acPassword != a.acPassword))) {
        refresh(a);
      }
    }
    _emit();
  }

  void refresh(Account account) {
    if (_disposed || !loaded) return;
    final key = id(account);
    if (account.acPassword.isEmpty) {
      errors[key] = '请填写AC系统密码';
      _emit();
      return;
    }
    if (!_queue.contains(key)) _queue.add(key);
    statuses[key] = '等待读取课表';
    _emit();
    if (!running) _drain();
  }

  Future<void> _drain() async {
    running = true;
    _emit();
    while (_queue.isNotEmpty && !_disposed) {
      final key = _queue.removeAt(0);
      // Resolve the newest saved account when the request starts.
      final selected = _accounts[key];
      if (selected == null || selected.acPassword.isEmpty) continue;
      currentId = key;
      errors.remove(key);
      try {
        final timetable = await fetcher.fetch(selected, (message) {
          statuses[key] = message;
          _emit();
        });
        if (_disposed) break;
        if (_accounts[key]?.acPassword != selected.acPassword) continue;
        if (timetable.campusId.toLowerCase() != key) {
          throw const AttendanceError('AC_IDENTITY_MISMATCH', '学生身份不一致，未保存课表');
        }
        statuses[key] = '正在保存课程表';
        _emit();
        final old = schedules[key];
        schedules[key] = timetable;
        try {
          await _save();
        } catch (_) {
          if (old == null) {
            schedules.remove(key);
          } else {
            schedules[key] = old;
          }
          throw const AttendanceError('AC_CACHE_FAILED', '课表保存失败，原有课表保留');
        }
      } on AttendanceError catch (e) {
        errors[key] = e.message;
      } catch (_) {
        errors[key] = '课表读取失败，请检查网络后重试';
      } finally {
        statuses.remove(key);
        currentId = null;
        _emit();
      }
    }
    running = false;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
