import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/episode_comments_page.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/info_page.dart';
import 'package:kazumi/pages/route_error_page.dart';
import 'package:kazumi/pages/webview/internal_browser_page.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

final infoModule = createModule(
  path: '/info',
  register: (c) {
    c
      ..route(
        '/',
        provide: (s) => s.add<InfoController>(InfoController.new),
        child: (context, state) {
          final bangumiItem = state.arguments;
          if (bangumiItem is! BangumiItem) {
            return const RouteErrorPage(message: '番组详情参数无效，请返回后重新打开。');
          }
          return InfoPage(
            inputBangumiItem: bangumiItem,
            infoController: context.read<InfoController>(),
            pluginsController: inject<PluginsController>(),
          );
        },
      )
      // 单集讨论单独成页，避免在剧集列表里内联展开把列表撑长。
      ..route(
        '/episode/comments',
        child: (context, state) {
          final args = state.arguments;
          if (args is! EpisodeCommentsArgs) {
            return const RouteErrorPage(message: '单集讨论参数无效，请返回后重试。');
          }
          return EpisodeCommentsPage(
            subjectTitle: args.subjectTitle,
            episode: args.episode,
          );
        },
      )
      // 内置浏览器：在应用内直接浏览网页。
      ..route(
        '/browser',
        child: (context, state) {
          final args = state.arguments;
          if (args is! InternalBrowserArgs) {
            return const RouteErrorPage(message: '浏览器参数无效，请返回后重试。');
          }
          return InternalBrowserPage(
            url: args.url,
            title: args.title,
            userAgent: args.userAgent,
          );
        },
      );
  },
);
