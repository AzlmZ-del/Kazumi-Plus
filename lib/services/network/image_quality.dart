import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 番剧封面的分辨率档位。
///
/// Bangumi 的封面图有两种互不兼容的取法：
///
/// * `lain.bgm.tv` 在 `/pic/` 前插 `/r/<宽度>/` 前缀，但只认固定的
///   `100, 200, 400, 600, 800, 1200`，其它宽度一律返回 400。
/// * `api.bgm.tv/v0/{subjects|characters|persons}/<id>/image` 用 `type`
///   查询参数，而它的档位名对应的宽度和前缀形式完全不同 —— 这里的
///   `medium` 是 800 宽，而 200 宽对应的是 `small`，不是 `medium`。
///
/// 所以按档位名去取图，两个接口出来的尺寸会差出几十倍。
/// [applyUrl] 改成朝一个明确的「目标宽度」改写 URL，让所有入口口径一致，
/// 同时绕开镜像那边 `images['common']` 和 `images['large']` 重复的已知 bug。
enum ImageQuality implements AccelerationMode {
  original,
  large,
  medium,
  small;

  static ImageQuality get current =>
      values.asNameMap()[GStorage.getSetting(SettingsKeys.imageQuality)] ??
      original;

  /// 请求的目标宽度（像素），`null` 表示不做处理、保持原图。
  /// 高度由封面自身的宽高比推算，不在这里指定。
  int? get targetWidth => switch (this) {
    original => null,
    large => 800,
    medium => 400,
    small => 200,
  };

  static const _apiImageKinds = {'subjects', 'characters', 'persons'};

  @override
  String get label => switch (this) {
    original => '原图',
    large => '大',
    medium => '中',
    small => '小',
  };

  @override
  String get description => switch (this) {
    original => '加载原始封面（默认）',
    large => '宽度 800 像素',
    medium => '宽度 400 像素',
    small => '宽度 200 像素',
  };

  /// 把 [src] 改写到 [targetWidth]，非 Bangumi 域名的链接原样返回。
  ///
  /// `original` 档以及识别不出来的 URL 都直接返回原值。
  String applyUrl(String src) {
    final width = targetWidth;
    if (width == null || src.isEmpty) return src;

    final uri = Uri.tryParse(src);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return src;
    }
    if (uri.host == 'lain.bgm.tv') return _applyLain(uri, width);
    if (uri.host == 'api.bgm.tv') return _applyApi(uri, width);
    return src;
  }

  static String _applyLain(Uri uri, int width) {
    final marker = uri.path.indexOf('/pic/');
    if (marker < 0) return uri.toString();
    final resized = uri.replace(
      path: '${uri.path.substring(0, marker)}/r/$width${uri.path.substring(marker)}',
    );
    return resized.toString();
  }

  static String _applyApi(Uri uri, int width) {
    final segments = uri.pathSegments;
    if (segments.length != 4 || segments[0] != 'v0' || segments[3] != 'image') {
      return uri.toString();
    }
    if (int.tryParse(segments[2]) == null ||
        !_apiImageKinds.contains(segments[1])) {
      return uri.toString();
    }
    final query = Map<String, String>.from(uri.queryParameters)
      ..['type'] = switch (width) {
        800 => 'medium',
        400 => 'common',
        200 => 'small',
        _ => 'large',
      };
    return uri.replace(queryParameters: query).toString();
  }
}
