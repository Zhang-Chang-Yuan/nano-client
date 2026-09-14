import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/proxy_core.dart';
import 'package:nano_client/state/app_controller.dart';

void main() {
  group('新增代理设置的序列化', () {
    test('自动接管系统代理 / 自动选最快 能往返', () {
      const original = ProxyConfig(
        autoSystemProxy: false,
        autoSelectFastest: false,
        autoTestOnConnect: false,
        nodeSort: NodeSortMode.delay,
      );

      final restored = ProxyConfig.fromJson(original.toJson());

      expect(restored, equals(original));
      expect(restored.autoSystemProxy, isFalse);
      expect(restored.autoSelectFastest, isFalse);
      expect(restored.nodeSort, NodeSortMode.delay);
    });

    test('旧版本配置缺少这些字段时按开启处理（向后兼容）', () {
      // 模拟上一版写下的配置：没有 autoSystemProxy / autoSelectFastest
      final legacy = ProxyConfig.fromJson({
        'routeMode': 'auto',
        'safeDns': false,
        'mixedPort': 7890,
        'nodeSort': 'default',
      });

      expect(legacy.autoSystemProxy, isTrue);
      expect(legacy.autoSelectFastest, isTrue);
      expect(legacy.autoTestOnConnect, isTrue);
    });

    test('线程化整份配置后新字段保持不变', () {
      const config = AppConfig(
        proxy: ProxyConfig(autoSystemProxy: false, autoSelectFastest: false),
      );
      final restored = AppConfig.fromJson(config.toJson());
      expect(restored.proxy.autoSystemProxy, isFalse);
      expect(restored.proxy.autoSelectFastest, isFalse);
    });
  });

  group('连接状态语义', () {
    test('内核在跑但系统代理未接管时不算已连接', () {
      const state = AppState(
        config: AppConfig(),
        coreStatus: CoreStatus.running,
        systemProxyActive: false,
      );

      expect(state.isRunning, isTrue);
      expect(state.isConnected, isFalse);
    });

    test('内核在跑且系统代理已接管才算已连接', () {
      const state = AppState(
        config: AppConfig(),
        coreStatus: CoreStatus.running,
        systemProxyActive: true,
      );
      expect(state.isConnected, isTrue);
    });

    test('内核停了就不算已连接', () {
      const state = AppState(
        config: AppConfig(),
        coreStatus: CoreStatus.stopped,
        systemProxyActive: true,
      );
      expect(state.isConnected, isFalse);
    });
  });
}
