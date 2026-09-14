// 系统代理设置。
//
// 桌面端启动内核只是在本地开了一个代理端口，浏览器和系统默认并不会走它 ——
// 用户会误以为"连上了却还是本地 IP"。这里提供一键接管：
//
//   Linux   -> gsettings（GNOME 系统代理）
//   Windows -> 注册表 Internet Settings
//   macOS   -> networksetup（对当前网络服务生效）
//
// ⚠️ 两个踩过的坑，改动前务必先读：
//
// 1. **不能只看退出码。** 从缺少 `DBUS_SESSION_BUS_ADDRESS` 的上下文启动时，
//    `gsettings set` 会打印 dconf 警告、**退出码却是 0**，而值根本没写进去。
//    所以每次设置后都要读回确认，见 `_verifyLinuxProxy`。
//
// 2. **必须补上会话总线变量。** 桌面启动时环境里通常有，但从某些终端/服务
//    启动时会缺失，导致上面第 1 条。见 [linuxSessionEnv]。

import 'dart:io';

/// 一次系统代理操作的结果。
class SystemProxyResult {
  const SystemProxyResult({required this.ok, this.detail, this.stdout});

  final bool ok;

  /// 失败原因。
  final String? detail;

  /// 命令的标准输出，便于诊断。
  final String? stdout;

  static const SystemProxyResult success = SystemProxyResult(ok: true);
}

/// 计算 Linux 下 `gsettings` / dconf 需要的会话环境变量。
///
/// 从缺少 `DBUS_SESSION_BUS_ADDRESS` 的上下文启动时，gsettings 会**静默失败**
/// （退出码 0 但值没写进去）。这里显式补上，指向会话总线 socket。
///
/// [parent] 是当前进程的环境；[uid] 用于在 `XDG_RUNTIME_DIR` 缺失时兜底。
Map<String, String> linuxSessionEnv(Map<String, String> parent, {String? uid}) {
  final env = <String, String>{};

  var runtimeDir = parent['XDG_RUNTIME_DIR'];
  if ((runtimeDir == null || runtimeDir.isEmpty) &&
      uid != null &&
      uid.isNotEmpty) {
    runtimeDir = '/run/user/$uid';
  }
  if (runtimeDir == null || runtimeDir.isEmpty) return env;

  env['XDG_RUNTIME_DIR'] = runtimeDir;

  final address = parent['DBUS_SESSION_BUS_ADDRESS'];
  if (address == null || address.isEmpty) {
    env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=$runtimeDir/bus';
  }
  return env;
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
        final env = await _sessionEnv();
        return await _run('gsettings', [
          'set',
          'org.gnome.system.proxy',
          'mode',
          'none',
        ], environment: env);
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
    final env = await _sessionEnv();

    for (final scheme in ['http', 'https', 'socks']) {
      final hostResult = await _run('gsettings', [
        'set',
        'org.gnome.system.proxy.$scheme',
        'host',
        host,
      ], environment: env);
      if (!hostResult.ok) return hostResult;

      final portResult = await _run('gsettings', [
        'set',
        'org.gnome.system.proxy.$scheme',
        'port',
        '$port',
      ], environment: env);
      if (!portResult.ok) return portResult;
    }

    await _run('gsettings', [
      'set',
      'org.gnome.system.proxy',
      'ignore-hosts',
      "['localhost', '127.0.0.0/8', '::1']",
    ], environment: env);

    final modeResult = await _run('gsettings', [
      'set',
      'org.gnome.system.proxy',
      'mode',
      'manual',
    ], environment: env);
    if (!modeResult.ok) return modeResult;

    return _verifyLinuxProxy(host, port, env);
  }

  /// 读回确认真的写进去了。
  ///
  /// 必需 —— `gsettings` 在 dconf 不可用时也会返回退出码 0。
  Future<SystemProxyResult> _verifyLinuxProxy(
    String host,
    int port,
    Map<String, String> env,
  ) async {
    final mode = await _run('gsettings', [
      'get',
      'org.gnome.system.proxy',
      'mode',
    ], environment: env);
    final readMode = (mode.stdout ?? '').replaceAll("'", '').trim();
    if (readMode != 'manual') {
      return SystemProxyResult(
        ok: false,
        detail:
            '系统代理未生效（读到 "$readMode"）。'
            '通常是当前环境缺少会话总线（DBUS_SESSION_BUS_ADDRESS）导致，'
            '可手动把代理指向 $host:$port',
      );
    }

    final readHost = await _run('gsettings', [
      'get',
      'org.gnome.system.proxy.http',
      'host',
    ], environment: env);
    final readPort = await _run('gsettings', [
      'get',
      'org.gnome.system.proxy.http',
      'port',
    ], environment: env);
    final actualHost = (readHost.stdout ?? '').replaceAll("'", '').trim();
    final actualPort = (readPort.stdout ?? '').trim();
    if (actualHost != host || actualPort != '$port') {
      return SystemProxyResult(
        ok: false,
        detail: '系统代理地址不符（读到 $actualHost:$actualPort）',
      );
    }

    return SystemProxyResult.success;
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

    final enable = await _run('reg', [
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
    if (!enable.ok) return enable;

    // 同样读回确认
    final readBack = await _run('reg', [
      'query',
      _windowsKey,
      '/v',
      'ProxyEnable',
    ]);
    if (!(readBack.stdout ?? '').contains('0x1')) {
      return const SystemProxyResult(ok: false, detail: '系统代理未生效（注册表读回不一致）');
    }
    return SystemProxyResult.success;
  }

  // -- macOS ---------------------------------------------------------------

  Future<SystemProxyResult> _enableMacos(String host, int port) async {
    final service = await _macosActiveService();
    if (service == null) {
      return const SystemProxyResult(ok: false, detail: '找不到活动的网络服务');
    }
    for (final args in <List<String>>[
      ['-setwebproxy', service, host, '$port'],
      ['-setsecurewebproxy', service, host, '$port'],
      ['-setsocksfirewallproxy', service, host, '$port'],
    ]) {
      final result = await _run('networksetup', args);
      if (!result.ok) return result;
    }
    return SystemProxyResult.success;
  }

  /// 取当前正在使用的网络服务名（networksetup 需要服务名而不是接口名）。
  Future<String?> _macosActiveService() async {
    final route = await Process.run('route', ['-n', 'get', 'default']);
    final match = RegExp(r'interface:\s*(\w+)').firstMatch('${route.stdout}');
    final device = match?.group(1);
    if (device == null) return null;

    final order = await Process.run('networksetup', [
      '-listnetworkserviceorder',
    ]);
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

  // -- 公共 ----------------------------------------------------------------

  Future<Map<String, String>> _sessionEnv() async {
    if (!Platform.isLinux) return const {};
    var uid = Platform.environment['UID'];
    if (uid == null || uid.isEmpty) {
      uid = await _currentUid();
    }
    return linuxSessionEnv(Platform.environment, uid: uid);
  }

  Future<String?> _currentUid() async {
    try {
      final result = await Process.run('id', ['-u']);
      if (result.exitCode == 0) return '${result.stdout}'.trim();
    } on Object {
      // 拿不到就算了，交给上层报错
    }
    return null;
  }

  Future<SystemProxyResult> _run(
    String exe,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    try {
      final result = await Process.run(
        exe,
        args,
        environment: environment,
        includeParentEnvironment: true,
      );
      final out = '${result.stdout}'.trim();
      if (result.exitCode == 0) {
        return SystemProxyResult(ok: true, stdout: out);
      }
      final err = '${result.stderr}'.trim();
      return SystemProxyResult(
        ok: false,
        stdout: out,
        detail: err.isEmpty ? '$exe 退出码 ${result.exitCode}' : err,
      );
    } on ProcessException catch (e) {
      return SystemProxyResult(ok: false, detail: '无法执行 $exe：${e.message}');
    }
  }
}
