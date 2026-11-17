import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as im;
import 'package:saver_gallery/saver_gallery.dart';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';

/// 保存格式的选择。
enum ImageSaveFormat {
  /// 原样写出原始字节，不重新编码——画质与体积都保持图源提供的样子。
  original,

  /// 转成 PNG 后写出。无损，但 JPEG 图源转过来体积会涨数倍，
  /// 且已丢掉的细节找不回来。
  png,

  /// 转成 JPEG 后写出。有损，透明通道会被白底铺平；
  /// 体积通常远小于 PNG，适合分享与外传。
  jpg,
}

/// 一张图的基本信息，用于在保存菜单上展示。
class ImageFileInfo {
  const ImageFileInfo({
    required this.width,
    required this.height,
    required this.extension,
    required this.byteSize,
  });

  final int width;
  final int height;
  final String extension;
  final int byteSize;

  /// `1920 × 1080` 形式的尺寸文案。
  String get sizeLabel => '$width × $height';

  /// `JPEG` / `PNG` 这类格式文案。
  String get formatLabel =>
      extension.toUpperCase() == 'JPG' ? 'JPEG' : extension.toUpperCase();

  /// `JPEG · 1920 × 1080 · 172 KB`，保存菜单一行说明用。
  String get summary => '$formatLabel · $sizeLabel · ${formatBytes(byteSize)}';

  /// 把字节数写成 `172 KB` / `1.5 MB`。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.round()} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }
}

/// 一次保存的三种结局。
enum ImageSaveStatus {
  /// 已落盘（进了相册，或另存为指定了路径）。
  saved,

  /// 用户在另存为对话框里取消，不算失败，调用方不要提示错误。
  cancelled,

  /// 下载、转码或写盘出错。
  failed,
}

/// 保存结果。[message] 只在 [ImageSaveStatus.failed] 时有内容，可直接提示用户。
class ImageSaveResult {
  const ImageSaveResult._(this.status, [this.message = '']);

  const ImageSaveResult.saved() : this._(ImageSaveStatus.saved);

  const ImageSaveResult.cancelled() : this._(ImageSaveStatus.cancelled);

  factory ImageSaveResult.failed([String message = '图片保存失败，请重试']) =>
      ImageSaveResult._(ImageSaveStatus.failed, message);

  final ImageSaveStatus status;
  final String message;
}

/// 把网络图片存进相册（桌面端弹另存为对话框）。
///
/// 详情页的「保存封面」与全屏预览里的长按保存共用这条链路。
///
/// 存的是**原始字节**，不做转码：图源本来就是 JPEG，
/// 硬转 PNG 会让 172 KB 的封面涨到 1.5 MB，纯属白占空间。
/// 扩展名按文件头魔数判定，所以 .jpg / .png / .webp 都能各归各位。
class ImageSaver {
  const ImageSaver._();

  /// 保存 [imageUrl]。文件名不带扩展名，扩展名由真实图片格式决定。
  ///
  /// [format] 为 [ImageSaveFormat.png] / [ImageSaveFormat.jpg] 时会重新编码；
  /// 转码失败就退回原始字节，不让用户点了保存却什么都没落下。
  static Future<ImageSaveResult> save({
    required String imageUrl,
    required String fileName,
    ImageSaveFormat format = ImageSaveFormat.original,
  }) async {
    if (imageUrl.trim().isEmpty) {
      return ImageSaveResult.failed('暂无图片');
    }
    try {
      final source = await loadBytes(imageUrl);
      final bytes = switch (format) {
        ImageSaveFormat.original => source,
        ImageSaveFormat.png => await toPng(source) ?? source,
        ImageSaveFormat.jpg => toJpg(source) ?? source,
      };
      final fullName = '$fileName.${extensionOf(bytes)}';
      if (isDesktop()) {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存图片',
          fileName: fullName,
          type: FileType.custom,
          allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
          bytes: bytes,
          lockParentWindow: true,
        );
        return path == null
            ? const ImageSaveResult.cancelled()
            : const ImageSaveResult.saved();
      }
      if (Platform.isAndroid) {
        // saver_gallery 会解码再压缩，存「原图」时体积会翻倍、画质也会掉一遍。
        // 安卓这边自己写 MediaStore，字节原样落盘。
        await const MethodChannel(
          _galleryWriterChannel,
        ).invokeMethod<String>('saveImage', {
          'bytes': bytes,
          'fileName': fullName,
          'mimeType': _mimeTypeOf(extensionOf(bytes)),
        });
        return const ImageSaveResult.saved();
      }
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: fullName,
        skipIfExists: false,
      );
      if (!result.isSuccess) {
        throw StateError(result.errorMessage ?? 'Gallery save failed');
      }
      return const ImageSaveResult.saved();
    } catch (error) {
      KazumiLogger().w('ImageSaver: failed to save image', error: error);
      return ImageSaveResult.failed();
    }
  }

  /// 安卓侧原样写盘的通道（见 `GalleryWriter.kt`）。
  static const String _galleryWriterChannel =
      'com.predidit.kazumi/gallery_writer';

  /// 扩展名对应的 MIME，写进 MediaStore 后系统才知道怎么归类。
  static String _mimeTypeOf(String extension) => switch (extension) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => 'image/jpeg',
  };

  /// 读出尺寸、格式与体积，供保存菜单展示。
  ///
  /// 只解析文件头拿宽高，不整张解码：1920×2800 的图解码要占几十 MB 内存，
  /// 而菜单只是要显示三个数字。解析不出来时返回 null，调用方不显示即可。
  static Future<ImageFileInfo?> describe(String imageUrl) async {
    if (imageUrl.trim().isEmpty) return null;
    try {
      final bytes = await loadBytes(imageUrl);
      final extension = extensionOf(bytes);
      final size = readDimensions(bytes);
      return ImageFileInfo(
        width: size?.$1 ?? 0,
        height: size?.$2 ?? 0,
        extension: extension,
        byteSize: bytes.length,
      );
    } catch (error) {
      KazumiLogger().w('ImageSaver: failed to describe image', error: error);
      return null;
    }
  }

  /// 只解析文件头拿宽高，不整张解码。
  ///
  /// 1920×2800 的图整张解码要占几十 MB 内存并耗时上百毫秒，而菜单只是
  /// 要显示两个数字。解不出宽高时返回 null。
  static (int, int)? readDimensions(Uint8List bytes) {
    try {
      final decoder = im.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (decoder == null || info == null) return null;
      if (info.width <= 0 || info.height <= 0) return null;
      return (info.width, info.height);
    } catch (_) {
      // startDecode 拿到异常数据时会抛，按「不知道尺寸」处理即可。
      return null;
    }
  }

  /// 把任意格式的图片转成 PNG 字节；转了也没意义或转不动时返回 null。
  ///
  /// 已经是 PNG 的原样返回，避免无谓的重新编码。
  static Future<Uint8List?> toPng(Uint8List source) async {
    try {
      if (extensionOf(source) == 'png') return source;
      final decoded = im.decodeImage(source);
      if (decoded == null) return null;
      return Uint8List.fromList(im.encodePng(decoded));
    } catch (error) {
      KazumiLogger().w('ImageSaver: failed to encode png', error: error);
      return null;
    }
  }

  /// 把任意格式的图片转成 JPEG 字节；转不动时返回 null。
  ///
  /// 这里**总是**重新编码，即使图源本来就是 JPEG：卡片上「保存为 JPG」与
  /// 「保存原图」是两个不同的选项，前者要的是统一格式，原样返回会让两项
  /// 完全等价，用户点了也看不出区别。带透明通道的图由编码器铺白底。
  ///
  /// [chroma] 必须是 yuv420：image 包默认 yuv444 会保留每个像素的完整色度，
  /// 实测同一张 1366×1948 封面，yuv444 出 941,929 字节、yuv420 出 743,606，
  /// 与相机和图源的通用编码一致才用后者。
  ///
  /// q=95 是产品上固定的档位（用户 2026-11-16 明确要求），不随图源调整。
  static Uint8List? toJpg(Uint8List source, {int quality = 95}) {
    try {
      final decoded = im.decodeImage(source);
      if (decoded == null) return null;
      return Uint8List.fromList(
        im.encodeJpg(
          decoded,
          quality: quality.clamp(1, 100),
          chroma: im.JpegChroma.yuv420,
        ),
      );
    } catch (error) {
      KazumiLogger().w('ImageSaver: failed to encode jpg', error: error);
      return null;
    }
  }

  /// 取网络图片的原始字节。
  ///
  /// 走缓存管理器，已经加载过的图不会二次下载。
  static Future<Uint8List> loadBytes(String imageUrl) async {
    final file = await CachedNetworkImageProvider.defaultCacheManager
        .getSingleFile(imageUrl)
        .timeout(const Duration(seconds: 30));
    return file.readAsBytes();
  }

  /// 按文件头魔数判断图片格式，返回不带点的扩展名。
  ///
  /// 不能信 URL 后缀，也不能信缓存文件名：缓存落盘时用的是 UUID + 通用后缀。
  /// 判不出来时按 jpg 兜底，图源绝大多数是 JPEG。
  static String extensionOf(Uint8List bytes) {
    bool startsWith(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    // JPEG 魔数：FF D8 FF
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
    // PNG 魔数：89 50 4E 47 0D 0A 1A 0A
    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'png';
    }
    // GIF 魔数：GIF87a / GIF89a
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
    // WebP 魔数：RIFF....WEBP
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
        startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'webp';
    }
    // BMP 魔数：BM
    if (startsWith(const [0x42, 0x4D])) return 'bmp';
    return 'jpg';
  }

  /// 把任意标题清洗成可用作文件名的片段。
  ///
  /// 去掉文件系统保留字符，按 [maxLength] 截断；全被清空时用 [fallback] 兜底。
  static String safeName(
    String title, {
    int maxLength = 60,
    String fallback = '图片',
  }) {
    final name = String.fromCharCodes(
      title
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .trim()
          .runes
          .take(maxLength),
    );
    return name.isEmpty ? fallback : name;
  }
}
