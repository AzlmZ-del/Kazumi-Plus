import 'package:hive_ce/hive.dart';

part 'collect_change_module.g.dart';

// 存放收藏变更历史，用于和 WebDAV 增量同步。
@HiveType(typeId: 5)
class CollectedBangumiChange {
  // 以秒级时间戳作主键：Hive key 上限 4294967295，且要避免多端同步时主键冲突。
  @HiveField(0)
  int id;

  @HiveField(1)
  int bangumiID;

  // 1 = 新增，2 = 更新，3 = 删除。
  @HiveField(2)
  int action;

  // 1 = 在看，2 = 想看，3 = 搁置，4 = 看过，5 = 抛弃。
  // 注意与 BangumiCollectionType（API 侧）编号不同，转换走 toCollectType()。
  @HiveField(3)
  int type;

  @HiveField(4)
  int timestamp;

  CollectedBangumiChange(
      this.id, this.bangumiID, this.action, this.type, this.timestamp);

  @override
  String toString() {
    return 'id: $id, bangumi: $bangumiID, action: $action, time: $timestamp';
  }
}
