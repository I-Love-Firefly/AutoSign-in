import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'enterprise_network.dart';

class NetworkSettingsDialog extends StatefulWidget {
  final String mode;
  const NetworkSettingsDialog({super.key, required this.mode});
  @override
  State<NetworkSettingsDialog> createState() => _NetworkSettingsDialogState();
}

class _NetworkSettingsDialogState extends State<NetworkSettingsDialog> {
  late String mode = widget.mode;
  String phase2 = 'MSCHAPV2';
  String? error;
  bool busy = false;
  bool get isIos => defaultTargetPlatform == TargetPlatform.iOS;
  bool automaticSupported = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final p = await NativeEnterpriseTransport().preferences();
      if (mounted) {
        setState(() {
          phase2 = p['phase2'] == 'GTC' ? 'GTC' : 'MSCHAPV2';
          automaticSupported = p['automaticSupported'] != false;
        });
      }
    } on PlatformException catch (_) {}
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await NativeEnterpriseTransport.saveSettings(mode, phase2);
      if (mounted) Navigator.pop(context, mode);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.message ?? '设置保存失败';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('校园网方式'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: mode,
              isExpanded: true,
              items: const [
                DropdownMenuItem(
                  value: 'student5g',
                  child: Text('Student-5G · 系统确认'),
                ),
                DropdownMenuItem(
                  value: 'manual5g',
                  child: Text('Student-5G · 手动切换'),
                ),
                DropdownMenuItem(
                  value: 'student',
                  child: Text('Student · 旧版流程'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      if (v != null) setState(() => mode = v);
                    },
            ),
            const SizedBox(height: 12),
            Text(
              mode == 'student5g'
                  ? isIos
                        ? '应用申请更新 Student-5G 配置，你在 iPhone 系统提示中确认；连接稳定并经学校核验账号后继续。'
                        : '应用填写当前学生的配置，你在系统页面确认；重新连接并核验账号后继续。需要 Android 11 或以上。'
                  : mode == 'manual5g'
                  ? '打开系统“设置 → Wi-Fi”，修改 Student-5G 的身份和密码，断开重连后返回；应用核验账号后继续。'
                  : '使用之前的 Student 网页认证切换。连接成功不保证签到系统认可此网络。',
            ),
            if (!automaticSupported && mode == 'student5g')
              const Text('当前系统或认证设置不支持自动配置，请选择手动切换。'),
            const SizedBox(height: 8),
            const Text('使用账号中的“校园网密码”，无需每个学生分别设置认证参数。'),
            if (!isIos)
              ExpansionTile(
                title: const Text('共用认证设置'),
                children: [
                  const Text('PEAP · 系统可信证书 · xmu.edu.my'),
                  DropdownButtonFormField<String>(
                    key: ValueKey(phase2),
                    initialValue: phase2,
                    decoration: const InputDecoration(labelText: '第二阶段认证'),
                    items: const [
                      DropdownMenuItem(
                        value: 'MSCHAPV2',
                        child: Text('MSCHAPV2'),
                      ),
                      DropdownMenuItem(value: 'GTC', child: Text('GTC')),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v != null) setState(() => phase2 = v);
                          },
                  ),
                ],
              ),
            if (isIos)
              const Text('系统确认使用 PEAP 和学校服务器证书域名校验。需要 GTC 或学校描述文件时，请使用手动切换。'),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: busy ? null : save, child: const Text('保存')),
      ],
    ),
  );
}
