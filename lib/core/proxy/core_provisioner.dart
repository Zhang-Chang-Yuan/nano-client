// 把随包携带（assets）的 sing-box 内核与规则集释放到运行目录。
//
// 为什么复制而不是直接执行 assets：
//   * assets 在 Android/桌面端的落盘路径不一定有可执行权限；
//   * sing-box 需要把 cache.db、规则集等写在可写目录；
//   * 通过比较版本标记，可以只在首次运行或内核升级时释放一次。
//
// 内核二进制约 30MB，**不提交到仓库**，由 CI 或 `tool/fetch_core.dart` 下载后
// 放到 `assets/bin/<platform>/`。

import 'dart:io';

import 'package:flutter/services.dart';

import 'singbox_config.dart';

/// 当前平台对应的内核可执行文件名。
String get coreExecutableName =>
    Platform.isWindows ? 'sing-box.exe' : 'sing-box';

/// assets 中内核所在路径。
///
/// 仓库里 `assets/bin/` 只有一个占位文件；真正的内核可执行文件由
/// `tool/fetch_core.dart` 或 CI 按目标平台下载后放进来（见 `.gitignore`）。
String get coreAssetPath => 'assets/bin/$coreExecutableName';

/// assets 中规则集所在目录。
const String ruleSetAssetDirectory = 'assets/rule-set';

/// 释放结果。
class ProvisionResult {
  const ProvisionResult({
    required this.executablePath,
    required this.workingDirectory,
    required this.availableRuleSets,
    required this.provisioned,
  });

  final String executablePath;
  final String workingDirectory;
  final List<String> availableRuleSets;

  /// 本次是否真的重新释放了文件。
  final bool provisioned;
}

/// 负责把内核与规则集释放到 [targetDirectory]。
class CoreProvisioner {
  CoreProvisioner({
    required this.assetBundle,
    required this.targetDirectory,
    this.coreVersion = 'unknown',
  });

  final AssetBundle assetBundle;
  final Directory targetDirectory;

  /// 内核版本号，用于判断是否需要重新释放。
  final String coreVersion;

  static const String _stampFile = '.core-version';

  Future<ProvisionResult> provision() async {
    if (!targetDirectory.existsSync()) {
      targetDirectory.createSync(recursive: true);
    }

    final executable = File('${targetDirectory.path}/$coreExecutableName');
    final stamp = File('${targetDirectory.path}/$_stampFile');
    final upToDate =
        executable.existsSync() &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == coreVersion;

    if (upToDate) {
      return ProvisionResult(
        executablePath: executable.path,
        workingDirectory: targetDirectory.path,
        availableRuleSets: _existingRuleSets(),
        provisioned: false,
      );
    }

    await _extractCore(executable);
    final ruleSets = await _extractRuleSets();
    await stamp.writeAsString(coreVersion, flush: true);

    return ProvisionResult(
      executablePath: executable.path,
      workingDirectory: targetDirectory.path,
      availableRuleSets: ruleSets,
      provisioned: true,
    );
  }

  Future<void> _extractCore(File target) async {
    final assetPath = coreAssetPath;
    final ByteData data;
    try {
      data = await assetBundle.load(assetPath);
    } on Object catch (e) {
      throw CoreProvisionException(
        '找不到内核资源 $assetPath。'
        '请先运行 `dart run tool/fetch_core.dart` 下载内核，或使用会自带内核的 CI 构建产物。'
        '（$e）',
      );
    }

    await target.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );

    if (Platform.isWindows) return;

    // 赋予可执行权限
    await Process.run('chmod', ['+x', target.path]);

    if (Platform.isMacOS) {
      // Apple Silicon 要求所有可执行文件至少带 ad-hoc 签名，否则 exec 会失败。
      // 从 assets 释放出来的二进制没有签名，这里就地补一个。
      final codesign = await Process.run('codesign', [
        '--force',
        '--sign',
        '-',
        '--timestamp=none',
        target.path,
      ]);
      if (codesign.exitCode != 0) {
        throw CoreProvisionException('为内核补 ad-hoc 签名失败：${codesign.stderr}');
      }
    }
  }

  Future<List<String>> _extractRuleSets() async {
    final directory = Directory('${targetDirectory.path}/rule-set');
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final manifest = await _loadRuleSetManifest();
    final available = <String>[];
    for (final tag in manifest.isEmpty ? kCnRuleSets : manifest) {
      final assetPath = '$ruleSetAssetDirectory/$tag.srs';
      try {
        final data = await assetBundle.load(assetPath);
        final target = File('${directory.path}/$tag.srs');
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        available.add(tag);
      } on Object {
        // 缺少某个规则集不致命，auto 模式会退化为更粗的分流。
        continue;
      }
    }
    return available;
  }

  Future<List<String>> _loadRuleSetManifest() async {
    try {
      final raw = await assetBundle.loadString(
        '$ruleSetAssetDirectory/manifest.txt',
      );
      return raw
          .split(RegExp(r'[\r\n]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.startsWith('#'))
          .toList();
    } on Object {
      return kCnRuleSets;
    }
  }

  List<String> _existingRuleSets() {
    final directory = Directory('${targetDirectory.path}/rule-set');
    if (!directory.existsSync()) return const [];
    return kCnRuleSets
        .where((tag) => File('${directory.path}/$tag.srs').existsSync())
        .toList();
  }
}

/// 内核资源缺失或释放失败。
class CoreProvisionException implements Exception {
  CoreProvisionException(this.message);

  final String message;

  @override
  String toString() => 'CoreProvisionException: $message';
}
