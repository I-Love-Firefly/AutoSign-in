import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:attendance_assistant/main.dart';
import 'package:attendance_assistant/account_store.dart';
import 'package:attendance_assistant/domain.dart';

class OfflineProvider implements AttendanceProvider {
  bool closed = false;
  @override
  Future<void> login(Account a, void Function(Stage) progress) async {
    progress(Stage.navigating);
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course c, String code) async =>
      throw StateError('No mutation in this device test');
  @override
  Future<bool> verify(Course c) async => false;
  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('mobile secure storage and account interaction', (t) async {
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accountName: 'attendance_qa_only',
        accessibility: KeychainAccessibility.unlocked_this_device,
        synchronizable: false,
      ),
      aOptions: AndroidOptions(
        storageNamespace: 'attendance_qa_only',
        resetOnError: false,
      ),
    );
    final store = SecureAccountStore(storage: storage);
    await storage.delete(key: SecureAccountStore.key);
    final provider = OfflineProvider();
    try {
      await t.pumpWidget(
        AttendanceAssistant(store: store, providerFactory: () => provider),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('增加账号'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextFormField, '学生姓名 / 备注'),
        '设备测试账号',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'Campus ID'),
        'DEVICE-TEST',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, '签到系统密码'),
        'temporary-offline-test',
      );
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      // Allow native encrypted storage I/O to complete.
      for (var i = 0; i < 30 && find.text('设备测试账号').evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('设备测试账号'), findsOneWidget);
      final restored = await SecureAccountStore(
        storage: const FlutterSecureStorage(
          iOptions: IOSOptions(
            accountName: 'attendance_qa_only',
            accessibility: KeychainAccessibility.unlocked_this_device,
            synchronizable: false,
          ),
          aOptions: AndroidOptions(
            storageNamespace: 'attendance_qa_only',
            resetOnError: false,
          ),
        ),
      ).load();
      expect(restored.single.campusId, 'DEVICE-TEST');
      expect(restored.single.password, 'temporary-offline-test');
      await t.enterText(find.byKey(const ValueKey('attendance-code')), '1234');
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('设备测试账号'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('设备测试账号'));
      await t.pumpAndSettle();
      expect(find.text('本次签到记录'), findsOneWidget);
      expect(find.text('步骤记录'), findsOneWidget);
      expect(find.textContaining('当前没有可签到课程'), findsNWidgets(2));
      expect(find.text('返回列表'), findsOneWidget);
      expect(provider.closed, isTrue);
      expect(t.takeException(), isNull);
    } finally {
      await storage.delete(key: SecureAccountStore.key);
    }
  });
}
