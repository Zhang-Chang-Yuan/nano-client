import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../state/app_controller.dart';
import '../common/ui_feedback.dart';
import '../settings/settings_screen.dart';

/// 主页：连接开关 + 模式 + 节点列表。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listenMessages(context);
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nano'),
        actions: [
          IconButton(
            tooltip: '刷新节点',
            icon: const Icon(Icons.refresh),
            onPressed: state.busy ? null : controller.refreshSubscription,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: BusyOverlay(
        busy: state.busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectCard(state: state, onToggle: controller.toggle),
            const SizedBox(height: 16),
            _ModeSelector(state: state),
            const SizedBox(height: 16),
            if (state.subscription != null) ...[
              _SubscriptionCard(state: state),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Text('节点', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${state.nodes.length} 个',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.nodes.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Text('还没有节点'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: state.busy
                            ? null
                            : controller.refreshSubscription,
                        child: const Text('获取节点'),
                      ),
                    ],
                  ),
                ),
              )
            else
              Card(
                clipBehavior: Clip.antiAlias,
                child: RadioGroup<String>(
                  groupValue: state.selectedNodeTag,
                  onChanged: (value) {
                    if (value != null) controller.selectNode(value);
                  },
                  child: Column(
                    children: [
                      for (var i = 0; i < state.nodes.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        RadioListTile<String>(
                          value: state.nodes[i].tag,
                          title: Text(state.nodes[i].tag),
                          subtitle: Text(
                            '${state.nodes[i].protocol.toUpperCase()} · '
                            '${state.nodes[i].endpoint}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (state.coreLogs.isNotEmpty) ...[
              const SizedBox(height: 16),
              _CoreLogs(logs: state.coreLogs),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.state, required this.onToggle});

  final AppState state;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = state.isRunning;
    final scheme = theme.colorScheme;

    return Card(
      color: running ? scheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(state.coreStatus.label, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            Semantics(
              button: true,
              label: running ? '断开连接' : '建立连接',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: state.isBusy ? null : onToggle,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: running
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                  ),
                  child: Icon(
                    Icons.power_settings_new,
                    size: 56,
                    color: running ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              state.selectedNode?.tag ?? '未选择节点',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            if (running) ...[
              const SizedBox(height: 8),
              Text(
                'SOCKS5 / HTTP  ${state.config.proxy.listen}:${state.config.proxy.mixedPort}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  const _ModeSelector({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = AppMode.fromConfig(
      state.config.proxy.routeMode,
      state.config.proxy.safeDns,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('模式', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SegmentedButton<AppMode>(
              segments: [
                for (final mode in AppMode.values)
                  ButtonSegment<AppMode>(
                    value: mode,
                    label: Text(mode.label),
                    icon: Icon(_modeIcon(mode)),
                  ),
              ],
              selected: {current ?? AppMode.auto},
              onSelectionChanged: (selection) => ref
                  .read(appControllerProvider.notifier)
                  .setMode(selection.first),
            ),
            const SizedBox(height: 8),
            Text(
              (current ?? AppMode.auto).description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  IconData _modeIcon(AppMode mode) => switch (mode) {
    AppMode.auto => Icons.alt_route,
    AppMode.global => Icons.public,
    AppMode.safe => Icons.shield_outlined,
  };
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final info = state.subscription!;
    final theme = Theme.of(context);
    final ratio = info.usedRatio;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  info.plan?.name ?? '订阅',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                if (info.isExpired)
                  Text('已过期', style: TextStyle(color: theme.colorScheme.error))
                else if (info.expiredAt != null)
                  Text(
                    '到期 ${_formatDate(info.expiredAt!)}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if (ratio != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: ratio),
              const SizedBox(height: 6),
              Text(
                '已用 ${_formatBytes((info.usedUpload ?? 0) + (info.usedDownload ?? 0))}'
                ' / ${_formatBytes(info.transferEnable ?? 0)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CoreLogs extends StatelessWidget {
  const _CoreLogs({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        title: const Text('内核日志'),
        subtitle: Text('${logs.length} 行', style: theme.textTheme.bodySmall),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(
                logs.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String _formatDate(int epochSeconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
