import 'dart:math';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:mobx/mobx.dart';

part 'popular_controller.g.dart';

class PopularController = _PopularController with _$PopularController;

abstract class _PopularController with Store {
  static const int _trendPageSize = 24;

  int _trendOffset = 0;

  @observable
  String currentTag = '';

  @observable
  ObservableList<BangumiItem> bangumiList = ObservableList.of([]);

  @observable
  ObservableList<BangumiItem> trendList = ObservableList.of([]);

  double scrollOffset = 0.0;

  @observable
  bool isLoadingMore = false;

  @observable
  bool isTimeOut = false;

  bool get _bangumiMirrorEnabled =>
      BangumiAcceleration.current == BangumiAcceleration.mirror;

  void setCurrentTag(String s) {
    currentTag = s;
  }

  void clearBangumiList() {
    bangumiList.clear();
  }

  // 异步 action 把每个 await 之间的片段各自提交为一次事务，
  // 从而把多次完成写入合并成一条通知。
  @action
  Future<void> queryBangumiByTrend({String type = 'add'}) async {
    if (type == 'init') {
      trendList.clear();
      _trendOffset = 0;
    }
    isLoadingMore = true;
    final page = _bangumiMirrorEnabled
        ? await BangumiApi.getBangumiMirrorPopularSubjects(
            limit: _trendPageSize,
            offset: _trendOffset,
          )
        : await BangumiApi.getBangumiTrendsList(
            limit: _trendPageSize,
            offset: _trendOffset,
          );
    final result = page.items;
    if (result.isNotEmpty) {
      _trendOffset += _trendPageSize;
    }
    final existingIds = trendList.map((item) => item.id).toSet();
    trendList.addAll(result.where((item) => existingIds.add(item.id)));
    isLoadingMore = false;
    // A rejected token used to yield an empty list and nothing else, so a
    // non-empty grid hid the failure completely. Keep the grid, but say so.
    if (page.failed && trendList.isNotEmpty) {
      KazumiDialog.showToast(message: '加载失败，请检查网络或 Bangumi 授权');
    }
    isTimeOut = trendList.isEmpty;
  }

  @action
  Future<void> queryBangumiByTag({String type = 'add'}) async {
    if (type == 'init') {
      bangumiList.clear();
    }
    isLoadingMore = true;
    var tag = currentTag;
    final page = _bangumiMirrorEnabled
        ? await BangumiApi.getBangumiMirrorPopularSubjects(
            tag: tag,
            offset: bangumiList.length,
          )
        : await BangumiApi.getBangumiList(
            rank: Random().nextInt(8000) + 1,
            tag: tag,
          );
    bangumiList.addAll(page.items);
    isLoadingMore = false;
    if (page.failed && bangumiList.isNotEmpty) {
      KazumiDialog.showToast(message: '加载失败，请检查网络或 Bangumi 授权');
    }
    isTimeOut = bangumiList.isEmpty;
  }
}
