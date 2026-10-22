/// 深链解析。
///
/// 移植自 Predidit/Kazumi 提交 6485e353（feat: support anime deep links #2736）。
/// 支持两种链接：
///   `kazumi://bangumi/<id>`          → 打开对应 Bangumi 条目详情
///   `kazumi://search?query=<关键词>` → 用该关键词发起搜索
sealed class KazumiDeepLink {
  const KazumiDeepLink();

  static KazumiDeepLink? parse(Uri uri) {
    if (uri.scheme != 'kazumi') return null;
    try {
      if (uri.host == 'bangumi' && uri.pathSegments.length == 1) {
        final raw = uri.pathSegments.single;
        final id = int.tryParse(raw);
        // 只接受纯数字：不许带符号、空白或前导零。
        if (id != null && id > 0 && '$id' == raw) return BangumiDeepLink(id);
      }
      if (uri.host == 'search') {
        final query = uri.queryParameters['query']?.trim() ?? '';
        if (query.isNotEmpty) return SearchDeepLink(query);
      }
    } on FormatException {
      // 百分号编码不合法。
    }
    return null;
  }
}

final class BangumiDeepLink extends KazumiDeepLink {
  const BangumiDeepLink(this.id);
  final int id;
}

final class SearchDeepLink extends KazumiDeepLink {
  const SearchDeepLink(this.query);
  final String query;
}
