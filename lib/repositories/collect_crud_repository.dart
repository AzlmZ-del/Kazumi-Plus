import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 收藏的数据访问接口。
abstract class ICollectCrudRepository {
  /// 每次写入收藏项发一次通知，WebDAV 同步还原也算在内。
  Stream<void> get changes;

  /// 获取所有收藏
  List<CollectedBangumi> getAllCollectibles();

  /// 取收藏类型，未收藏返回 0。
  int getCollectType(int id);

  /// 添加或更新收藏。
  Future<void> addCollectible(BangumiItem bangumiItem, int type);

  /// 更新收藏里缓存的番剧信息。
  Future<void> updateCollectible(BangumiItem bangumiItem);

  /// 删除收藏。
  Future<void> deleteCollectible(int id);

  /// 获取旧版收藏列表（用于迁移）
  List<BangumiItem> getFavorites();

  /// 清空旧版收藏（迁移后）
  Future<void> clearFavorites();
}

/// 基于 Hive 的收藏数据访问实现。
class CollectCrudRepository implements ICollectCrudRepository {
  final _collectiblesBox = GStorage.collectibles;
  final _favoritesBox = GStorage.favorites;

  @override
  Stream<void> get changes => _collectiblesBox.watch();

  @override
  List<CollectedBangumi> getAllCollectibles() {
    try {
      return _collectiblesBox.values.cast<CollectedBangumi>().toList();
    } catch (e) {
      KazumiLogger().w(
        'GStorage: get all collectibles failed',
        error: e,
      );
      return [];
    }
  }

  @override
  int getCollectType(int id) {
    try {
      final collectible = _collectiblesBox.get(id);
      return collectible?.type ?? 0;
    } catch (e) {
      KazumiLogger().w(
        'GStorage: get collect type failed. id=$id',
        error: e,
      );
      return 0;
    }
  }

  @override
  Future<void> addCollectible(BangumiItem bangumiItem, int type) async {
    try {
      final collectedBangumi = CollectedBangumi(
        bangumiItem,
        DateTime.now(),
        type,
      );
      await GStorage.putCollectible(collectedBangumi);
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: add collectible failed. id=${bangumiItem.id}, type=$type',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> updateCollectible(BangumiItem bangumiItem) async {
    try {
      final collectible = _collectiblesBox.get(bangumiItem.id);
      if (collectible == null) {
        KazumiLogger().i(
          'GStorage: update collectible failed. collectible not found, id=${bangumiItem.id}',
        );
        return;
      }
      collectible.bangumiItem = bangumiItem;
      await GStorage.putCollectible(collectible);
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: update collectible failed. id=${bangumiItem.id}',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> deleteCollectible(int id) async {
    try {
      await GStorage.deleteCollectible(id);
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: delete collectible failed. id=$id',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  List<BangumiItem> getFavorites() {
    try {
      return _favoritesBox.values.cast<BangumiItem>().toList();
    } catch (e) {
      KazumiLogger().i(
        'GStorage: get favorites failed',
        error: e,
      );
      return [];
    }
  }

  @override
  Future<void> clearFavorites() async {
    try {
      await _favoritesBox.clear();
      await _favoritesBox.flush();
    } catch (e) {
      KazumiLogger().i(
        'GStorage: clear favorites failed',
        error: e,
      );
      rethrow;
    }
  }
}
