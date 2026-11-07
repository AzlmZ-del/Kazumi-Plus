import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 搜索历史的数据访问接口。
abstract class ISearchHistoryRepository {
  /// 获取所有搜索历史（按时间戳倒序）
  List<SearchHistory> getAllHistories();

  /// 保存一条搜索历史，返回是否成功。
  Future<bool> saveHistory(String keyword);

  /// 删除指定的一条搜索历史。
  Future<void> deleteHistory(SearchHistory history);

  /// 清空所有搜索历史
  Future<void> clearAllHistories();

  /// 删掉同关键词的重复记录。
  Future<void> deleteDuplicates(String keyword);

  /// 判断是否已达到 [maxCount] 条上限。
  bool isHistoryFull(int maxCount);

  /// 删除最旧的历史记录
  Future<void> deleteOldest();
}

/// 基于 Hive 的搜索历史数据访问实现。
///
/// 基于Hive实现的搜索历史数据访问层
class SearchHistoryRepository implements ISearchHistoryRepository {
  final _searchHistoryBox = GStorage.searchHistory;

  @override
  List<SearchHistory> getAllHistories() {
    try {
      final histories = _searchHistoryBox.values.toList().cast<SearchHistory>();
      histories.sort((a, b) => b.timestamp - a.timestamp);
      return histories;
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: get all search histories failed',
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  @override
  Future<bool> saveHistory(String keyword) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final history = SearchHistory(keyword, timestamp);
      await _searchHistoryBox.put(timestamp.toString(), history);
      return true;
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: save search history failed. keyword=$keyword',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<void> deleteHistory(SearchHistory history) async {
    try {
      await _searchHistoryBox.delete(history.key);
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: delete search history failed. key=${history.key}',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> clearAllHistories() async {
    try {
      await _searchHistoryBox.clear();
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: clear all search histories failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> deleteDuplicates(String keyword) async {
    try {
      final histories = getAllHistories();
      final duplicates = histories.where((h) => h.keyword == keyword);
      for (var history in duplicates) {
        await deleteHistory(history);
      }
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: delete duplicate search histories failed. keyword=$keyword',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  bool isHistoryFull(int maxCount) {
    try {
      return _searchHistoryBox.length >= maxCount;
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: check if search history is full failed',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<void> deleteOldest() async {
    try {
      final histories = getAllHistories();
      if (histories.isNotEmpty) {
        await deleteHistory(histories.last);
      }
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'GStorage: delete oldest search history failed',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
