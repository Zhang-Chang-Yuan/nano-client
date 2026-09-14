// sing-box 内核的启动、停止与运行时控制。
//
// 抽象出 [ProxyCore] 是为了让上层 UI 与具体平台解耦：
//   * 桌面端（Linux/Windows/macOS）用 [ProcessProxyCore]，把官方 sing-box
//     可执行文件作为子进程拉起，通过 Clash API 控制节点切换。
//   * 移动端（Android/iOS）需要一个把 sing-box 编译进应用的实现
//     （libbox + VpnService），见 `docs/PLATFORMS.md`。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/panel_api.dart';

/// 去掉内核输出里的 ANSI 颜色转义。
///
/// sing-box 会给日志上色，直接把原始行塞进界面会看到一堆 `\x1b[31m`。
String stripAnsi(String input) =>
    input.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');

/// 内核运行状态。
enum CoreStatus {
  stopped('已停止'),
  starting('启动中'),
  running('运行中'),
  stopping('停止中'),
  failed('启动失败');

  const CoreStatus(this.label);

  final String label;
}

/// 内核事件。
class CoreEvent {
  const CoreEvent(this.status, {this.message, this.logLine});

  final CoreStatus status;
  final String? message;
  final String? logLine;
}

/// 内核接口。
abstract class ProxyCore {
  /// 状态变化流。
  Stream<CoreEvent> get events;

  CoreStatus get status;

  /// 用给定的 sing-box 配置启动内核。
  ///
  /// [configJson] 是完整的 sing-box 配置；[workingDirectory] 必须包含
  /// 配置引用的规则集等资源。
  Future<void> start({
    required String configJson,
    required String workingDirectory,
  });

  /// 停止内核。
  Future<void> stop();

  /// 释放资源。
  Future<void> dispose();
}

/// 通过子进程运行官方 sing-box 可执行文件（桌面端）。
class ProcessProxyCore implements ProxyCore {
  ProcessProxyCore({
    required this.executablePath,
    this.mixedPort = 7890,
    this.clashPort = 9090,
    this.clashSecret = '',
    this.transport,
  });

  /// sing-box 可执行文件路径。
  final String executablePath;

  /// 混合入站（SOCKS5 + HTTP）端口，用于启动前的占用检查。
  final int mixedPort;

  final int clashPort;
  final String clashSecret;

  /// 用于访问 Clash API 的 HTTP 传输层；为 null 时跳过就绪探测。
  final HttpTransport? transport;

  /// 内核最近若干行输出，启动失败时用来回溯原因。
  final List<String> _recentOutput = [];

  final _controller = StreamController<CoreEvent>.broadcast();
  Process? _process;
  CoreStatus _status = CoreStatus.stopped;

  @override
  Stream<CoreEvent> get events => _controller.stream;

  @override
  CoreStatus get status => _status;

  void _emit(CoreStatus status, {String? message, String? logLine}) {
    _status = status;
    if (!_controller.isClosed) {
      _controller.add(CoreEvent(status, message: message, logLine: logLine));
    }
  }

  /// 记录内核输出，供启动失败时回溯原因。
  void _recordOutput(String rawLine) {
    final line = stripAnsi(rawLine);
    if (line.trim().isEmpty) return;
    _recentOutput.add(line);
    if (_recentOutput.length > 40) _recentOutput.removeAt(0);
    _emit(_status, logLine: line);
  }

  /// 从最近的输出里挑一条最能说明问题的，作为失败原因。
  String _failureDetail() {
    if (_recentOutput.isEmpty) return '';
    // 优先 FATAL/ERROR，其次最后一行
    for (final line in _recentOutput.reversed) {
      if (line.contains('FATAL') || line.contains('ERROR')) {
        return '：${_stripLevel(line)}';
      }
    }
    return '：${_recentOutput.last}';
  }

  String _stripLevel(String line) {
    // sing-box 的行形如 "FATAL[0000] start service: ..."
    final match = RegExp(r'^(FATAL|ERROR|WARN|INFO)\[\d+\]\s*')
        .firstMatch(line);
    return match == null ? line : line.substring(match.end);
  }

  /// 检查端口是否已被占用。
  ///
  /// 内核在端口冲突时只会打印一行 FATAL 就退出，从界面上看很像"启动超时"，
  /// 所以这里提前查一次，给出能直接照着做的提示。
  Future<bool> isPortInUse(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await socket.close();
      return false;
    } on SocketException {
      return true;
    }
  }

  @override
  Future<void> start({
    required String configJson,
    required String workingDirectory,
  }) async {
    if (_status == CoreStatus.running || _status == CoreStatus.starting) {
      return;
    }
    _emit(CoreStatus.starting);
    _recentOutput.clear();

    for (final entry in {'混合代理': mixedPort, 'Clash API': clashPort}.entries) {
      if (await isPortInUse(entry.value)) {
        _emit(
          CoreStatus.failed,
          message:
              '${entry.key}端口 ${entry.value} 已被占用，'
              '请在「设置 → 代理」里换一个端口后重试',
        );
        return;
      }
    }

    final dir = Directory(workingDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final configFile = File('${dir.path}/singbox-config.json');
    await configFile.writeAsString(configJson, flush: true);

    final executable = File(executablePath);
    if (!executable.existsSync()) {
      _emit(CoreStatus.failed, message: '找不到内核可执行文件: $executablePath');
      return;
    }

    try {
      final process = await Process.start(executablePath, [
        'run',
        '-c',
        configFile.path,
      ], workingDirectory: dir.path);
      _process = process;

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_recordOutput);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_recordOutput);

      unawaited(
        process.exitCode.then((code) {
          _process = null;
          if (_status == CoreStatus.stopping || _status == CoreStatus.stopped) {
            _emit(CoreStatus.stopped);
          } else if (code == 0) {
            _emit(CoreStatus.stopped);
          } else {
            // 把内核自己的报错带出来，别只留一个退出码
            _emit(
              CoreStatus.failed,
              message: '内核退出（代码 $code）${_failureDetail()}',
            );
          }
        }),
      );

      // 等 Clash API 就绪，避免 UI 立刻查询时失败。
      final ready = await _waitForClashApi();
      if (ready) {
        _emit(CoreStatus.running);
      } else if (_status != CoreStatus.failed) {
        // 没就绪且进程也没报错 —— 多半是等超时了
        _emit(
          CoreStatus.failed,
          message: '内核启动超时，Clash API 未就绪${_failureDetail()}',
        );
      }
    } on Object catch (e) {
      _emit(CoreStatus.failed, message: '启动失败: $e');
    }
  }

  @override
  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      _emit(CoreStatus.stopped);
      return;
    }
    _emit(CoreStatus.stopping);
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    _process = null;
    _emit(CoreStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  Future<bool> _waitForClashApi() async {
    final httpTransport = transport;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_process == null) return false;
      if (httpTransport == null) return true;
      try {
        final response = await httpTransport.send(
          ApiRequest(
            method: 'GET',
            url: 'http://127.0.0.1:$clashPort/version',
            headers: _clashHeaders,
            timeout: const Duration(seconds: 2),
          ),
        );
        if (response.isOk) return true;
      } on Object {
        // 还没起来，继续等
      }
    }
    return false;
  }

  Map<String, String> get _clashHeaders => {
    if (clashSecret.isNotEmpty) 'Authorization': 'Bearer $clashSecret',
  };

  /// 读取 Clash API 的代理组信息。
  Future<Map<String, dynamic>> fetchProxies() async {
    final httpTransport = transport;
    if (httpTransport == null) throw StateError('未提供 HttpTransport');
    final response = await httpTransport.send(
      ApiRequest(
        method: 'GET',
        url: 'http://127.0.0.1:$clashPort/proxies',
        headers: _clashHeaders,
      ),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Clash API 返回了非预期内容');
    }
    return decoded;
  }

  /// 切换 Selector 组当前选中的节点。
  Future<void> selectNode(String groupTag, String nodeTag) async {
    final httpTransport = transport;
    if (httpTransport == null) throw StateError('未提供 HttpTransport');
    await httpTransport.send(
      ApiRequest(
        method: 'PUT',
        url: 'http://127.0.0.1:$clashPort/proxies/$groupTag',
        headers: {..._clashHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': nodeTag}),
      ),
    );
  }

  /// 测速用的目标地址。
  ///
  /// Clash API 会**经由被测节点**请求它，因此不要求本机直连可达。
  /// `generate_204` 是各家客户端约定俗成的测速端点，响应体极小。
  static const String defaultTestUrl = 'http://www.gstatic.com/generate_204';

  /// 通过 Clash API 测试单个节点的延迟。
  ///
  /// 返回毫秒数；超时或失败返回 `null`。**不抛异常**，方便批量测速时逐个降级。
  Future<int?> testDelay(
    String nodeTag, {
    String url = defaultTestUrl,
    int timeoutMs = 5000,
  }) async {
    final httpTransport = transport;
    if (httpTransport == null) throw StateError('未提供 HttpTransport');

    final query = Uri(queryParameters: {'timeout': '$timeoutMs', 'url': url})
        .query;

    try {
      final response = await httpTransport.send(
        ApiRequest(
          method: 'GET',
          url:
              'http://127.0.0.1:$clashPort/proxies/'
              '${Uri.encodeComponent(nodeTag)}/delay?$query',
          headers: _clashHeaders,
          timeout: Duration(milliseconds: timeoutMs + 3000),
        ),
      );
      if (!response.isOk) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final delay = decoded['delay'];
      if (delay is int) return delay;
      if (delay is num) return delay.toInt();
      return null;
    } on Object {
      return null;
    }
  }
}
