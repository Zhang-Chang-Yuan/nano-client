import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../state/app_controller.dart';
import '../setup/setup_screen.dart';

/// 设置页：服务器、代理参数、DNS、账号与重置。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('服务器'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('面板地址'),
            subtitle: Text(
              state.config.panel.apiBase.isEmpty
                  ? '未配置'
                  : state.config.panel.apiBase,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SetupScreen()),
            ),
          ),
          if (state.config.panel.chatUrl != null)
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('客服'),
              subtitle: Text(state.config.panel.chatUrl!),
            ),

          const _SectionHeader('代理'),
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: const Text('监听地址'),
            subtitle: Text(state.config.proxy.listen),
          ),
          _PortTile(
            label: '混合端口（SOCKS5 + HTTP）',
            value: state.config.proxy.mixedPort,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(mixedPort: value),
            ),
          ),
          _PortTile(
            label: 'Clash API 端口',
            value: state.config.proxy.clashPort,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(clashPort: value),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vpn_lock_outlined),
            title: const Text('TUN 模式'),
            subtitle: const Text('接管全部流量，需要管理员权限'),
            value: state.config.proxy.enableTun,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(enableTun: value),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.speed_outlined),
            title: const Text('连接后自动测速'),
            subtitle: const Text('连接成功后逐节点测一次延迟，便于按延迟排序'),
            value: state.config.proxy.autoTestOnConnect,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(autoTestOnConnect: value),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.check_circle_outline),
            title: const Text('测速后自动选最快'),
            subtitle: const Text('测速完成后自动切到延迟最低的节点，省去连上再换线'),
            value: state.config.proxy.autoSelectFastest,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(autoSelectFastest: value),
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.language),
            title: const Text('自动接管系统代理'),
            subtitle: Text(
              state.systemProxyActive
                  ? '当前已接管；断开时自动还原'
                  : '连接时把系统代理指向本地端口，断开时还原',
            ),
            value: state.config.proxy.autoSystemProxy,
            onChanged: (value) => controller.updateProxy(
              state.config.proxy.copyWith(autoSystemProxy: value),
            ),
          ),

          const _SectionHeader('DNS'),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('私密 DNS'),
            subtitle: const Text('DoT 加密并经代理隧道，防止 DNS 泄漏'),
            trailing: Switch(
              value: state.config.proxy.safeDns,
              onChanged: (value) => controller.updateProxy(
                state.config.proxy.copyWith(safeDns: value),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('DNS 提供商'),
            subtitle: Text(state.config.proxy.dnsProvider.label),
            trailing: DropdownButton<DnsProvider>(
              value: state.config.proxy.dnsProvider,
              underline: const SizedBox.shrink(),
              onChanged: (value) {
                if (value == null) return;
                controller.updateProxy(
                  state.config.proxy.copyWith(dnsProvider: value),
                );
              },
              items: [
                for (final provider in DnsProvider.values)
                  DropdownMenuItem(
                    value: provider,
                    child: Text(provider.label),
                  ),
              ],
            ),
          ),

          const _SectionHeader('账号'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('当前账号'),
            subtitle: Text(
              state.config.account.email.isEmpty
                  ? '未登录'
                  : state.config.account.email,
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.password_outlined),
            title: const Text('记住密码'),
            subtitle: const Text('密码始终加密保存，关闭后会立即从配置中移除'),
            value: state.config.account.rememberPassword,
            onChanged: controller.setRememberPassword,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            onTap: controller.logout,
          ),

          const _SectionHeader('其它'),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('内核日志级别'),
            subtitle: Text(state.config.proxy.logLevel),
            trailing: DropdownButton<String>(
              value: state.config.proxy.logLevel,
              underline: const SizedBox.shrink(),
              onChanged: (value) {
                if (value == null) return;
                controller.updateProxy(
                  state.config.proxy.copyWith(logLevel: value),
                );
              },
              items: const [
                DropdownMenuItem(value: 'trace', child: Text('trace')),
                DropdownMenuItem(value: 'debug', child: Text('debug')),
                DropdownMenuItem(value: 'info', child: Text('info')),
                DropdownMenuItem(value: 'warn', child: Text('warn')),
                DropdownMenuItem(value: 'error', child: Text('error')),
              ],
            ),
          ),
          const _VersionTile(),
          ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              '重置应用',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text('清除本地配置与加密密钥，此操作不可撤销'),
            onTap: () => _confirmReset(context, ref),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置应用'),
        content: const Text('将删除本地加密配置与主密钥，且无法恢复。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定重置'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(appControllerProvider.notifier).reset();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _PortTile extends StatelessWidget {
  const _PortTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.settings_ethernet),
      title: Text(label),
      subtitle: Text('$value'),
      onTap: () async {
        final controller = TextEditingController(text: '$value');
        final result = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(label),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (result == null) return;
        final parsed = int.tryParse(result);
        if (parsed == null || parsed < 1 || parsed > 65535) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('端口必须是 1-65535 之间的整数')),
            );
          }
          return;
        }
        onChanged(parsed);
      },
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('版本'),
          subtitle: Text(
            info == null ? '读取中…' : '${info.version}+${info.buildNumber}',
          ),
        );
      },
    );
  }
}
