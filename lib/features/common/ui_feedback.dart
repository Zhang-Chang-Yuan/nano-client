import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_controller.dart';

/// 在界面上回显 [AppState] 里的 error / notice 一次性消息。
///
/// 用法：在页面 `build` 中调用 `ref.listenMessages(context)`。
extension MessageListener on WidgetRef {
  void listenMessages(BuildContext context) {
    listen<AppState>(appControllerProvider, (previous, next) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      if (next.error != null && next.error != previous?.error) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(next.error!),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              behavior: SnackBarBehavior.floating,
            ),
          );
        read(appControllerProvider.notifier).clearError();
      } else if (next.notice != null && next.notice != previous?.notice) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(next.notice!),
              behavior: SnackBarBehavior.floating,
            ),
          );
        read(appControllerProvider.notifier).clearNotice();
      }
    });
  }
}

/// 简单的加载遮罩。
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key, required this.busy, required this.child});

  final bool busy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x33000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
