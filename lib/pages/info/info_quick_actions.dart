import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/webview/internal_browser_page.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 详情页的快捷动作：保存封面、内部浏览、外部打开。
///
/// 顶部菜单（[InfoActionsMenu]）与信息卡上的三个按钮共用这套实现，
/// 避免同一份逻辑在两处各写一遍。
class InfoQuickActions {
  const InfoQuickActions._();

  /// 番剧显示名，中文名优先。
  static String displayTitle(BangumiItem item) =>
      item.nameCn.trim().isEmpty ? item.name : item.nameCn;

  /// 复制番剧标题到剪贴板并提示。
  static Future<void> copyTitle(
    BuildContext context,
    BangumiItem item,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: displayTitle(item)));
      if (!context.mounted) return;
      _toast(context, '标题已复制');
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to copy title', error: error);
      if (!context.mounted) return;
      _toast(context, '复制失败，请重试');
    }
  }

  /// 把封面原图转成 PNG 存到相册（桌面端弹出另存为对话框）。
  static Future<void> saveCover(
    BuildContext context,
    BangumiItem item,
  ) async {
    final imageUrl = ['large', 'common', 'medium', 'small', 'grid']
        .map((size) => item.images[size]?.trim() ?? '')
        .firstWhere((url) => url.isNotEmpty, orElse: () => '');
    if (imageUrl.isEmpty) {
      _toast(context, '暂无封面');
      return;
    }
    final fileName = _coverFileName(displayTitle(item), item.id);
    try {
      final bytes = await _loadCoverPng(imageUrl);
      if (!context.mounted) return;

      if (isDesktop()) {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存封面',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['png'],
          bytes: bytes,
          lockParentWindow: true,
        );
        if (!context.mounted) return;
        if (path != null) _toast(context, '封面已保存');
        return;
      }

      final result = await SaverGallery.saveImage(
        bytes,
        fileName: fileName,
        skipIfExists: false,
      );
      if (!context.mounted) return;
      if (!result.isSuccess) {
        throw StateError(result.errorMessage ?? 'Gallery save failed');
      }
      _toast(context, '已保存到相册');
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to save cover', error: error);
      _toast(context, '封面保存失败，请重试');
    }
  }

  /// 在内置浏览器里打开该条目的 Bangumi 页面。
  static Future<void> openInternally(
    BuildContext context,
    BangumiItem item, {
    String userAgent = '',
  }) async {
    await context.pushNamed(
      '/info/browser',
      arguments: InternalBrowserArgs(
        url: 'https://bangumi.tv/subject/${item.id}',
        title: displayTitle(item),
        userAgent: userAgent,
      ),
    );
  }

  /// 用系统浏览器打开该条目的 Bangumi 页面。
  static Future<void> openExternally(
    BuildContext context,
    BangumiItem item,
  ) async {
    try {
      if (await launchUrl(
        Uri.https('bangumi.tv', '/subject/${item.id}'),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to open browser', error: error);
    }
    if (!context.mounted) return;
    _toast(context, '无法打开浏览器');
  }

  /// 分享条目：番剧名 + Bangumi 链接 + 中文简介。
  ///
  /// Bangumi 的 summary 字段有时会在中文简介后面附上 `[简介原文]` 与日文原文，
  /// 分享时只保留第一段中文简介，原文整块丢掉。
  static Future<void> share(
    BuildContext context,
    BangumiItem item,
  ) async {
    final title = displayTitle(item);
    final summary = _summaryWithoutOriginal(item.summary);
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('https://bangumi.tv/subject/${item.id}');
    if (summary.isNotEmpty) {
      buffer
        ..writeln()
        ..write(summary);
    }
    try {
      await SharePlus.instance.share(
        ShareParams(text: buffer.toString(), subject: title),
      );
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to share', error: error);
      if (!context.mounted) return;
      _toast(context, '分享失败，请重试');
    }
  }

  /// 去掉简介里附带的原文（日文）部分，只留中文简介。
  ///
  /// Bangumi 的中文简介后面会接一段原文，两者的分界是**连续三个以上换行**
  /// （实测 `\r\n\r\n\r\n\r\n`）；纯中文简介只有普通段落换行（`\r\n\r\n`），
  /// 不会被误切。`[简介原文]` 标记有时缺失或写法不同，因此只作为兜底：
  /// 两个分界点谁更靠前就用谁。
  static String _summaryWithoutOriginal(String summary) {
    final text = summary.replaceAll('\r\n', '\n');
    var cut = text.length;
    final gap = RegExp(r'\n{3,}').firstMatch(text);
    if (gap != null) cut = gap.start;
    final marker = RegExp(r'[\[【]\s*简介原文\s*[\]】]').firstMatch(text);
    if (marker != null && marker.start < cut) cut = marker.start;
    return text.substring(0, cut).trim();
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    KazumiDialog.showToast(context: context, message: message);
  }

  static String _coverFileName(String title, int subjectId) {
    final safeTitle = String.fromCharCodes(
      title
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .trim()
          .runes
          .take(60),
    );
    return '${safeTitle.isEmpty ? '封面' : safeTitle}-$subjectId.png';
  }

  static Future<Uint8List> _loadCoverPng(String imageUrl) async {
    final file = await CachedNetworkImageProvider.defaultCacheManager
        .getSingleFile(imageUrl)
        .timeout(const Duration(seconds: 30));
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      try {
        // Normalize cached formats to PNG without downscaling.
        final data =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('Could not encode cover');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
