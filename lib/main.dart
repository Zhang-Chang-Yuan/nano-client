import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/config/config_repository.dart';
import 'core/config/secure_key_store.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDirectory = await getApplicationSupportDirectory();
  final configDirectory = Directory('${supportDirectory.path}/config');
  if (!configDirectory.existsSync()) {
    configDirectory.createSync(recursive: true);
  }

  // 优先使用系统安全存储（Keystore / Keychain / DPAPI / libsecret），
  // 不可用时降级到 0600 权限的密钥文件，并在界面上给出提示。
  final keyStore = CompositeKeyStore(
    primary: PlatformSecureKeyStore(),
    fallback: FileFallbackKeyStore(File('${configDirectory.path}/.master_key')),
  );

  final repository = ConfigRepository(
    keyStore: keyStore,
    directory: configDirectory,
  );

  // 启动即读取配置；读不到（首次启动或文件损坏）会自动初始化。
  final loadResult = await repository.load();

  runApp(
    ProviderScope(
      overrides: [
        configRepositoryProvider.overrideWithValue(repository),
        initialConfigProvider.overrideWithValue(loadResult),
      ],
      child: const NanoApp(),
    ),
  );
}
