/// `/api/v2/search/episodes` 的响应。
///
/// 与 `/api/v2/search/anime` 不同，这里的条目没有封面、评分与放送日期。
class DanmakuSearchAnime {
  final int animeId;
  final String animeTitle;
  final String typeDescription;

  const DanmakuSearchAnime({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
  });

  factory DanmakuSearchAnime.fromJson(Map<String, dynamic> json) {
    return DanmakuSearchAnime(
      animeId: json['animeId'],
      animeTitle: json['animeTitle'],
      typeDescription: json['typeDescription'] ?? '',
    );
  }
}

class DanmakuSearchResponse {
  final List<DanmakuSearchAnime> animes;

  /// 结果被截断，提示用户缩小关键词范围。
  final bool hasMore;

  const DanmakuSearchResponse({
    required this.animes,
    required this.hasMore,
  });

  factory DanmakuSearchResponse.fromJson(Map<String, dynamic> json) {
    var list = json['animes'] as List;
    return DanmakuSearchResponse(
      animes: list.map((i) => DanmakuSearchAnime.fromJson(i)).toList(),
      hasMore: json['hasMore'] ?? false,
    );
  }
}
