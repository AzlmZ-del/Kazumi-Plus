/// 可选的前缀，用来反转剧集列表的顺序。
///
/// 有些站点把最新一集排在前面（`3, 2, 1`）。把剧集选择器写成
/// `-<selector>`（XPath）或 `-<jsonpath>`（API），Kazumi 就会还原成
/// 自然顺序（`1, 2, 3`），不必改规则本身。
///
/// 只有剧集列表认这个前缀。线路列表与线路名列表按下标配对，
/// 只反转其中一个会让每条线路都静默贴错名字；
/// 所以线路列表那里只会剥掉前缀并给出提示。
library;

/// 唯一合法的反转标记。
const String reversePrefix = '-';

/// 出现在诊断信息里，让前缀用错时能给出看得懂的提示。
const String reversePrefixLabel = '反序前缀（-）';

/// 把可选的反转标记从 [raw] 里剥出来。
///
/// 返回清理后的表达式，以及调用方是否应当反转结果列表。
/// 标记只匹配开头，所以只是在中间某处含 `-` 的普通表达式不受影响。
///
/// XPath 里 `-1` 和 `-.5` 是合法的（虽然没意义的）数值表达式，
/// 所以 XPath 调用方要传 [xpathNumericLiteral] 把它们排除在外。
/// 点号后面必须跟数字才算数值，因此 `-.//a` 仍按反转标记处理。
///
/// JSONPath 恒以 `$` 开头，所以 API 调用方不必开那个标志，
/// 任何紧跟着 `$` 的 `-` 都毫无歧义地是反转标记。
({String expression, bool reverse}) splitReversePrefix(
  String raw, {
  bool xpathNumericLiteral = false,
}) {
  final trimmed = raw.trimLeft();
  if (!trimmed.startsWith(reversePrefix)) {
    return (expression: raw, reverse: false);
  }
  final rest = trimmed.substring(reversePrefix.length).trim();
  if (rest.isEmpty) {
    return (expression: raw, reverse: false);
  }
  if (xpathNumericLiteral &&
      RegExp(r'^(?:[0-9]|\.[0-9])').hasMatch(rest)) {
    return (expression: raw, reverse: false);
  }
  return (expression: rest, reverse: true);
}
