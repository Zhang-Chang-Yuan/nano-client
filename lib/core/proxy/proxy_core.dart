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
    this.clashPort = 9090,
    this.clashSecret = '',
    this.transport,
  });

  /// sing-box 可执行文件路径。
  final String executablePath;

  final int clashPort;
  final String clashSecret;

  /// 用于访问 Clash API 的 HTTP 传输层；为 null 时跳过就绪探测。
  final HttpTransport? transport;

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

  @override
  Future<void> start({
    required String configJson,
    required String workingDirectory,
  }) async {
    if (_status == CoreStatus.running || _status == CoreStatus.starting) {
      return;
    }
    _emit(CoreStatus.starting);

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
          .listen((line) => _emit(_status, logLine: line));
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _emit(_status, logLine: line));

      unawaited(
        process.exitCode.then((code) {
          _process = null;
          if (_status == CoreStatus.stopping || _status == CoreStatus.stopped) {
            _emit(CoreStatus.stopped);
          } else if (code == 0) {
            _emit(CoreStatus.stopped);
          } else {
            _emit(CoreStatus.failed, message: '内核退出，代码 $code');
          }
        }),
      );

      // 等 Clash API 就绪，避免 UI 立刻查询时失败。
      final ready = await _waitForClashApi();
      if (ready) {
        _emit(CoreStatus.running);
      } else {
        _emit(CoreStatus.failed, message: '内核启动超时，Clash API 未就绪');
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
}
