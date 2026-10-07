import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/main.dart';
import 'package:attendance_assistant/account_store.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/flow_progress_page.dart';
import 'package:attendance_assistant/portable_archive.dart';
import 'package:attendance_assistant/timetable.dart';

import 'domain_test.dart' show FakeProvider;
import 'timetable_test.dart' as timetable_fixture;

class MemoryStore implements AccountStore {
  List<Account> accounts = [];
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> a) async {
    accounts = a;
  }
}

class EmptyTimetableFetcher implements TimetableFetcher {
  @override
  Future<StudentTimetable> fetch(
    Account account,
    void Function(String) progress,
  ) async => StudentTimetable(
    campusId: account.campusId,
    semester: '202609',
    fetchedAt: DateTime.utc(2026, 10, 6),
    lessons: [],
  );
}

void main() {
  testWidgets(
    'cached current lesson appears on account and updates when it ends',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final store = MemoryStore()..accounts = [timetable_fixture.account];
      final cache = MemoryTimetableStore()
        ..schedules = {'test-001': timetable_fixture.table()};
      var current = timetable_fixture.now;
      await t.pumpWidget(
        AttendanceAssistant(
          store: store,
          timetableStore: cache,
          timetableFetcher: EmptyTimetableFetcher(),
          clock: () => current,
        ),
      );
      await t.pumpAndSettle();
      final lesson = find.text('正在上课\nOperating Systems (Lab)\n地点：A1#105');
      expect(lesson, findsOneWidget);
      expect(t.widget<Text>(lesson).style?.color, const Color(0xFF18733C));
      expect(find.text('TEST-001'), findsOneWidget);
      expect(find.text('签到时请连接 Student Wi-Fi，请勿使用 Student-5G'), findsOneWidget);
      current = DateTime.parse('2026-10-06T19:00:00+08:00');
      await t.pump(const Duration(seconds: 30));
      expect(lesson, findsNothing);
      expect(find.textContaining('当前无课'), findsNothing);
      expect(find.textContaining('未填写'), findsNothing);
      expect(find.textContaining('点击本人姓名开始签到'), findsNothing);
      final tile = find.ancestor(
        of: find.text('Test'),
        matching: find.byType(ListTile),
      );
      expect(
        t
            .widgetList<Text>(
              find.descendant(of: tile, matching: find.byType(Text)),
            )
            .map((text) => text.data),
        ['T', 'Test', 'TEST-001'],
      );
      await t.ensureVisible(tile);
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('查看课表'));
      await t.pumpAndSettle();
      expect(find.text('课表 · Test'), findsOneWidget);
      expect(find.textContaining('SOF201 · 17:00–19:00'), findsOneWidget);
    },
  );
  testWidgets('editor toggles each password independently', (t) async {
    await t.binding.setSurfaceSize(const Size(430, 920));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AccountEditor(
            original: Account(
              'Test',
              'TEST-001',
              'old-password',
              networkPassword: 'old-network',
              acPassword: 'old-ac-password',
            ),
          ),
        ),
      ),
    );
    final system = find.widgetWithText(TextFormField, '新密码（留空保持原密码）');
    final network = find.widgetWithText(TextFormField, '校园网新密码（留空保持原密码）');
    final ac = find.widgetWithText(TextFormField, 'AC系统密码');
    await t.enterText(system, 'fake-system-password');
    await t.enterText(network, 'fake-network-password');
    await t.enterText(ac, 'fake-ac-password');
    bool obscured(Finder field) => t
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .obscureText;
    expect(obscured(system), isTrue);
    expect(obscured(network), isTrue);
    await t.tap(find.byTooltip('显示校园网密码'));
    await t.pump();
    expect(obscured(network), isFalse);
    expect(obscured(system), isTrue);
    await t.tap(find.byTooltip('显示签到系统密码'));
    await t.pump();
    expect(obscured(system), isFalse);
    await t.tap(find.byTooltip('隐藏校园网密码'));
    await t.pump();
    expect(obscured(network), isTrue);
    expect(obscured(system), isFalse);
    await t.ensureVisible(find.byTooltip('显示AC系统密码'));
    await t.tap(find.byTooltip('显示AC系统密码'));
    await t.pump();
    expect(obscured(ac), isFalse);
    expect(obscured(network), isTrue);
    expect(obscured(system), isFalse);
    await t.tap(find.byTooltip('隐藏AC系统密码'));
    await t.pump();
    expect(obscured(ac), isTrue);
  });
  testWidgets('encrypted export and import preview update duplicate accounts', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(430, 920));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final store = MemoryStore()
      ..accounts = [const Account('旧账号', 'A001', 'old-password')];
    final archive = FakeArchiveBridge()
      ..incoming = [
        const Account('更新账号', 'a001', 'new-password'),
        const Account('新增账号', 'A002', 'another-password'),
      ];
    await t.pumpWidget(
      AttendanceAssistant(store: store, archiveBridge: archive),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('加密导出'));
    await t.pumpAndSettle();
    await t.enterText(
      find.widgetWithText(TextFormField, '传输密码'),
      'test-transfer-password-123',
    );
    await t.enterText(
      find.widgetWithText(TextFormField, '再次输入传输密码'),
      'test-transfer-password-123',
    );
    await t.tap(find.text('加密并选择保存位置'));
    await t.pumpAndSettle();
    expect(archive.savedName, endsWith('.xmumaccounts'));
    expect(utf8.decode(archive.saved!), isNot(contains('old-password')));
    await t.tap(find.text('导入账号'));
    await t.pumpAndSettle();
    await t.enterText(
      find.widgetWithText(TextFormField, '传输密码'),
      'test-transfer-password-123',
    );
    await t.tap(find.text('解密并预览'));
    await t.pumpAndSettle();
    expect(find.textContaining('新增 1 个，已有 1 个'), findsOneWidget);
    expect(store.accounts.length, 1);
    await t.tap(find.text('更新重复并导入'));
    await t.pumpAndSettle();
    expect(store.accounts.length, 2);
    expect(
      store.accounts
          .singleWhere((a) => a.campusId.toLowerCase() == 'a001')
          .password,
      'new-password',
    );
  });

  testWidgets(
    'progress page preserves completed steps and shows failure at its step',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final provider = FailingLoginProvider();
      await t.pumpWidget(
        MaterialApp(
          home: FlowProgressPage(
            account: const Account('测试学生', 'EXAMPLE', 'dummy'),
            code: '1234',
            inspectOnly: false,
            providerFactory: () => provider,
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('进行中 · 提交账号并获取登录票据'), findsOneWidget);
      final login = find.byKey(const ValueKey('flow-authenticating'));
      expect(
        find.descendant(of: login, matching: find.text('成功')),
        findsOneWidget,
      );
      provider.gate.complete();
      await t.pumpAndSettle();
      final ticket = find.byKey(const ValueKey('flow-loginTicket'));
      expect(
        find.descendant(of: ticket, matching: find.text('失败')),
        findsOneWidget,
      );
      expect(find.textContaining('测试账号密码错误'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('flow-cleaning')),
          matching: find.text('成功'),
        ),
        findsOneWidget,
      );
      expect(provider.closes, 1);
      expect(find.text('返回列表'), findsOneWidget);
    },
  );

  testWidgets('cleanup failure is shown on cleanup step instead of hanging', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: FlowProgressPage(
          account: const Account('测试学生', 'EXAMPLE', 'dummy'),
          code: '',
          inspectOnly: true,
          providerFactory: () => CleanupFailureProvider(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('清理登录会话时发生错误'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-cleaning')),
        matching: find.text('失败'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sync warning stays visible while course inspection succeeds', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: FlowProgressPage(
          account: const Account('测试学生', 'EXAMPLE', 'dummy'),
          code: '',
          inspectOnly: true,
          providerFactory: () => SyncWarningProvider(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-syncing')),
        matching: find.text('警告'),
      ),
      findsOneWidget,
    );
    await t.drag(find.byType(ListView).first, const Offset(0, 1000));
    await t.pumpAndSettle();
    expect(find.textContaining('登录成功；查询到'), findsOneWidget);
  });

  testWidgets(
    'add, persist in store, search, inspect, edit and delete account',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final store = MemoryStore();
      final p = FakeProvider()..list = [];
      await t.pumpWidget(
        AttendanceAssistant(
          store: store,
          providerFactory: () => p,
          timetableFetcher: EmptyTimetableFetcher(),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('增加账号'), findsOneWidget);
      await t.tap(find.text('增加账号'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextFormField, '学生姓名 / 备注'),
        'Test Student',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'Campus ID'),
        'TEST-001',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, '签到系统密码'),
        'private-test-password',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, '校园网密码'),
        'private-network-password',
      );
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.campusId, 'TEST-001');
      expect(store.accounts.single.networkPassword, 'private-network-password');
      expect(store.accounts.single.acPassword, '');
      expect(find.text('Test Student'), findsOneWidget);
      final tile = find.ancestor(
        of: find.text('Test Student'),
        matching: find.byType(ListTile),
      );
      expect(t.widget<ListTile>(tile).onTap, isNotNull);
      await t.enterText(find.byKey(const ValueKey('attendance-code')), '12');
      await t.pump();
      expect(t.widget<ListTile>(tile).onTap, isNull);
      await t.enterText(find.byKey(const ValueKey('attendance-code')), '1234');
      await t.pump();
      expect(t.widget<ListTile>(tile).onTap, isNotNull);
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('测试登录 / 查询（不签到）'));
      await t.pumpAndSettle();
      expect(p.submissions, 0);
      expect(find.textContaining('未提交签到'), findsOneWidget);
      await t.tap(find.text('返回列表'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('编辑账号'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextFormField, '学生姓名 / 备注'),
        'Renamed',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'AC系统密码'),
        'private-ac-password',
      );
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.password, 'private-test-password');
      expect(store.accounts.single.networkPassword, 'private-network-password');
      expect(store.accounts.single.acPassword, 'private-ac-password');
      final renamed = find.ancestor(
        of: find.text('Renamed'),
        matching: find.byType(ListTile),
      );
      await t.tap(
        find.descendant(
          of: renamed,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('编辑账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.acPassword, 'private-ac-password');
      await t.tap(
        find.descendant(
          of: renamed,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('删除账号'));
      await t.pumpAndSettle();
      expect(store.accounts, isNotEmpty);
      await t.tap(find.text('删除'));
      await t.pumpAndSettle();
      expect(store.accounts, isEmpty);
    },
  );
  testWidgets('storage load failure does not permit overwriting accounts', (
    t,
  ) async {
    await t.pumpWidget(AttendanceAssistant(store: BrokenStore()));
    await t.pumpAndSettle();
    expect(find.textContaining('无法读取安全存储'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '增加账号'))
          .onPressed,
      isNull,
    );
  });
}

class FailingLoginProvider implements AttendanceProvider {
  final gate = Completer<void>();
  int closes = 0;
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    progress(Stage.loginConfig);
    progress(Stage.loginTicket);
    await gate.future;
    throw const AttendanceError('AUTH_FAILED', '测试账号密码错误');
  }

  @override
  Future<List<Course>> courses() async => throw StateError('not reached');
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async {
    closes++;
  }
}

class BrokenStore implements AccountStore {
  @override
  Future<List<Account>> load() async => throw Exception('unavailable');
  @override
  Future<void> save(List<Account> accounts) async =>
      throw StateError('must not overwrite');
}

class FakeArchiveBridge implements ArchiveBridge {
  List<Account> incoming = [];
  Uint8List? saved;
  String? savedName;
  @override
  Future<Uint8List> encrypt(Uint8List plaintext, String passphrase) async {
    expect(passphrase, 'test-transfer-password-123');
    expect(PortableAccounts.decode(plaintext).length, 1);
    return Uint8List.fromList(utf8.encode('encrypted-fixture'));
  }

  @override
  Future<Uint8List> decrypt(Uint8List archive, String passphrase) async {
    expect(passphrase, 'test-transfer-password-123');
    return PortableAccounts.encode(incoming);
  }

  @override
  Future<Uint8List?> open() async =>
      Uint8List.fromList(utf8.encode('encrypted-fixture'));
  @override
  Future<bool> save(Uint8List archive, String filename) async {
    saved = archive;
    savedName = filename;
    return true;
  }
}

class CleanupFailureProvider implements AttendanceProvider {
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {}
  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async => throw StateError('cleanup unavailable');
}

class SyncWarningProvider implements AttendanceProvider {
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    progress(Stage.syncing);
    progress(Stage.syncWarning);
    progress(Stage.semester);
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async {}
}
