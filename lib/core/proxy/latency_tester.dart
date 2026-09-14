// 不依赖内核的节点延迟测量。
//
// 之前「测速」会偷偷把内核拉起来（因为走 Clash API 才能实测），
// 副作用是界面直接进入"已连接"状态、却又不接管系统代理，
// 让人以为连上了却又不能用。
//
// 这里改用 TCP 握手耗时：只需要一条到 `server:port` 的连接，
// 起不到内核、不碰系统代理。
//
// 代价是它测的是**到节点入口的往返时延**，而不是整条代理链路的表现
// （节点挂在 CDN 后面时，测到的是 CDN 边缘）。因此：
//   * 未连接时用 TCP 延迟 —— 足够区分哪个节点快
//   * 已连接时仍用 Clash API 实测 —— 更贴近真实体验

import 'dart:io';

/// TCP 握手延迟测量器。
class TcpLatencyTester {
  const TcpLatencyTester();

  /// 测一次 TCP 握手耗时（毫秒）。
  ///
  /// 失败或超时返回 `null`，不抛异常，方便批量测速时逐个降级。
  Future<int?> ping(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (host.isEmpty || port <= 0) return null;

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } on Object {
      return null;
    } finally {
      // 立刻关掉：我们只关心握手耗时，不建立会话
      socket?.destroy();
    }
  }
}
