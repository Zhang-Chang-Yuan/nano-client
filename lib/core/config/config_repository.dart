// 配置文件的读写。
//
// 生命周期（对应需求「启动读取，读不到再初始化」）：
//
//   1. 确保主密钥存在；不存在就在安全存储里生成一个 256 位随机密钥。
//   2. 读取配置文件；不存在则用默认值初始化并落盘。
//   3. 文件存在但解密/解析失败（密钥换了、文件被改、格式升级失败）时，
//      把损坏文件改名备份，然后重新初始化，保证应用一定能启动。
//
// 落盘内容永远是 AES-256-GCM 信封，**绝不含明文**。

import 'dart:convert';
import 'dart:io';

import '../crypto/crypto_service.dart';
import 'app_config.dart';
import 'secure_key_store.dart';

/// 配置加载结果。
class ConfigLoadResult {
  const ConfigLoadResult({
    required this.config,
    required this.createdNew,
    required this.recoveredFromCorruption,
    this.backupPath,
  });

  final AppConfig config;

  /// 是否是本次新建的配置（首次启动或用户重置）。
  final bool createdNew;

  /// 是否因为原文件损坏而重建。
  final bool recoveredFromCorruption;

  /// 损坏文件的备份路径。
  final String? backupPath;
}

/// 配置文件仓库。
class ConfigRepository {
  ConfigRepository({
    required this.keyStore,
    this.directory,
    CryptoService? crypto,
    this.fileName = 'config.enc',
  }) : _crypto = crypto ?? CryptoService();

  final SecureKeyStore keyStore;
  final CryptoService _crypto;
  final String fileName;

  /// 配置文件所在目录。必须在调用 [load] / [save] 前可用。
  Directory? directory;

  List<int>? _cachedKey;

  File get configFile => File('${_requireDirectory().path}/$fileName');

  Directory _requireDirectory() {
    final dir = directory;
    if (dir == null) {
      throw StateError('ConfigRepository.directory 尚未设置');
    }
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 取得（必要时创建）主密钥。
  Future<List<int>> ensureMasterKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;

    var key = await keyStore.read();
    if (key == null || key.length != kMasterKeyLength) {
      key = _crypto.generateMasterKey();
      await keyStore.write(key);
    }
    _cachedKey = key;
    return key;
  }

  /// 加载配置，读不到就初始化。
  Future<ConfigLoadResult> load() async {
    final key = await ensureMasterKey();
    final file = configFile;

    if (!file.existsSync()) {
      const fresh = AppConfig();
      await save(fresh);
      return const ConfigLoadResult(
        config: AppConfig(),
        createdNew: true,
        recoveredFromCorruption: false,
      );
    }

    try {
      final envelope = await file.readAsString();
      final plain = await _crypto.decryptString(envelope, key);
      final decoded = jsonDecode(plain);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('配置根节点不是 JSON 对象');
      }
      final config = AppConfig.fromJson(decoded);
      return ConfigLoadResult(
        config: config,
        createdNew: false,
        recoveredFromCorruption: false,
      );
    } on Object catch (error) {
      // 任何异常都不能让应用起不来：备份损坏文件后重新初始化。
      final backup = await _backupCorrupted(file, error);
      const fresh = AppConfig();
      await save(fresh);
      return ConfigLoadResult(
        config: fresh,
        createdNew: true,
        recoveredFromCorruption: true,
        backupPath: backup,
      );
    }
  }

  /// 加密并写入配置。
  Future<void> save(AppConfig config) async {
    final key = await ensureMasterKey();
    final plain = jsonEncode(config.toJson());
    final envelope = await _crypto.encryptString(plain, key);

    final file = configFile;
    // 先写临时文件再原子替换，避免写入过程中断电导致配置半截。
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(envelope, flush: true);
    if (file.existsSync()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }

  /// 抹掉配置与主密钥（「重置应用」）。
  Future<void> reset() async {
    final file = configFile;
    if (file.existsSync()) {
      await file.delete();
    }
    await keyStore.delete();
    _cachedKey = null;
  }

  Future<String?> _backupCorrupted(File file, Object error) async {
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final backup = File('${file.path}.corrupt-$stamp.bak');
      await file.rename(backup.path);
      return backup.path;
    } on Object {
      // 备份失败也不能阻断启动
      try {
        await file.delete();
      } on Object {
        // 忽略
      }
      return null;
    }
  }
}
