import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/info_quick_actions.dart';

class InfoActionsMenu extends StatefulWidget {
  const InfoActionsMenu({
    super.key,
    required this.bangumiItem,
    this.userAgent = '',
  });

  final BangumiItem bangumiItem;

  /// 当前番剧所属规则配置的 User-Agent；为空时内置浏览器用手机 UA。
  final String userAgent;

  @override
  State<InfoActionsMenu> createState() => _InfoActionsMenuState();
}

class _InfoActionsMenuState extends State<InfoActionsMenu> {
  bool _savingCover = false;

  Future<void> _saveCover() async {
    if (_savingCover) return;
    setState(() => _savingCover = true);
    try {
      await InfoQuickActions.saveCover(context, widget.bangumiItem);
    } finally {
      if (mounted) setState(() => _savingCover = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KazumiMenuButton(
      menuChildren: [
        KazumiMenuItem(
          onPressed: _savingCover ? null : _saveCover,
          leadingIcon: const Icon(Icons.download_rounded, size: 18),
          label: _savingCover ? '保存中…' : '保存封面',
        ),
        KazumiMenuItem(
          onPressed: () => InfoQuickActions.openInternally(
            context,
            widget.bangumiItem,
            userAgent: widget.userAgent,
          ),
          leadingIcon: const Icon(Icons.travel_explore_rounded, size: 18),
          label: '内部浏览',
        ),
        KazumiMenuItem(
          onPressed: () =>
              InfoQuickActions.openExternally(context, widget.bangumiItem),
          leadingIcon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: '外部打开',
        ),
        KazumiMenuItem(
          onPressed: () =>
              InfoQuickActions.share(context, widget.bangumiItem),
          leadingIcon: const Icon(Icons.share_rounded, size: 18),
          label: '分享番剧',
        ),
      ],
      builder: (context, toggle) => IconButton(
        tooltip: '更多操作',
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: toggle,
      ),
    );
  }
}
