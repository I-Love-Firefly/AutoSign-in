import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'domain.dart';

abstract interface class AccountStore {
  Future<List<Account>> load();
  Future<void> save(List<Account> accounts);
}

class SecureAccountStore implements AccountStore {
  final FlutterSecureStorage storage;
  SecureAccountStore({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
          );
  static const key = 'xmum_accounts_v1';
  @override
  Future<List<Account>> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) {
      return [];
    }
    return (jsonDecode(raw) as List)
        .map((e) => Account.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<void> save(List<Account> accounts) => storage.write(
    key: key,
    value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
  );
}
