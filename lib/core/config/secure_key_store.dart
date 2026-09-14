// 主密钥的保存与读取。
//
// 主密钥是加密配置文件的唯一凭据，**绝不写进配置文件本身**，
// 而是交给操作系统提供的安全存储：
//
//   Android  ->  Keystore（经 EncryptedSharedPreferences）
//   iOS/macOS->  Keychain
//   Windows  ->  Credential Manager（DPAPI 保护）
//   Linux    ->  libsecret（GNOME Keyring / KWallet）
//
// 这样即使配置文件被拷走，没有当前用户的安全存储也无法解密。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 主密钥存储的抽象，便于在测试中替换为内存实现。
abstract class SecureKeyStore {
  /// 读取主密钥；不存在时返回 `null`。
  Future<List<int>?> read();

  /// 写入主密钥。
  Future<void> write(List<int> key);

  /// 删除主密钥（用于「重置应用」）。
  Future<void> delete();
}

/// 基于 `flutter_secure_storage` 的实现。
class PlatformSecureKeyStore implements SecureKeyStore {
  PlatformSecureKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _key = 'nano.master_key.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<int>?> read() async {
    final encoded = await _storage.read(key: _key);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      // 数据损坏，当作不存在处理，由上层重新初始化。
      return null;
    }
  }

  @override
  Future<void> write(List<int> key) =>
      _storage.write(key: _key, value: base64Encode(key));

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// 仅用于测试与降级场景的内存实现。
class InMemoryKeyStore implements SecureKeyStore {
  InMemoryKeyStore([this._key]);

  List<int>? _key;

  @override
  Future<List<int>?> read() async => _key;

  @override
  Future<void> write(List<int> key) async => _key = List<int>.from(key);

  @override
  Future<void> delete() async => _key = null;
}

/// 降级方案：把主密钥写进一个权限为 0600 的文件。
///
/// 仅在系统安全存储不可用时使用（典型场景：Linux 桌面没有安装
/// gnome-keyring / kwallet，`libsecret` 不可用）。
///
/// 安全性弱于系统钥匙串 —— 同一台机器上的其他进程若拿到该文件即可解密配置。
/// 因此 [CompositeKeyStore] 会记录是否走了降级路径，UI 需要向用户明示。
class FileFallbackKeyStore implements SecureKeyStore {
  FileFallbackKeyStore(this.file);

  final File file;

  @override
  Future<List<int>?> read() async {
    if (!file.existsSync()) return null;
    try {
      return base64Decode(file.readAsStringSync().trim());
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(List<int> key) async {
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString(base64Encode(key), flush: true);
    if (!Platform.isWindows) {
      // 仅所有者可读写
      await Process.run('chmod', ['600', file.path]);
    }
  }

  @override
  Future<void> delete() async {
    if (file.existsSync()) {
      await file.delete();
    }
  }
}

/// 先尝试系统安全存储，失败时降级到文件。
class CompositeKeyStore implements SecureKeyStore {
  CompositeKeyStore({required this.primary, required this.fallback});

  final SecureKeyStore primary;
  final SecureKeyStore fallback;

  /// 最近一次操作是否使用了降级存储。
  bool usedFallback = false;

  @override
  Future<List<int>?> read() async {
    try {
      final value = await primary.read();
      if (value != null) {
        usedFallback = false;
        return value;
      }
    } on Object {
      usedFallback = true;
    }
    final value = await fallback.read();
    if (value != null) usedFallback = true;
    return value;
  }

  @override
  Future<void> write(List<int> key) async {
    if (usedFallback) {
      await fallback.write(key);
      return;
    }
    try {
      await primary.write(key);
      usedFallback = false;
    } on Object {
      usedFallback = true;
      await fallback.write(key);
    }
  }

  @override
  Future<void> delete() async {
    try {
      await primary.delete();
    } on Object {
      // 忽略：主存储不可用时也要保证能清理降级存储
    }
    await fallback.delete();
  }
}
