import 'dart:convert';

import 'package:flutter/services.dart';

import 'domain.dart';

abstract interface class ArchiveBridge {
  Future<Uint8List> encrypt(Uint8List plaintext, String passphrase);
  Future<Uint8List> decrypt(Uint8List archive, String passphrase);
  Future<bool> save(Uint8List archive, String filename);
  Future<Uint8List?> open();
}

class AndroidArchiveBridge implements ArchiveBridge {
  static const channel = MethodChannel('com.xmum.attendance_assistant/archive');

  @override
  Future<Uint8List> encrypt(Uint8List plaintext, String passphrase) async =>
      (await channel.invokeMethod<Uint8List>('encrypt', {
        'bytes': plaintext,
        'password': passphrase,
      }))!;

  @override
  Future<Uint8List> decrypt(Uint8List archive, String passphrase) async =>
      // Platform message buffers can be read-only. Own the plaintext buffer so
      // the importer can clear it after decoding, including on parse failures.
      Uint8List.fromList(
        (await channel.invokeMethod<Uint8List>('decrypt', {
          'bytes': archive,
          'password': passphrase,
        }))!,
      );

  @override
  Future<bool> save(Uint8List archive, String filename) async =>
      await channel.invokeMethod<bool>('save', {
        'bytes': archive,
        'name': filename,
      }) ==
      true;

  @override
  Future<Uint8List?> open() => channel.invokeMethod<Uint8List>('open');
}

enum ImportMode { addOnly, updateDuplicates }

class ImportPlan {
  final List<Account> incoming;
  final int newCount, duplicateCount;
  const ImportPlan(this.incoming, this.newCount, this.duplicateCount);

  List<Account> apply(List<Account> existing, ImportMode mode) {
    final accounts = <String, Account>{
      for (final account in existing) account.campusId.toLowerCase(): account,
    };
    for (final account in incoming) {
      final id = account.campusId.toLowerCase();
      if (mode == ImportMode.updateDuplicates || !accounts.containsKey(id)) {
        accounts[id] = account;
      }
    }
    return accounts.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }
}

class PortableAccounts {
  static const maxAccounts = 2000;
  static const maxBytes = 4 * 1024 * 1024;
  static const maxPayloadBytes = 2 * 1024 * 1024;

  static void _validate(List<Account> accounts) {
    if (accounts.length > maxAccounts) {
      throw const FormatException('账号数量超过导入导出上限');
    }
    final ids = <String>{};
    for (final account in accounts) {
      if (account.name.trim().isEmpty ||
          account.name.length > 60 ||
          account.campusId.trim().isEmpty ||
          RegExp(r'\s').hasMatch(account.campusId) ||
          account.password.isEmpty ||
          account.password.length > 8192 ||
          account.networkPassword.length > 8192 ||
          account.acPassword.length > 8192 ||
          !ids.add(account.campusId.toLowerCase())) {
        throw const FormatException('账号数据含无效字段或重复 Campus ID');
      }
    }
  }

  static Uint8List encode(List<Account> accounts) {
    _validate(accounts);
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'xmum-attendance-accounts',
          'version': 1,
          'accounts': accounts.map((account) => account.toJson()).toList(),
        }),
      ),
    );
    if (bytes.length > maxPayloadBytes) {
      throw const FormatException('账号数据过大，无法导出');
    }
    return bytes;
  }

  static List<Account> decode(Uint8List bytes) {
    if (bytes.length > maxPayloadBytes) {
      throw const FormatException('账号文件过大');
    }
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map ||
          data['format'] != 'xmum-attendance-accounts' ||
          data['version'] != 1 ||
          data['accounts'] is! List) {
        throw const FormatException('账号文件格式不受支持');
      }
      final accounts = <Account>[];
      for (final item in data['accounts'] as List) {
        if (item is! Map ||
            item.keys.any(
              (key) => !const [
                'name',
                'campusId',
                'password',
                'networkPassword',
                'acPassword',
              ].contains(key),
            )) {
          throw const FormatException('账号文件内容无效');
        }
        accounts.add(Account.fromJson(Map<String, dynamic>.from(item)));
      }
      _validate(accounts);
      return accounts;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('账号文件内容无效');
    }
  }

  static ImportPlan plan(List<Account> existing, List<Account> incoming) {
    _validate(existing);
    _validate(incoming);
    final oldIds = existing
        .map((account) => account.campusId.toLowerCase())
        .toSet();
    final duplicates = incoming
        .where((account) => oldIds.contains(account.campusId.toLowerCase()))
        .length;
    if (existing.length + incoming.length - duplicates > maxAccounts) {
      throw const FormatException('导入后账号数量超过上限');
    }
    return ImportPlan(incoming, incoming.length - duplicates, duplicates);
  }
}
