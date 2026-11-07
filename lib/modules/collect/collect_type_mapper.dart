import 'package:kazumi/modules/bangumi/bangumi_collection_type.dart';
import 'package:kazumi/modules/collect/collect_type.dart';

extension BangumiCollectionTypeMapper on BangumiCollectionType {
  CollectType toCollectType() {
    return switch (this) {
      BangumiCollectionType.planToWatch => CollectType.planToWatch,
      BangumiCollectionType.watched => CollectType.watched,
      BangumiCollectionType.watching => CollectType.watching,
      BangumiCollectionType.onHold => CollectType.onHold,
      BangumiCollectionType.abandoned => CollectType.abandoned,
      BangumiCollectionType.unknown => CollectType.none,
    };
  }
}

extension CollectTypeBangumiMapper on CollectType {
  BangumiCollectionType? toBangumiCollectionType() {
    return switch (this) {
      CollectType.planToWatch => BangumiCollectionType.planToWatch,
      CollectType.watched => BangumiCollectionType.watched,
      CollectType.watching => BangumiCollectionType.watching,
      CollectType.onHold => BangumiCollectionType.onHold,
      CollectType.abandoned => BangumiCollectionType.abandoned,
      // 返回 null 表示「不上传」：调用方 updateBangumiByType /
      // updateBangumiCollection 见到 null 就直接 return false，
      // 不用 unknown，因为那是 API 的读取值而非可写入值。
      CollectType.none => null,
    };
  }
}
