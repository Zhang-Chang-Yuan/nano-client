// 应用状态与业务编排。
//
// 这一层是 UI 与「配置 / 面板 / 内核」三块核心逻辑之间的唯一粘合点：
// UI 只读 [AppState]、只调 [AppController] 的方法，不直接碰 IO。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api/dio_transport.dart';
import '../core/api/panel_api.dart';
import '../core/config/app_config.dart';
import '../core/config/config_repository.dart';
import '../core/proxy/core_provisioner.dart';
import '../core/proxy/proxy_core.dart';
import '../core/proxy/singbox_config.dart';
import '../core/proxy/system_proxy.dart';
import '../core/subscription/proxy_node.dart';

/// 配置下发地址候选，来自 APK 逆向（见 doc/01-recon.md §4.1）。
const List<String> kDefaultConfigSources = [
  'https://nanoapi.oss-ap-northeast-1.aliyuncs.com/u.json',
  'https://47.76.194.59/u.json',
  'https://54.37.159.199/u_nano.json',
];

// ---------------------------------------------------------------------------
// Provider 声明
// ---------------------------------------------------------------------------

/// 由 `main()` 覆盖为真实实例。
final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) => throw UnimplementedError('必须在 ProviderScope.overrides 中提供'),
);

/// 启动时加载到的配置结果。
final initialConfigProvider = Provider<ConfigLoadResult>(
  (ref) => throw UnimplementedError('必须在 ProviderScope.overrides 中提供'),
);

final httpTransportProvider = Provider<HttpTransport>((ref) => DioTransport());

final panelApiProvider = Provider<PanelApi>((ref) {
  final config = ref.watch(appControllerProvider).config;
  return PanelApi(
    transport: ref.watch(httpTransportProvider),
    apiBase: config.panel.apiBase,
  );
});

final appControllerProvider = NotifierProvider<AppController, AppState>(
  AppController.new,
);

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

@immutable
class AppState {
  const AppState({
    required this.config,
    this.coreStatus = CoreStatus.stopped,
    this.nodes = const [],
    this.subscription,
    this.busy = false,
    this.error,
    this.notice,
    this.coreLogs = const [],
    this.recoveredFromCorruption = false,
    this.corruptBackupPath,
    this.nodeDelays = const {},
    this.testingNodes = false,
    this.systemProxyActive = false,
    this.systemProxyDetail,
  });

  final AppConfig config;
  final CoreStatus coreStatus;
  final List<ProxyNode> nodes;
  final SubscribeInfo? subscription;

  /// 是否有耗时操作在进行，用于禁用按钮 / 显示进度。
  final bool busy;

  final String? error;
  final String? notice;

  /// 内核最近若干行日志，便于排查。
  final List<String> coreLogs;

  final bool recoveredFromCorruption;
  final String? corruptBackupPath;

  /// 测速结果：节点 tag -> 延迟（毫秒）。
  ///
  /// 未测速的节点不在表里；测速失败的记为 [failedDelay]。
  final Map<String, int> nodeDelays;

  /// 是否正在批量测速。
  final bool testingNodes;

  /// 系统代理是否已被本应用接管。
  final bool systemProxyActive;

  /// 接管失败时的原因。
  final String? systemProxyDetail;

  bool get isRunning => coreStatus == CoreStatus.running;

  /// 真正"连上了"：内核在跑，且系统代理已接管。
  bool get isConnected => isRunning && systemProxyActive;
  bool get isBusy => busy || coreStatus == CoreStatus.starting;

  /// 是否需要引导用户进入服务器配置向导。
  bool get needsSetup => !config.panel.isComplete;

  /// 是否需要登录。
  bool get needsLogin => !config.account.hasSavedCredentials;

  String? get selectedNodeTag => config.proxy.selectedNodeTag;

  ProxyNode? get selectedNode {
    final tag = selectedNodeTag;
    if (tag == null) return null;
    for (final node in nodes) {
      if (node.tag == tag) return node;
    }
    return null;
  }

  /// 测速失败的哨兵值。
  static const int failedDelay = -1;

  /// 按当前排序方式排好序的节点列表。
  List<ProxyNode> get sortedNodes {
    final list = List<ProxyNode>.of(nodes);
    switch (config.proxy.nodeSort) {
      case NodeSortMode.defaultOrder:
        break;
      case NodeSortMode.name:
        list.sort((a, b) => a.tag.compareTo(b.tag));
      case NodeSortMode.delay:
        list.sort((a, b) => _delayRank(a.tag).compareTo(_delayRank(b.tag)));
    }
    return list;
  }

  /// 排序用的延迟排名：可用延迟按数值排，失败与未测速一律排到最后。
  int _delayRank(String tag) {
    final delay = nodeDelays[tag];
    if (delay == null || delay <= 0) return 1 << 30;
    return delay;
  }

  AppState copyWith({
    AppConfig? config,
    CoreStatus? coreStatus,
    List<ProxyNode>? nodes,
    SubscribeInfo? subscription,
    bool? busy,
    String? error,
    String? notice,
    List<String>? coreLogs,
    bool? recoveredFromCorruption,
    String? corruptBackupPath,
    Map<String, int>? nodeDelays,
    bool? testingNodes,
    bool? systemProxyActive,
    String? systemProxyDetail,
    bool clearError = false,
    bool clearNotice = false,
    bool clearSubscription = false,
  }) {
    return AppState(
      config: config ?? this.config,
      coreStatus: coreStatus ?? this.coreStatus,
      nodes: nodes ?? this.nodes,
      subscription: clearSubscription
          ? null
          : (subscription ?? this.subscription),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      notice: clearNotice ? null : (notice ?? this.notice),
      coreLogs: coreLogs ?? this.coreLogs,
      recoveredFromCorruption:
          recoveredFromCorruption ?? this.recoveredFromCorruption,
      corruptBackupPath: corruptBackupPath ?? this.corruptBackupPath,
      nodeDelays: nodeDelays ?? this.nodeDelays,
      testingNodes: testingNodes ?? this.testingNodes,
      systemProxyActive: systemProxyActive ?? this.systemProxyActive,
      systemProxyDetail: systemProxyDetail ?? this.systemProxyDetail,
    );
  }
}

// ---------------------------------------------------------------------------
// 控制器
// ---------------------------------------------------------------------------

class AppController extends Notifier<AppState> {
  ProxyCore? _core;
  StreamSubscription<CoreEvent>? _coreSubscription;
  static const _systemProxy = SystemProxyController();
  bool _systemProxyApplied = false;
  List<String> _availableRuleSets = const [];

  @override
  AppState build() {
    final load = ref.read(initialConfigProvider);
    return AppState(
      config: load.config,
      recoveredFromCorruption: load.recoveredFromCorruption,
      corruptBackupPath: load.backupPath,
    );
  }

  ConfigRepository get _repository => ref.read(configRepositoryProvider);

  // -- 配置持久化 ---------------------------------------------------------

  Future<void> _persist(AppConfig config) async {
    state = state.copyWith(config: config, clearError: true);
    await _repository.save(config);
  }

  /// 更新面板（服务器）配置。
  Future<void> updatePanel(PanelConfig panel) async {
    await _persist(
      state.config.copyWith(
        panel: panel,
        initialized: state.config.initialized || panel.isComplete,
      ),
    );
  }

  /// 自动从配置源拉取面板地址。
  Future<bool> discoverPanel() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final panel = await PanelApi.fetchPanelConfigFromAny(
        ref.read(httpTransportProvider),
        kDefaultConfigSources,
      );
      await _persist(state.config.copyWith(panel: panel, initialized: true));
      state = state.copyWith(busy: false, notice: '已获取服务器配置：${panel.apiBase}');
      return true;
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '获取服务器配置失败：$e');
      return false;
    }
  }

  Future<void> updateProxy(ProxyConfig proxy) async {
    await _persist(state.config.copyWith(proxy: proxy));
  }

  /// 是否记住密码。关闭时会立即把已保存的密码从配置里抹掉。
  Future<void> setRememberPassword(bool value) async {
    final account = state.config.account;
    if (value) {
      await _persist(
        state.config.copyWith(
          account: account.copyWith(rememberPassword: true),
        ),
      );
      return;
    }
    await _persist(
      state.config.copyWith(
        account: account.copyWith(rememberPassword: false, clearPassword: true),
      ),
    );
  }

  /// 界面上的三档模式切换。
  Future<void> setMode(AppMode mode) async {
    final (routeMode, safeDns) = mode.routeAndSafeDns;
    await updateProxy(
      state.config.proxy.copyWith(
        routeMode: routeMode,
        safeDns: safeDns,
        // 安全模式默认用 App 内置的 google_dns
        dnsProvider:
            safeDns && state.config.proxy.dnsProvider == DnsProvider.ali
            ? DnsProvider.google
            : state.config.proxy.dnsProvider,
      ),
    );
  }

  Future<void> setOnboardingCompleted(bool value) async {
    await _persist(state.config.copyWith(onboardingCompleted: value));
  }

  void clearError() => state = state.copyWith(clearError: true);

  void clearNotice() => state = state.copyWith(clearNotice: true);

  // -- 登录 ---------------------------------------------------------------

  Future<bool> login({required String email, required String password}) async {
    final panel = state.config.panel;
    if (!panel.isComplete) {
      state = state.copyWith(error: '请先配置服务器地址');
      return false;
    }

    state = state.copyWith(busy: true, clearError: true);
    try {
      final api = PanelApi(
        transport: ref.read(httpTransportProvider),
        apiBase: panel.apiBase,
      );
      final result = await api.login(email: email, password: password);
      final remember = state.config.account.rememberPassword;
      await _persist(
        state.config.copyWith(
          initialized: true,
          account: state.config.account.copyWith(
            email: email,
            // 只有勾选「记住密码」才落盘；落盘内容整体加密。
            password: remember ? password : null,
            clearPassword: !remember,
            authData: result.authData,
          ),
        ),
      );
      state = state.copyWith(busy: false, notice: '登录成功');
      await refreshSubscription();
      return true;
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '登录失败：$e');
      return false;
    }
  }

  Future<void> logout() async {
    await stop();
    await _persist(state.config.copyWith(account: const AccountConfig()));
    state = state.copyWith(nodes: const [], clearSubscription: true);
  }

  /// 使用已保存的凭据静默登录（启动时调用）。
  Future<void> loginWithSavedCredentials() async {
    final account = state.config.account;
    final password = account.password;
    if (!account.hasSavedCredentials || password == null) {
      state = state.copyWith(error: '没有可用的已保存凭据，请手动登录');
      return;
    }
    await login(email: account.email, password: password);
  }

  // -- 订阅与节点 ---------------------------------------------------------

  Future<void> refreshSubscription() async {
    final authData = state.config.account.authData;
    if (authData == null || authData.isEmpty) {
      state = state.copyWith(error: '缺少登录凭据，请重新登录');
      return;
    }

    state = state.copyWith(busy: true, clearError: true);
    try {
      final api = PanelApi(
        transport: ref.read(httpTransportProvider),
        apiBase: state.config.panel.apiBase,
      );
      final info = await api.getSubscribe(authData);
      final content = await api.fetchSubscription(info.subscribeUrl);
      final parsed = parseSubscription(content);

      List<ProxyNode> nodes = parsed.nodes;
      if (parsed.config != null) {
        // 服务端直接下发了完整配置：这里只提取 outbound 的 tag 供界面展示，
        // 真正的配置注入在连接时处理（后续版本完善）。
        nodes = const [];
      }

      if (nodes.isEmpty) {
        state = state.copyWith(
          busy: false,
          subscription: info,
          nodes: const [],
          error: parsed.config != null
              ? '服务端返回的是完整配置，当前版本仅支持节点列表'
              : '订阅中没有解析到可用节点',
        );
        return;
      }

      final selected = state.config.proxy.selectedNodeTag;
      final stillValid =
          selected != null && nodes.any((n) => n.tag == selected);
      final tag = stillValid ? selected : nodes.first.tag;

      await _persist(
        state.config.copyWith(
          proxy: state.config.proxy.copyWith(selectedNodeTag: tag),
        ),
      );
      state = state.copyWith(
        busy: false,
        nodes: nodes,
        subscription: info,
        // 节点换了，旧的测速结果不再有意义
        nodeDelays: const {},
        notice: '已获取 ${nodes.length} 个节点',
      );
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '获取节点失败：$e');
    }
  }

  /// 切换节点。
  Future<void> selectNode(String tag) async {
    await _persist(
      state.config.copyWith(
        proxy: state.config.proxy.copyWith(selectedNodeTag: tag),
      ),
    );
    final core = _core;
    if (core is ProcessProxyCore && state.isRunning) {
      try {
        await core.selectNode('proxy', tag);
      } on Object catch (e) {
        state = state.copyWith(error: '切换节点失败：$e');
      }
    }
  }

  /// 切换节点列表的排序方式。
  Future<void> setNodeSort(NodeSortMode mode) async {
    await updateProxy(state.config.proxy.copyWith(nodeSort: mode));
  }

  /// 批量测速。
  ///
  /// 走 Clash API，由内核**经由每个节点**发一次小请求，所以需要内核在运行。
  /// 为了不必"先连接才能测速"，这里会在需要时**静默把内核拉起来**；
  /// 这一步**不接管系统代理** —— 用户只是想先看看哪个节点快。
  ///
  /// 测完若开启了 [ProxyConfig.autoSelectFastest]，会切到延迟最低的节点，
  /// 这样随后点连接就直接用最快的线路，不用连上再换。
  Future<void> testAllNodes() async {
    if (state.testingNodes || state.nodes.isEmpty) return;

    if (!state.isRunning) {
      state = state.copyWith(busy: true, clearError: true);
      try {
        final started = await _startCore();
        state = state.copyWith(busy: false);
        if (!started) return; // _startCore 已经写入错误
      } on Object catch (e) {
        state = state.copyWith(busy: false, error: '启动内核失败：$e');
        return;
      }
    }

    final core = _core;
    if (core is! ProcessProxyCore) return;

    final tags = state.nodes.map((n) => n.tag).toList();
    state = state.copyWith(
      testingNodes: true,
      nodeDelays: const {},
      clearError: true,
    );

    final results = <String, int>{};
    // 并发太高会让内核同时开太多连接，反而把延迟测歪；4 是个稳妥值。
    const concurrency = 4;
    for (var i = 0; i < tags.length; i += concurrency) {
      final batch = tags.skip(i).take(concurrency).toList();
      await Future.wait(
        batch.map((tag) async {
          final delay = await core.testDelay(tag);
          results[tag] = delay == null || delay <= 0
              ? AppState.failedDelay
              : delay;
          // 每测完一个就刷新一次，界面立刻能看到结果
          state = state.copyWith(nodeDelays: Map<String, int>.of(results));
        }),
      );
    }

    final ok = results.values.where((d) => d > 0).length;
    state = state.copyWith(
      testingNodes: false,
      nodeDelays: results,
      notice: '测速完成：$ok / ${tags.length} 个节点可用',
    );

    if (state.config.proxy.autoSelectFastest) {
      final fastest = _fastestTag(results, tags);
      if (fastest != null && fastest != state.selectedNodeTag) {
        await selectNode(fastest);
        state = state.copyWith(notice: '已自动选择最快的节点：$fastest');
      }
    }
  }

  /// 在测速结果里挑延迟最低的；全部失败时返回 null。
  String? _fastestTag(Map<String, int> results, List<String> order) {
    String? best;
    var bestDelay = 1 << 30;
    for (final tag in order) {
      final delay = results[tag];
      if (delay == null || delay <= 0) continue;
      if (delay < bestDelay) {
        bestDelay = delay;
        best = tag;
      }
    }
    return best;
  }

  // -- 内核生命周期 -------------------------------------------------------

  Future<ProvisionResult> _provisionCore() async {
    final support = await getApplicationSupportDirectory();
    final provisioner = CoreProvisioner(
      assetBundle: rootBundle,
      targetDirectory: Directory('${support.path}/core'),
      coreVersion: await _resolveCoreVersion(),
    );
    final result = await provisioner.provision();
    _availableRuleSets = result.availableRuleSets;
    return result;
  }

  Future<String> _resolveCoreVersion() async {
    try {
      final manifest = await rootBundle.loadString('assets/bin/VERSION');
      return manifest.trim();
    } on Object {
      return 'unknown';
    }
  }

  /// 只把内核拉起来，**不接管系统代理**。
  ///
  /// 测速也需要内核（要经各节点发包），所以这一步被 connect 与 testAllNodes 共用。
  /// 返回内核是否处于运行状态。
  Future<bool> _startCore() async {
    if (state.isRunning) return true;

    if (state.nodes.isEmpty) {
      await refreshSubscription();
      if (state.nodes.isEmpty) return false;
    }

    final provision = await _provisionCore();
    final config = buildSingboxConfig(
      nodes: state.nodes,
      proxy: state.config.proxy,
      availableRuleSets: _availableRuleSets,
      listen: state.config.proxy.listen,
      mixedPort: state.config.proxy.mixedPort,
      clashPort: state.config.proxy.clashPort,
      clashSecret: state.config.proxy.clashSecret,
      cachePath: '${provision.workingDirectory}/cache.db',
      defaultNodeTag: state.selectedNodeTag,
    );

    final core = ProcessProxyCore(
      executablePath: provision.executablePath,
      mixedPort: state.config.proxy.mixedPort,
      clashPort: state.config.proxy.clashPort,
      clashSecret: state.config.proxy.clashSecret,
      transport: ref.read(httpTransportProvider),
    );
    await _coreSubscription?.cancel();
    _coreSubscription = core.events.listen(_onCoreEvent);
    _core = core;

    await core.start(
      configJson: encodeConfig(config),
      workingDirectory: provision.workingDirectory,
    );

    // ⚠️ 必须读 core.status，不能读 state.isRunning。
    // state.coreStatus 是由事件流异步更新出来的，core.start() 返回时
    // 那个 running 事件可能还没投递到，读 state 会误判成启动失败，
    // 导致后面的系统代理接管被整段跳过。
    return core.status == CoreStatus.running;
  }

  /// 连接：拉起内核，并把系统代理指向它。
  Future<void> connect() async {
    // 内核在跑但系统代理没接管时，这一下是"接管"，不能直接返回
    if (state.busy) return;
    if (state.isRunning && state.systemProxyActive) return;

    state = state.copyWith(busy: true, clearError: true);

    try {
      final started = await _startCore();
      if (!started) {
        state = state.copyWith(busy: false);
        return;
      }

      await _applySystemProxy();
      state = state.copyWith(busy: false);

      // 连接后自动测一轮速，让节点列表直接带上延迟并自动选最快
      if (state.config.proxy.autoTestOnConnect) {
        unawaited(testAllNodes());
      }
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '启动失败：$e');
    }
  }

  /// 把系统代理指向本应用的本地端口。
  Future<void> _applySystemProxy() async {
    if (!state.config.proxy.autoSystemProxy) {
      state = state.copyWith(
        systemProxyActive: false,
        systemProxyDetail: '已在设置中关闭自动接管，需手动配置代理',
      );
      return;
    }
    if (!_systemProxy.isSupported) {
      state = state.copyWith(
        systemProxyActive: false,
        systemProxyDetail: '当前平台不支持自动设置，请手动配置代理',
      );
      return;
    }

    final host = state.config.proxy.listen == '0.0.0.0'
        ? '127.0.0.1'
        : state.config.proxy.listen;
    final result = await _systemProxy.enable(
      host: host,
      port: state.config.proxy.mixedPort,
    );
    _systemProxyApplied = result.ok;
    state = state.copyWith(
      systemProxyActive: result.ok,
      systemProxyDetail: result.ok ? null : result.detail,
    );
  }

  /// 还原系统代理。
  Future<void> _clearSystemProxy() async {
    if (!_systemProxyApplied) {
      state = state.copyWith(systemProxyActive: false);
      return;
    }
    await _systemProxy.disable();
    _systemProxyApplied = false;
    state = state.copyWith(systemProxyActive: false, systemProxyDetail: null);
  }

  Future<void> stop() async {
    await _clearSystemProxy();

    final core = _core;
    if (core == null) {
      state = state.copyWith(coreStatus: CoreStatus.stopped, busy: false);
      return;
    }
    await core.stop();
    state = state.copyWith(coreStatus: CoreStatus.stopped, busy: false);
  }

  /// 电源按钮：已接管则断开，否则（含"内核在跑但没接管"）执行接管。
  Future<void> toggle() async {
    if (state.isConnected) {
      await stop();
    } else {
      await connect();
    }
  }

  void _onCoreEvent(CoreEvent event) {
    final logs = [...state.coreLogs];
    if (event.logLine != null) {
      logs.add(event.logLine!);
      if (logs.length > 200) logs.removeRange(0, logs.length - 200);
    }
    state = state.copyWith(
      coreStatus: event.status,
      coreLogs: logs,
      busy: event.status == CoreStatus.starting,
      error: event.status == CoreStatus.failed ? event.message : null,
    );
  }

  /// 重置：抹掉配置与主密钥。
  Future<void> reset() async {
    await stop();
    await _repository.reset();
    state = const AppState(config: AppConfig());
  }
}

/// 内核供应来源（测试中可替换）。
final coreAssetBundleProvider = Provider<AssetBundle>((ref) => rootBundle);
