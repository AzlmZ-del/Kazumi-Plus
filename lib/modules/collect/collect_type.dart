/// 收藏类型枚举，标识番剧的收藏状态。
/// 编号与 BangumiCollectionType（API 侧）不同，跨模块转换走 toCollectType()。
enum CollectType {
  none(0, '未收藏'),

  watching(1, '在看'),

  planToWatch(2, '想看'),

  onHold(3, '搁置'),

  watched(4, '看过'),

  abandoned(5, '抛弃');

  const CollectType(this.value, this.label);

  final int value;

  final String label;

  /// 根据数值获取枚举
  static CollectType fromValue(int value) {
    return CollectType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => CollectType.none,
    );
  }

  /// 是否为有效的收藏状态（排除未收藏）
  bool get isCollected => this != CollectType.none;
}
