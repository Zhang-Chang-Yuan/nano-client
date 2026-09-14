// AES-256-GCM 加解密工具。
//
// 设计要点：
//   * 使用 `cryptography` 纯 Dart 实现，不依赖任何原生库，五个平台行为一致。
//   * 每次加密都生成随机 nonce，绝不复用。
//   * 密文信封自带算法与版本信息，便于日后平滑升级。
//
// 本文件不涉及任何密钥来源问题，密钥管理见 `ConfigKeyStore`。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 加密信封的版本号。
const int kEnvelopeVersion = 1;

/// 加密算法标识，写入信封，便于将来更换算法。
const String kEnvelopeAlgorithm = 'AES-256-GCM';

/// 生成的对称密钥长度（字节）。
const int kMasterKeyLength = 32;

/// 加解密失败时抛出。
class CryptoException implements Exception {
  CryptoException(this.message);

  final String message;

  @override
  String toString() => 'CryptoException: $message';
}

/// 对字节序列做 AES-256-GCM 加解密。
class CryptoService {
  CryptoService({AesGcm? algorithm, Random? random})
    : _algorithm = algorithm ?? AesGcm.with256bits(),
      _random = random ?? Random.secure();

  final AesGcm _algorithm;
  final Random _random;

  /// 生成一个新的 256 位主密钥。
  List<int> generateMasterKey() {
    final key = Uint8List(kMasterKeyLength);
    for (var i = 0; i < key.length; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }

  /// 加密明文，返回可直接落盘的信封字符串（JSON）。
  ///
  /// 信封中的 `data` 与 `mac` 分开存放，便于排查问题；
  /// 两者任一被篡改都会导致解密失败。
  Future<String> encryptToEnvelope(
    List<int> plainBytes,
    List<int> masterKey,
  ) async {
    _ensureKeyLength(masterKey);
    final nonce = _algorithm.newNonce();
    final secretKey = SecretKey(masterKey);
    final box = await _algorithm.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );
    return jsonEncode({
      'v': kEnvelopeVersion,
      'alg': kEnvelopeAlgorithm,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    });
  }

  /// 解密信封，返回明文字节。
  ///
  /// 任何格式错误、密钥错误或数据被改动都会抛出 [CryptoException]。
  Future<List<int>> decryptFromEnvelope(
    String envelope,
    List<int> masterKey,
  ) async {
    _ensureKeyLength(masterKey);

    final Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(envelope);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('信封不是 JSON 对象');
      }
      map = decoded;
    } on FormatException catch (e) {
      throw CryptoException('信封解析失败: ${e.message}');
    }

    final version = map['v'];
    if (version != kEnvelopeVersion) {
      throw CryptoException('不支持的信封版本: $version');
    }
    final alg = map['alg'];
    if (alg != kEnvelopeAlgorithm) {
      throw CryptoException('不支持的算法: $alg');
    }

    final List<int> nonce;
    final List<int> mac;
    final List<int> data;
    try {
      nonce = base64Decode(map['nonce'] as String);
      mac = base64Decode(map['mac'] as String);
      data = base64Decode(map['data'] as String);
    } on Object {
      throw CryptoException('信封中的 nonce/mac/data 不是合法 base64');
    }

    try {
      final clear = await _algorithm.decrypt(
        SecretBox(data, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(masterKey),
      );
      return clear;
    } on SecretBoxAuthenticationError {
      throw CryptoException('校验失败：密钥不匹配或配置已被篡改');
    } on Object catch (e) {
      throw CryptoException('解密失败: $e');
    }
  }

  /// 便捷方法：加密 UTF-8 文本。
  Future<String> encryptString(String plain, List<int> masterKey) =>
      encryptToEnvelope(utf8.encode(plain), masterKey);

  /// 便捷方法：解密为 UTF-8 文本。
  Future<String> decryptString(String envelope, List<int> masterKey) async {
    final bytes = await decryptFromEnvelope(envelope, masterKey);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw CryptoException('明文不是合法 UTF-8');
    }
  }

  void _ensureKeyLength(List<int> key) {
    if (key.length != kMasterKeyLength) {
      throw CryptoException('主密钥长度必须是 $kMasterKeyLength 字节，实际 ${key.length}');
    }
  }
}
