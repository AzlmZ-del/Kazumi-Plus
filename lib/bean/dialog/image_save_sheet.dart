import 'dart:async';

import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/services/network/image_saver.dart';
import 'package:kazumi/utils/device.dart';

/// 弹出「保存图片」卡片，选完格式直接落盘。
///
/// 全屏预览的长按与详情页封面的长按共用这一处，避免两份菜单各写一遍。
/// 卡片用底部弹层而不是贴着手指的气泡：手机与桌面同一套，长按位置也不挑剔。
///
/// [label] 是弹层标题里的对象名（`封面` / `图片`），会拼上分辨率；
/// [fileBaseName] 是不带扩展名的文件名，扩展名由真实图片格式决定。
Future<void> showImageSaveSheet(
  BuildContext context, {
  required String imageUrl,
  required String fileBaseName,
  String label = '图片',
}) async {
  if (imageUrl.trim().isEmpty) {
    KazumiDialog.showToast(context: context, message: '暂无图片');
    return;
  }

  // 尺寸要下载完才知道，弹层不等人：先出标题与按钮，信息到了再补。
  final info = ValueNotifier<ImageFileInfo?>(null);
  var sheetOpen = true;
  unawaited(() async {
    final described = await ImageSaver.describe(imageUrl);
    // 弹层可能已经被关掉甚至销毁，晚到的信息不能再写进已释放的 notifier。
    if (described == null || !sheetOpen || !context.mounted) return;
    info.value = described;
  }());

  final format = await showAdaptiveBottomSheet<ImageSaveFormat>(
    context: context,
    builder: (sheetContext) => ValueListenableBuilder<ImageFileInfo?>(
      valueListenable: info,
      builder: (context, described, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题自带分辨率：`图片（1366 × 1948）`。
          // 不用 MaterialBottomSheetHeader——它固定 titleLarge(22pt)，
          // 加上分辨率会换行撑成两排，而那个组件还被十几个弹层共用，
          // 不为这一处调全局字号。
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    described == null
                        ? label
                        : '$label（${described.sizeLabel}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: materialBottomSheetContentPadding,
            child: SplitListGroup(
              children: [
                _SaveOptionTile(
                  icon: Icons.download_rounded,
                  title: '保存原图',
                  description: described == null
                      ? (isDesktop() ? '原始格式 · 不重新编码' : '原始格式 · 直接写入相册')
                      : '${described.formatLabel} · ${ImageFileInfo.formatBytes(described.byteSize)} · 不重新编码',
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ImageSaveFormat.original),
                ),
                _SaveOptionTile(
                  icon: Icons.photo_outlined,
                  title: '另存为 JPG',
                  description: 'JPEG · 质量 95 · 透明底铺白',
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ImageSaveFormat.jpg),
                ),
                _SaveOptionTile(
                  icon: Icons.image_outlined,
                  title: '另存为 PNG',
                  description: 'PNG · 无损 · 体积通常变大',
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ImageSaveFormat.png),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  // 先关标志再释放，避免异步回调抢在中间写进已释放的 notifier。
  sheetOpen = false;
  info.dispose();
  if (!context.mounted || format == null) return;
  await saveImageFromUrl(
    context,
    imageUrl: imageUrl,
    fileBaseName: fileBaseName,
    format: format,
  );
}

/// 保存卡片里的一行，样式对齐设置页的 `_TileLabel`：
/// 主标题 bodyLarge + onSurface，副标题 bodySmall + onSurfaceVariant，
/// 图标 24、间距 16、标题与副标题之间空 2。
///
/// 不复用 ListTile：它的 title/subtitle 走 ListTileTheme 的字号，
/// 和设置卡片对不上，之前这里就比设置页大一档。
class _SaveOptionTile extends StatelessWidget {
  const _SaveOptionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      onHighlightChanged: SplitListRow.pressReporterOf(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 24, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按指定格式保存一张网络图片，并提示结果。
Future<void> saveImageFromUrl(
  BuildContext context, {
  required String imageUrl,
  required String fileBaseName,
  ImageSaveFormat format = ImageSaveFormat.original,
}) async {
  final result = await ImageSaver.save(
    imageUrl: imageUrl,
    fileName: fileBaseName,
    format: format,
  );
  if (!context.mounted) return;
  switch (result.status) {
    case ImageSaveStatus.saved:
      KazumiDialog.showToast(
        context: context,
        message: isDesktop() ? '图片已保存' : '已保存到相册',
      );
    case ImageSaveStatus.cancelled:
      break;
    case ImageSaveStatus.failed:
      KazumiDialog.showToast(context: context, message: result.message);
  }
}
