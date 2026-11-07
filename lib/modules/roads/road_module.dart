/// 一条播放线路：同一部番的一组分集来源。
///
/// [data] 与 [identifier] 是平行数组，必须等长、下标一一对应。
/// [data] 存每集的定位串——在线播放时是集号字符串，离线下载时是视频 URL，
/// 具体含义由调用方按场景解释；[identifier] 是给人看的集名。
class Road {
  String name;
  List<String> data;
  List<String> identifier;

  Road({
    required this.name,
    required this.data,
    required this.identifier,
  });
}
