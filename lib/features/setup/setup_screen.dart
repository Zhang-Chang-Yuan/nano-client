import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../state/app_controller.dart';
import '../common/ui_feedback.dart';

/// 首次运行的初始化向导：确定面板（服务器）地址。
///
/// 服务器配置属于「全部配置」的一部分，会随其它配置一起加密写入配置文件，
/// 下次启动直接读取，不再进入本页。
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late final TextEditingController _apiController;
  bool _manual = false;

  @override
  void initState() {
    super.initState();
    _apiController = TextEditingController(
      text: ref.read(appControllerProvider).config.panel.apiBase,
    );
  }

  @override
  void dispose() {
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    final ok = await ref.read(appControllerProvider.notifier).discoverPanel();
    if (ok && mounted) {
      _apiController.text = ref
          .read(appControllerProvider)
          .config
          .panel
          .apiBase;
    }
  }

  Future<void> _confirmManual() async {
    final text = _apiController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写服务器 API 地址')));
      return;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址格式不正确，需形如 https://example.com/api/v1')),
      );
      return;
    }
    await ref
        .read(appControllerProvider.notifier)
        .updatePanel(PanelConfig(apiBase: text));
    await ref.read(appControllerProvider.notifier).setOnboardingCompleted(true);
  }

  @override
  Widget build(BuildContext context) {
    ref.listenMessages(context);
    final state = ref.watch(appControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('初始化')),
      body: BusyOverlay(
        busy: state.busy,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(
              Icons.travel_explore,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('配置服务器', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '服务器地址可以自动从配置源获取，也可以手动填写。\n'
              '这些信息会和其它配置一起加密保存到本地配置文件，'
              '下次启动自动读取。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: state.busy ? null : _discover,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('自动获取'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => setState(() => _manual = !_manual),
              icon: Icon(_manual ? Icons.expand_less : Icons.expand_more),
              label: Text(_manual ? '收起手动填写' : '手动填写地址'),
            ),
            if (_manual) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _apiController,
                decoration: const InputDecoration(
                  labelText: '面板 API 地址',
                  hintText: 'https://example.com/api/v1',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: state.busy ? null : _confirmManual,
                child: const Text('保存并继续'),
              ),
            ],
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('配置源', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final url in kDefaultConfigSources)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(url, style: theme.textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
