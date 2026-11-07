// 落库值与 dandanplay 的 chConvert 参数一致，不能随意改动。
enum DanmakuChConvert {
  none(0),
  simplified(1),
  traditional(2);

  const DanmakuChConvert(this.value);

  final int value;

  static DanmakuChConvert fromValue(int value) => switch (value) {
    1 => simplified,
    2 => traditional,
    _ => none,
  };
}
