import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

enum XPathRuleFormatKind {
  invalidUrl,
  invalidDocument,
  invalidSelector,
}

enum XPathRuleField {
  searchList,
  searchName,
  searchResult,
  chapterRoads,
  chapterRoadName,
  chapterResult,
  captchaDetectValue,
  captchaImage,
  captchaButton,
}

/// Optional prefix on an XPath expression that flips the resulting node list.
///
/// Some sites list the newest episode first (`3, 2, 1`). Writing the episode
/// XPath as `-<selector>` makes Kazumi restore the natural order
/// (`1, 2, 3`) without touching the rule's selectors.
///
/// `-` is safe as a marker because XPath 1.0 treats a leading `-` as unary
/// minus applied to a node-set, which always evaluates to NaN and therefore
/// never matches anything — no working rule can legitimately start with it.
///
/// Only the episode list honours this prefix. Reversing the road list would
/// desynchronise it from the index-aligned road-name list, so the prefix is
/// stripped and ignored there (a diagnostic is emitted instead).
const String xpathReversePrefix = '-';

/// Shown in diagnostics so a misused prefix gets an understandable message.
const String xpathReversePrefixLabel = '反序前缀（-）';

class XPathRuleFormatException implements Exception {
  const XPathRuleFormatException(
    this.message, {
    required this.kind,
    this.field,
    this.expression,
    this.cause,
  });

  final String message;
  final XPathRuleFormatKind kind;
  final XPathRuleField? field;
  final String? expression;
  final Object? cause;

  @override
  String toString() => 'XPathRuleFormatException.${kind.name}: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

class XPathRuleStrategy {
  const XPathRuleStrategy();

  PreparedRuleRequest prepareSearchRequest(
    RuleExecutionConfig config,
    String keyword,
  ) {
    final queryUrl = config.searchUrl.replaceAll(
      '@keyword',
      Uri.encodeQueryComponent(keyword),
    );
    final uri = Uri.tryParse(queryUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw XPathRuleFormatException(
        '搜索 URL 无效: $queryUrl',
        kind: XPathRuleFormatKind.invalidUrl,
      );
    }
    if (!config.usePost) {
      return PreparedRuleRequest(
        method: 'GET',
        url: queryUrl,
        includeCookies: true,
      );
    }
    return PreparedRuleRequest(
      method: 'POST',
      url: uri.replace(query: null).toString(),
      bodyType: 'form',
      body: uri.queryParameters,
      includeCookies: true,
    );
  }

  PreparedRuleRequest prepareChapterRequest(
    RuleExecutionConfig config,
    String source,
  ) {
    final url = normalizeEpisodeUrl(config.baseUrl, source);
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw XPathRuleFormatException(
        '章节 URL 无效: $url',
        kind: XPathRuleFormatKind.invalidUrl,
      );
    }
    // XPath chapter requests historically go out without stored cookies;
    // only search requests attach them.
    return PreparedRuleRequest(method: 'GET', url: url);
  }

  RuleSearchParseResult parseSearch(
    String raw,
    RuleExecutionConfig config,
  ) {
    final root = _documentElement(raw);
    if (detectsCaptchaChallenge(
      raw,
      config.antiCrawlerConfig,
      htmlElement: root,
    )) {
      throw CaptchaRequiredException(config.pluginName);
    }

    final items = <SearchItem>[];
    final fragments = <String>[];
    final diagnostics = <String>[];
    final nodes = _runSelector(
      XPathRuleField.searchList,
      config.searchList,
      () => root.queryXPath(config.searchList).nodes,
    );
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      try {
        final name = _runSelector(
              XPathRuleField.searchName,
              config.searchName,
              () => node.queryXPath(config.searchName).node,
            )?.text?.trim() ??
            '';
        final source = _runSelector(
              XPathRuleField.searchResult,
              config.searchResult,
              () => node.queryXPath(config.searchResult).node,
            )?.attributes['href']?.trim() ??
            '';
        if (name.isEmpty || source.isEmpty) {
          diagnostics.add('搜索节点 $index 缺少名称或来源，已跳过');
          continue;
        }
        items.add(SearchItem(name: name, src: source));
        fragments.add(_fragment(node.node));
      } on XPathRuleFormatException {
        rethrow;
      } catch (error) {
        diagnostics.add('搜索节点 $index 解析失败: $error');
      }
    }
    return RuleSearchParseResult(
      items: items,
      matchedFragments: fragments,
      diagnostics: diagnostics,
    );
  }

  /// Splits the optional reverse marker off an XPath expression.
  ///
  /// Returns the cleaned selector and whether the caller should reverse the
  /// resulting node list. Only [xpathReversePrefix] is matched, right at the
  /// start, so an ordinary selector that merely contains a `-` further in is
  /// untouched.
  ///
  /// A leading `-` followed by a number is left alone: `-1` and `-.5` are
  /// legal (if pointless) XPath numeric expressions, not a request to reverse.
  /// A dot only counts when a digit follows, so `-.//a` stays a reverse marker.
  ({String expression, bool reverse}) _splitReversePrefix(String raw) {
    final trimmed = raw.trimLeft();
    if (trimmed.startsWith(xpathReversePrefix)) {
      final rest = trimmed.substring(xpathReversePrefix.length).trim();
      if (rest.isNotEmpty &&
          !RegExp(r'^(?:[0-9]|\.[0-9])').hasMatch(rest)) {
        return (expression: rest, reverse: true);
      }
    }
    return (expression: raw, reverse: false);
  }

  RuleChapterParseResult parseChapters(
    String raw,
    RuleExecutionConfig config,
  ) {
    final root = _documentElement(raw);
    final roads = <Road>[];
    final diagnostics = <String>[];
    // Only the episode selector honours the reverse prefix. The road list is
    // paired with the road-name list by index, so reversing one without the
    // other would silently mislabel every road; the prefix is stripped and
    // reported there instead.
    final episodeSelector = _splitReversePrefix(config.chapterResult);
    final roadsSelector = _splitReversePrefix(config.chapterRoads);
    if (roadsSelector.reverse) {
      diagnostics.add('$xpathReversePrefixLabel 只对剧集列表生效，播放线路列表已忽略');
    }
    final roadNodes = _runSelector(
      XPathRuleField.chapterRoads,
      roadsSelector.expression,
      () => root.queryXPath(roadsSelector.expression).nodes,
    );
    // Optional: road names live outside the road nodes on many sites (tab
    // headers vs. tab panes), so they are queried separately and matched to
    // the roads by index.
    final roadNameSelector = _splitReversePrefix(config.chapterRoadName);
    final roadNameExpression = roadNameSelector.expression.trim();
    if (roadNameSelector.reverse) {
      diagnostics.add('$xpathReversePrefixLabel 只对剧集列表生效，线路名称列表已忽略');
    }
    // Starts as an empty list of the same element type, so the optional field
    // can be skipped without a second type parameter.
    var roadNameNodes = roadNodes.sublist(0, 0);
    if (roadNameExpression.isNotEmpty) {
      roadNameNodes = _runSelector(
        XPathRuleField.chapterRoadName,
        roadNameExpression,
        () => root.queryXPath(roadNameExpression).nodes,
      );
    }
    if (roadNameNodes.isNotEmpty &&
        roadNameNodes.length != roadNodes.length) {
      diagnostics.add(
        '线路名称数量 ${roadNameNodes.length} 与线路数量 ${roadNodes.length} 不一致，'
        '按顺序对齐',
      );
    }
    for (var roadIndex = 0; roadIndex < roadNodes.length; roadIndex++) {
      final roadNode = roadNodes[roadIndex];
      try {
        final urls = <String>[];
        final names = <String>[];
        final episodeNodes = _runSelector(
          XPathRuleField.chapterResult,
          episodeSelector.expression,
          () => roadNode.queryXPath(episodeSelector.expression).nodes,
        );
        // Sites that list the newest episode first are parsed back into
        // broadcast order so "第1集"（or the site's own `1`）lines up with the
        // first episode the user expects.
        final orderedEpisodes =
            episodeSelector.reverse ? episodeNodes.reversed.toList() : episodeNodes;
        for (var episodeIndex = 0;
            episodeIndex < orderedEpisodes.length;
            episodeIndex++) {
          try {
            final episode = orderedEpisodes[episodeIndex].node;
            final source = episode.attributes['href']?.trim() ?? '';
            if (source.isEmpty) {
              diagnostics.add(
                '线路 $roadIndex 的剧集节点 $episodeIndex 缺少 URL，已跳过',
              );
              continue;
            }
            final name = (episode.text ?? '').replaceAll(RegExp(r'\s+'), '');
            urls.add(normalizeEpisodeUrl(config.baseUrl, source));
            names.add(name.isEmpty ? '第${episodeIndex + 1}集' : name);
          } catch (error) {
            diagnostics.add(
              '线路 $roadIndex 的剧集节点 $episodeIndex 解析失败: $error',
            );
          }
        }
        if (urls.isEmpty) {
          diagnostics.add('线路 $roadIndex 没有有效剧集，已跳过');
          continue;
        }
        final roadLabel = roadIndex < roadNameNodes.length
            ? _roadNameText(
                roadNameNodes[roadIndex].node,
                roadNameNodes[roadIndex].text,
              )
            : '';
        roads.add(
          Road(
            name: roadLabel.isEmpty ? '播放线路${roads.length + 1}' : roadLabel,
            data: urls,
            identifier: names,
          ),
        );
      } on XPathRuleFormatException {
        rethrow;
      } catch (error) {
        diagnostics.add('线路节点 $roadIndex 解析失败: $error');
      }
    }
    return RuleChapterParseResult(
      roads: roads,
      diagnostics: diagnostics,
    );
  }

  /// 线路名只取节点的「直接文本子节点」，跳过子元素里的文字。
  ///
  /// 很多站点把集数放在线路名后面：`<a>天堂<span>3</span></a>`，
  /// 直接取 `text` 会得到 `天堂3`。这里只拼 Text 子节点，
  /// 得到 `天堂`；若没有直接文本（如 `<a><span>天堂</span></a>`），
  /// 再回退到完整文本。
  String _roadNameText(Node? element, String? fallbackText) {
    if (element != null) {
      final buffer = StringBuffer();
      for (final child in element.nodes) {
        if (child is Text) buffer.write(child.text);
      }
      final direct = buffer.toString().trim();
      if (direct.isNotEmpty) {
        return direct.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }
    return (fallbackText ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool detectsCaptchaChallenge(
    String raw,
    AntiCrawlerConfig config, {
    Element? htmlElement,
  }) {
    if (!config.enabled) return false;
    final detectValue = config.captchaDetectValue.trim();
    if (detectValue.isNotEmpty) {
      switch (config.captchaDetectType) {
        case CaptchaDetectType.text:
          return raw.contains(detectValue);
        case CaptchaDetectType.regex:
          try {
            return RegExp(
              detectValue,
              caseSensitive: false,
              dotAll: true,
            ).hasMatch(raw);
          } on FormatException {
            return false;
          }
        case CaptchaDetectType.xpath:
        default:
          final root = htmlElement ?? _documentElement(raw);
          return _runSelector(
                XPathRuleField.captchaDetectValue,
                detectValue,
                () => root.queryXPath(detectValue).node,
              ) !=
              null;
      }
    }

    final root = htmlElement ?? _documentElement(raw);
    final fallbackSelectors = <(XPathRuleField, String)>[
      (XPathRuleField.captchaImage, config.captchaImage),
      (XPathRuleField.captchaButton, config.captchaButton),
    ];
    for (final (field, expression) in fallbackSelectors) {
      if (expression.trim().isEmpty) continue;
      final node = _runSelector(
        field,
        expression,
        () => root.queryXPath(expression).node,
      );
      if (node != null) return true;
    }
    return false;
  }

  Element _documentElement(String raw) {
    try {
      final element = parse(raw).documentElement;
      if (element == null) {
        throw const XPathRuleFormatException(
          'HTML 响应没有根节点',
          kind: XPathRuleFormatKind.invalidDocument,
        );
      }
      return element;
    } on XPathRuleFormatException {
      rethrow;
    } catch (error) {
      throw XPathRuleFormatException(
        'HTML 响应解析失败',
        kind: XPathRuleFormatKind.invalidDocument,
        cause: error,
      );
    }
  }

  T _runSelector<T>(
    XPathRuleField field,
    String expression,
    T Function() query,
  ) {
    final label = _fieldLabel(field);
    if (expression.trim().isEmpty) {
      throw XPathRuleFormatException(
        '$label XPath 不能为空',
        kind: XPathRuleFormatKind.invalidSelector,
        field: field,
        expression: expression,
      );
    }
    try {
      return query();
    } catch (error) {
      throw XPathRuleFormatException(
        '$label XPath 无效: $expression',
        kind: XPathRuleFormatKind.invalidSelector,
        field: field,
        expression: expression,
        cause: error,
      );
    }
  }

  String _fieldLabel(XPathRuleField field) {
    return switch (field) {
      XPathRuleField.searchList => '搜索结果列表',
      XPathRuleField.searchName => '条目名称',
      XPathRuleField.searchResult => '条目链接',
      XPathRuleField.chapterRoads => '播放线路列表',
      XPathRuleField.chapterRoadName => '线路名称列表',
      XPathRuleField.chapterResult => '剧集列表',
      XPathRuleField.captchaDetectValue => '验证页检测',
      XPathRuleField.captchaImage => '验证码图片',
      XPathRuleField.captchaButton => '验证按钮',
    };
  }

  String _fragment(Node node) {
    return node is Element ? node.outerHtml : node.text ?? '';
  }
}
