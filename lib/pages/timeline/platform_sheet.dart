import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/pages/webview/internal_browser_page.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:url_launcher/url_launcher.dart';

/// 平台档期弹窗：列出当天该番的全部平台，每个平台右侧两个图标，
/// 分别用内置浏览器与系统浏览器打开。
///
/// 平台条目来自 bangumi-data 的 `sites[]`，`url` 由 `siteMeta.urlTemplate`
/// 拼出；拿不到链接时置灰、不给图标，只显示平台名与时刻。
Future<void> showPlatformSheet({
  required BuildContext context,
  required BangumiItem item,
  required SiteSchedule? schedule,
}) {
  return showAdaptiveBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    maxHeightFactor: .7,
    builder: (sheetContext) => _PlatformSheet(item: item, schedule: schedule),
  );
}

/// 用内置浏览器打开 [url]。
///
/// 先关掉弹窗再跳：不关的话内置浏览器页会叠在弹窗下面，返回时又是弹窗。
Future<void> _openInternal(
  BuildContext context, {
  required String url,
  required String title,
}) async {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) navigator.pop();
  await context.pushNamed(
    '/info/browser',
    arguments: InternalBrowserArgs(url: url, title: title),
  );
}

/// 交给系统浏览器。
Future<void> _openExternal(BuildContext context, String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (error) {
    KazumiLogger().w(
      'PlatformSheet: failed to open external browser',
      error: error,
    );
  }
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
}

class _PlatformSheet extends StatelessWidget {
  const _PlatformSheet({required this.item, required this.schedule});

  final BangumiItem item;
  final SiteSchedule? schedule;

  String get _title {
    final nameCn = item.nameCn.trim();
    return nameCn.isNotEmpty ? nameCn : item.name.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final platforms = schedule?.platforms ?? const <SchedulePlatform>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MaterialBottomSheetHeader(
          title: '播放平台',
          description: platforms.isEmpty
              ? '$_title · 暂无平台信息'
              : '$_title · ${platforms.length} 个平台',
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: platforms.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Text(
                    '该条目在 bangumi-data 里没有可用的平台条目，通常是新番尚未收录。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: platforms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) => _PlatformTile(
                    platform: platforms[index],
                    onInternal: () => _openInternal(
                      context,
                      url: platforms[index].url!,
                      title: platforms[index].name,
                    ),
                    onExternal: () =>
                        _openExternal(context, platforms[index].url!),
                  ),
                ),
        ),
      ],
    );
  }
}

class _PlatformTile extends StatelessWidget {
  const _PlatformTile({
    required this.platform,
    required this.onInternal,
    required this.onExternal,
  });

  final SchedulePlatform platform;
  final VoidCallback onInternal;
  final VoidCallback onExternal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final url = platform.url ?? '';
    final hasUrl = url.isNotEmpty;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 0),
      title: Text(
        platform.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        [
          platform.time,
          if (platform.regions.isNotEmpty) platform.regions.take(4).join('/'),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      trailing: hasUrl
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '在应用内打开',
                  icon: const Icon(Icons.travel_explore_rounded),
                  onPressed: onInternal,
                ),
                IconButton(
                  tooltip: '用外部浏览器打开',
                  icon: const Icon(Icons.open_in_new_rounded),
                  onPressed: onExternal,
                ),
              ],
            )
          : Text(
              '无链接',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
      // 整行点击等同「应用内打开」，与左侧图标保持一致。
      onTap: hasUrl ? onInternal : null,
      enabled: hasUrl,
    );
  }
}
