// 系统代理设置。
//
// 桌面端启动内核只是在本地开了一个代理端口，浏览器和系统默认并不会走它 ——
// 用户会误以为"连上了却还是本地 IP"。这里提供一键接管：
//
//   Linux   -> gsettings（GNOME 系统代理）
//   Windows -> 注册表 Internet Settings
//   macOS   -> networksetup（对当前网络服务生效）
//
// 注意：这些命令只改动"代理开关"，不负责备份用户原有的代理配置。
// 关闭时会把代理关掉（而不是恢复成原来那套）。

import 'dart:io';

/// 一次系统代理操作的结果。
class SystemProxyResult {
  const SystemProxyResult({required this.ok, this.detail});

  final bool ok;
  final String? detail;

  static const SystemProxyResult success = SystemProxyResult(ok: true);
}

/// 跨平台系统代理控制器。
class SystemProxyController {
  const SystemProxyController();

  /// 当前平台是否支持自动设置系统代理。
  bool get isSupported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  String get platformHint => switch (true) {
    _ when Platform.isLinux => 'GNOME 系统代理',
    _ when Platform.isWindows => 'Windows Internet 选项',
    _ when Platform.isMacOS => 'macOS 网络服务',
    _ => '当前平台不支持自动设置，请手动配置',
  };

  /// 打开系统代理，指向 [host]:[port]。
  Future<SystemProxyResult> enable({
    required String host,
    required int port,
  }) async {
    try {
      if (Platform.isLinux) return await _enableLinux(host, port);
      if (Platform.isWindows) return await _enableWindows(host, port);
      if (Platform.isMacOS) return await _enableMacos(host, port);
      return const SystemProxyResult(ok: false, detail: '不支持的平台');
    } on Object catch (e) {
      return SystemProxyResult(ok: false, detail: '$e');
    }
  }

  /// 关闭系统代理。
  Future<SystemProxyResult> disable() async {
    try {
      if (Platform.isLinux) {
        return await _run('gsettings', [
          'set',
          'org.gnome.system.proxy',
          'mode',
          'none',
        ]);
      }
      if (Platform.isWindows) {
        return await _run('reg', [
          'add',
          _windowsKey,
          '/v',
          'ProxyEnable',
          '/t',
          'REG_DWORD',
          '/d',
          '0',
          '/f',
        ]);
      }
      if (Platform.isMacOS) {
        final service = await _macosActiveService();
        if (service == null) {
          return const SystemProxyResult(ok: false, detail: '找不到活动的网络服务');
        }
        for (final cmd in [
          '-setwebproxystate',
          '-setsecurewebproxystate',
          '-setsocksfirewallproxystate',
        ]) {
          await _run('networksetup', [cmd, service, 'off']);
        }
        return SystemProxyResult.success;
      }
      return const SystemProxyResult(ok: false, detail: '不支持的平台');
    } on Object catch (e) {
      return SystemProxyResult(ok: false, detail: '$e');
    }
  }

  // -- Linux ---------------------------------------------------------------

  Future<SystemProxyResult> _enableLinux(String host, int port) async {
    // 依次设置 http / https / socks 三组，再切到 manual
    for (final scheme in ['http', 'https', 'socks']) {
      final hostResult = await _run('gsettings', [
        'set',
        'org.gnome.system.proxy.$scheme',
        'host',
        host,
      ]);
      if (!hostResult.ok) return hostResult;
      final portResult = await _run('gsettings', [
        'set',
        'org.gnome.system.proxy.$scheme',
        'port',
        '$port',
      ]);
      if (!portResult.ok) return portResult;
    }
    final ignore = await _run('gsettings', [
      'set',
      'org.gnome.system.proxy',
      'ignore-hosts',
      "['localhost', '127.0.0.0/8', '::1']",
    ]);
    if (!ignore.ok) return ignore;
    return _run('gsettings', [
      'set',
      'org.gnome.system.proxy',
      'mode',
      'manual',
    ]);
  }

  // -- Windows -------------------------------------------------------------

  static const String _windowsKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  Future<SystemProxyResult> _enableWindows(String host, int port) async {
    final server = await _run('reg', [
      'add',
      _windowsKey,
      '/v',
      'ProxyServer',
      '/t',
      'REG_SZ',
      '/d',
      '$host:$port',
      '/f',
    ]);
    if (!server.ok) return server;

    final bypass = await _run('reg', [
      'add',
      _windowsKey,
      '/v',
      'ProxyOverride',
      '/t',
      'REG_SZ',
      '/d',
      'localhost;127.*;10.*;172.16.*;192.168.*;<local>',
      '/f',
    ]);
    if (!bypass.ok) return bypass;

    return _run('reg', [
      'add',
      _windowsKey,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      '1',
      '/f',
    ]);
  }

  // -- macOS ---------------------------------------------------------------

  Future<SystemProxyResult> _enableMacos(String host, int port) async {
    final service = await _macosActiveService();
    if (service == null) {
      return const SystemProxyResult(ok: false, detail: '找不到活动的网络服务');
    }
    final commands = <List<String>>[
      ['-setwebproxy', service, host, '$port'],
      ['-setsecurewebproxy', service, host, '$port'],
      ['-setsocksfirewallproxy', service, host, '$port'],
    ];
    for (final args in commands) {
      final result = await _run('networksetup', args);
      if (!result.ok) return result;
    }
    return SystemProxyResult.success;
  }

  /// 取当前正在使用的网络服务名（networksetup 需要服务名而不是接口名）。
  Future<String?> _macosActiveService() async {
    // route 输出里带默认接口，例如 "interface: en0"
    final route = await Process.run('route', ['-n', 'get', 'default']);
    final match = RegExp(r'interface:\s*(\w+)').firstMatch('${route.stdout}');
    final device = match?.group(1);
    if (device == null) return null;

    final order = await Process.run('networksetup', [
      '-listnetworkserviceorder',
    ]);
    // 形如 "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)"
    final blocks = '${order.stdout}'.split(RegExp(r'\n(?=\(\d+\))'));
    for (final block in blocks) {
      if (block.contains('Device: $device')) {
        final name = RegExp(
          r'^\(\d+\)\s*(.+)$',
          multiLine: true,
        ).firstMatch(block);
        if (name != null) return name.group(1)?.trim();
      }
    }
    return null;
  }

  Future<SystemProxyResult> _run(String exe, List<String> args) async {
    try {
      final result = await Process.run(exe, args);
      if (result.exitCode == 0) return SystemProxyResult.success;
      final err = '${result.stderr}'.trim();
      return SystemProxyResult(
        ok: false,
        detail: err.isEmpty ? '$exe 退出码 ${result.exitCode}' : err,
      );
    } on ProcessException catch (e) {
      return SystemProxyResult(ok: false, detail: '无法执行 $exe：${e.message}');
    }
  }
}
