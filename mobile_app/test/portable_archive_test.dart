import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/portable_archive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native decrypt reply can be cleared when platform buffer is read-only', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(AndroidArchiveBridge.channel.name, (
      message,
    ) async {
      final payload = PortableAccounts.encode([
        const Account('Fixture', 'DUMMY-001', 'fictional-password'),
      ]);
      // The Flutter engine wraps incoming platform messages as read-only data.
      return const StandardMethodCodec()
          .encodeSuccessEnvelope(payload)
          .asUnmodifiableView();
    });
    addTearDown(
      () => messenger.setMockMessageHandler(
        AndroidArchiveBridge.channel.name,
        null,
      ),
    );
    final plaintext = await AndroidArchiveBridge().decrypt(
      Uint8List(0),
      'fictional-transfer-password',
    );
    expect(PortableAccounts.decode(plaintext).single.campusId, 'DUMMY-001');
    plaintext.fillRange(0, plaintext.length, 0);
    expect(plaintext.every((value) => value == 0), isTrue);
  });
  test('AC password is optional and survives portable archive and merges', () {
    const complete = Account(
      'Test',
      'AC001',
      'attendance',
      networkPassword: 'network',
      acPassword: 'ac-private',
    );
    final restored = PortableAccounts.decode(
      PortableAccounts.encode([complete]),
    ).single;
    expect(restored.acPassword, 'ac-private');
    expect(restored.password, 'attendance');
    expect(restored.networkPassword, 'network');
    final legacy = Account.fromJson({
      'name': 'Old',
      'campusId': 'AC001',
      'password': 'old',
    });
    expect(legacy.acPassword, '');
    expect(legacy.toJson().containsKey('acPassword'), isFalse);
    expect(
      PortableAccounts.decode(PortableAccounts.encode([legacy]))
          .single
          .acPassword,
      '',
    );
    final plan = PortableAccounts.plan([legacy], [restored]);
    expect(
      plan.apply([legacy], ImportMode.updateDuplicates).single.acPassword,
      'ac-private',
    );
    expect(plan.apply([legacy], ImportMode.addOnly).single.acPassword, '');
    expect(
      () => PortableAccounts.encode([
        Account('Too long', 'AC002', 'attendance', acPassword: 'x' * 8193),
      ]),
      throwsA(isA<FormatException>()),
    );
  });
  const old = Account('原账号', 'S001', 'old-private');
  const changed = Account('更新账号', 's001', 'new-private');
  const added = Account('新增账号', 'S002', 'added-private');

  test('portable payload round trips complete account data', () {
    final decoded = PortableAccounts.decode(
      PortableAccounts.encode([old, added]),
    );
    expect(decoded.map((a) => a.name), ['原账号', '新增账号']);
    expect(decoded.map((a) => a.password), ['old-private', 'added-private']);
  });

  test('import plan counts duplicates and keeps unrelated accounts', () {
    final plan = PortableAccounts.plan([old], [changed, added]);
    expect(plan.newCount, 1);
    expect(plan.duplicateCount, 1);
    final addOnly = plan.apply([old], ImportMode.addOnly);
    expect(addOnly.length, 2);
    expect(
      addOnly.singleWhere((a) => a.campusId.toLowerCase() == 's001').password,
      'old-private',
    );
    final update = plan.apply([old], ImportMode.updateDuplicates);
    expect(update.length, 2);
    expect(
      update.singleWhere((a) => a.campusId.toLowerCase() == 's001').password,
      'new-private',
    );
    expect(old.password, 'old-private');
  });

  test('invalid archive is rejected before any merge', () {
    expect(
      () => PortableAccounts.decode(
        Uint8List.fromList(utf8.encode('{"accounts":[]}')),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PortableAccounts.encode([old, changed]),
      throwsA(isA<FormatException>()),
    );
    final raw = utf8.encode(
      jsonEncode({
        'format': 'xmum-attendance-accounts',
        'version': 1,
        'accounts': [
          {'name': 'x', 'campusId': 'S001', 'password': ''},
        ],
      }),
    );
    expect(
      () => PortableAccounts.decode(Uint8List.fromList(raw)),
      throwsA(isA<FormatException>()),
    );
  });
}
