import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:attendance_assistant/campus_network.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Wi-Fi bound status query without login or logout', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final transport = AndroidCampusTransport();
      try {
        final ip = await transport.bind();
        expect(ip, startsWith('10.'));
        final state = await transport.connectionState();
        expect(state['ip'], ip);
        expect(state['captivePortal'], isA<bool>());
        expect(state['validated'], isA<bool>());
        debugPrint(
          'Wi-Fi system state: captive_portal=${state['captivePortal']}, validated=${state['validated']}',
        );
        final status = await transport.get('/cgi-bin/rad_user_info', {
          'ip': ip,
        });
        expect(status['client_ip'] ?? status['online_ip'], ip);
        expect(status['error'], anyOf('ok', 'not_online_error'));
        final config = CampusPortalConfig.parse(
          await transport.portalPage(),
          ip,
        );
        expect(config.acId, matches(RegExp(r'^[1-9]\d*$')));
        // Network parameters only; no account identifiers or credential material.
        debugPrint(
          'Wi-Fi portal verified: ac_id=${config.acId}, mac_auth=${config.macAuth}, nas_ip=${config.nasIp.isEmpty ? "empty" : config.nasIp}, ip_matches=true',
        );
        final unauthenticated = await transport.get(
          '/v1/srun_portal_online',
          {},
        );
        expect(unauthenticated['code'], isA<int>());
        expect(unauthenticated['code'], isNot(0));
        debugPrint(
          'Online-session API: JSON decoded; unauthenticated request rejected',
        );
      } finally {
        await transport.release();
      }
    });
  });
}
