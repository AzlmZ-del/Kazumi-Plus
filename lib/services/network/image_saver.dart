import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';

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
  static Future<ImageSaveResult> save({
    required String imageUrl,
    required String fileName,
  }) async {
    if (imageUrl.trim().isEmpty) {
      return ImageSaveResult.failed('暂无图片');
    }
    try {
      final bytes = await loadBytes(imageUrl);
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

    // JPEG: FF D8 FF
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'png';
    }
    // GIF: GIF87a / GIF89a
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
    // WebP: RIFF....WEBP
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
        startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'webp';
    }
    // BMP: BM
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
