import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/utils/device.dart';

enum SettingGroup {
  player,
  danmaku,
  theme,
  interface,
  proxy,
  webdav,
  download,
  bangumi,
  collect,
  sync,
  update,
  misc,
}

class SettingContext {
  const SettingContext({this.compactLayout = false});

  final bool compactLayout;
}

class SettingKey<T> {
  const SettingKey(
    this.name,
    this.defaultValue, {
    required this.group,
    this.defaultResolver,
  });

  final String name;
  final T defaultValue;
  final SettingGroup group;
  final T Function(SettingContext context)? defaultResolver;

  T resolveDefault(SettingContext context) {
    return defaultResolver?.call(context) ?? defaultValue;
  }
}

// Add new settings here. SettingsKeys is the public typed registry used by
// callers; new keys can use literal string names directly.
class SettingsKeys {
  static const hAenable = SettingKey<bool>(
    _SettingBoxKey.hAenable,
    true,
    group: SettingGroup.player,
  );
  static const hardwareDecoder = SettingKey<String>(
    _SettingBoxKey.hardwareDecoder,
    'auto-safe',
    group: SettingGroup.player,
  );
  static const searchEnhanceEnable = SettingKey<bool>(
    _SettingBoxKey.searchEnhanceEnable,
    true,
    group: SettingGroup.misc,
  );
  static const autoUpdate = SettingKey<bool>(
    _SettingBoxKey.autoUpdate,
    true,
    group: SettingGroup.update,
  );
  static const checkPluginUpdateOnStartup = SettingKey<bool>(
    'checkPluginUpdateOnStartup',
    true,
    group: SettingGroup.update,
  );
  static const alwaysOntop = SettingKey<bool>(
    _SettingBoxKey.alwaysOntop,
    false,
    group: SettingGroup.misc,
  );
  static const defaultPlaySpeed = SettingKey<double>(
    _SettingBoxKey.defaultPlaySpeed,
    1.0,
    group: SettingGroup.player,
  );
  static const defaultShortcutForwardPlaySpeed = SettingKey<double>(
    _SettingBoxKey.defaultShortcutForwardPlaySpeed,
    2.0,
    group: SettingGroup.player,
  );
  static const defaultAspectRatioType = SettingKey<int>(
    _SettingBoxKey.defaultAspectRatioType,
    1,
    group: SettingGroup.player,
  );
  static const buttonSkipTime = SettingKey<int>(
    _SettingBoxKey.buttonSkipTime,
    80,
    group: SettingGroup.player,
  );
  static const arrowKeySkipTime = SettingKey<int>(
    _SettingBoxKey.arrowKeySkipTime,
    10,
    group: SettingGroup.player,
  );
  static const danmakuEnhance = SettingKey<bool>(
    _SettingBoxKey.danmakuEnhance,
    true,
    group: SettingGroup.danmaku,
  );

  /// Off on desktop and on on mobile, like the B 站 client.
  static final pauseOnDanmakuEdit = SettingKey<bool>(
    'pauseOnDanmakuEdit',
    true,
    group: SettingGroup.danmaku,
    defaultResolver: (_) => !isDesktop(),
  );
  static const danmakuBorder = SettingKey<bool>(
    _SettingBoxKey.danmakuBorder,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuBorderSize = SettingKey<double>(
    _SettingBoxKey.danmakuBorderSize,
    1.5,
    group: SettingGroup.danmaku,
  );
  static const danmakuOpacity = SettingKey<double>(
    _SettingBoxKey.danmakuOpacity,
    1.0,
    group: SettingGroup.danmaku,
  );
  static final danmakuFontSize = SettingKey<double>(
    _SettingBoxKey.danmakuFontSize,
    25.0,
    group: SettingGroup.danmaku,
    defaultResolver: (context) => context.compactLayout ? 16.0 : 25.0,
  );
  static const danmakuTop = SettingKey<bool>(
    _SettingBoxKey.danmakuTop,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuScroll = SettingKey<bool>(
    _SettingBoxKey.danmakuScroll,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuBottom = SettingKey<bool>(
    _SettingBoxKey.danmakuBottom,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuMassive = SettingKey<bool>(
    _SettingBoxKey.danmakuMassive,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuDeduplication = SettingKey<bool>(
    _SettingBoxKey.danmakuDeduplication,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuChConvert = SettingKey<int>(
    'danmakuChConvert',
    0,
    group: SettingGroup.danmaku,
  );
  static const danmakuArea = SettingKey<double>(
    _SettingBoxKey.danmakuArea,
    1.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuColor = SettingKey<bool>(
    _SettingBoxKey.danmakuColor,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuDuration = SettingKey<double>(
    _SettingBoxKey.danmakuDuration,
    8.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuLineHeight = SettingKey<double>(
    _SettingBoxKey.danmakuLineHeight,
    1.6,
    group: SettingGroup.danmaku,
  );
  static const danmakuTimeOffset = SettingKey<double>(
    _SettingBoxKey.danmakuTimeOffset,
    0.0,
    group: SettingGroup.danmaku,
  );
  static const danmakuEnabledByDefault = SettingKey<bool>(
    _SettingBoxKey.danmakuEnabledByDefault,
    false,
    group: SettingGroup.danmaku,
  );
  static const danmakuBiliBiliSource = SettingKey<bool>(
    _SettingBoxKey.danmakuBiliBiliSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuGamerSource = SettingKey<bool>(
    _SettingBoxKey.danmakuGamerSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuDanDanSource = SettingKey<bool>(
    _SettingBoxKey.danmakuDanDanSource,
    true,
    group: SettingGroup.danmaku,
  );
  static const danmakuFontWeight = SettingKey<int>(
    _SettingBoxKey.danmakuFontWeight,
    4,
    group: SettingGroup.danmaku,
  );
  static const danmakuFollowSpeed = SettingKey<bool>(
    _SettingBoxKey.danmakuFollowSpeed,
    true,
    group: SettingGroup.danmaku,
  );
  static const themeMode = SettingKey<String>(
    _SettingBoxKey.themeMode,
    'system',
    group: SettingGroup.theme,
  );
  static const themeColor = SettingKey<String>(
    _SettingBoxKey.themeColor,
    'default',
    group: SettingGroup.theme,
  );
  static const privateMode = SettingKey<bool>(
    _SettingBoxKey.privateMode,
    false,
    group: SettingGroup.player,
  );
  static const autoPlay = SettingKey<bool>(
    _SettingBoxKey.autoPlay,
    true,
    group: SettingGroup.player,
  );
  static const autoPlayNext = SettingKey<bool>(
    _SettingBoxKey.autoPlayNext,
    true,
    group: SettingGroup.player,
  );
  static const playResume = SettingKey<bool>(
    _SettingBoxKey.playResume,
    true,
    group: SettingGroup.player,
  );
  static const showPlayerError = SettingKey<bool>(
    _SettingBoxKey.showPlayerError,
    false,
    group: SettingGroup.player,
  );
  static const oledEnhance = SettingKey<bool>(
    _SettingBoxKey.oledEnhance,
    false,
    group: SettingGroup.theme,
  );
  static const displayMode = SettingKey<String?>(
    _SettingBoxKey.displayMode,
    null,
    group: SettingGroup.interface,
  );
  static const enableGitProxy = SettingKey<bool>(
    _SettingBoxKey.enableGitProxy,
    true,
    group: SettingGroup.proxy,
  );
  // JSON-encoded rule repository list. An empty string means "never
  // configured", which decodes to the built-in official repository only.
  static const ruleRepositories = SettingKey<String>(
    'ruleRepositories',
    '',
    group: SettingGroup.proxy,
  );
  static const enableBangumiProxy = SettingKey<bool>(
    _SettingBoxKey.enableBangumiProxy,
    true,
    group: SettingGroup.proxy,
  );
  static const imageAcceleration = SettingKey<String>(
    'imageAcceleration',
    'ech',
    group: SettingGroup.proxy,
  );
  // Defaults to ECH: it reaches the official API without relying on a mirror.
  static const bangumiAcceleration = SettingKey<String>(
    'bangumiAcceleration',
    'ech',
    group: SettingGroup.proxy,
  );
  // Rules repository acceleration. An empty value falls back to the legacy
  // `enableGitProxy` switch so existing installs keep their current behaviour.
  static const rulesMirror = SettingKey<String>(
    'rulesMirror',
    '',
    group: SettingGroup.proxy,
  );
  static const enableSystemProxy = SettingKey<bool>(
    _SettingBoxKey.enableSystemProxy,
    false,
    group: SettingGroup.proxy,
  );
  static const defaultStartupPage = SettingKey<String>(
    _SettingBoxKey.defaultStartupPage,
    '/tab/popular/',
    group: SettingGroup.interface,
  );
  // Deep links open on top of whatever page the app was showing, so Back
  // returns there. Opt in to reset the stack to the start page first, which
  // costs the current tab position but makes Back land on the home tab.
  static const deepLinkReturnHome = SettingKey<bool>(
    'deepLinkReturnHome',
    false,
    group: SettingGroup.interface,
  );
  static const webDavEnable = SettingKey<bool>(
    _SettingBoxKey.webDavEnable,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableHistory = SettingKey<bool>(
    _SettingBoxKey.webDavEnableHistory,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableCollect = SettingKey<bool>(
    _SettingBoxKey.webDavEnableCollect,
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableDanmakuShield = SettingKey<bool>(
    'webDavEnableDanmakuShield',
    false,
    group: SettingGroup.webdav,
  );
  static const webDavEnableCredentials = SettingKey<bool>(
    'webDavEnableCredentials',
    false,
    group: SettingGroup.webdav,
  );
  /// 本地备份目录（空 = 尚未选择）。
  ///
  /// 存的是原生侧拿到的绝对路径，不是文档树 URI —— 备份就是普通的文件拷贝，
  /// 需要能直接 `File.copy`。
  static const localBackupDirectory = SettingKey<String>(
    'localBackupDirectory',
    '',
    group: SettingGroup.sync,
  );

  /// macOS 沙盒下的持久目录授权，仅在 macOS 写入。
  static const localBackupDirectoryBookmark = SettingKey<String>(
    'localBackupDirectoryBookmark',
    '',
    group: SettingGroup.sync,
  );

  /// 本地备份/恢复勾选的四类内容。
  ///
  /// 与 WebDAV 那四个开关分开存：两边想备份的东西往往不一样，
  /// 本地常常只留一份轻量的观看记录。
  static const localBackupEnable = SettingKey<bool>(
    'localBackupEnable',
    false,
    group: SettingGroup.sync,
  );

  /// 「同步云端开关」：本地备份要备份哪几项，直接跟随【启用 WebDAV】的四个开关。
  ///
  /// 开着的时候下面那四个 `localBackupEnableXxx` 不参与判断（`LocalBackupService`
  /// 的四个 getter 会改读 `webDavEnableXxx`），界面上也会把它们藏起来 ——
  /// 两处同时可改会让「到底以谁为准」变得说不清。
  ///
  /// 关着时退回原来那四个独立开关，各存各的。
  static const localBackupFollowWebDav = SettingKey<bool>(
    'localBackupFollowWebDav',
    false,
    group: SettingGroup.sync,
  );
  static const localBackupEnableHistory = SettingKey<bool>(
    'localBackupEnableHistory',
    false,
    group: SettingGroup.sync,
  );
  static const localBackupEnableCollect = SettingKey<bool>(
    'localBackupEnableCollect',
    false,
    group: SettingGroup.sync,
  );
  static const localBackupEnableDanmakuShield = SettingKey<bool>(
    'localBackupEnableDanmakuShield',
    false,
    group: SettingGroup.sync,
  );
  static const localBackupEnableCredentials = SettingKey<bool>(
    'localBackupEnableCredentials',
    false,
    group: SettingGroup.sync,
  );
  static const danmakuShieldSyncDeviceId = SettingKey<String>(
    'danmakuShieldSyncDeviceId',
    '',
    group: SettingGroup.sync,
  );
  static const danmakuShieldSyncState = SettingKey<String>(
    'danmakuShieldSyncState',
    '',
    group: SettingGroup.sync,
  );
  static const danmakuShieldSyncCorruptState = SettingKey<String>(
    'danmakuShieldSyncCorruptState',
    '',
    group: SettingGroup.sync,
  );
  static const webDavURL = SettingKey<String>(
    _SettingBoxKey.webDavURL,
    '',
    group: SettingGroup.webdav,
  );
  static const webDavUsername = SettingKey<String>(
    _SettingBoxKey.webDavUsername,
    '',
    group: SettingGroup.webdav,
  );
  static const webDavPassword = SettingKey<String>(
    _SettingBoxKey.webDavPassword,
    '',
    group: SettingGroup.webdav,
  );
  static const lowMemoryMode = SettingKey<bool>(
    _SettingBoxKey.lowMemoryMode,
    false,
    group: SettingGroup.player,
  );
  // Null preserves the legacy lowMemoryMode choice until a policy is selected.
  static const lowMemoryPolicy = SettingKey<String?>(
    'lowMemoryPolicy',
    null,
    group: SettingGroup.player,
  );
  static const showWindowButton = SettingKey<bool>(
    _SettingBoxKey.showWindowButton,
    false,
    group: SettingGroup.theme,
  );
  static const useDynamicColor = SettingKey<bool>(
    _SettingBoxKey.useDynamicColor,
    false,
    group: SettingGroup.theme,
  );
  static const exitBehavior = SettingKey<int>(
    _SettingBoxKey.exitBehavior,
    2,
    group: SettingGroup.interface,
  );
  static const playerDebugMode = SettingKey<bool>(
    _SettingBoxKey.playerDebugMode,
    false,
    group: SettingGroup.player,
  );
  static const syncPlayEndPoint = SettingKey<String>(
    _SettingBoxKey.syncPlayEndPoint,
    defaultSyncPlayEndPoint,
    group: SettingGroup.player,
  );
  static const syncPlayUserName = SettingKey<String>(
    'syncPlayUserName',
    '',
    group: SettingGroup.player,
  );
  static const androidEnableOpenSLES = SettingKey<bool>(
    _SettingBoxKey.androidEnableOpenSLES,
    true,
    group: SettingGroup.player,
  );
  static const androidVideoRenderer = SettingKey<String>(
    _SettingBoxKey.androidVideoRenderer,
    'auto',
    group: SettingGroup.player,
  );
  static const androidAutoEnterPIP = SettingKey<bool>(
    _SettingBoxKey.androidAutoEnterPIP,
    false,
    group: SettingGroup.player,
  );
  static const defaultSuperResolutionMode = SettingKey<int>(
    _SettingBoxKey.defaultSuperResolutionMode,
    1,
    group: SettingGroup.player,
  );
  static const disableSuperResolutionWarning = SettingKey<bool>(
    _SettingBoxKey.disableSuperResolutionWarning,
    false,
    group: SettingGroup.player,
  );
  static const playerDisableAnimations = SettingKey<bool>(
    _SettingBoxKey.playerDisableAnimations,
    false,
    group: SettingGroup.player,
  );
  static const playerLogLevel = SettingKey<int>(
    _SettingBoxKey.playerLogLevel,
    2,
    group: SettingGroup.player,
  );
  static const timelineNotShowAbandonedBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineNotShowAbandonedBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const timelineNotShowWatchedBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineNotShowWatchedBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const timelineOnlyShowWatchingBangumis = SettingKey<bool>(
    _SettingBoxKey.timelineOnlyShowWatchingBangumis,
    false,
    group: SettingGroup.collect,
  );
  static const useSystemFont = SettingKey<bool>(
    _SettingBoxKey.useSystemFont,
    false,
    group: SettingGroup.theme,
  );
  static const forceAdBlocker = SettingKey<bool>(
    _SettingBoxKey.forceAdBlocker,
    false,
    group: SettingGroup.player,
  );
  static const backgroundPlayback = SettingKey<bool>(
    _SettingBoxKey.backgroundPlayback,
    false,
    group: SettingGroup.player,
  );
  static const proxyEnable = SettingKey<bool>(
    _SettingBoxKey.proxyEnable,
    false,
    group: SettingGroup.proxy,
  );
  static const proxyConfigured = SettingKey<bool>(
    _SettingBoxKey.proxyConfigured,
    false,
    group: SettingGroup.proxy,
  );
  static const proxyUrl = SettingKey<String>(
    _SettingBoxKey.proxyUrl,
    '',
    group: SettingGroup.proxy,
  );
  static const proxyTestUrl = SettingKey<String>(
    _SettingBoxKey.proxyTestUrl,
    '',
    group: SettingGroup.proxy,
  );
  static const showRating = SettingKey<bool>(
    _SettingBoxKey.showRating,
    true,
    group: SettingGroup.interface,
  );
  static const defaultCollectLayout = SettingKey<String>(
    'defaultCollectLayout',
    'list',
    group: SettingGroup.interface,
  );

  // Opt-in R18 search. Requires a Bangumi access token; without one the API
  // silently drops the nsfw filter, so the setting has no effect.
  static const bangumiShowR18 = SettingKey<bool>(
    'bangumiShowR18',
    false,
    group: SettingGroup.interface,
  );
  // Search results without a Chinese title used to be dropped silently. Keep
  // that as the default so existing behaviour does not change, but let users
  // opt in to the untranslated entries instead of losing them.
  static const bangumiShowUntranslated = SettingKey<bool>(
    'bangumiShowUntranslated',
    false,
    group: SettingGroup.interface,
  );
  static const downloadParallelEpisodes = SettingKey<int>(
    _SettingBoxKey.downloadParallelEpisodes,
    2,
    group: SettingGroup.download,
  );
  static const downloadParallelSegments = SettingKey<int>(
    _SettingBoxKey.downloadParallelSegments,
    3,
    group: SettingGroup.download,
  );
  static const downloadDanmaku = SettingKey<bool>(
    _SettingBoxKey.downloadDanmaku,
    true,
    group: SettingGroup.download,
  );
  static const downloadDirectory = SettingKey<String>(
    _SettingBoxKey.downloadDirectory,
    '',
    group: SettingGroup.download,
  );
  // macOS only: security-scoped bookmark that keeps downloadDirectory
  // writable across app restarts under the sandbox.
  static const downloadDirectoryBookmark = SettingKey<String>(
    'downloadDirectoryBookmark',
    '',
    group: SettingGroup.download,
  );
  static const shortcutDialogShown = SettingKey<bool>(
    _SettingBoxKey.shortcutDialogShown,
    false,
    group: SettingGroup.misc,
  );
  static const onboardingCompleted = SettingKey<bool>(
    'onboardingCompleted',
    false,
    group: SettingGroup.misc,
  );
  static const bangumiSyncEnable = SettingKey<bool>(
    _SettingBoxKey.bangumiSyncEnable,
    false,
    group: SettingGroup.bangumi,
  );
  static const bangumiAccessToken = SettingKey<String>(
    _SettingBoxKey.bangumiAccessToken,
    '',
    group: SettingGroup.bangumi,
  );
  static const bangumiSyncPriority = SettingKey<int>(
    _SettingBoxKey.bangumiSyncPriority,
    0,
    group: SettingGroup.bangumi,
  );
  static const bangumiImmediateSyncToastEnable = SettingKey<bool>(
    _SettingBoxKey.bangumiImmediateSyncToastEnable,
    true,
    group: SettingGroup.bangumi,
  );
  static const bangumiWebCookie = SettingKey<String>(
    'bangumiWebCookie',
    '',
    group: SettingGroup.bangumi,
  );
  static const bangumiWebEmail = SettingKey<String>(
    'bangumiWebEmail',
    '',
    group: SettingGroup.bangumi,
  );
  static const bangumiWebPassword = SettingKey<String>(
    'bangumiWebPassword',
    '',
    group: SettingGroup.bangumi,
  );

  /// 网页登录拿到 `chii_auth` 的本地时间（毫秒时间戳），0 表示没记录过。
  ///
  /// 只用于在卡片上显示「已登录 · 2026-10-25 23:49」，不参与任何判断：
  /// cookie 是否有效一律以服务端返回的 `CHOBITS_UID` 为准。
  static const bangumiWebLoginAt = SettingKey<int>(
    'bangumiWebLoginAt',
    0,
    group: SettingGroup.bangumi,
  );

  /// 上次成功取到的 Bangumi 昵称，空字符串表示没记录过。
  ///
  /// 昵称只能拿 Access Token 打一次 `/v0/me` 才拿得到（网页登录本身只给 UID）。
  /// 落盘是为了进页面首帧就能显示「昵称 · UID」，不必等网络回来再刷一次。
  static const bangumiWebNickname = SettingKey<String>(
    'bangumiWebNickname',
    '',
    group: SettingGroup.bangumi,
  );

  /// 上一次校验登录态（请求 `/subject/1` 读 `CHOBITS_UID`）的时间，
  /// 毫秒时间戳，0 表示从没校验过。
  ///
  /// 进页面时如果这个时间在 [bangumiWebValidateCacheMinutes] 以内，就直接沿用
  /// 上次结果，不再发请求；「重新检查」按钮永远绕过缓存。
  static const bangumiWebValidatedAt = SettingKey<int>(
    'bangumiWebValidatedAt',
    0,
    group: SettingGroup.bangumi,
  );

  /// 上一次校验的结论：true 有效、false 失效。只在 [bangumiWebValidatedAt]
  /// 落在缓存窗口内时才可信。
  static const bangumiWebValidatedOk = SettingKey<bool>(
    'bangumiWebValidatedOk',
    false,
    group: SettingGroup.bangumi,
  );

  /// 上一次校验读到的 UID（`CHOBITS_UID`），0 表示没记录。
  ///
  /// 命中缓存时靠它把副标题的「UID 808296」补回来，否则会退化成
  /// 「已登录，可删除 Bangumi 收藏」。
  static const bangumiWebUid = SettingKey<int>(
    'bangumiWebUid',
    0,
    group: SettingGroup.bangumi,
  );

  /// 登录态校验结果的缓存时长（小时），范围 1~24。
  ///
  /// 进页面时如果上次校验时间在这个窗口内，就直接沿用上次结论，不再发请求；
  /// 「重新检查」按钮永远绕过缓存。
  static const bangumiWebValidateIntervalHours = SettingKey<int>(
    'bangumiWebValidateIntervalHours',
    6,
    group: SettingGroup.bangumi,
  );
  static const brightnessVolumeGesture = SettingKey<bool>(
    _SettingBoxKey.brightnessVolumeGesture,
    true,
    group: SettingGroup.player,
  );
  static const historySyncDeviceId = SettingKey<String>(
    _SettingBoxKey.historySyncDeviceId,
    '',
    group: SettingGroup.sync,
  );
  static const historySyncSequence = SettingKey<int>(
    _SettingBoxKey.historySyncSequence,
    0,
    group: SettingGroup.sync,
  );
  static const historySyncSnapshotInitialized = SettingKey<bool>(
    _SettingBoxKey.historySyncSnapshotInitialized,
    false,
    group: SettingGroup.sync,
  );
  static const playerControllerLayerDisappearTime = SettingKey<int>(
    'playerControllerLayerDisappearTime',
    4000,
    group: SettingGroup.player,
  );
  static const defaultVolume = SettingKey<double>(
    'defaultVolume',
    100.0,
    group: SettingGroup.player,
  );
  static const playerMuted = SettingKey<bool>(
    'playerMuted',
    false,
    group: SettingGroup.player,
  );

  static final List<SettingKey<Object?>> all = [
    hAenable,
    hardwareDecoder,
    searchEnhanceEnable,
    autoUpdate,
    checkPluginUpdateOnStartup,
    alwaysOntop,
    defaultPlaySpeed,
    defaultShortcutForwardPlaySpeed,
    defaultAspectRatioType,
    buttonSkipTime,
    arrowKeySkipTime,
    danmakuEnhance,
    pauseOnDanmakuEdit,
    danmakuBorder,
    danmakuBorderSize,
    danmakuOpacity,
    danmakuFontSize,
    danmakuTop,
    danmakuScroll,
    danmakuBottom,
    danmakuMassive,
    danmakuDeduplication,
    danmakuChConvert,
    danmakuArea,
    danmakuColor,
    danmakuDuration,
    danmakuLineHeight,
    danmakuTimeOffset,
    danmakuEnabledByDefault,
    danmakuBiliBiliSource,
    danmakuGamerSource,
    danmakuDanDanSource,
    danmakuFontWeight,
    danmakuFollowSpeed,
    themeMode,
    themeColor,
    privateMode,
    autoPlay,
    autoPlayNext,
    playResume,
    showPlayerError,
    oledEnhance,
    displayMode,
    enableGitProxy,
    ruleRepositories,
    enableBangumiProxy,
    imageAcceleration,
    bangumiAcceleration,
    rulesMirror,
    enableSystemProxy,
    defaultStartupPage,
    deepLinkReturnHome,
    webDavEnable,
    webDavEnableHistory,
    webDavEnableCollect,
    webDavEnableDanmakuShield,
    webDavEnableCredentials,
    danmakuShieldSyncDeviceId,
    danmakuShieldSyncState,
    danmakuShieldSyncCorruptState,
    webDavURL,
    webDavUsername,
    webDavPassword,
    lowMemoryMode,
    lowMemoryPolicy,
    showWindowButton,
    useDynamicColor,
    exitBehavior,
    playerDebugMode,
    syncPlayEndPoint,
    syncPlayUserName,
    androidEnableOpenSLES,
    androidVideoRenderer,
    androidAutoEnterPIP,
    defaultSuperResolutionMode,
    disableSuperResolutionWarning,
    playerDisableAnimations,
    playerLogLevel,
    timelineNotShowAbandonedBangumis,
    timelineNotShowWatchedBangumis,
    timelineOnlyShowWatchingBangumis,
    useSystemFont,
    forceAdBlocker,
    backgroundPlayback,
    proxyEnable,
    proxyConfigured,
    proxyUrl,
    proxyTestUrl,
    showRating,
    defaultCollectLayout,
    bangumiShowR18,
    bangumiShowUntranslated,
    downloadParallelEpisodes,
    downloadParallelSegments,
    downloadDanmaku,
    downloadDirectory,
    downloadDirectoryBookmark,
    shortcutDialogShown,
    onboardingCompleted,
    bangumiSyncEnable,
    bangumiAccessToken,
    bangumiSyncPriority,
    bangumiImmediateSyncToastEnable,
    bangumiWebCookie,
    bangumiWebEmail,
    bangumiWebPassword,
    bangumiWebLoginAt,
    bangumiWebNickname,
    bangumiWebValidatedAt,
    bangumiWebValidatedOk,
    bangumiWebUid,
    bangumiWebValidateIntervalHours,
    brightnessVolumeGesture,
    historySyncDeviceId,
    historySyncSequence,
    historySyncSnapshotInitialized,
    localBackupDirectory,
    localBackupDirectoryBookmark,
    localBackupEnable,
    localBackupFollowWebDav,
    localBackupEnableHistory,
    localBackupEnableCollect,
    localBackupEnableDanmakuShield,
    localBackupEnableCredentials,
    playerControllerLayerDisappearTime,
    defaultVolume,
    playerMuted,
  ];

  static List<SettingKey<Object?>> byGroup(SettingGroup group) {
    return [
      for (final key in all)
        if (key.group == group) key,
    ];
  }

  SettingsKeys._();
}

// Historical Hive key names used by settings created before the typed registry.
// Keep these strings stable so existing users keep their saved settings.
// New settings do not need to be added here unless they intentionally reuse an
// existing persisted key.
class _SettingBoxKey {
  static const String hAenable = 'hAenable',
      hardwareDecoder = 'hardwareDecoder',
      searchEnhanceEnable = 'searchEnhanceEnable',
      autoUpdate = 'autoUpdate',
      alwaysOntop = 'alwaysOntop',
      defaultPlaySpeed = 'defaultPlaySpeed',
      defaultShortcutForwardPlaySpeed = 'defaultShortcutForwardPlaySpeed',
      defaultAspectRatioType = 'defaultAspectRatioType',
      buttonSkipTime = 'buttonSkipTime',
      arrowKeySkipTime = 'arrowKeySkipTime',
      danmakuEnhance = 'danmakuEnhance',
      danmakuBorder = 'danmakuBorder',
      danmakuBorderSize = 'danmakuBorderSize',
      danmakuOpacity = 'danmakuOpacity',
      danmakuFontSize = 'danmakuFontSize',
      danmakuTop = 'danmakuTop',
      danmakuScroll = 'danmakuScroll',
      danmakuBottom = 'danmakuBottom',
      danmakuMassive = 'danmakuMassive',
      danmakuDeduplication = 'danmakuDeduplication',
      danmakuArea = 'danmakuArea',
      danmakuColor = 'danmakuColor',
      danmakuDuration = 'danmakuDuration',
      danmakuLineHeight = 'danmakuLineHeight',
      danmakuTimeOffset = 'danmakuTimeOffset',
      danmakuEnabledByDefault = 'danmakuEnabledByDefault',
      danmakuBiliBiliSource = 'danmakuBiliBiliSource',
      danmakuGamerSource = 'danmakuGamerSource',
      danmakuDanDanSource = 'danmakuDanDanSource',
      danmakuFontWeight = 'danmakuFontWeight',
      danmakuFollowSpeed = 'danmakuFollowSpeed',
      themeMode = 'themeMode',
      themeColor = 'themeColor',
      privateMode = 'privateMode',
      autoPlay = 'autoPlay',
      autoPlayNext = 'autoPlayNext',
      playResume = 'playResume',
      showPlayerError = 'showPlayerError',
      oledEnhance = 'oledEnhance',
      displayMode = 'displayMode',
      enableGitProxy = 'enableGitProxy',
      enableBangumiProxy = 'enableBangumiProxy',
      enableSystemProxy = 'enableSystemProxy',
      defaultStartupPage = 'defaultStartupPage',
      webDavEnable = 'webDavEnable',
      webDavEnableHistory = 'webDavEnableHistory',
      webDavEnableCollect = 'webDavEnableCollect',
      webDavURL = 'webDavURL',
      webDavUsername = 'webDavUsername',
      webDavPassword = 'webDavPasswd',
      lowMemoryMode = 'lowMemoryMode',
      showWindowButton = 'showWindowButton',
      useDynamicColor = 'useDynamicColor',
      exitBehavior = 'exitBehavior',
      playerDebugMode = 'playerDebugMode',
      syncPlayEndPoint = 'syncPlayEndPoint',
      androidEnableOpenSLES = 'androidEnableOpenSLES',
      androidVideoRenderer = 'androidVideoRenderer',
      androidAutoEnterPIP = 'androidAutoEnterPIP',
      defaultSuperResolutionMode = 'defaultSuperResolutionType',
      disableSuperResolutionWarning = 'superResolutionWarn',
      playerDisableAnimations = 'playerDisableAnimations',
      playerLogLevel = 'playerLogLevel',
      timelineNotShowAbandonedBangumis = 'timelineNotShowAbandonedBangumis',
      timelineNotShowWatchedBangumis = 'timelineNotShowWatchedBangumis',
      timelineOnlyShowWatchingBangumis = 'timelineOnlyShowWatchingBangumis',
      useSystemFont = 'useSystemFont',
      forceAdBlocker = 'forceAdBlocker',
      backgroundPlayback = 'backgroundPlayback',
      proxyEnable = 'proxyEnable',
      proxyConfigured = 'proxyConfigured',
      proxyUrl = 'proxyUrl',
      proxyTestUrl = 'proxyTestUrl',
      showRating = 'showRating',
      downloadParallelEpisodes = 'downloadParallelEpisodes',
      downloadParallelSegments = 'downloadParallelSegments',
      downloadDanmaku = 'downloadDanmaku',
      downloadDirectory = 'downloadDirectory',
      shortcutDialogShown = 'shortcutDialogShown',
      bangumiSyncEnable = 'bangumiSyncEnable',
      bangumiAccessToken = 'bangumiAccessToken',
      bangumiSyncPriority = 'bangumiSyncPriority',
      bangumiImmediateSyncToastEnable = 'bangumiImmediateSyncToastEnable',
      brightnessVolumeGesture = 'brightnessVolumeGesture',
      historySyncDeviceId = 'historySyncDeviceId',
      historySyncSequence = 'historySyncSequence',
      historySyncSnapshotInitialized = 'historySyncSnapshotInitialized';
}
