import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/portable_archive.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native archive encryption survives transfer and rejects tampering',
    (tester) async {
      final bridge = AndroidArchiveBridge();
      final payload = PortableAccounts.encode([
        const Account('虚构测试账号', 'DUMMY-001', 'not-a-real-password'),
      ]);
      const passphrase = 'offline-transfer-passphrase-123';
      final first = await bridge.encrypt(payload, passphrase);
      final second = await bridge.encrypt(payload, passphrase);
      expect(base64Encode(first), isNot(base64Encode(second)));
      final outer = jsonDecode(utf8.decode(first)) as Map;
      expect(outer['format'], 'xmum-attendance-accounts-encrypted');
      expect(utf8.decode(first), isNot(contains('not-a-real-password')));
      final roundTrip = await bridge.decrypt(first, passphrase);
      expect(PortableAccounts.decode(roundTrip).single.campusId, 'DUMMY-001');
      await expectLater(
        bridge.decrypt(first, 'incorrect-transfer-passphrase'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'DECRYPT_FAILED',
          ),
        ),
      );
      final corrupted = Map<String, dynamic>.from(outer);
      final data = base64Decode(corrupted['data'] as String);
      data[data.length - 1] ^= 1;
      corrupted['data'] = base64Encode(data);
      await expectLater(
        bridge.decrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(corrupted))),
          passphrase,
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'DECRYPT_FAILED',
          ),
        ),
      );
    },
  );
  testWidgets(
    'Android document picker saves and opens encrypted test archive',
    (tester) async {
      final bridge = AndroidArchiveBridge();
      final payload = PortableAccounts.encode([
        const Account('文件选择器测试', 'DUMMY-FILE-001', 'fictional-password'),
      ]);
      const passphrase = 'offline-transfer-passphrase-123';
      final encrypted = await bridge.encrypt(payload, passphrase);
      final saved = await bridge.save(
        encrypted,
        'xmum-transfer-test.xmumaccounts',
      );
      expect(saved, isTrue);
      final picked = await bridge.open();
      expect(picked, isNotNull);
      final decrypted = await bridge.decrypt(picked!, passphrase);
      expect(
        PortableAccounts.decode(decrypted).single.campusId,
        'DUMMY-FILE-001',
      );
    },
  );
}
