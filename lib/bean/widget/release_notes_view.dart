import 'package:flutter/material.dart';

/// GitHub Release 正文用的迷你 markdown 渲染。
///
/// 只认更新日志里实际会出现的五种标记：
/// `##` / `###` 标题、`- ` 列表项、`**粗体**`、`` `行内代码` ``。
/// 其余字符一律按普通文字输出。
///
/// 之所以不引现成的 markdown 包：GitHub 的正文语法本来就收敛，为了五种
/// 标记拖进一个依赖（`flutter_markdown` 已停维护，`gpt_markdown` 是小团队）
/// 不划算，而自己解析反而完全可控 —— 遇到没见过的语法就当普通文字，
/// 不会渲染出奇怪的结构。
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView({super.key, required this.markdown});

  /// 原始 markdown 文本，通常是 Release 的 `body` 字段。
  final String markdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.45,
    );
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      color: colors.onSurface,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
    final sectionStyle = theme.textTheme.labelLarge?.copyWith(
      color: colors.primary,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    final boldStyle = (bodyStyle ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: colors.onSurface,
    );
    final codeStyle = (bodyStyle ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontSize: (bodyStyle?.fontSize ?? 14) - 1,
      color: colors.onSurface,
      height: 1.2,
    );

    final blocks = _parse(markdown);
    if (blocks.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (index > 0) {
        children.add(SizedBox(height: _gapBefore(block.kind)));
      }
      children.add(
        switch (block.kind) {
          _BlockKind.title => Text(block.text, style: titleStyle),
          _BlockKind.section => Text(block.text, style: sectionStyle),
          _BlockKind.bullet => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 用固定宽度承载圆点，条目文字自然对齐成一条竖线。
              SizedBox(
                width: 16,
                child: Text('•', style: bodyStyle),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: _inlineSpans(
                      block.text,
                      base: bodyStyle,
                      bold: boldStyle,
                      code: codeStyle,
                    ),
                  ),
                ),
              ),
            ],
          ),
          _BlockKind.paragraph => Text.rich(
            TextSpan(
              children: _inlineSpans(
                block.text,
                base: bodyStyle,
                bold: boldStyle,
                code: codeStyle,
              ),
            ),
          ),
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 块之间的竖向间隔。标题上下都要留白，列表项之间只要一点点。
  static double _gapBefore(_BlockKind kind) => switch (kind) {
        _BlockKind.title => 14,
        _BlockKind.section => 10,
        _BlockKind.bullet => 5,
        _BlockKind.paragraph => 7,
      };

  /// 按行切块。空行直接丢掉 —— 块间距由 [_gapBefore] 统一给，
  /// 保留空行会让原本的排版节奏翻倍。
  static List<_Block> _parse(String source) {
    final blocks = <_Block>[];
    for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('### ')) {
        blocks.add(_Block(_BlockKind.section, line.substring(4).trim()));
      } else if (line.startsWith('## ')) {
        blocks.add(_Block(_BlockKind.title, line.substring(3).trim()));
      } else if (line.startsWith('# ')) {
        blocks.add(_Block(_BlockKind.title, line.substring(2).trim()));
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        blocks.add(_Block(_BlockKind.bullet, line.substring(2).trim()));
      } else {
        blocks.add(_Block(_BlockKind.paragraph, line));
      }
    }
    return blocks;
  }

  /// 把一行里的 `**粗体**` 与 `` `行内代码` `` 拆成 span。
  ///
  /// 标记没闭合时按普通文字处理，宁可少渲染也不要吞掉半行内容。
  static List<InlineSpan> _inlineSpans(
    String text, {
    TextStyle? base,
    TextStyle? bold,
    TextStyle? code,
  }) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString(), style: base));
      buffer.clear();
    }

    var index = 0;
    while (index < text.length) {
      if (text.startsWith('**', index)) {
        final end = text.indexOf('**', index + 2);
        if (end > index + 2) {
          flush();
          spans.add(
            TextSpan(text: text.substring(index + 2, end), style: bold),
          );
          index = end + 2;
          continue;
        }
      }
      if (text[index] == '`') {
        final end = text.indexOf('`', index + 1);
        if (end > index + 1) {
          flush();
          spans.add(
            TextSpan(text: text.substring(index + 1, end), style: code),
          );
          index = end + 1;
          continue;
        }
      }
      buffer.write(text[index]);
      index++;
    }
    flush();
    return spans;
  }
}

enum _BlockKind { title, section, bullet, paragraph }

class _Block {
  const _Block(this.kind, this.text);

  final _BlockKind kind;
  final String text;
}
