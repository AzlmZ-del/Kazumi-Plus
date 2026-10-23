<div align=center>

<h1>Kazumi Plus</h1>

<img src="assets/images/logo/logo_rounded.png" width=200></img>

<img src="https://img.shields.io/badge/Flutter-03A9F4?style=for-the-badge&logo=flutter&logoColor=white"></img>
<img src="https://img.shields.io/badge/Dart-00B4AB?style=for-the-badge&logo=Dart&logoColor=white"></img>
<img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=for-the-badge"></img>

<p>基于 <a href="https://github.com/Predidit/Kazumi">Predidit/Kazumi</a> 的个人魔改版番剧采集与在线观看程序。</p>
</div>

> **这不是官方项目。** 与上游作者、官方仓库无关，也**没有向上游提 PR 的打算**。
> 改动全部由个人需求驱动，按自己手头的源和用法维护，不承诺功能通用性。

## 这是什么

上游 [Kazumi](https://github.com/Predidit/Kazumi) 用最多五行 XPath 选择器构建规则来采集番剧。
这个仓库是它的 fork，**规则引擎、播放器、弹幕、超分、追番、时间表等基础能力完全来自上游**，
只在上面补了一批自用功能。

应用显示名是 **Kazumi Plus**，`applicationId` 为 `com.patch.kazumi`，与官方版
`com.predidit.kazumi` 不冲突，**两个版本可以同时装在一台机器上**。

配套的规则仓库在 [**AzlmZ-del/Kazumi-Plus-Rules**](https://github.com/AzlmZ-del/Kazumi-Plus-Rules)。

## 相对官方版多了什么

| 功能 | 说明 |
|---|---|
| **多规则仓库** | 可同时挂多个第三方仓库，规则条目记录来源；目录聚合、同名去重、按仓库地址路由下载，另有独立管理页 |
| **内置个人仓库** | 除官方仓库外，`AzlmZ-del/Kazumi-Plus-Rules` 也作为内置仓库常驻列表第二位（可关闭、不可删除） |
| **加速方式可选** | 番剧条目、规则仓库、图片三处各自独立选择加速：直连 / ECH 加密握手 / 镜像。规则仓库的镜像还能在 gh-proxy、ghfast、GitCode 之间切换，只作用于两个内置仓库，第三方仓库不受影响 |
| **规则登录与令牌** | 规则可声明登录接口，凭据本地保存、令牌缓存，401 自动重登；规则还能声明播放接口，绕开 WebView 直接取直链 |
| **详情页增强** | 剧集页签、已播出/未播出区分、讨论行内展开或独立页面、「内部打开」 |
| **Bangumi** | R18 条目搜索、无中文名条目可选保留、镜像取不到时回落到官方接口 |
| **独立 applicationId** | 与官方版并存安装 |

规则文件里这些字段**只有本版认识**，官方版会直接忽略，所以用了 API 模式的规则必须配本版：

| 字段 | 用途 |
|---|---|
| `auth` | 规则登录流程、`tokenPath`、`refreshOnStatus` |
| `searchApiConfig` / `chapterApiConfig` | API 模式取数（`searchMode: api`） |
| `episodePage` / `play` | 播放直链接口 |
| `antiCrawlerConfig` | 验证码流程 |

设计取舍见 [docs/custom-rule-repository-design.md](docs/custom-rule-repository-design.md)。

## 安装

只发 Android，只出 **arm64-v8a**。装最新版到 [Releases](../../releases) 下载，
之后 **设置 → 更新 → 检查更新** 会读本仓库的 Release 并支持应用内覆盖升级。

> 从早期 **debug 签名**的构建升级会失败（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），
> 需要先卸载旧版。之后同签名的版本都能直接覆盖升级。

其余平台需自行构建。

## 构建

需要 Flutter 3.47.7（stable）与 Dart `>=3.10.0 <4.0.0`，工具链准备见
[Flutter 官方文档](https://docs.flutter.dev/get-started/install)。中国大陆可能需要配 MavenCentral /
GitHub / SourceForge 镜像。

弹弹play 与 Bangumi 镜像接口需要签名，本地构建在仓库根目录放一个 `build_local.env`
（**已在 `.gitignore` 里，切勿提交**）：

```dotenv
DANDAN_APPID=xxx
DANDAN_KEY=xxx
MIRROR_APPID=xxx
MIRROR_KEY=xxx
```

这四个值会被注入成 `--dart-define`：`DANDAN_APPID`/`DANDAN_KEY` →
`DANDANAPI_APPID`/`DANDANAPI_KEY`，`MIRROR_APPID`/`MIRROR_KEY` → `KAZUMI_APPID`/`KAZUMI_KEY`。
源码里只有 `String.fromEnvironment` 占位，没有任何真实值。

```powershell
.\build_apk.ps1            # Android，编完自动 adb install
.\build_apk.ps1 -NoInstall # 只出包
.\build_local.ps1          # Windows 桌面
```

等价的手工命令：

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --dart-define=DANDANAPI_APPID=... \
  --dart-define=DANDANAPI_KEY=... \
  --dart-define=KAZUMI_APPID=... \
  --dart-define=KAZUMI_KEY=...
```

## 免责声明

本项目基于 GNU 通用许可证第 3 版（GPL-3.0）授权。**不提供任何视频内容**，
不内嵌视频文件、字幕或账号，规则只描述公开站点的搜索、章节与播放接口。

不保证适用性、可靠性或准确性。在法律允许的最大范围内，作者与贡献者不承担任何因使用
本软件而产生的直接、间接、偶然、特殊或后果性损害赔偿责任。

使用本项目需遵守所在地法律法规，不得进行任何侵犯第三方知识产权的行为。

## 致谢

图标来自 [Yuquanaaa](https://www.pixiv.net/users/66219277) 发表在
[Pixiv](https://www.pixiv.net/artworks/116666979) 上的作品，版权归原作者所有，
本项目已获授权使用。**该图标不是自由使用的**，未经原作者明确授权，任何人不得擅自使用、
复制、修改或分发。内嵌字体为 [Mi Sans](https://hyperos.mi.com/font/zh/details/sc/)，
由 [Xiaomi](https://www.mi.com/index.html) 开发并拥有版权。

上游生态里的这些项目撑起了本版绝大部分能力：[XpathSelector](https://github.com/simonkimi/xpath_selector)、
[弹弹play](https://www.dandanplay.com/)、[Bangumi](https://bangumi.tv/)、
[Anime4K](https://github.com/bloc97/Anime4K)、[SyncPlay](https://github.com/Syncplay/syncplay)、
[trace.moe](https://trace.moe)、[media-kit](https://github.com/media-kit/media-kit)、
[avbuild](https://github.com/wang-bin/avbuild)、[hive](https://github.com/isar/hive)，
以及 [上游所有贡献者](https://github.com/Predidit/Kazumi/graphs/contributors)。
