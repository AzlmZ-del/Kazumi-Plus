import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/webview/internal_browser_page.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/image_saver.dart';
import 'package:kazumi/utils/device.dart';
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
  ///
  /// 复制成功时给一次轻震动（`lightImpact`），让长按有「按下去了」的实感；
  /// 桌面端该调用是空操作，不会报错。
  static Future<void> copyTitle(
    BuildContext context,
    BangumiItem item,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: displayTitle(item)));
      HapticFeedback.lightImpact();
      if (!context.mounted) return;
      _toast(context, '标题已复制');
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to copy title', error: error);
      if (!context.mounted) return;
      _toast(context, '复制失败，请重试');
    }
  }

  /// 把封面原图转成 PNG 存到相册（桌面端弹出另存为对话框）。
  ///
  /// 档位按原图优先挑：保存要的是最清晰的那张，
  /// 与列表封面的显示档位（[ImageQuality]）无关。
  static Future<void> saveCover(
    BuildContext context,
    BangumiItem item,
  ) async {
    final imageUrl = coverImageUrl(item);
    if (imageUrl.isEmpty) {
      _toast(context, '暂无封面');
      return;
    }
    final result = await ImageSaver.save(
      imageUrl: imageUrl,
      fileName: coverFileName(item),
    );
    if (!context.mounted) return;
    switch (result.status) {
      case ImageSaveStatus.saved:
        _toast(context, isDesktop() ? '封面已保存' : '已保存到相册');
      case ImageSaveStatus.cancelled:
        break;
      case ImageSaveStatus.failed:
        _toast(context, result.message);
    }
  }

  /// 条目封面的原图链接，按清晰度从高到低取第一个非空的。
  ///
  /// 各接口给的 images 键不一致（有的缺 `large`、有的 `common` 与 `large` 重复），
  /// 因此不认某个具体键，只认「第一个有值的」。
  static String coverImageUrl(BangumiItem item) {
    return ['large', 'common', 'medium', 'small', 'grid']
        .map((size) => item.images[size]?.trim() ?? '')
        .firstWhere((url) => url.isNotEmpty, orElse: () => '');
  }

  /// 封面保存时用的文件名（不含扩展名）。
  static String coverFileName(BangumiItem item) =>
      '${ImageSaver.safeName(displayTitle(item), fallback: '封面')}-${item.id}';

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

  /// 分享条目：番剧名 + 官方链接 + 两条深链 + 中文简介。
  ///
  /// 深链格式见 `KazumiDeepLink`：`kazumi://bangumi/<id>` 直开详情页，
  /// `kazumi://search?query=<关键词>` 以番剧名发起搜索。
  /// Bangumi 的 summary 字段有时会在中文简介后面附上 `[简介原文]` 与日文原文，
  /// 分享时只保留第一段中文简介，原文整块丢掉。
  static Future<void> share(
    BuildContext context,
    BangumiItem item,
  ) async {
    final title = displayTitle(item);
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: buildShareText(
            title: title,
            id: item.id,
            summary: _summaryWithoutOriginal(item.summary),
          ),
          subject: title,
        ),
      );
    } catch (error) {
      KazumiLogger().w('InfoQuickActions: failed to share', error: error);
      if (!context.mounted) return;
      _toast(context, '分享失败，请重试');
    }
  }

  /// 拼装分享正文。抽成纯函数，便于单测覆盖格式。
  ///
  /// 输出形如：
  /// ```
  /// 番剧名
  /// 官方链接：https://bangumi.tv/subject/1
  /// 详情直达：kazumi://bangumi/1
  /// 快速搜索：kazumi://search?query=%E7%95%AA%E5%89%A7%E5%90%8D
  ///
  /// 简介
  /// ```
  @visibleForTesting
  static String buildShareText({
    required String title,
    required int id,
    required String summary,
  }) {
    final detail = Uri(scheme: 'kazumi', host: 'bangumi', path: '/$id');
    final search = Uri(
      scheme: 'kazumi',
      host: 'search',
      queryParameters: {'query': title},
    );
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('官方链接：https://bangumi.tv/subject/$id')
      ..writeln('详情直达：$detail')
      ..write('快速搜索：$search');
    if (summary.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln()
        ..write(summary);
    }
    return buffer.toString();
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
}
