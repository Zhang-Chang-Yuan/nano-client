import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/config/config_repository.dart';
import 'package:nano_client/core/crypto/crypto_service.dart';
import 'package:nano_client/core/config/secure_key_store.dart';

void main() {
  late Directory tempDir;
  late InMemoryKeyStore keyStore;
  late ConfigRepository repository;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nano_config_test');
    keyStore = InMemoryKeyStore();
    repository = ConfigRepository(keyStore: keyStore, directory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('首次启动：没有配置文件时自动初始化', () async {
    expect(repository.configFile.existsSync(), isFalse);

    final result = await repository.load();

    expect(result.createdNew, isTrue);
    expect(result.recoveredFromCorruption, isFalse);
    expect(result.config.panel.isComplete, isFalse);
    expect(repository.configFile.existsSync(), isTrue);
  });

  test('写入磁盘的是密文，不含任何明文敏感信息', () async {
    const password = 'correct horse battery staple';
    const email = 'someone@example.com';
    const apiBase = 'https://panel.example.com/api/v1';

    await repository.save(
      const AppConfig(
        initialized: true,
        panel: PanelConfig(apiBase: apiBase),
        account: AccountConfig(email: email, password: password),
      ),
    );

    final raw = await repository.configFile.readAsString();

    expect(raw.contains(password), isFalse, reason: '密码绝不能明文落盘');
    expect(raw.contains(email), isFalse);
    expect(raw.contains(apiBase), isFalse);
    expect(raw.contains('apiBase'), isFalse);
  });

  test('保存后重新加载，配置逐字段一致', () async {
    const original = AppConfig(
      initialized: true,
      onboardingCompleted: true,
      panel: PanelConfig(
        apiBase: 'https://panel.example.com/api/v1',
        chatUrl: 'https://chat.example.com',
        configSource: 'https://cfg.example.com/u.json',
      ),
      account: AccountConfig(
        email: 'user@example.com',
        password: 'pw',
        authData: 'jwt.token.here',
      ),
      proxy: ProxyConfig(
        routeMode: RouteMode.global,
        safeDns: true,
        dnsProvider: DnsProvider.cloudflare,
        mixedPort: 1080,
        enableTun: true,
        selectedNodeTag: '🇭🇰 香港 01',
      ),
    );
    await repository.save(original);

    final result = await ConfigRepository(
      keyStore: keyStore,
      directory: tempDir,
    ).load();

    expect(result.createdNew, isFalse);
    expect(result.config, equals(original));
  });

  test('文件损坏时重建并保留备份，不会让应用起不来', () async {
    await repository.save(const AppConfig(initialized: true));
    await repository.configFile.writeAsString('这不是一个合法的加密信封');

    final result = await repository.load();

    expect(result.recoveredFromCorruption, isTrue);
    expect(result.createdNew, isTrue);
    expect(result.backupPath, isNotNull);
    expect(File(result.backupPath!).existsSync(), isTrue);
    // 重建后仍然是可用的加密配置
    expect(repository.configFile.existsSync(), isTrue);
  });

  test('主密钥换了以后旧配置无法解密，会走重建流程', () async {
    await repository.save(
      const AppConfig(initialized: true, autoConnect: true),
    );

    final another = ConfigRepository(
      keyStore: InMemoryKeyStore(),
      directory: tempDir,
    );
    final result = await another.load();

    expect(result.recoveredFromCorruption, isTrue);
    expect(result.config.autoConnect, isFalse);
  });

  test('主密钥只生成一次并会被复用', () async {
    final first = await repository.ensureMasterKey();
    final second = await repository.ensureMasterKey();

    expect(first, equals(second));
    expect(first.length, kMasterKeyLength);
    expect(await keyStore.read(), equals(first));
  });

  test('reset 会同时清掉配置文件与主密钥', () async {
    await repository.save(const AppConfig(initialized: true));
    expect(repository.configFile.existsSync(), isTrue);

    await repository.reset();

    expect(repository.configFile.existsSync(), isFalse);
    expect(await keyStore.read(), isNull);
  });

  test('未知字段与缺失字段都能安全解析（向前/向后兼容）', () {
    final progress = AppConfig.fromJson({
      'initialized': true,
      'unknownFieldFromFuture': {'a': 1},
      'proxy': {'mixedPort': '1080'},
    });

    expect(progress.initialized, isTrue);
    expect(progress.proxy.mixedPort, 1080);
    expect(progress.proxy.routeMode, RouteMode.auto);
    expect(progress.panel.apiBase, '');
  });

  test('AppMode 预设与底层配置可以互相推导', () {
    expect(AppMode.auto.routeAndSafeDns, (RouteMode.auto, false));
    expect(AppMode.global.routeAndSafeDns, (RouteMode.global, false));
    expect(AppMode.safe.routeAndSafeDns, (RouteMode.auto, true));

    expect(AppMode.fromConfig(RouteMode.auto, false), AppMode.auto);
    expect(AppMode.fromConfig(RouteMode.global, false), AppMode.global);
    expect(AppMode.fromConfig(RouteMode.auto, true), AppMode.safe);
    expect(AppMode.fromConfig(RouteMode.global, true), isNull);
  });
}
