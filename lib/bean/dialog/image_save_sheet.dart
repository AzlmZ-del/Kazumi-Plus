import 'dart:async';

import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/services/network/image_saver.dart';
import 'package:kazumi/utils/device.dart';

/// Opens the save-image sheet; the picked format is written straight away.
///
/// [label] names the object in the title and gets the resolution appended,
/// [fileBaseName] omits the extension since the image format decides it.
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

  // The size is unknown until the download ends, so details land after the sheet.
  final info = ValueNotifier<ImageFileInfo?>(null);
  var sheetOpen = true;
  unawaited(() async {
    final described = await ImageSaver.describe(imageUrl);
    // The sheet may already be disposed: late data must not reach its notifier.
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
          // Not MaterialBottomSheetHeader: its fixed titleLarge (22pt) wraps once the
          // resolution is appended, and a dozen sheets share that component.
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

  // Clear the flag first: an async callback must not write to a released notifier.
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

/// One row inside the save sheet, styled after the settings page `_TileLabel`:
/// `bodyLarge` title, `bodyMedium` subtitle. `ListTile` is not reused because its
/// theme sizes sit one step larger than those cards.
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
      statesController: SplitListRow.statesOf(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 24, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
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
                    style: textTheme.bodyMedium?.copyWith(
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

/// Saves a network image in the given format and reports the result.
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
