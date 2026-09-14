// 应用配置模型。
//
// 整个应用的**全部**可变状态都集中在这里，包括服务器（面板）配置、
// 账号、代理参数与界面偏好。它会被序列化成 JSON 后加密写入磁盘。
//
// 注意：本文件只负责数据结构与序列化，**不做任何加密**，
// 加密由 `ConfigRepository` 统一处理，避免密钥泄露到模型层。

import 'package:flutter/foundation.dart';

/// 路由模式。
///
/// 命名对齐原 App 的 `settings.connection.routeMode.mode.*` 设置项。
enum RouteMode {
  /// 自动分流：国内域名/IP 直连，其余走代理。
  auto('auto', '自动分流'),

  /// 全局代理：除局域网外全部走代理。
  global('global', '全局代理');

  const RouteMode(this.id, this.label);

  /// 持久化用的稳定标识，不要随意更改。
  final String id;

  /// 界面展示用的中文名。
  final String label;

  static RouteMode fromId(String? id) {
    return RouteMode.values.firstWhere(
      (m) => m.id == id,
      orElse: () => RouteMode.auto,
    );
  }
}

/// 私密 DNS 提供商。
///
/// 前两项对应原 App 内硬编码的 `ali_dns` / `google_dns`。
enum DnsProvider {
  ali('ali', '阿里 DNS', '223.5.5.5', '223.6.6.6'),
  google('google', 'Google DNS', '8.8.8.8', '8.8.4.4'),
  cloudflare('cloudflare', 'Cloudflare DNS', '1.1.1.1', '1.0.0.1');

  const DnsProvider(this.id, this.label, this.primary, this.secondary);

  final String id;
  final String label;
  final String primary;
  final String secondary;

  static DnsProvider fromId(String? id) {
    return DnsProvider.values.firstWhere(
      (p) => p.id == id,
      orElse: () => DnsProvider.ali,
    );
  }
}

/// 节点列表的排序方式。
enum NodeSortMode {
  /// 保持订阅返回的原始顺序。
  defaultOrder('default', '默认顺序'),

  /// 按测速延迟从低到高；未测速或测速失败的排在最后。
  delay('delay', '按延迟'),

  /// 按节点名称排序。
  name('name', '按名称');

  const NodeSortMode(this.id, this.label);

  final String id;
  final String label;

  static NodeSortMode fromId(String? id) {
    return NodeSortMode.values.firstWhere(
      (m) => m.id == id,
      orElse: () => NodeSortMode.defaultOrder,
    );
  }
}

/// 界面上的三档模式预设。
///
/// `safe` 等价于「自动分流 + 私密 DNS」，对应原 App 的 `safeDns` 开关。
enum AppMode {
  auto('auto', '自动', '国内直连、国外走代理'),
  global('global', '全局', '所有流量都走代理'),
  safe('safe', '安全', '自动分流 + 私密 DNS（DoT 经代理隧道）');

  const AppMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  /// 展开成底层的路由模式与私密 DNS 开关。
  (RouteMode, bool) get routeAndSafeDns => switch (this) {
    AppMode.auto => (RouteMode.auto, false),
    AppMode.global => (RouteMode.global, false),
    AppMode.safe => (RouteMode.auto, true),
  };

  /// 由底层配置反推当前处于哪个预设；无法精确对应时返回 `null`。
  static AppMode? fromConfig(RouteMode routeMode, bool safeDns) {
    if (safeDns && routeMode == RouteMode.auto) return AppMode.safe;
    if (!safeDns && routeMode == RouteMode.auto) return AppMode.auto;
    if (!safeDns && routeMode == RouteMode.global) return AppMode.global;
    return null;
  }
}

/// 面板（服务器）配置。
///
/// 由 `u.json` 下发，用户可以覆盖或手工填写。
@immutable
class PanelConfig {
  const PanelConfig({
    this.configSource,
    this.apiBase = '',
    this.chatUrl,
    this.owUrl,
  });

  /// 配置下发地址（`u.json`）。
  final String? configSource;

  /// 面板 API 根，例如 `https://example.com/api/v1`。
  final String apiBase;

  final String? chatUrl;
  final String? owUrl;

  bool get isComplete => apiBase.trim().isNotEmpty;

  PanelConfig copyWith({
    String? configSource,
    String? apiBase,
    String? chatUrl,
    String? owUrl,
  }) {
    return PanelConfig(
      configSource: configSource ?? this.configSource,
      apiBase: apiBase ?? this.apiBase,
      chatUrl: chatUrl ?? this.chatUrl,
      owUrl: owUrl ?? this.owUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'configSource': configSource,
    'apiBase': apiBase,
    'chatUrl': chatUrl,
    'owUrl': owUrl,
  };

  static PanelConfig fromJson(Map<String, dynamic> json) => PanelConfig(
    configSource: json['configSource'] as String?,
    apiBase: (json['apiBase'] as String?) ?? '',
    chatUrl: json['chatUrl'] as String?,
    owUrl: json['owUrl'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is PanelConfig &&
      other.configSource == configSource &&
      other.apiBase == apiBase &&
      other.chatUrl == chatUrl &&
      other.owUrl == owUrl;

  @override
  int get hashCode => Object.hash(configSource, apiBase, chatUrl, owUrl);
}

/// 账号配置。
///
/// 密码只有在用户勾选「记住密码」时才会写入配置文件；
/// 无论是否记住，落盘的整个配置文件都是加密的。
@immutable
class AccountConfig {
  const AccountConfig({
    this.email = '',
    this.password,
    this.authData,
    this.rememberPassword = true,
  });

  final String email;

  /// 用户密码。`null` 表示未保存。
  final String? password;

  /// 面板返回的 JWT（`auth_data`），用于免密调用接口。
  final String? authData;

  final bool rememberPassword;

  bool get hasSavedCredentials =>
      email.trim().isNotEmpty && (password?.isNotEmpty ?? false);

  AccountConfig copyWith({
    String? email,
    String? password,
    String? authData,
    bool? rememberPassword,
    bool clearPassword = false,
    bool clearAuthData = false,
  }) {
    return AccountConfig(
      email: email ?? this.email,
      password: clearPassword ? null : (password ?? this.password),
      authData: clearAuthData ? null : (authData ?? this.authData),
      rememberPassword: rememberPassword ?? this.rememberPassword,
    );
  }

  Map<String, dynamic> toJson() => {
    'email': email,
    'password': password,
    'authData': authData,
    'rememberPassword': rememberPassword,
  };

  static AccountConfig fromJson(Map<String, dynamic> json) => AccountConfig(
    email: (json['email'] as String?) ?? '',
    password: json['password'] as String?,
    authData: json['authData'] as String?,
    rememberPassword: (json['rememberPassword'] as bool?) ?? true,
  );

  @override
  bool operator ==(Object other) =>
      other is AccountConfig &&
      other.email == email &&
      other.password == password &&
      other.authData == authData &&
      other.rememberPassword == rememberPassword;

  @override
  int get hashCode => Object.hash(email, password, authData, rememberPassword);
}

/// 代理运行参数。
@immutable
class ProxyConfig {
  const ProxyConfig({
    this.routeMode = RouteMode.auto,
    this.safeDns = false,
    this.dnsProvider = DnsProvider.ali,
    this.listen = '127.0.0.1',
    this.mixedPort = 7890,
    this.clashPort = 9090,
    this.clashSecret = '',
    this.enableTun = false,
    this.logLevel = 'info',
    this.selectedNodeTag,
    this.nodeSort = NodeSortMode.defaultOrder,
    this.autoTestOnConnect = true,
    this.autoSelectFastest = false,
    this.autoSystemProxy = true,
    this.nodeChosenByUser = false,
  });

  final RouteMode routeMode;
  final bool safeDns;
  final DnsProvider dnsProvider;
  final String listen;
  final int mixedPort;
  final int clashPort;
  final String clashSecret;
  final bool enableTun;
  final String logLevel;

  /// 上次选中的节点 tag，用于启动时恢复。
  final String? selectedNodeTag;

  /// 节点列表排序方式。
  final NodeSortMode nodeSort;

  /// 连接成功后是否自动测速一次。
  final bool autoTestOnConnect;

  /// 测速后是否自动切到延迟最低的节点。
  ///
  /// 默认关闭：自动改用户已经选好的节点很容易让人困惑。
  /// 即便打开，也只会在用户**没有手动选过节点**时才生效（见 [nodeChosenByUser]）。
  final bool autoSelectFastest;

  /// 用户是否手动选过节点。
  ///
  /// 一旦为 true，就表示用户有自己的偏好，任何自动逻辑都不该覆盖它。
  final bool nodeChosenByUser;

  /// 连接时是否自动接管系统代理。
  ///
  /// 桌面端起内核只是开了个本地端口，浏览器默认不走它；
  /// 打开这一项后，连接会同时把系统代理指向该端口，断开时还原。
  final bool autoSystemProxy;

  ProxyConfig copyWith({
    RouteMode? routeMode,
    bool? safeDns,
    DnsProvider? dnsProvider,
    String? listen,
    int? mixedPort,
    int? clashPort,
    String? clashSecret,
    bool? enableTun,
    String? logLevel,
    String? selectedNodeTag,
    NodeSortMode? nodeSort,
    bool? autoTestOnConnect,
    bool? autoSelectFastest,
    bool? autoSystemProxy,
    bool? nodeChosenByUser,
    bool clearSelectedNode = false,
  }) {
    return ProxyConfig(
      routeMode: routeMode ?? this.routeMode,
      safeDns: safeDns ?? this.safeDns,
      dnsProvider: dnsProvider ?? this.dnsProvider,
      listen: listen ?? this.listen,
      mixedPort: mixedPort ?? this.mixedPort,
      clashPort: clashPort ?? this.clashPort,
      clashSecret: clashSecret ?? this.clashSecret,
      enableTun: enableTun ?? this.enableTun,
      logLevel: logLevel ?? this.logLevel,
      selectedNodeTag: clearSelectedNode
          ? null
          : (selectedNodeTag ?? this.selectedNodeTag),
      nodeSort: nodeSort ?? this.nodeSort,
      autoTestOnConnect: autoTestOnConnect ?? this.autoTestOnConnect,
      autoSelectFastest: autoSelectFastest ?? this.autoSelectFastest,
      autoSystemProxy: autoSystemProxy ?? this.autoSystemProxy,
      nodeChosenByUser: nodeChosenByUser ?? this.nodeChosenByUser,
    );
  }

  Map<String, dynamic> toJson() => {
    'routeMode': routeMode.id,
    'safeDns': safeDns,
    'dnsProvider': dnsProvider.id,
    'listen': listen,
    'mixedPort': mixedPort,
    'clashPort': clashPort,
    'clashSecret': clashSecret,
    'enableTun': enableTun,
    'logLevel': logLevel,
    'selectedNodeTag': selectedNodeTag,
    'nodeSort': nodeSort.id,
    'autoTestOnConnect': autoTestOnConnect,
    'autoSelectFastest': autoSelectFastest,
    'autoSystemProxy': autoSystemProxy,
    'nodeChosenByUser': nodeChosenByUser,
  };

  static ProxyConfig fromJson(Map<String, dynamic> json) => ProxyConfig(
    routeMode: RouteMode.fromId(json['routeMode'] as String?),
    safeDns: (json['safeDns'] as bool?) ?? false,
    dnsProvider: DnsProvider.fromId(json['dnsProvider'] as String?),
    listen: (json['listen'] as String?) ?? '127.0.0.1',
    mixedPort: _asInt(json['mixedPort'], 7890),
    clashPort: _asInt(json['clashPort'], 9090),
    clashSecret: (json['clashSecret'] as String?) ?? '',
    enableTun: (json['enableTun'] as bool?) ?? false,
    logLevel: (json['logLevel'] as String?) ?? 'info',
    selectedNodeTag: json['selectedNodeTag'] as String?,
    nodeSort: NodeSortMode.fromId(json['nodeSort'] as String?),
    autoTestOnConnect: (json['autoTestOnConnect'] as bool?) ?? true,
    autoSelectFastest: (json['autoSelectFastest'] as bool?) ?? false,
    autoSystemProxy: (json['autoSystemProxy'] as bool?) ?? true,
    nodeChosenByUser: (json['nodeChosenByUser'] as bool?) ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.routeMode == routeMode &&
      other.safeDns == safeDns &&
      other.dnsProvider == dnsProvider &&
      other.listen == listen &&
      other.mixedPort == mixedPort &&
      other.clashPort == clashPort &&
      other.clashSecret == clashSecret &&
      other.enableTun == enableTun &&
      other.logLevel == logLevel &&
      other.selectedNodeTag == selectedNodeTag &&
      other.nodeSort == nodeSort &&
      other.autoTestOnConnect == autoTestOnConnect &&
      other.autoSelectFastest == autoSelectFastest &&
      other.autoSystemProxy == autoSystemProxy &&
      other.nodeChosenByUser == nodeChosenByUser;

  @override
  int get hashCode => Object.hash(
    routeMode,
    safeDns,
    dnsProvider,
    listen,
    mixedPort,
    clashPort,
    clashSecret,
    enableTun,
    logLevel,
    selectedNodeTag,
    nodeSort,
    autoTestOnConnect,
    autoSelectFastest,
    autoSystemProxy,
    nodeChosenByUser,
  );
}

/// 应用总配置。
@immutable
class AppConfig {
  const AppConfig({
    this.schemaVersion = currentSchemaVersion,
    this.initialized = false,
    this.onboardingCompleted = false,
    this.panel = const PanelConfig(),
    this.account = const AccountConfig(),
    this.proxy = const ProxyConfig(),
    this.startMinimized = false,
    this.autoConnect = false,
  });

  /// 配置结构版本。升级时用它做迁移。
  static const int currentSchemaVersion = 1;

  final int schemaVersion;

  /// 是否已完成初始化。为 false 时进入首次配置向导。
  final bool initialized;

  /// 首次配置向导是否已走完。
  final bool onboardingCompleted;

  final PanelConfig panel;
  final AccountConfig account;
  final ProxyConfig proxy;

  final bool startMinimized;
  final bool autoConnect;

  /// 是否具备发起登录的最小条件。
  bool get canLogin => panel.isComplete && account.email.trim().isNotEmpty;

  AppConfig copyWith({
    int? schemaVersion,
    bool? initialized,
    bool? onboardingCompleted,
    PanelConfig? panel,
    AccountConfig? account,
    ProxyConfig? proxy,
    bool? startMinimized,
    bool? autoConnect,
  }) {
    return AppConfig(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      initialized: initialized ?? this.initialized,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      panel: panel ?? this.panel,
      account: account ?? this.account,
      proxy: proxy ?? this.proxy,
      startMinimized: startMinimized ?? this.startMinimized,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'initialized': initialized,
    'onboardingCompleted': onboardingCompleted,
    'panel': panel.toJson(),
    'account': account.toJson(),
    'proxy': proxy.toJson(),
    'startMinimized': startMinimized,
    'autoConnect': autoConnect,
  };

  /// 从 JSON 恢复配置。
  ///
  /// 采用防御式解析：缺失或类型不符的字段一律回退到默认值，
  /// 避免旧版本配置导致应用无法启动。
  /// （文件完整性由 AES-GCM 的认证标签保证，此处无需再对内容过度严格。）
  static AppConfig fromJson(Map<String, dynamic> json) {
    return AppConfig(
      schemaVersion: _asInt(json['schemaVersion'], currentSchemaVersion),
      initialized: (json['initialized'] as bool?) ?? false,
      onboardingCompleted: (json['onboardingCompleted'] as bool?) ?? false,
      panel: _asMap(json['panel'], PanelConfig.fromJson, const PanelConfig()),
      account: _asMap(
        json['account'],
        AccountConfig.fromJson,
        const AccountConfig(),
      ),
      proxy: _asMap(json['proxy'], ProxyConfig.fromJson, const ProxyConfig()),
      startMinimized: (json['startMinimized'] as bool?) ?? false,
      autoConnect: (json['autoConnect'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppConfig &&
      other.schemaVersion == schemaVersion &&
      other.initialized == initialized &&
      other.onboardingCompleted == onboardingCompleted &&
      other.panel == panel &&
      other.account == account &&
      other.proxy == proxy &&
      other.startMinimized == startMinimized &&
      other.autoConnect == autoConnect;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    initialized,
    onboardingCompleted,
    panel,
    account,
    proxy,
    startMinimized,
    autoConnect,
  );
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

T _asMap<T>(Object? value, T Function(Map<String, dynamic>) build, T fallback) {
  if (value is Map<String, dynamic>) return build(value);
  if (value is Map) return build(value.cast<String, dynamic>());
  return fallback;
}
