/// 网络设置里几个「加速」选择器共用的形状。
///
/// 每个具体枚举各自提供 [label] 与 [description]，这样同一个对话框与设置项
/// 能渲染所有模式列表，不必写分支。
abstract interface class AccelerationMode implements Enum {
  String get label;

  String get description;
}
