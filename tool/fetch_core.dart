// 下载 sing-box 内核与分流规则集到 `assets/`。
//
// 内核二进制约 30MB，不适合提交到仓库，因此由本脚本（本地开发）
// 或 CI 在构建前获取。用法：
//
//   dart run tool/fetch_core.dart              # 取最新稳定版
//   dart run tool/fetch_core.dart --version 1.14.0
//   dart run tool/fetch_core.dart --rules-only # 只更新规则集
//
// 依赖：dev_dependencies 中的 archive（纯 Dart，跨平台）。

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:io';

import 'package:archive/archive_io.dart';

const String _repo = 'SagerNet/sing-box';

/// 规则集来源：文件名 -> 下载地址
const Map<String, String> _ruleSets = {
  'geosite-cn.srs': 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs',
  'geoip-cn.srs': 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs',
};

Future<void> main(List<String> args) async {
  final rulesOnly = args.contains('--rules-only');
  final versionArg = _readOption(args, '--version');

  final root = Directory.current;
  final binDir = Directory('${root.path}/assets/bin');
  final ruleDir = Directory('${root.path}/assets/rule-set');
  binDir.createSync(recursive: true);
  ruleDir.createSync(recursive: true);

  if (!rulesOnly) {
    final version = versionArg ?? await _latestVersion();
    stdout.writeln('sing-box 版本: $version');
    await _downloadCore(version: version, binDir: binDir);
    File('${binDir.path}/VERSION').writeAsStringSync('$version\n');
  }

  await _downloadRuleSets(ruleDir);
  stdout.writeln('完成。');
}

String? _readOption(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

Future<String> _latestVersion() async {
  final json = await _getJson(
    'https://api.github.com/repos/$_repo/releases/latest',
  );
  final tag = json['tag_name'];
  if (tag is! String || tag.isEmpty) {
    throw StateError('无法从 GitHub 获取最新版本号');
  }
  return tag.replaceFirst('v', '');
}

/// 当前平台对应的 release 资源名。
String _assetName(String version) {
  final arch = _arch();
  if (Platform.isLinux) return 'sing-box-$version-linux-$arch-glibc.tar.gz';
  if (Platform.isWindows) return 'sing-box-$version-windows-$arch.zip';
  if (Platform.isMacOS) return 'sing-box-$version-darwin-$arch.tar.gz';
  throw UnsupportedError('不支持的平台: ${Platform.operatingSystem}');
}

String _arch() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => 'amd64',
    Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
    _ => throw UnsupportedError('不支持的架构: $abi'),
  };
}

Future<void> _downloadCore({
  required String version,
  required Directory binDir,
}) async {
  final asset = _assetName(version);
  final url = 'https://github.com/$_repo/releases/download/v$version/$asset';
  stdout.writeln('下载内核: $url');

  final bytes = await _getBytes(url);
  final executableName = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final target = File('${binDir.path}/$executableName');

  final Archive archive;
  if (asset.endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes);
  } else {
    // GitHub 的 tar.gz 需要先解 gzip 再解 tar
    final decompressed = const GZipDecoder().decodeBytes(bytes);
    archive = TarDecoder().decodeBytes(decompressed);
  }

  final entry = archive.files.firstWhere(
    (f) => f.name == executableName || f.name.endsWith('/$executableName'),
    orElse: () => throw StateError('压缩包中没有找到 $executableName'),
  );

  await target.writeAsBytes(entry.content as List<int>, flush: true);
  if (!Platform.isWindows) {
    await Process.run('chmod', ['+x', target.path]);
  }
  final size = (await target.length() / 1024 / 1024).toStringAsFixed(1);
  stdout.writeln('  -> ${target.path} ($size MB)');
}

Future<void> _downloadRuleSets(Directory ruleDir) async {
  for (final entry in _ruleSets.entries) {
    final target = File('${ruleDir.path}/${entry.key}');
    try {
      final bytes = await _getBytes(entry.value);
      await target.writeAsBytes(bytes, flush: true);
      stdout.writeln('规则集 ${entry.key} (${bytes.length} 字节)');
    } on Object catch (e) {
      // 规则集不影响内核可用性：缺失时 auto 模式会自动退化。
      stdout.writeln('规则集 ${entry.key} 下载失败，跳过: $e');
    }
  }
  File('${ruleDir.path}/manifest.txt').writeAsStringSync(
    '# auto 模式使用的规则集，每行一个 tag，对应 assets/rule-set/<tag>.srs\n'
    'geosite-cn\ngeoip-cn\n',
  );
}

Future<Map<String, dynamic>> _getJson(String url) async {
  final bytes = await _getBytes(url, headers: {'Accept': 'application/json'});
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw StateError('$url 返回的不是 JSON 对象');
  }
  return decoded;
}

Future<List<int>> _getBytes(
  String url, {
  Map<String, String> headers = const {},
  int attempt = 1,
}) async {
  const maxAttempts = 4;
  try {
    return await _getBytesOnce(url, headers);
  } on Object catch (e) {
    if (attempt >= maxAttempts) rethrow;
    stdout.writeln('  下载失败（第 $attempt 次）：$e，1 秒后重试…');
    await Future<void>.delayed(Duration(seconds: attempt));
    return _getBytes(url, headers: headers, attempt: attempt + 1);
  }
}

Future<List<int>> _getBytesOnce(String url, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    request.headers.set('User-Agent', 'nano-client-fetch-core');
    final response = await request.close();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers.value('location');
      await response.drain<void>();
      if (location != null) return await _getBytesOnce(location, headers);
    }
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}
