import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/crypto/crypto_service.dart';

void main() {
  final service = CryptoService();

  group('CryptoService', () {
    test('生成的密钥长度固定为 32 字节', () {
      for (var i = 0; i < 20; i++) {
        expect(service.generateMasterKey().length, kMasterKeyLength);
      }
    });

    test('两次生成的密钥不相同', () {
      final a = service.generateMasterKey();
      final b = service.generateMasterKey();
      expect(a, isNot(equals(b)));
    });

    test('加密再解密可以还原原文', () async {
      final key = service.generateMasterKey();
      const plain = '这是一段包含中文与 emoji 🚀 的配置内容';
      final envelope = await service.encryptString(plain, key);
      expect(await service.decryptString(envelope, key), plain);
    });

    test('密文信封不含明文', () async {
      final key = service.generateMasterKey();
      const secret = 'super-secret-password';
      final envelope = await service.encryptString(secret, key);
      expect(envelope.contains(secret), isFalse);
      final decoded = jsonDecode(envelope) as Map<String, dynamic>;
      expect(base64Decode(decoded['data'] as String), isNot(contains(secret)));
    });

    test('每次加密使用不同的 nonce，密文不重复', () async {
      final key = service.generateMasterKey();
      final first = await service.encryptString('same', key);
      final second = await service.encryptString('same', key);
      expect(first, isNot(equals(second)));
    });

    test('用错误的密钥解密会失败', () async {
      final envelope = await service.encryptString(
        'data',
        service.generateMasterKey(),
      );
      expect(
        () => service.decryptString(envelope, service.generateMasterKey()),
        throwsA(isA<CryptoException>()),
      );
    });

    test('密文被篡改会被 GCM 校验发现', () async {
      final key = service.generateMasterKey();
      final envelope = await service.encryptString('data', key);
      final map = jsonDecode(envelope) as Map<String, dynamic>;
      final data = base64Decode(map['data'] as String);
      data[0] ^= 0xFF;
      map['data'] = base64Encode(data);

      expect(
        () => service.decryptString(jsonEncode(map), key),
        throwsA(isA<CryptoException>()),
      );
    });

    test('密钥长度不对时立刻报错', () {
      expect(
        () => service.encryptToEnvelope(
          utf8.encode('x'),
          List<int>.filled(16, 0),
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('信封版本或算法不匹配时拒绝解密', () async {
      final key = service.generateMasterKey();
      final envelope = await service.encryptString('data', key);
      final map = jsonDecode(envelope) as Map<String, dynamic>;

      map['v'] = 999;
      expect(
        () => service.decryptString(jsonEncode(map), key),
        throwsA(isA<CryptoException>()),
      );

      map['v'] = kEnvelopeVersion;
      map['alg'] = 'ROT13';
      expect(
        () => service.decryptString(jsonEncode(map), key),
        throwsA(isA<CryptoException>()),
      );
    });

    test('非 JSON 内容会被拒绝', () {
      expect(
        () => service.decryptFromEnvelope(
          'not json',
          service.generateMasterKey(),
        ),
        throwsA(isA<CryptoException>()),
      );
    });
  });
}
