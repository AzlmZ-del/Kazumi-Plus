import 'package:flutter/services.dart' show appBuildName;

class ApiEndpoints {
  /// Current version.
  static const String version = appBuildName ?? '0.0.0';

  /// Rule API level.
  static const int apiLevel = 9;

  /// Project homepage.
  static const String projectUrl = "https://kazumi.app/";

  /// GitHub project homepage.
  static const String sourceUrl = "https://github.com/Predidit/Kazumi";

  /// Icon author.
  static const String iconUrl = "https://www.pixiv.net/users/66219277";

  /// Rule repository.
  static const String pluginShop =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/';

  /// gh-proxy acceleration host. Kept bare for callers that build their own prefix.
  static const String ghProxyHost = 'cdn.gh-proxy.org';

  /// Prefix mirror: append the full URL to this base.
  static const String ghProxyMirror = 'https://$ghProxyHost/';

  /// Backup prefix mirror.
  static const String ghfastMirror = 'https://ghfast.top/';

  /// gh-proxy.com: tested more stable than [ghProxyMirror]; works for both built-in repos.
  static const String ghProxyComMirror = 'https://gh-proxy.com/';

  /// ghproxy.imciel.com: latency comparable to gh-proxy.com.
  static const String ghProxyImcielMirror = 'https://ghproxy.imciel.com/';

  /// ghproxy.net: works but noticeably slower.
  static const String ghProxyNetMirror = 'https://ghproxy.net/';

  /// ghproxy.cn: very slow, and mirrors only the official repo.
  static const String ghProxyCnMirror = 'https://ghproxy.cn/';

  /// jsDelivr path mirror: rewrite GitHub raw as `gh/<owner>/<repo>@<ref>/<path>`.
  static const String jsDelivrMirror = 'https://cdn.jsdelivr.net/gh/';

  /// jsDelivr CDN node for the same content, with latency close to the main domain.
  static const String jsDelivrGcoreMirror = 'https://gcore.jsdelivr.net/gh/';

  /// Fixed GitHub raw prefix; path mirrors rewrite based on this.
  static const String githubRawPrefix = 'https://raw.githubusercontent.com/';

  /// Path mirror: only the official rule repo; replace the `pluginShop` prefix rather than append.
  static const String gitcodeMirror =
      'https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/';

  /// Personal rule repo, bundled alongside the official one.
  static const String personalPluginShop =
      'https://raw.githubusercontent.com/AzlmZ-del/Kazumi-Plus-Rules/main/';

  /// Repo hosting this build's releases.
  static const String releasesRepo = 'https://github.com/AzlmZ-del/Kazumi-Plus';

  /// In-app update: read the latest release of this repo.
  static const String latestApp =
      'https://api.github.com/repos/AzlmZ-del/Kazumi-Plus/releases/latest';

  /// In-app update mirror: gh-proxy forwarding of api.github.com, reachable directly in CN.
  static const String latestAppMirror =
      'https://cdn.gh-proxy.org/https://api.github.com/repos/AzlmZ-del/Kazumi-Plus/releases/latest';

  /// Release asset download acceleration prefix (prepend to the full URL).
  static const String releaseDownloadProxy = 'https://cdn.gh-proxy.org/';

  /// Bangumi mirror test backend.
  static const String bangumiMirrorDomain = 'https://api.kazumi.fyi';

  /// DanDanPlay website.
  static const String dandanIndex = 'https://www.dandanplay.com/';

  /// Bangumi website.
  static const String bangumiIndex = 'https://bangumi.tv/';

  /// bangumi-data dataset (CC BY 4.0; broadcast times and platform sources for schedules).
  static const String bangumiDataIndex =
      'https://github.com/bangumi-data/bangumi-data';

  /// Bangumi API base URL.
  static const String bangumiAPIDomain = 'https://api.bgm.tv';


  /// Telegram group.
  static const String telegramGroup = 'https://t.me/kazumi_app';

  /// Subject relations.
  static const String bangumiRelationsByID = '/v0/subjects/{0}/subjects';

  /// Subject search.
  static const String bangumiRankSearch =
      '/v0/search/subjects?limit={0}&offset={1}';

  /// Get characters of a subject by ID.
  static const String bangumiCharacterByID = '/v0/subjects/{0}/characters';

  /// Get staff of a subject by ID.
  static const String bangumiStaffByID = '/v0/subjects/{0}/persons';

  /// Get episode IDs of a subject by ID.
  static const String bangumiEpisodeByID = '/v0/episodes';

  /// Get the user info for the current access token.
  static const String bangumiUsernameByToken = '/v0/me';

  /// Add or update a single collection entry for the user.
  static const String bangumiSetCollection = '/v0/users/-/collections/{0}';

  /// Get all collections of a user (any type). Args: username, limit, offset.
  static const String bangumiGetAllCollections =
      '/v0/users/{0}/collections?subject_type=2&limit={1}&offset={2}';

  /// Bangumi Next API Domain
  static const String bangumiAPINextDomain = 'https://next.bgm.tv';

  static const bangumiPublicApiHosts = {'api.bgm.tv', 'next.bgm.tv'};

  /// Daily broadcast calendar.
  static const String bangumiCalendar = '/p1/calendar';

  /// Trending subjects.
  static const String bangumiTrendsNext = '/p1/trending/subjects';

  /// Kazumi Bangumi mirror cached popularity ranking.
  static const String bangumiMirrorPopularSubjects =
      '/kazumi/v1/popular/subjects';

  /// Kazumi Bangumi mirror seasonal calendar.
  static const String bangumiMirrorSeasonCalendar =
      '/kazumi/v1/calendar/season';

  /// Subject info.
  static const String bangumiInfoByIDNext = '/p1/subjects/{0}';

  /// Subject comments.
  static const String bangumiCommentsByIDNext =
      '/p1/subjects/{0}/comments?limit={1}&offset={2}';

  /// Episode comments.
  static const String bangumiEpisodeCommentsByIDNext =
      '/p1/episodes/{0}/comments';

  /// Character info.
  static const String bangumiCharacterInfoByCharacterIDNext =
      '/p1/characters/{0}';

  /// Character comments.
  static const String bangumiCharacterCommentsByIDNext =
      '/p1/characters/{0}/comments';

  /// DanDanPlay API Domain
  static const String dandanAPIDomain = 'https://api.dandanplay.net';

  /// Get danmaku (comments).
  static const String dandanAPIComment = "/api/v2/comment/";

  /// Search DanDanPlay subject metadata.
  static const String dandanAPISearchEpisodes = "/api/v2/search/episodes";

  /// Get DanDanPlay subject metadata.
  static const String dandanAPIInfo = "/api/v2/bangumi/";

  /// Get DanDanPlay subject metadata by Bangumi (BGM) subject ID.
  static const String dandanAPIInfoByBgmBangumiId = "/api/v2/bangumi/bgmtv/{0}";

  /// Identify a subject from an image.
  static const String traceApi = 'https://api.trace.moe/search';

  static String formatUrl(String url, List<dynamic> params) {
    for (int i = 0; i < params.length; i++) {
      url = url.replaceAll('{$i}', params[i].toString());
    }
    return url;
  }
}
