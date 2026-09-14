// TUN 模式需要的系统权限，以及一键授权。
//
// 背景：TUN 模式要在网络层接管流量（建虚拟网卡 + 改路由表），
// 这在 Linux 上需要 `CAP_NET_ADMIN`（多数发行版还要 `CAP_NET_RAW`）。
//
// 三种做法：
//   1. 整个应用用 sudo 跑      —— 体验最差，且把 GUI 也交给了 root
//   2. 每次连接弹密码框        —— 每次都要输密码，谈不上"一键"
//   3. **给内核二进制加 file capability** —— 授权一次，之后免密
//
// 这里采用第 3 种：`setcap cap_net_admin,cap_net_raw+ep <内核>`。
// 授权本身需要 root，通过 `pkexec` 触发一次系统密码框（polkit），
// 之后内核就能以普通用户身份创建 TUN 设备。
//
// 注意：内核每次重新释放（版本变化）都会丢掉 capability，需要重新授权。

import 'dart:io';

/// 我们的 TUN 网卡名。固定下来便于识别与清理残留。
const String kTunInterfaceName = 'nanotun';

/// TUN 网段，与 sing-box 配置保持一致。
const String kTunCidr = '172.19.0.0/30';

/// sing-box auto_route 使用的策略路由优先级起点。
const int kTunRulePriorityBase = 9000;
const int kTunRulePriorityEnd = 9010;

/// 权限状态。
enum TunPrivilegeStatus {
  /// 已具备创建 TUN 的权限。
  ready,

  /// 缺权限，但可以一键授权。
  needsGrant,

  /// 当前平台无法自动授权，只能手工处理。
  unsupported,
}

/// 检查 / 授权的结果。
class TunPrivilegeResult {
  const TunPrivilegeResult({
    required this.status,
    this.detail,
    this.command,
    this.hasLeftovers = false,
  });

  final TunPrivilegeStatus status;

  /// 需要向用户解释的原因。
  final String? detail;

  /// 无法自动授权时，给用户手工执行的命令。
  final String? command;

  /// 是否存在上次异常退出留下的残留（网卡/路由）。真实踩到过。
  final bool hasLeftovers;

  bool get isReady => status == TunPrivilegeStatus.ready;
}

/// TUN 权限与残留管理。
class TunPrivilege {
  const TunPrivilege();

  /// 需要的 capability。
  static const List<String> capabilities = ['cap_net_admin', 'cap_net_raw'];

  static String get _capSpec => '${capabilities.join(',')}+ep';

  /// 检查内核二进制是否已获得 TUN 权限。
  Future<TunPrivilegeResult> check(String executablePath) async {
    if (!Platform.isLinux) {
      return TunPrivilegeResult(
        status: TunPrivilegeStatus.unsupported,
        detail: Platform.isWindows
            ? 'Windows 下 TUN 需要管理员权限，请以管理员身份运行本应用'
            : 'macOS 下 TUN 需要 root 权限，请用 sudo 启动本应用',
      );
    }

    if (!File('/dev/net/tun').existsSync()) {
      return const TunPrivilegeResult(
        status: TunPrivilegeStatus.unsupported,
        detail: '系统没有 /dev/net/tun，无法使用 TUN 模式',
      );
    }

    final hasCaps = await _hasCapabilities(executablePath);
    final leftovers = await hasLeftovers();

    if (hasCaps) {
      return TunPrivilegeResult(
        status: TunPrivilegeStatus.ready,
        hasLeftovers: leftovers,
        detail: leftovers ? '检测到上次异常退出留下的路由残留' : null,
      );
    }

    return TunPrivilegeResult(
      status: TunPrivilegeStatus.needsGrant,
      detail: 'TUN 需要一次系统授权（给内核加 ${capabilities.join(" / ")} 权限），之后免密',
      command: manualCommand(executablePath),
      hasLeftovers: leftovers,
    );
  }

  /// 一键授权：通过 pkexec 触发一次系统密码框。
  Future<TunPrivilegeResult> grant(String executablePath) async {
    if (!Platform.isLinux) {
      return check(executablePath);
    }
    if (!File(executablePath).existsSync()) {
      return const TunPrivilegeResult(
        status: TunPrivilegeStatus.unsupported,
        detail: '找不到内核可执行文件，请先连接一次让它释放出来',
      );
    }

    final result = await Process.run('pkexec', [
      'setcap',
      _capSpec,
      executablePath,
    ]);

    if (result.exitCode != 0) {
      final err = '${result.stderr}'.trim();
      return TunPrivilegeResult(
        status: TunPrivilegeStatus.needsGrant,
        detail: err.isEmpty
            ? '授权未完成（pkexec 退出码 ${result.exitCode}）'
            : '授权未完成：$err',
        command: manualCommand(executablePath),
      );
    }

    // 不信任退出码，重新读一遍确认
    final after = await check(executablePath);
    if (!after.isReady) {
      return TunPrivilegeResult(
        status: TunPrivilegeStatus.needsGrant,
        detail: '授权命令执行了，但内核仍未获得权限',
        command: manualCommand(executablePath),
      );
    }
    return after;
  }

  /// 清理上次异常退出留下的 TUN 网卡与策略路由。
  ///
  /// 真实踩到过：内核被强杀时来不及回收，残留的规则会让下一次 TUN 启动行为异常。
  Future<String?> cleanupLeftovers() async {
    if (!Platform.isLinux) return '当前平台无需清理';

    final commands = <List<String>>[
      ['ip', 'link', 'del', 'dev', kTunInterfaceName],
      ..._priorityRange().map((p) => ['ip', 'rule', 'del', 'priority', '$p']),
    ];

    final failures = <String>[];
    for (final cmd in commands) {
      final result = await Process.run('pkexec', cmd);
      // 删除不存在的对象也会返回非 0，只记录真正意外的错误
      final err = '${result.stderr}'.trim();
      final ignorable =
          err.isEmpty ||
          err.contains('Cannot find device') ||
          err.contains('No such file') ||
          err.contains('No such process');
      if (result.exitCode != 0 && !ignorable) {
        failures.add('${cmd.join(" ")}: $err');
      }
    }

    if (failures.isNotEmpty) return failures.first;
    return null;
  }

  /// 是否检测到残留。
  Future<bool> hasLeftovers() async {
    if (!Platform.isLinux) return false;
    try {
      final link = await Process.run('ip', ['link', 'show', kTunInterfaceName]);
      if (link.exitCode == 0) return true;

      final rule = await Process.run('ip', ['rule', 'show']);
      final text = '${rule.stdout}';
      for (final p in _priorityRange()) {
        if (RegExp('^$p:', multiLine: true).hasMatch(text)) return true;
      }
    } on Object {
      // 查不了就当没有
    }
    return false;
  }

  Iterable<int> _priorityRange() sync* {
    for (var p = kTunRulePriorityBase; p <= kTunRulePriorityEnd; p++) {
      yield p;
    }
  }

  /// 无法自动授权时，给用户手工执行的命令。
  static String manualCommand(String executablePath) =>
      'sudo setcap $_capSpec "$executablePath"';

  Future<bool> _hasCapabilities(String executablePath) async {
    try {
      final result = await Process.run('getcap', [executablePath]);
      if (result.exitCode != 0) return false;
      final out = '${result.stdout}';
      return capabilities.every(out.contains);
    } on Object {
      // 没有 getcap（比如精简系统）时退回用 getfattr 查 xattr
      try {
        final r = await Process.run('getfattr', [
          '-n',
          'security.capability',
          executablePath,
        ]);
        return r.exitCode == 0 && '${r.stdout}'.isNotEmpty;
      } on Object {
        return false;
      }
    }
  }
}
