import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/proxy/proxy_core.dart';

void main() {
  group('stripAnsi', () {
    test('去掉 sing-box 输出里的颜色转义', () {
      const raw = '\u001b[31mFATAL\u001b[0m[0000] start service: bind failed';
      expect(stripAnsi(raw), 'FATAL[0000] start service: bind failed');
    });

    test('无转义时原样返回', () {
      expect(stripAnsi('plain line'), 'plain line');
    });

    test('多段转义都能清掉', () {
      const raw = '\u001b[36mINFO\u001b[0m \u001b[1mnetwork\u001b[0m: started';
      expect(stripAnsi(raw), 'INFO network: started');
    });
  });

  group('端口占用检查', () {
    test('已绑定端口会被识别为占用', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      final core = ProcessProxyCore(
        executablePath: '/nonexistent',
        mixedPort: port,
      );

      expect(await core.isPortInUse(port), isTrue);
      await socket.close();
    });

    test('空闲端口会被识别为空闲', () async {
      // 先占一个再放开，拿到一个"刚刚还空着"的端口号
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final core = ProcessProxyCore(
        executablePath: '/nonexistent',
        mixedPort: port,
      );
      expect(await core.isPortInUse(port), isFalse);
    });
  });

  group('启动失败时的报错', () {
    test('端口被占用时直接给出可操作的提示，不去启动内核', () async {
      // 占住端口，模拟"另一个客户端已经在跑"
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;

      final core = ProcessProxyCore(
        executablePath: '/nonexistent-binary',
        mixedPort: port,
        clashPort: 0,
      );

      final events = <CoreEvent>[];
      final sub = core.events.listen(events.add);

      await core.start(configJson: '{}', workingDirectory: '/tmp');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final failed = events
          .where((e) => e.status == CoreStatus.failed)
          .toList();
      expect(failed, isNotEmpty);
      expect(failed.last.message, contains('已被占用'));
      expect(failed.last.message, contains('$port'));
      // 提示里要告诉用户去哪儿改
      expect(failed.last.message, contains('设置'));

      await sub.cancel();
      await socket.close();
    });
  });
}
