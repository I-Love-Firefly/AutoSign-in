import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_store.dart';
import 'api_provider.dart';
import 'domain.dart';
import 'campus_network.dart';
import 'enterprise_network.dart';
import 'network_settings_dialog.dart';
import 'flow_progress_page.dart';
import 'portable_archive.dart';
import 'timetable.dart';
import 'timetable_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AttendanceAssistant());
}

class AttendanceAssistant extends StatelessWidget {
  final AccountStore? store;
  final AttendanceProvider Function()? providerFactory;
  final ArchiveBridge? archiveBridge;
  final TimetableStore? timetableStore;
  final TimetableFetcher? timetableFetcher;
  final DateTime Function()? clock;
  const AttendanceAssistant({
    super.key,
    this.store,
    this.providerFactory,
    this.archiveBridge,
    this.timetableStore,
    this.timetableFetcher,
    this.clock,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '签到助手',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2857DC)),
      scaffoldBackgroundColor: const Color(0xFFF5F7FC),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFF1F4FA),
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
    ),
    home: HomePage(
      store: store ?? SecureAccountStore(),
      providerFactory:
          providerFactory ??
          () => AdaptiveNetworkProvider(ApiAttendanceProvider()),
      enableNetworkSettings: providerFactory == null,
      archiveBridge: archiveBridge ?? AndroidArchiveBridge(),
      timetableStore:
          timetableStore ??
          (store == null ? SecureTimetableStore() : MemoryTimetableStore()),
      timetableFetcher: timetableFetcher ?? AcTimetableFetcher(),
      clock: clock ?? DateTime.now,
    ),
  );
}

class HomePage extends StatefulWidget {
  final bool enableNetworkSettings;
  final AccountStore store;
  final AttendanceProvider Function() providerFactory;
  final ArchiveBridge archiveBridge;
  final TimetableStore timetableStore;
  final TimetableFetcher timetableFetcher;
  final DateTime Function() clock;
  const HomePage({
    super.key,
    this.enableNetworkSettings = false,
    required this.store,
    required this.providerFactory,
    required this.archiveBridge,
    required this.timetableStore,
    required this.timetableFetcher,
    required this.clock,
  });
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _code = TextEditingController(), _search = TextEditingController();
  List<Account> _accounts = [];
  final List<String> _events = [];
  bool _loading = true, _saving = false, _busy = false;
  String? _storageError;
  String _networkMode = 'student5g';
  late final TimetableController _timetables;
  late final Timer _clockTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timetables = TimetableController(
      store: widget.timetableStore,
      fetcher: widget.timetableFetcher,
    )..addListener(_refreshView);
    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshView(),
    );
    _load();
    if (widget.enableNetworkSettings) _loadNetworkMode();
  }

  Future<void> _loadNetworkMode() async {
    try {
      final settings = await AndroidEnterpriseTransport().preferences();
      if (mounted) {
        setState(
          () => _networkMode = settings['mode'] as String? ?? 'student5g',
        );
      }
    } on PlatformException catch (_) {}
  }

  Future<void> _networkSettings() async {
    if (_busy || _saving) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (_) => NetworkSettingsDialog(mode: _networkMode),
    );
    if (mounted && mode != null) setState(() => _networkMode = mode);
  }

  Future<void> _load() async {
    try {
      final accounts = await widget.store.load();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          _loading = false;
          _storageError = null;
        });
        unawaited(_timetables.initialize(accounts));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _storageError = '无法读取安全存储，请重试。不会覆盖已有账号。';
        });
      }
    }
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _timetables.removeListener(_refreshView);
    _timetables.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _code.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshView();
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        !_busy) {
      _code.clear();
      if (mounted) {
        setState(() {});
      }
    }
  }

  bool get ready =>
      (_code.text.isEmpty || RegExp(r'^\d{4}$').hasMatch(_code.text)) &&
      !_busy &&
      !_saving &&
      !_timetables.running;
  void _refreshView() {
    if (mounted) setState(() {});
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _save(List<Account> next) async {
    setState(() => _saving = true);
    try {
      await widget.store.save(next);
      if (mounted) {
        setState(() => _accounts = next);
        _timetables.updateAccounts(next);
      }
    } catch (_) {
      _notice('保存失败，原账号未被替换，请重试');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _edit([Account? original]) async {
    final next = await showDialog<Account>(
      context: context,
      builder: (_) => AccountEditor(original: original),
    );
    if (next == null || !mounted) {
      return;
    }
    final duplicate = _accounts.any(
      (a) =>
          a.campusId.toLowerCase() == next.campusId.toLowerCase() &&
          a != original,
    );
    if (duplicate) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('账号已存在'),
          content: const Text('是否使用刚填写的信息更新该 Campus ID？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('更新账号'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) {
        return;
      }
    }
    await _save(
      [
        ..._accounts.where(
          (a) =>
              a != original &&
              a.campusId.toLowerCase() != next.campusId.toLowerCase(),
        ),
        next,
      ]..sort((a, b) => a.name.compareTo(b.name)),
    );
  }

  Future<void> _delete(Account account) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号？'),
        content: Text('将从本机移除 ${account.name} 的账号与密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _save(_accounts.where((a) => a != account).toList());
    }
  }

  Future<void> _exportAccounts() async {
    if (_busy || _saving || _storageError != null || _accounts.isEmpty) return;
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const ArchivePasswordDialog(exporting: true),
    );
    if (passphrase == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final plaintext = PortableAccounts.encode(_accounts);
      late final Uint8List archive;
      try {
        archive = await widget.archiveBridge.encrypt(plaintext, passphrase);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
      final now = DateTime.now();
      final date =
          '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final saved = await widget.archiveBridge.save(
        archive,
        'xmum-accounts-$date.xmumaccounts',
      );
      if (saved) _notice('已加密导出 ${_accounts.length} 个账号');
    } on FormatException catch (error) {
      _notice(error.message);
    } on PlatformException catch (error) {
      _notice(error.message ?? '导出失败，请重试');
    } catch (_) {
      _notice('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importAccounts() async {
    if (_busy || _saving || _storageError != null) return;
    setState(() => _saving = true);
    try {
      final archive = await widget.archiveBridge.open();
      if (archive == null || !mounted) return;
      if (archive.length > PortableAccounts.maxBytes) {
        throw const FormatException('账号文件过大');
      }
      final passphrase = await showDialog<String>(
        context: context,
        builder: (_) => const ArchivePasswordDialog(exporting: false),
      );
      if (passphrase == null || !mounted) return;
      final plaintext = await widget.archiveBridge.decrypt(archive, passphrase);
      late final List<Account> incoming;
      try {
        incoming = PortableAccounts.decode(plaintext);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
      if (incoming.isEmpty) {
        _notice('文件中没有账号');
        return;
      }
      if (!mounted) return;
      final plan = PortableAccounts.plan(_accounts, incoming);
      final mode = await showDialog<ImportMode>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认导入账号'),
          content: Text(
            '文件包含 ${incoming.length} 个账号。\n'
            '新增 ${plan.newCount} 个，已有 ${plan.duplicateCount} 个相同 Campus ID。\n'
            '现有的其他账号会保留。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ImportMode.addOnly),
              child: const Text('仅添加新账号'),
            ),
            if (plan.duplicateCount > 0)
              FilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, ImportMode.updateDuplicates),
                child: const Text('更新重复并导入'),
              ),
          ],
        ),
      );
      if (mode == null || !mounted) return;
      final merged = plan.apply(_accounts, mode);
      await widget.store.save(merged);
      if (mounted) {
        setState(() => _accounts = merged);
        _timetables.updateAccounts(merged);
        _notice('导入完成，当前共 ${merged.length} 个账号');
      }
    } on FormatException catch (error) {
      _notice(error.message);
    } on PlatformException catch (error) {
      _notice(error.message ?? '导入失败，请检查文件和传输密码');
    } catch (_) {
      _notice('导入失败，原账号未被修改');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _run(Account account, {bool inspect = false}) async {
    if (_busy || _saving || _timetables.running || (!inspect && !ready)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      final result = await Navigator.push<RunResult>(
        context,
        MaterialPageRoute(
          builder: (_) => FlowProgressPage(
            account: account,
            code: _code.text,
            inspectOnly: inspect,
            providerFactory: widget.providerFactory,
          ),
        ),
      );
      if (!mounted || result == null) return;
      final now = DateTime.now();
      setState(() {
        _events.insert(
          0,
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} · ${result.code}',
        );
        if (_events.length > 30) _events.removeLast();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspectNetworkSessions(Account account) async {
    if (_busy || _saving || _timetables.running) return;
    setState(() => _busy = true);
    final transport = AndroidCampusTransport();
    Future<CampusSessionReport> query() async {
      try {
        return await CampusNetwork(transport).inspectSessions(account);
      } finally {
        await transport.release();
      }
    }

    final result = query();
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => FutureBuilder<CampusSessionReport>(
          future: result,
          builder: (_, snapshot) {
            final done = snapshot.connectionState == ConnectionState.done;
            final report = snapshot.data;
            final error = snapshot.error;
            return PopScope(
              canPop: done,
              child: AlertDialog(
                title: Text('校园网在线会话 · ${account.name}'),
                content: !done
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('正在查询学校记录，不切换账号'),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Text(
                          report == null
                              ? error is AttendanceError
                                    ? error.message
                                    : '无法查询校园网会话，请检查 Student 连接后重试'
                              : '当前手机 IP：${report.deviceIp}\n手机认证状态：${report.deviceOnline ? "在线" : "离线"}（按 IP 查询）\n\n'
                                    '该账号在线会话：${report.accountIps.length} 条\n'
                                    '${report.accountIps.isEmpty ? "学校列表中没有在线会话" : report.accountIps.map((ip) => "$ip${ip == report.deviceIp ? '（当前手机 IP）' : '（其他或旧 IP）'}").join('\n')}\n\n'
                                    '仅查询，未注销任何设备。其他 IP 也可能是本机旧会话，需在学校在线设备管理中核验。',
                        ),
                      ),
                actions: [
                  TextButton(
                    onPressed: done ? () => Navigator.pop(ctx) : null,
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPortal() async {
    // Deliberately passes no application session or credentials to the browser.
    try {
      final ok = await launchUrl(
        Uri.parse('https://acad.xmu.edu.my/mobile/#/student/myAttendance'),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        _notice('无法打开浏览器');
      }
    } catch (_) {
      _notice('无法打开浏览器');
    }
  }

  Future<void> _exit() async {
    if (_busy) {
      return;
    }
    _code.clear();
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _accounts
        .where(
          (a) => '${a.name} ${a.campusId}'.toLowerCase().contains(
            _search.text.toLowerCase(),
          ),
        )
        .toList();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '签到助手',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          backgroundColor: const Color(0xFFF5F7FC),
          actions: [
            IconButton(
              onPressed: _busy ? null : _openPortal,
              tooltip: '学校原页面',
              icon: const Icon(Icons.open_in_browser),
            ),
            PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (value) {
                if (value == 'network') _networkSettings();
                if (value == 'exit') {
                  _exit();
                }
                if (value == 'log') {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('本次运行记录'),
                      content: SingleChildScrollView(
                        child: Text(
                          _events.isEmpty
                              ? '暂无记录。仅记录时间与结果类型，不含账号凭据。'
                              : _events.join('\n'),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                if (widget.enableNetworkSettings)
                  const PopupMenuItem(value: 'network', child: Text('校园网方式')),
                const PopupMenuItem(value: 'log', child: Text('运行记录')),
                const PopupMenuItem(value: 'exit', child: Text('清空验证码并退出')),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFF193C9B),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '请输入验证码（可选）',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '有验证码时填写 · 无验证码可直接选择本人账号',
                                  style: TextStyle(
                                    color: Color(0xFFD2DFFF),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        key: const ValueKey('attendance-code'),
                                        controller: _code,
                                        enabled: !_busy,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter
                                              .digitsOnly,
                                          LengthLimitingTextInputFormatter(4),
                                        ],
                                        onChanged: (_) => setState(() {}),
                                        style: const TextStyle(
                                          fontSize: 30,
                                          letterSpacing: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        decoration: const InputDecoration(
                                          hintText: '0000',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      onPressed: _busy
                                          ? null
                                          : () => setState(() => _code.clear()),
                                      icon: const Icon(Icons.refresh),
                                      tooltip: '清空 / 更换验证码',
                                      color: Colors.white,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.wifi,
                                size: 20,
                                color: Color(0xFF193C9B),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _networkMode == 'student'
                                      ? '当前使用 Student 旧版切换；该网络可能无法通过签到校验'
                                      : '签到优先使用 Student-5G；切换账号需系统确认或手动修改网络配置',
                                  style: const TextStyle(height: 1.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_storageError != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Column(
                              children: [
                                Text(
                                  _storageError!,
                                  style: const TextStyle(color: Colors.red),
                                ),
                                TextButton(
                                  onPressed: _load,
                                  child: const Text('重试读取'),
                                ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '学生账号  ${_accounts.length}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              FilledButton.icon(
                                onPressed:
                                    _busy || _saving || _storageError != null
                                    ? null
                                    : () => _edit(),
                                icon: const Icon(Icons.person_add_alt_1),
                                label: const Text('增加账号'),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      _busy || _saving || _storageError != null
                                      ? null
                                      : _importAccounts,
                                  icon: const Icon(Icons.file_open_outlined),
                                  label: const Text('导入账号'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      _busy ||
                                          _saving ||
                                          _storageError != null ||
                                          _accounts.isEmpty
                                      ? null
                                      : _exportAccounts,
                                  icon: const Icon(Icons.save_alt),
                                  label: const Text('加密导出'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              hintText: '搜索姓名或 Campus ID',
                              prefixIcon: Icon(Icons.search),
                            ),
                          ),
                        ),
                        SizedBox(
                          child: _accounts.isEmpty
                              ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.people_outline,
                                          size: 56,
                                          color: Color(0xFF8B9BBC),
                                        ),
                                        SizedBox(height: 16),
                                        Text(
                                          '先增加一个学生账号',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        SizedBox(height: 8),
                                        Text(
                                          '账号与密码加密保存在本机\n不会上传到第三方服务',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.black54,
                                            height: 1.6,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : filtered.isEmpty
                              ? const Center(child: Text('没有匹配的账号'))
                              : ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    16,
                                  ),
                                  itemCount: filtered.length,
                                  itemBuilder: (ctx, index) {
                                    final a = filtered[index];
                                    final scheduleId = _timetables.id(a);
                                    final schedule =
                                        _timetables.schedules[scheduleId];
                                    final currentLessons =
                                        schedule?.current(widget.clock()) ?? [];
                                    return Card(
                                      color: Colors.white,
                                      margin: const EdgeInsets.only(bottom: 10),
                                      elevation: 0,
                                      child: ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 10,
                                            ),
                                        leading: CircleAvatar(
                                          backgroundColor: const Color(
                                            0xFFE8EEFF,
                                          ),
                                          child: Text(a.name.characters.first),
                                        ),
                                        title: Text(
                                          a.name,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        subtitle: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              a.campusId,
                                              style: const TextStyle(
                                                height: 1.6,
                                              ),
                                            ),
                                            for (final lesson in currentLessons)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 6,
                                                ),
                                                child: Text(
                                                  '正在上课\n${lesson.name}\n地点：${lesson.venue}',
                                                  style: const TextStyle(
                                                    color: Color(0xFF18733C),
                                                    height: 1.6,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        onTap: ready ? () => _run(a) : null,
                                        trailing: PopupMenuButton<String>(
                                          enabled:
                                              !_busy &&
                                              !_saving &&
                                              !_timetables.running,
                                          onSelected: (v) {
                                            if (v == 'timetable') {
                                              Navigator.push<void>(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => TimetablePage(
                                                    account: a,
                                                    controller: _timetables,
                                                    clock: widget.clock,
                                                  ),
                                                ),
                                              );
                                            }
                                            if (v == 'refreshTimetable') {
                                              _timetables.refresh(a);
                                            }
                                            if (v == 'edit') {
                                              _edit(a);
                                            }
                                            if (v == 'delete') {
                                              _delete(a);
                                            }
                                            if (v == 'inspect') {
                                              _run(a, inspect: true);
                                            }
                                            if (v == 'networkSessions') {
                                              _inspectNetworkSessions(a);
                                            }
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'networkSessions',
                                              child: Text('查询校园网会话（不切换）'),
                                            ),
                                            PopupMenuItem(
                                              value: 'timetable',
                                              child: Text('查看课表'),
                                            ),
                                            PopupMenuItem(
                                              value: 'refreshTimetable',
                                              child: Text('刷新课表'),
                                            ),
                                            PopupMenuItem(
                                              value: 'inspect',
                                              child: Text('测试登录 / 查询（不签到）'),
                                            ),
                                            PopupMenuItem(
                                              value: 'edit',
                                              child: Text('编辑账号'),
                                            ),
                                            PopupMenuItem(
                                              value: 'delete',
                                              child: Text('删除账号'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class ArchivePasswordDialog extends StatefulWidget {
  final bool exporting;
  const ArchivePasswordDialog({super.key, required this.exporting});

  @override
  State<ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<ArchivePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.exporting ? '设置传输密码' : '输入传输密码'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.exporting
                  ? '导出文件包含全部账号和密码，只有输入此传输密码才能在另一台手机导入。请使用至少 12 个字符并妥善保存。'
                  : '请输入导出时设置的传输密码。',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '传输密码'),
              validator: (value) =>
                  value == null || value.length < 12 ? '至少输入 12 个字符' : null,
            ),
            if (widget.exporting) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '再次输入传输密码'),
                validator: (value) =>
                    value != _password.text ? '两次输入的密码不一致' : null,
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _password.text);
          }
        },
        child: Text(widget.exporting ? '加密并选择保存位置' : '解密并预览'),
      ),
    ],
  );
}

class AccountEditor extends StatefulWidget {
  final Account? original;
  const AccountEditor({super.key, this.original});
  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController name,
      campus,
      password,
      networkPassword,
      acPassword;
  bool visible = false, networkVisible = false, acVisible = false;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.original?.name);
    campus = TextEditingController(text: widget.original?.campusId);
    password = TextEditingController();
    networkPassword = TextEditingController();
    acPassword = TextEditingController();
  }

  @override
  void dispose() {
    name.dispose();
    campus.dispose();
    password.dispose();
    networkPassword.dispose();
    acPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.original == null ? '增加账号' : '编辑账号'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '仅录入本人或已获授权的账号。密码由 Android 安全存储加密保存。',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: '学生姓名 / 备注'),
              validator: (s) => s == null || s.trim().isEmpty ? '请输入姓名' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: campus,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Campus ID'),
              validator: (s) =>
                  s == null ||
                      s.trim().isEmpty ||
                      RegExp(r'\s').hasMatch(s.trim())
                  ? '请输入有效 Campus ID'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: password,
              obscureText: !visible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: widget.original == null ? '签到系统密码' : '新密码（留空保持原密码）',
                suffixIcon: IconButton(
                  tooltip: visible ? '隐藏签到系统密码' : '显示签到系统密码',
                  onPressed: () => setState(() => visible = !visible),
                  icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
                ),
              ),
              validator: (s) =>
                  widget.original == null && (s == null || s.isEmpty)
                  ? '请输入密码'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: networkPassword,
              obscureText: !networkVisible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: widget.original?.networkPassword.isNotEmpty == true
                    ? '校园网新密码（留空保持原密码）'
                    : '校园网密码',
                suffixIcon: IconButton(
                  tooltip: networkVisible ? '隐藏校园网密码' : '显示校园网密码',
                  onPressed: () =>
                      setState(() => networkVisible = !networkVisible),
                  icon: Icon(
                    networkVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: acPassword,
              obscureText: !acVisible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'AC系统密码',
                helperText: widget.original?.acPassword.isNotEmpty == true
                    ? '留空保持原密码 · ac.xmu.edu.my'
                    : '可选填 · ac.xmu.edu.my',
                suffixIcon: IconButton(
                  tooltip: acVisible ? '隐藏AC系统密码' : '显示AC系统密码',
                  onPressed: () => setState(() => acVisible = !acVisible),
                  icon: Icon(
                    acVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              Account(
                name.text.trim(),
                campus.text.trim(),
                password.text.isEmpty
                    ? widget.original!.password
                    : password.text,
                networkPassword: networkPassword.text.isEmpty
                    ? widget.original?.networkPassword ?? ''
                    : networkPassword.text,
                acPassword: acPassword.text.isEmpty
                    ? widget.original?.acPassword ?? ''
                    : acPassword.text,
              ),
            );
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
