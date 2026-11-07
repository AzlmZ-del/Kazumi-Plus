// 记录进入 tag 时 list 所在位置
class BBCodeTag {
  int? bold;
  int? italic;
  int? underline;
  int? strikeThrough;
  int? masked;
  int? quoted;
  int? code;
  int? size;
  int? color;
  int? link;
  int? img;

  void clear() {
    bold = null;
    italic = null;
    underline = null;
    strikeThrough = null;
    masked = null;
    quoted = null;
    code = null;
    size = null;
    color = null;
    link = null;
    img = null;
  }
}

class BBCodeText {
  String text;

  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strikeThrough = false;
  bool masked = false;
  bool quoted = false;
  bool code = false;

  int size = 14;
  String? color;
  String? link;

  BBCodeText({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeThrough = false,
    this.masked = false,
    this.quoted = false,
    this.code = false,
    this.size = 14,
    this.color,
    this.link,
  });
}

class BBCodeBgm {
  int id;

  BBCodeBgm({required this.id});
}

class BBCodeMusume {
  int id;

  BBCodeMusume({required this.id});
}

class BBCodeSticker {
  /// 由 ctx.start!.type - 11 算得（11 是 lexer 里首个 sticker 字面量的前一位），
  /// 重新生成 BBCodeLexer 增删字面量会整体错位且不报错。
  int id;

  BBCodeSticker({required this.id});
}

class BBCodeImg {
  String imageUrl;

  BBCodeImg({required this.imageUrl});
}

/// 全局可变单例：enter/exit 靠它跨方法传下标，故解析必须同步完成。
/// 唯一清理点是 bbcode_widget.dart 中 walk 之后紧跟的 clear()，异常路径会漏清。
BBCodeTag bbCodeTag = BBCodeTag();
