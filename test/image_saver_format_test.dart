import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:kazumi/services/network/image_saver.dart';

/// 造一张最小的 PNG，用于验证「已无损就不再重编码」与尺寸读取。
Uint8List _tinyPng(int width, int height) {
  final image = im.Image(width: width, height: height);
  return Uint8List.fromList(im.encodePng(image));
}

Uint8List _tinyJpg(int width, int height) {
  final image = im.Image(width: width, height: height);
  return Uint8List.fromList(im.encodeJpg(image));
}

void main() {
  group('字节数文案', () {
    test('小于 1 KB 用字节', () {
      expect(ImageFileInfo.formatBytes(512), '512 B');
    });

    test('KB 段四舍五入到整数', () {
      expect(ImageFileInfo.formatBytes(1024), '1 KB');
      expect(ImageFileInfo.formatBytes(172 * 1024), '172 KB');
    });

    test('超过 1 MB 保留一位小数', () {
      expect(ImageFileInfo.formatBytes(1536 * 1024), '1.5 MB');
    });

    test('十几 MB 不再带小数', () {
      expect(ImageFileInfo.formatBytes(15 * 1024 * 1024), '15 MB');
    });
  });

  group('尺寸与格式描述', () {
    test('PNG 读出真实宽高', () {
      final bytes = _tinyPng(1920, 1080);
      final size = ImageSaver.readDimensions(bytes);
      expect(size, isNotNull);
      expect(size!.$1, 1920);
      expect(size.$2, 1080);
    });

    test('JPEG 读出真实宽高', () {
      final bytes = _tinyJpg(800, 600);
      final size = ImageSaver.readDimensions(bytes);
      expect(size, isNotNull);
      expect(size!.$1, 800);
      expect(size.$2, 600);
    });

    test('无法识别的数据不猜尺寸', () {
      final garbage = Uint8List.fromList(List.filled(64, 0x00));
      expect(ImageSaver.readDimensions(garbage), isNull);
    });

    test('summary 拼上格式、尺寸与体积', () {
      const info = ImageFileInfo(
        width: 1920,
        height: 1080,
        extension: 'jpg',
        byteSize: 172 * 1024,
      );
      expect(info.sizeLabel, '1920 × 1080');
      expect(info.formatLabel, 'JPEG');
      expect(info.summary, 'JPEG · 1920 × 1080 · 172 KB');
    });
  });

  group('转 PNG', () {
    test('本来就是 PNG 时原样返回，不重复编码', () async {
      final source = _tinyPng(64, 64);
      final result = await ImageSaver.toPng(source);
      expect(result, isNotNull);
      expect(identical(result, source), isTrue);
    });

    test('JPEG 转出来的确实是 PNG 魔数', () async {
      final jpg = _tinyJpg(64, 64);
      final png = await ImageSaver.toPng(jpg);
      expect(png, isNotNull);
      expect(ImageSaver.extensionOf(png!), 'png');
      // 转码后应该能重新读出同样的宽高。
      final size = ImageSaver.readDimensions(png);
      expect(size, isNotNull);
      expect(size!.$1, 64);
      expect(size.$2, 64);
    });

    test('损坏数据转码失败时返回 null，而不是抛异常', () async {
      final garbage = Uint8List.fromList(List.filled(32, 0xFF));
      expect(await ImageSaver.toPng(garbage), isNull);
    });
  });

  group('转 JPG', () {
    test('图源是 JPEG 也重新编码，保证与「保存原图」不等价', () {
      final source = _tinyJpg(64, 64);
      final result = ImageSaver.toJpg(source);
      expect(result, isNotNull);
      // 不能再是原样返回：两项功能重复是之前实测发现的缺陷。
      expect(identical(result, source), isFalse);
      expect(ImageSaver.extensionOf(result!), 'jpg');
    });

    test('PNG 转出来的确实是 JPEG 魔数', () {
      final png = _tinyPng(64, 64);
      final jpg = ImageSaver.toJpg(png);
      expect(jpg, isNotNull);
      expect(ImageSaver.extensionOf(jpg!), 'jpg');
      final size = ImageSaver.readDimensions(jpg);
      expect(size, isNotNull);
      expect(size!.$1, 64);
      expect(size.$2, 64);
    });

    test('带透明通道的 PNG 转 JPEG 不会失败', () {
      final source = Uint8List.fromList(
        im.encodePng(im.Image(width: 32, height: 32, numChannels: 4)),
      );
      final jpg = ImageSaver.toJpg(source);
      expect(jpg, isNotNull);
      expect(ImageSaver.extensionOf(jpg!), 'jpg');
    });

    test('转出的 JPEG 用 yuv420 而非库默认的 yuv444', () {
      // 渐变色图：两种色度采样的体积差在这里最明显，纯色图测不出来。
      final image = im.Image(width: 256, height: 256);
      for (var y = 0; y < 256; y++) {
        for (var x = 0; x < 256; x++) {
          image.setPixelRgb(x, y, x, y, (x + y) % 256);
        }
      }
      final source = Uint8List.fromList(im.encodePng(image));
      final actual = ImageSaver.toJpg(source)!;
      final yuv444 = Uint8List.fromList(
        im.encodeJpg(image, quality: 95, chroma: im.JpegChroma.yuv444),
      );
      final yuv420 = Uint8List.fromList(
        im.encodeJpg(image, quality: 95, chroma: im.JpegChroma.yuv420),
      );
      // 产物体积应贴着 yuv420，而不是库默认的 yuv444。
      expect(actual.length, yuv420.length);
      expect(actual.length, lessThan(yuv444.length));
    });

    test('损坏数据转码失败时返回 null，而不是抛异常', () {
      final garbage = Uint8List.fromList(List.filled(32, 0xFF));
      expect(ImageSaver.toJpg(garbage), isNull);
    });
  });
}
