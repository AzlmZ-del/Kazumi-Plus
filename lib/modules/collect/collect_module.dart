import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';

part 'collect_module.g.dart';

@HiveType(typeId: 3)
class CollectedBangumi {
  @HiveField(0)
  BangumiItem bangumiItem;

  @HiveField(1)
  DateTime time;

  /// 收藏类型，取值见 [CollectType]：1 在看、2 想看、3 搁置、4 看过、5 抛弃。
  /// 注意与 BangumiCollectionType（API 侧）编号不同，转换走 toCollectType()。
  @HiveField(2)
  int type;

  String get key => bangumiItem.id.toString();

  CollectedBangumi(this.bangumiItem, this.time, this.type);

  static String getKey(BangumiItem bangumiItem) => bangumiItem.id.toString();

  @override
  String toString() {
    return 'type: $type, time: $time, anime: ${bangumiItem.name}';
  }
}
