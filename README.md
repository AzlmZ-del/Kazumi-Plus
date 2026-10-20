<div align=center>

<h1>Kazumi Plus</h1>

<img src="assets/images/logo/logo_rounded.png" width=200></img>

<img src="https://img.shields.io/badge/Flutter-03A9F4?style=for-the-badge&logo=flutter&logoColor=white"></img>
<img src="https://img.shields.io/badge/Dart-00B4AB?style=for-the-badge&logo=Dart&logoColor=white"></img>
<img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=for-the-badge"></img>

<p>基于 <a href="https://github.com/Predidit/Kazumi">Predidit/Kazumi</a> 的个人魔改版番剧采集与在线观看程序。
在原版基础上加了多规则仓库、规则登录与直链接口、详情页剧集与讨论、Bangumi R18 搜索等能力。</p>
</div>

> **这不是官方项目。** 与上游作者、官方仓库无关，不代表任何官方立场，也**没有向上游提 PR 的打算**。
> 改动全部由个人需求驱动，按自己手头的源和用法维护，不承诺功能通用性。

## 这是什么

上游 [Kazumi](https://github.com/Predidit/Kazumi) 用最多五行 XPath 选择器构建规则来采集番剧。
这个仓库是它的 fork，在原版之上补了一批自用功能，**基础能力（规则引擎、播放器、弹幕、超分、
追番、时间表等）完全来自上游**，没有重写。

改完之后的应用显示名是 **Kazumi Plus**，`applicationId` 是 `com.patch.kazumi`，
和官方版 `com.predidit.kazumi` 不冲突，**两个版本可以同时装在一台机器上**。

配套的规则仓库在 [**AzlmZ-del/KazumiRules**](https://github.com/AzlmZ-del/KazumiRules)。

## 相对官方版多了什么

| 功能 | 说明 |
|---|---|
| **多规则仓库** | 可同时挂多个第三方仓库，规则条目记录来源；目录聚合、同名去重、按仓库地址路由下载，另有独立管理页 |
| **规则登录与令牌** | 规则可声明登录接口，凭据本地保存、令牌缓存，401 自动重登；规则还能声明播放接口，绕开 WebView 直接取直链 |
| **详情页增强** | 剧集页签、已播出/未播出区分、讨论行内展开或独立页面、「内部打开」 |
| **Bangumi** | R18 条目搜索、无中文名条目可选保留、镜像取不到时回落到官方接口 |
| **独立 applicationId** | 与官方版并存安装 |

设计取舍写在 [docs/custom-rule-repository-design.md](docs/custom-rule-repository-design.md)。

规则文件里新增的这些字段**只有本版认识**，官方版会直接忽略，所以用了 API 模式的规则
必须配本版：

| 字段 | 用途 |
|---|---|
| `auth` | 规则登录流程、`tokenPath`、`refreshOnStatus` |
| `searchApiConfig` / `chapterApiConfig` | API 模式取数（`searchMode: api`） |
| `episodePage` / `play` | 播放直链接口 |
| `antiCrawlerConfig` | 验证码流程 |

## 安装

Android 走本仓库的 [Releases](../../releases)，附件名形如
`KazumiPlus-2.4.2-android-arm64-v8a.apk`。**只有 arm64-v8a**，armeabi-v7a / x86_64 的机器装不了。
装好后 **设置 → 更新 → 检查更新** 会读本仓库的最新 Release，有新版本就在应用内下载覆盖安装。

因为 `applicationId` 是 `com.patch.kazumi`、和官方版不同，两者可以装在一起互不影响，
设置与数据也是各自独立的。

> 从早期 **debug 签名**的构建升级会失败（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），
> 需要先卸载旧版再装这个正式签名的 APK。之后同签名的版本都能直接覆盖升级。

其余平台仍需自行构建，见下一节。

## 构建

### 环境

| 项 | 版本 |
|---|---|
| Flutter | 3.47.7（stable） |
| Dart SDK | `>=3.10.0 <4.0.0` |
| 当前版本号 | 2.4.2+20402（`pubspec.yaml`） |

其余平台工具链按 [Flutter 官方文档](https://docs.flutter.dev/get-started/install) 准备。
上游作者提醒过：本项目除了 Google 托管的 Flutter 依赖，还依赖 MavenCentral / GitHub /
SourceForge 上的资源，中国大陆可能需要配镜像。

### 凭据

弹弹play 与 Bangumi 镜像的接口需要签名，官方构建从 CI secrets 注入。本地构建需要自己准备
一个 `build_local.env`（**已在 `.gitignore` 里，切勿提交**）：

```dotenv
DANDAN_APPID=xxx
DANDAN_KEY=xxx
MIRROR_APPID=xxx
MIRROR_KEY=xxx
```

这四个值最终变成 `--dart-define`：`DANDAN_APPID`/`DANDAN_KEY` → `DANDANAPI_APPID`/`DANDANAPI_KEY`，
`MIRROR_APPID`/`MIRROR_KEY` → `KAZUMI_APPID`/`KAZUMI_KEY`。没有它们，Bangumi 镜像会对搜索与
评论请求返回 401，弹幕搜索也会失败。

源码里只有 `String.fromEnvironment` 的占位，没有任何真实值：

```dart
// lib/utils/bangumi_mirror_credentials.dart
const Map<String, String> bangumiMirrorCredentials = {
  'id': String.fromEnvironment('KAZUMI_APPID'),
  'value': String.fromEnvironment('KAZUMI_KEY'),
};
```

### 脚本

仓库里有四个本地构建脚本。它们**只读 `build_local.env` / `tools/local-credentials.json` 取凭据**，
没有内嵌任何密钥。

| 脚本 | 用途 |
|---|---|
| `build_apk.ps1` | Android，单架构 arm64 release，编完自动 `adb install -r`；`-NoInstall` 只编译 |
| `run_mobile.ps1` | 直接 `flutter run --release` 部署到已连接的设备（不落 apk 文件），脚本里写死了设备序列号，换机要改 |
| `build_local.ps1` | Windows 桌面 release 并启动；`-NoLaunch` 只编译 |
| `tools/build-local.sh` | POSIX 侧同一套凭据注入，`apk` / `windows` 两个目标，另支持 `--print-defines` |

```powershell
# Android：编译并装机
.\build_apk.ps1

# Android：只出包
.\build_apk.ps1 -NoInstall
# 产物 -> build\app\outputs\flutter-apk\app-arm64-v8a-release.apk

# Windows 桌面
.\build_local.ps1
```

手工构建等价于：

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --dart-define=DANDANAPI_APPID=... \
  --dart-define=DANDANAPI_KEY=... \
  --dart-define=KAZUMI_APPID=... \
  --dart-define=KAZUMI_KEY=...
```

### 验证

```bash
flutter analyze   # upstream 既有 17 条 info，error / warning 应为 0
flutter test      # 362 passed / 2 skipped
```

## 发布

打 tag 就会出 Release —— tag 必须是**裸版本号**且与 `pubspec.yaml` 的 `version` 一致：

```bash
git tag 2.4.2
git push --no-verify fork 2.4.2
```

`.github/workflows/android-release.yaml` 会校验 tag 与 `pubspec.yaml` 是否相等，然后用
`KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` 四个 secrets 还原
正式签名，产出 `KazumiPlus-<tag>-android-arm64-v8a.apk` 挂到 Release 上，
同时附一个 `KazumiPlus-<tag>-arm64-v8a.apk.sha256` 校验文件。

**tag 不能带 `v` 前缀**：`needUpdate()` 按 `.` 分段 `int.parse`，`v2.4.0` 会直接抛异常。
版本号只能往上抬（`2.4.2`、`2.5.0`…），发布后不能重发同一个 tag。

### 构建速度

优化前后的实测（同一台 `ubuntu-latest`，同一份代码，`workflow_dispatch` 跑的）：

| | 优化前 | 冷缓存 | 命中缓存 |
|---|---|---|---|
| 总耗时 | 8 分 27 秒 | 8 分 55 秒 | **3 分 20 秒** |
| `Build APK` | 421 秒 | 390 秒 | **118 秒** |
| 产物体积 | 74.4 MB | 31.97 MB | 31.97 MB |

注意冷缓存那轮**比优化前还慢 28 秒** —— 省下的编译时间被缓存的上传开销吃掉了
（三个 cache 存 47 秒、下一轮恢复 47 秒）。收益从第二次构建才开始兑现。

- **只出 arm64**。加 `--split-per-abi` 后 Gradle 只产出 `app-arm64-v8a-release.apk`，
  另外两个架构既不编译也不打进包（`aapt2` 只报 `native-code: 'arm64-v8a'`）。
  产物 31.9 MB，比全架构的 74.4 MB 小一半多，构建时间省约 3 分钟。
- **Gradle 发行包 + 依赖走 `actions/cache`**。第一次跑会在 `Gradle 8.14.5-all.zip`
  下载和 AGP 依赖解析上空等约 2 分钟，缓存命中后跳过。
- **NDK 28.2 单独缓存**。runner 预装 27.3 / 29.0 / 30.0，偏偏没有项目声明的 28.2，
  不缓存就得每次现下约 24 秒。
- **`PUB_CACHE` 缓存**。`flutter build` 内部自己会跑一次 `pub get`，不缓存要多下 76 秒。
- **`concurrency` 取消重复触发**。同一 tag 连推两次不会并行排队。

`Build APK` 那 118 秒里 Gradle 真正编译只占小头，剩下是 Flutter 的 AOT 编译与
Dart 到 native 的桥接，这部分没法再缓存。

上游那份 `release.yaml` 是全平台流水线，依赖 SignPath 签名、iOS 证书等本仓库没有的
secrets，已改成只保留 `workflow_dispatch` 手动触发，不再响应 tag。

## 与上游同步

```bash
tools/sync-upstream.sh --check   # 只看领先/落后多少提交
tools/sync-upstream.sh           # 把本地改动重放到最新 upstream/main
tools/sync-upstream.sh --abort   # 重放中途出问题，退回重放前
```

脚本会在重放后自动跑 `flutter analyze` 与 `flutter test` 做验收，失败会提示回退命令。
本机缺 MSVC 工具链时，测试跑不起来会被识别成环境问题而不是代码问题。

## 已知限制

- **自动更新指向本仓库**：`ApiEndpoints.latestApp` / `latestAppMirror` 都改成读
  `AzlmZ-del/Kazumi-Plus` 的 `/releases/latest`。镜像走
  `https://cdn.gh-proxy.org/` 前缀转发，国内可直连；拉不到会回落到 `api.github.com`。
  下载源的「镜像」选项同样用这个前缀拼 GitHub 的 `browser_download_url`，
  默认选中 **GitHub**。
- 本仓库只出 Android。Windows / Linux / macOS / iOS 的构建路径没有 CI，也未验证。
- `ApiEndpoints.pluginShop` 与 `pluginShopMirror` 仍指向上游的 `Predidit/KazumiRules`，
  自用规则要自己在**规则仓库管理**里加 `AzlmZ-del/KazumiRules` 的地址。
- 上游的 UA 串、`MethodChannel('com.predidit.kazumi/...')`、`BINARY_NAME`/`OriginalFilename`
  等标识按原样保留 —— 改它们会破坏构建或与官方行为不一致，属于有意为之。
- 只有 Android 与 Windows 的构建路径在本机跑通过；Linux / macOS / iOS 未验证。
- 上游的 `pr.yaml` 原样保留；上游那份多平台 `release.yaml` 已限制为手动触发。

## 平台

沿用上游：Android 10+、Windows 10+、macOS 10.15+、Linux（实验性）、iOS 13+（需侧载）。
上游另有 HarmonyOS 与 Web 的分支仓库，与本版无关。

## 上游功能与文档

规则写法、播放器、弹幕、超分、一起看这些都在上游：

- 项目主页：<https://github.com/Predidit/Kazumi>
- 规则开发文档：<https://kazumi.app/docs/rules/develop-rules>
- 上游规则仓库：<https://github.com/Predidit/KazumiRules>

## 免责声明

本项目基于 GNU 通用许可证第 3 版（GPL-3.0）授权。**不提供任何视频内容**，
不内嵌视频文件、字幕或账号，规则只描述公开站点的搜索、章节与播放接口。

不保证适用性、可靠性或准确性。在法律允许的最大范围内，作者与贡献者不承担任何因使用
本软件而产生的直接、间接、偶然、特殊或后果性损害赔偿责任。

使用本项目需遵守所在地法律法规，不得进行任何侵犯第三方知识产权的行为。

## 美术资源与致谢

图标来自 [Yuquanaaa](https://www.pixiv.net/users/66219277) 发表在
[Pixiv](https://www.pixiv.net/artworks/116666979) 上的作品，版权归原作者所有，
本项目已获授权使用。**该图标不是自由使用的**，未经原作者明确授权，任何人不得擅自使用、
复制、修改或分发。内嵌字体为 [Mi Sans](https://hyperos.mi.com/font/zh/details/sc/)，
由 [Xiaomi](https://www.mi.com/index.html) 开发并拥有版权。

上游生态里的这些项目撑起了本版绝大部分能力：

- [XpathSelector](https://github.com/simonkimi/xpath_selector) —— 规则引擎的基石
- [弹弹play](https://www.dandanplay.com/) —— 弹幕交互
- [Bangumi](https://bangumi.tv/) —— 番剧元数据
- [Anime4K](https://github.com/bloc97/Anime4K) —— 实时超分
- [SyncPlay](https://github.com/Syncplay/syncplay) —— 一起看
- [trace.moe](https://trace.moe) —— 以图找番
- [media-kit](https://github.com/media-kit/media-kit) —— 跨平台媒体播放
- [avbuild](https://github.com/wang-bin/avbuild) —— 非标准视频流的树外补丁
- [hive](https://github.com/isar/hive) —— 持久化储存

以及 [上游所有贡献者](https://github.com/Predidit/Kazumi/graphs/contributors)。
