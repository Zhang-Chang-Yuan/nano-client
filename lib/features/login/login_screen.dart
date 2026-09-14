import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_controller.dart';
import '../common/ui_feedback.dart';
import '../setup/setup_screen.dart';

/// 登录页。
///
/// 密码只在本页输入；勾选「记住密码」后才会随配置一起**加密**落盘，
/// 否则仅在内存中保留到下次登录。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final account = ref.read(appControllerProvider).config.account;
    _emailController = TextEditingController(text: account.email);
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await ref
        .read(appControllerProvider.notifier)
        .login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
    // 登录成功后 _RootGate 会自动切到主页，无需手动跳转。
  }

  @override
  Widget build(BuildContext context) {
    ref.listenMessages(context);
    final state = ref.watch(appControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
        actions: [
          IconButton(
            tooltip: '服务器设置',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SetupScreen()),
            ),
          ),
        ],
      ),
      body: BusyOverlay(
        busy: state.busy,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(
                Icons.lock_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('登录账号', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                '服务器：${state.config.panel.apiBase}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (state.recoveredFromCorruption)
                _WarningBanner(
                  text:
                      '原配置文件无法读取，已重新初始化。'
                      '${state.corruptBackupPath == null ? '' : '备份：${state.corruptBackupPath}'}',
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.alternate_email),
                ),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return '请输入邮箱';
                  if (!v.contains('@')) return '邮箱格式不正确';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: '密码',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => _submit(),
                validator: (value) =>
                    (value == null || value.isEmpty) ? '请输入密码' : null,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('记住密码'),
                subtitle: const Text('勾选后密码会随配置一起加密保存到本地'),
                value: state.config.account.rememberPassword,
                onChanged: (value) => ref
                    .read(appControllerProvider.notifier)
                    .setRememberPassword(value),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: state.busy ? null : _submit,
                child: const Text('登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}
