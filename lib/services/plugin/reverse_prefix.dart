/// Optional prefix that flips the order of an episode list.
///
/// Some sites list the newest episode first (`3, 2, 1`). Writing the episode
/// selector as `-<selector>` (XPath) or `-<jsonpath>` (API) makes Kazumi
/// restore the natural order (`1, 2, 3`) without touching the rule itself.
///
/// Only episode lists honour the prefix. Road lists are paired with the
/// road-name list by index, so reversing one without the other would silently
/// mislabel every road; the prefix is stripped and reported there instead.
library;

/// The one and only reverse marker.
const String reversePrefix = '-';

/// Shown in diagnostics so a misused prefix gets an understandable message.
const String reversePrefixLabel = '反序前缀（-）';

/// Splits the optional reverse marker off [raw].
///
/// Returns the cleaned expression and whether the caller should reverse the
/// resulting list. The marker is only matched right at the start, so an
/// ordinary expression that merely contains a `-` further in is untouched.
///
/// XPath accepts `-1` and `-.5` as legal (if pointless) numeric expressions,
/// so callers parsing XPath pass [xpathNumericLiteral] to leave those alone.
/// A dot only counts when a digit follows, so `-.//a` stays a reverse marker.
///
/// JSONPath always starts with `$`, so API callers leave the flag off and any
/// `-` immediately followed by `$` is unambiguously a marker.
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
