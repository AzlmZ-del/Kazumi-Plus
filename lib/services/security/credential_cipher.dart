import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 凭据备份文件的 AES 加解密（内置固定密钥）。
///
/// 设计取舍（用户 2026-10-27 拍板）：
/// - 密钥硬编码在 App 内，备份/恢复全程无感，不弹口令框。
/// - 防护目标是「网盘侧泄露」：拿到 WebDAV 凭据或翻到云盘文件的人
///   读不出内容。防不了拆 APK 反编译（密钥在代码里）——个人自用可接受。
/// - 算法：AES-256-GCM（自带认证标签，密钥错误/文件被篡改时解密
///   直接抛异常，不会解出乱码）。
/// - 密钥派生：PBKDF2 把可读的内置口令拉伸成 32 字节密钥并固定 salt，
///   派生结果在进程内缓存，避免每次备份都跑几万轮迭代。
class CredentialCipher {
  CredentialCipher._();

  /// 内置口令。只用于 PBKDF2 派生，不以明文出现在备份文件里。
  static const String _passphrase = 'kazumi-credential-backup-v1';

  /// PBKDF2 固定盐。换成别的值 = 全部旧备份作废，改前想清楚。
  static const String _salt = 'kazumi-credential-cipher-salt';

  static const int _iterations = 20000;
  static const int _nonceBytes = 12;

  static Uint8List? _derivedKey;

  /// PBKDF2-HMAC-SHA256 派生 32 字节 AES 密钥，进程内缓存。
  static Uint8List _key() {
    final cached = _derivedKey;
    if (cached != null) {
      return cached;
    }
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode(_salt)),
        _iterations,
        32,
      ));
    final key = derivator.process(Uint8List.fromList(utf8.encode(_passphrase)));
    _derivedKey = key;
    return key;
  }

  /// 加密任意 UTF-8 文本，返回可直接 JSON 化的 base64 密文。
  static String encryptToBase64(String plaintext) {
    final secureRandom = _newSecureRandom();
    final nonce = secureRandom.nextBytes(_nonceBytes);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key()), 128, nonce, Uint8List(0)));
    final cipherText =
        cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    final packed = Uint8List(nonce.length + cipherText.length);
    packed.setRange(0, nonce.length, nonce);
    packed.setRange(nonce.length, packed.length, cipherText);
    return base64Encode(packed);
  }

  /// 解密 [base64Payload]（`encryptToBase64` 的输出）。
  ///
  /// 密钥不对 / payload 被篡改 / 格式非法都会抛 [ArgumentError] 或
  /// [InvalidCipherTextException]，由调用方转成用户提示。
  static String decryptFromBase64(String base64Payload) {
    final packed = base64Decode(base64Payload);
    if (packed.length <= _nonceBytes) {
      throw ArgumentError('凭据备份文件内容不完整');
    }
    final nonce = Uint8List.sublistView(packed, 0, _nonceBytes);
    final cipherText = Uint8List.sublistView(packed, _nonceBytes);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(_key()), 128, nonce, Uint8List(0)));
    final plain = cipher.process(cipherText);
    return utf8.decode(plain);
  }

  static SecureRandom _newSecureRandom() {
    final random = FortunaRandom();
    final seedSource = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = seedSource.nextInt(256);
    }
    random.seed(KeyParameter(seed));
    return random;
  }
}
