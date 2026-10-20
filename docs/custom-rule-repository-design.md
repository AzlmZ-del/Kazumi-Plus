# 多规则仓库 —— 设计文档

对应 issue [#2485](https://github.com/Predidit/Kazumi/issues/2485)。
v2 修订：从「单仓库可选」升级为「多仓库并行加载 + 逐仓库启用/关闭」。
状态：待评审，未改动任何代码。

---

## 1. 目标

规则仓库从「一个硬编码地址」变成「一串可管理的仓库」，每个仓库可独立启用/关闭，启用中的仓库目录并行加载后合并展示。

验收标准：

1. 可添加任意多个仓库；填目录 URL 或 `index.json` 完整 URL 均可，两种写法等价。
2. 每个仓库有独立开关；关闭后它的规则从目录中消失，不参与安装与更新。
3. 启用中的仓库**同时**加载，一个仓库失败不影响其他仓库的规则展示。
4. 列表顺序即优先级，用于解决同名规则冲突。
5. 安装/更新时从**该规则所属仓库**取文件，不串仓库。
6. 官方 GitHub 镜像只作用于内置仓库（官方与个人），第三方仓库不受影响。
7. 内置仓库不可删除，只能关闭；官方保持 index 0，个人仓库固定在它后面。
8. 配置持久化；从未配置过的用户升级后行为与现在一致。
9. 不引入新依赖。

---

## 2. 现状

仓库地址是硬编码常量，只有一个：

| 位置 | 内容 |
|---|---|
| `lib/request/config/api_endpoints.dart:20-21` | `pluginShop = 'https://raw.githubusercontent.com/Predidit/KazumiRules/main/'` |
| `lib/request/config/api_endpoints.dart:24-25` | `pluginShopMirror = 'https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/'` |

使用点只有三处：

| 位置 | 用法 |
|---|---|
| `lib/request/apis/plugin_catalog_api.dart:12` | `'${ApiEndpoints.pluginShop}index.json'` 取目录 |
| `lib/request/apis/plugin_catalog_api.dart:57` | `'${ApiEndpoints.pluginShop}$name.json'` 取单条规则 |
| `lib/request/core/dio_factory.dart:113` | `if (!url.startsWith(ApiEndpoints.pluginShop))` 决定是否走镜像 |

第三条自带官方的边界：镜像靠前缀判断，第三方地址天然不匹配。多仓库下这条逻辑**完全不用改**，`enableGitProxy` 这个全局开关自动退化为「只影响官方那个仓库」。

目录数据的下游用法（决定了哪些要改）：

| 位置 | 现状 | 多仓库下的变化 |
|---|---|---|
| `plugins_controller.dart:78` | `Map<String, PluginHTTPItem> _pluginCatalogByName` | 保留，存去重后的胜出项 |
| `plugins_controller.dart:298` | `pluginStatus(item)` 按名字比对本地规则 | 不变 |
| `plugins_controller.dart:313` | `pluginUpdateStatus(plugin)` 按名字查远程 | 不变 |
| `plugins_controller.dart:334` | `tryUpdatePluginByName(name)` | 内部改成按 item 的仓库地址取 |
| `plugins_controller.dart:353` | `_pluginLoader(name)` | 需按仓库分发，见 §5.3 |
| `plugins_controller.dart:326` | `_updatablePluginNames()` | 改为返回 item 列表 |

---

## 3. 数据模型

### 3.1 仓库条目

新增 `lib/modules/plugin/rule_repository.dart`：

```dart
class RuleRepository {
  final String url;    // 归一化后，必以 / 结尾
  final String label;  // 显示名；空串时 UI 回退到主机名
  final bool enabled;
}
```

`label` 让它能显示「我的镜像」而不是一长串 URL；`url` 归一化后天然唯一，去重与比较都用它。

### 3.2 持久化格式

`SettingsKeys` 新增：

```dart
static const ruleRepositories = SettingKey<String>(
  'ruleRepositories',
  '',
  group: SettingGroup.proxy,
);
```

存 JSON 字符串而非 `List<String>`：一个条目有三个字段，拼字符串或拆成三个平行列表都会在增删时错位。JSON 一个 key 一次写完，原子且可读。

编解码放在 `RuleRepositoryList`（同文件）：

```dart
class RuleRepositoryList {
  static List<RuleRepository> decode(String raw);  // 空串 → 内置默认
  static String encode(List<RuleRepository> repos);
  static List<RuleRepository> defaults();          // [官方, enabled: true]
}
```

**空串 = 还没配置过**，此时返回 `defaults()`，不写盘。老用户升级后读到的就是官方单仓库，行为与现在一致；只要动过一次（开关、增删、排序），完整列表才落盘。

解码要**宽容**：单条 JSON 解析失败就跳过该条，不要整份配置作废——否则用户配置里有一条坏数据，整个仓库列表就归零了。

### 3.3 内置仓库的位置

本版有两个内置仓库：官方 `Predidit/KazumiRules` 与个人 `AzlmZ-del/Kazumi-Plus-Rules`。两者都**可关闭、不可删除、不可拖动**，分别固定在 index 0 与 index 1。理由：

- 可关闭：有人只想用第三方。
- 不可删除：删掉就再也找不到地址，用户只能重置设置。
- 恒在前两位：镜像前缀判断、`ApiEndpoints` 常量都还指着它们，位置固定能省很多特判。个人仓库紧跟官方，是因为它是本仓库作者自己维护的默认源，用户添加的仓库排在它们之后。

解码时会补回缺失的内置仓库，所以老配置（只有官方一条）升级后会自动多出个人仓库，不需要用户手动添加。个人仓库改过一次地址（`KazumiRules` → `Kazumi-Plus-Rules`），旧地址在解码时按地址迁移到新地址，否则老配置会同时留下旧条目与补回的新条目，列表里出现两个个人仓库。

全部仓库关掉是合法的（目录为空），但 UI 要给明确文案而不是空白。

---

## 4. 地址归一化

沿用 v1 的 `RulesRepositoryConfig.baseUri()`，规则不变：

| 输入 | 结果 |
|---|---|
| `https://example.com/rules/` | 原样 |
| `https://example.com/rules` | 补尾斜杠 |
| `https://example.com/rules/index.json` | 剥末段 → `https://example.com/rules/` |
| `https://cdn.jsdelivr.net/gh/u/R@1.2.0/` | 原样（末段含点但以 `/` 结尾，合法目录） |

拒绝：非 http(s)、无 host、带 `user:pass@`、带 `?query`/`#fragment`、末段含点却不以 `/` 结尾、host 是 `github.com`。

两个实现细节必须照做，否则会产出坏地址：

1. 用 `pathSegments` 判断并重建，**不要**对编码后的 `uri.path` 做定长截断。否则 `.../rules/index.json/` 和 `.../rules/%69ndex.json` 会被截成 `.../rules/i`。
2. `index.json` 匹配大小写不敏感。

多仓库下额外加两条约束：

- **添加时查重**：`baseUri()` 归一化后若与已有条目相同，提示「该仓库已存在」并高亮那一行，不重复添加。
- **官方地址归一化为空串的规则取消**。v1 里为了让单配置区分官方/自定义，官方要折叠成空串；多仓库下官方是列表里的显式条目，不需要这层折叠。否则「关掉官方再打开」会丢失条目。

---

## 5. 目录聚合

### 5.1 加载流程

```dart
Future<List<PluginHTTPItem>> refreshPluginCatalog() async {
  final generation = _pluginCatalogGeneration;
  final repos = enabledRepositories();      // 已启用，按列表顺序
  final results = await Future.wait(repos.map(_loadOneRepository));

  // 结果回到这里，检查 generation（见 §6）
  final merged = <PluginHTTPItem>[];
  final seen = <String>{};
  _repositoryFailures = {};
  for (final r in results) {
    if (r.error != null) {
      _repositoryFailures[r.repository.url] = r.error;
      continue;                              // 单仓库失败只跳过它
    }
    for (final item in r.items) {
      final key = pluginNameKey(item.name);
      if (seen.add(key)) {
        merged.add(item);                    // 首个出现的仓库胜出
      }
    }
  }
  ...
}
```

三个要点：

**并行而非串行。** 串行时仓库越多越慢，且一个超时会让后面的仓库排队。

**单个仓库失败隔离。** `_loadOneRepository` 内部自己 try/catch，返回 `({repository, items, error})` 记录，绝不向外抛。否则 `Future.wait` 一个失败就让整个目录加载失败——用户加了一个打不通的仓库，结果所有规则都没了，这是最难受的体验。

**每个仓库单独设超时。** `rulesRepoDio` 沿用 `NetworkConfig` 的全局超时，对单个不响应的仓库太长。建议在 `getText` 调用处包一个 `Future.timeout(Duration(seconds: 15))`，或者给 `getPluginList` 加可选 `timeout` 参数。第三方仓库质量不可控，这点很重要。

### 5.2 同名规则冲突

`_pluginCatalogByName` 是 `name → item` 的 map，天然只能一条。策略：**列表靠前的启用仓库胜出**，用户靠拖动排序就能调优先级。

被遮蔽的规则不丢失，另存：

```dart
Map<String, List<PluginHTTPItem>> _shadowedRules = const {};
// key = pluginNameKey，value = 同名的其余条目（按仓库顺序）
```

UI 上：

- 胜出的卡片照常显示，加一个来源 tag（`example.com`）。
- 若存在同名，tag 变成 `example.com +2`，长按/点击展开来源列表。

不做成两行并列卡片，因为 `pluginStatus` 是按名字算的，两行会显示两个一模一样的「已安装」，用户更懵。

### 5.3 安装/更新时定位仓库

这是多仓库最容易出错的地方：目录里合并了 N 个仓库的规则，点安装时必须回到**那条规则自己的仓库**去取 JSON。

`PluginHTTPItem` 是随目录返回的运行时对象，加两个字段即可（`lib/modules/plugin/plugin_http_module.dart`）：

```dart
class PluginHTTPItem {
  ...
  /// 该条目来自哪个仓库（归一化 URL）。仅在目录聚合时填充。
  String repositoryUrl = '';
  String repositoryLabel = '';
}
```

注意 `fromJson`（`:18-31`）不要碰这两个字段，让它们保持默认空串——它们不是仓库清单文件的内容，是聚合时贴上的运行时标号。

取文件改为按仓库分发。`PluginLoader` 的既有签名 `Future<Plugin> Function(String name)` 不能直接加参数（会破坏 `test/plugin_import_parser_test.dart:175` 等处注入的闭包类型），所以**新增一个 typedef**：

```dart
typedef PluginRepositoryLoader = Future<Plugin> Function(
  String repositoryUrl,
  String name,
);
```

控制器构造时多注入一个，默认 `PluginCatalogApi.getPluginFromRepository`。`_preparePluginUpdate` 逻辑：

```
按名字查 _pluginCatalogByName 拿到 item
  ├─ item.repositoryUrl 非空 → _repositoryLoader(item.repositoryUrl, name)
  ├─ item 为 null（本地有、目录没有，比如仓库被关了）→ 回退 _pluginLoader(name)
  └─ 都失败 → PluginUpdateResult.failed（保持既有语义）
```

`tryUpdatePluginByName(name)` 内部先反查 item 再走这条链，签名不变，调用方（`plugin_update_actions.dart:27`）无需改动。

`tryUpdateAllPlugin` 的 `_updatablePluginNames()` 改成返回 `List<PluginHTTPItem>`，`_preparePluginUpdates` 相应接收 item 列表——并发下载的 worker 逻辑本身不用动。

**一个必须注意的既有保护**：`_preparePluginUpdate` 里校验 `pluginNameKey(remotePlugin.name) != pluginNameKey(name)` 就拒绝（`:364-375`）。多仓库下这条更重要了——防止仓库 A 返回的 JSON 其实属于仓库 B 的同名规则，静默串换。保持原样即可。

### 5.4 编辑/导入的规则不受影响

用户自己写的规则（不来自任何仓库）`repositoryUrl` 恒为空，更新时走 `_pluginLoader` 回退——也就是官方仓库。这是现有行为，保持。

---

## 6. 失效与竞态

沿用 v1 的 generation 方案，理由在单仓库下成立，多仓库下更严重（仓库增删/开关/排序都是失效源）。

```dart
int _pluginCatalogGeneration = 0;

void invalidatePluginCatalog() {
  _pluginCatalogGeneration++;
  _pluginCatalogRefreshedAt = null;
  _pluginCatalogByName = const {};
  _shadowedRules = const {};
  _repositoryFailures = const {};
  pluginHTTPList.clear();
}
```

`refreshPluginCatalog` 拿到 generation 快照，`await` 完成后比对；不一致就丢弃结果并重新刷新，绝不写入 `_pluginCatalogRefreshedAt`。

问题路径（PR #2487 的评审也抓到了）：打开规则仓库页 → 首次加载未完成 → 用户关掉一个仓库 → 旧请求返回 → `_pluginCatalogRefreshedAt = DateTime.now()` → 被关掉的仓库的规则在 5 分钟（`_pluginCatalogMaxAge`，`:84`）内仍视为新鲜，点安装会去一个已禁用的仓库取文件。

同时 `_PluginCatalogViewState._refresh()`（`plugin_catalog_view.dart:94-101`）开头有 `if (_loading) return;`，首次加载期间的操作会被静默丢弃。这条守卫保留给手动连点防抖，但 `reload()` 要绕过它。

`AsyncSingleFlight`（`lib/utils/async_single_flight.dart`）在 `webdav.dart`、`captcha_verification_service.dart` 里仍有使用，只有 `plugins_controller.dart` 换成 generation 方案，不要顺手删工具类。

### 6.1 每仓库独立刷新

管理页里开关单个仓库时，不必等全量刷新：

```
开关切换 → 先改配置（乐观更新，开关立刻动）
       → invalidatePluginCatalog()
       → 全量 refreshPluginCatalog()
```

全量刷新在仓库少时够快；不做「只增量拉这一个仓库」的优化，因为合并逻辑（去重、优先级）必须全量重算才不会出错。开关置灰到刷新完成即可，有进度条。

---

## 7. 改动清单

### 7.1 新增

| 文件 | 内容 |
|---|---|
| `lib/modules/plugin/rule_repository.dart` | `RuleRepository` 模型 + `RuleRepositoryList` 编解码 + `defaults()` |
| `lib/request/config/rules_repository_config.dart` | `baseUri` / `catalogUri` / `ruleUri` / `enabledRepositories()` |
| `lib/pages/plugin_editor/rule_repository_page.dart` | 仓库管理页（§8.1） |
| `test/rule_repository_test.dart` | 编解码、默认值、宽容解码、查重 |
| `test/rules_repository_config_test.dart` | 归一化全表用例 |

### 7.2 修改

| 文件 | 改动 |
|---|---|
| `lib/services/storage/settings_keys.dart` | 加 `ruleRepositories`（String，默认 `''`），加入 `SettingsKeys.all` |
| `lib/modules/plugin/plugin_http_module.dart` | 加 `repositoryUrl` / `repositoryLabel` 两个运行时字段，`fromJson` 不动 |
| `lib/request/apis/plugin_catalog_api.dart` | 加 `getPluginListFrom(repositoryUrl)` 与 `getPluginFromRepository(url, name)`；原 `getPluginList()` / `getPlugin(name)` 保留为「取第一个启用仓库」的兼容壳或直接删（见 §10） |
| `lib/plugins/plugins_controller.dart` | 聚合加载、同名去重、`_shadowedRules`、`_repositoryFailures`、generation、按仓库分发 loader、`_updatablePluginNames` 改签名 |
| `lib/pages/plugin_editor/plugin_catalog_view.dart` | State 公开化、`reload()`、来源 tag、失败仓库提示条、空态文案 |
| `lib/pages/plugin_editor/plugin_shop_page.dart` | AppBar 加「管理仓库」入口、顶部状态条 |
| `lib/bean/settings/network_mirror_settings.dart` | 镜像开关描述改为「仅加速官方仓库」 |

### 7.3 不改

- `lib/request/core/dio_factory.dart` —— 前缀判断天然正确，只在注释里说明它与 `RulesRepositoryConfig` 的耦合。
- `lib/pages/onboarding/steps/plugin_shop_step.dart` —— 引导流程不放仓库管理入口。
- 已安装规则的存储格式 —— `plugins.json` 不动，规则本身不记来源。

---

## 8. 前端交互稿

### 8.1 仓库管理页

路由 `/settings/plugin/shop/repositories`，从规则仓库页 AppBar 进入。

```
← 规则仓库管理                       ＋

┌────────────────────────────────────────────┐
│ ⠿  官方规则仓库                    [●──]   │
│    raw.githubusercontent.com                │
└────────────────────────────────────────────┘
┌────────────────────────────────────────────┐
│ ⠿  我的镜像                        [●──]   │
│    cdn.jsdelivr.net/gh/me/Rules             │
│    22 条规则                    ⋮          │
└────────────────────────────────────────────┘
┌────────────────────────────────────────────┐
│ ⠿  朋友的小站                      [──○]   │
│    rules.example.com                        │
│    已关闭                       ⋮          │
└────────────────────────────────────────────┘

 仅使用你信任的仓库。第三方规则会访问其声明的网站和接口。
 拖动调整顺序，靠前的仓库优先提供同名规则。
```

元素行为：

| 元素 | 行为 |
|---|---|
| ⠿ 拖拽柄 | 重排，顺序即优先级；官方固定第一位，不能拖 |
| 名称 | 用户填的 `label`，空则显示主机名 |
| 副标题 | 归一化后的地址（去 scheme，省宽度）；第三行显示该仓库的规则数 / 加载失败 / 已关闭 |
| 开关 | 立即写配置 + 失效重载；重载期间开关禁用 |
| ⋮ 菜单 | 重命名 / 编辑地址 / 删除（官方无删除项） |
| ＋ | 打开添加弹窗 |
| 底部说明 | 固定的信任提示 + 排序说明 |

加载失败的仓库在副标题处显示红字「无法访问」，并在规则仓库页顶部汇总一条提示，其余仓库规则照常展示。

### 8.2 添加 / 编辑弹窗

```
┌──────────────────────────────────────────────┐
│  添加规则仓库                                 │
│                                              │
│  名称（可选）                                 │
│  ┌────────────────────────────────────────┐  │
│  │ 我的镜像                                │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  仓库地址                                     │
│  ┌────────────────────────────────────────┐  │
│  │ https://cdn.jsdelivr.net/gh/me/Rules/  │  │
│  └────────────────────────────────────────┘  │
│  填写包含 index.json 的目录，或直接粘贴        │
│  index.json 的完整地址                        │
│  ✗ 该仓库已存在                               │
│                                              │
│                取消          保存            │
└──────────────────────────────────────────────┘
```

校验在弹窗内联显示（`InputDecoration.errorText`），**不要用 toast**，出错时弹窗不关、用户改完直接重试。`FormatException.message` 本身就是给人看的中文。

`TextEditingController` 必须由 `State` 持有并在 `State.dispose()` 释放，不能用 `showDialog` 返回后 `dispose()`。`KazumiDialog.show` 的 Future 在 `Route.didPop` 就完成，早于退场动画与子树 dispose，此时 `autofocus` 的 TextField 仍在树里，会触发 "A TextEditingController was used after being disposed"。仓库里 `search_page.dart:455`、`rating_review_dialog.dart:91` 都是 State 持有写法。

保存后：

```
保存 → baseUri() 校验 → 查重 → 写配置
     → controller.invalidatePluginCatalog()
     → await 全量刷新
     → toast 三态：
         成功              「已保存」
         成功但该仓库失败    「已保存，但该仓库无法访问」
         刷新整体失败        「已保存，目录加载失败」
```

保存成功但加载失败**不回滚**——用户可能只是当下断网，回滚会让「我明明填了」变成更难理解的第二次失败。

### 8.3 规则仓库页

```
┌────────────────────────────────────────────┐
│  发现更多来源                                │
│  浏览社区规则，为你的番剧搜索添加更多选择。     │
│                                            │
│  [ 3 个仓库 · 2 个已启用        › ]         │
└────────────────────────────────────────────┘

  规则仓库镜像只作用于官方仓库，第三方仓库不受影响
```

顶部那条是入口，点击进管理页。`plugin_shop_page.dart` 现在是 `StatelessWidget`，要改成 `StatefulWidget` 持 `GlobalKey<PluginCatalogViewState>`；`SettingsDetailScaffold`（`:29-45`）已支持 `actions`。

### 8.4 规则卡片

`RuleCard`（`lib/bean/card/rule_card.dart:3-15`）已有 `tags`，加来源 tag 即可，不用改组件：

```
┌──────────────────────────────────────────┐
│  DM84                       作者 · 7sefun │
│  v1.2.0  含验证支持   example.com         │
│  更新于 2026-08-12              [ 安装 ]  │
└──────────────────────────────────────────┘
```

同名冲突时 tag 显示 `example.com +2`，点击弹出被遮蔽的来源清单（只读展示，含各自版本）。

来源 tag 用什么色：官方用 `surfaceContainerHighest`（与其他中性 tag 一致），第三方用 `secondaryContainer`，一眼能区分「这不是官方的东西」。

### 8.5 空态与失败态

| 情况 | 文案 |
|---|---|
| 所有仓库都关了 | 「所有规则仓库已关闭」+ 按钮「管理规则仓库」 |
| 全部仓库都加载失败 | 「无法访问任何规则仓库」+ 按钮「管理规则仓库」+ 列出失败的主机名 |
| 部分失败 | 顶部黄色提示条：「`example.com` 无法访问，正在显示其他仓库的规则。」可关闭 |

`plugin_catalog_view.dart:240-256` 现在的错误页永远只给「启用/关闭规则镜像」按钮，多仓库下这个按钮只对官方有意义，要按情况换成「管理规则仓库」。

### 8.6 设置页的镜像开关

`network_mirror_settings.dart:56-63` 保留，description 改为「仅加速官方仓库」。**不隐藏**——隐藏会让人以为开关消失了，置灰或保留可切换但写明作用范围更清楚。

---

## 9. 测试计划

| 类型 | 内容 |
|---|---|
| 单测 `test/rule_repository_test.dart` | 编解码往返、空串→默认列表、坏条目跳过不炸整份、查重、官方不可删不能移位 |
| 单测 `test/rules_repository_config_test.dart` | §4 表格全覆盖，含大小写、空段、编码片段、各类拒绝 |
| 单测（controller） | 两仓库合并去重（前胜后隐）；单仓库失败不拖垮其他；`invalidatePluginCatalog()` 后在途旧请求不得写入 catalog；`_shadowedRules` 正确 |
| 单测（controller） | 安装/更新按 `item.repositoryUrl` 取文件，不串仓库；`repositoryUrl` 为空时回退旧 loader |
| 手工 | 官方 + 一个 jsDelivr 镜像并行 → 目录合并 → 装镜像源的一条 → 关掉镜像 → 目录只剩官方 → 重开恢复 |
| 手工 | 加一个打不通的地址 → 其他仓库规则仍可用 → 顶部提示正确 |

`flutter analyze` 门槛：0 error / 0 warning，info 数不增加。

---

## 10. 取舍与边界

1. **同名冲突用「列表顺序优先」而非让用户逐条选。** 逐条选要记录「某仓库的某规则被用户显式偏好」，多一层持久化，收益有限。排序 + 展开看来源已经够用。
2. **不做增量刷新。** 改一个开关就全量重拉。仓库数量级是个位数到十几个，全量更可靠；如果将来有人加二十个仓库再看。
3. **已安装规则不记来源。** `plugins.json` 格式不动，避免迁移。代价是：仓库被关闭后，该仓库装来的规则在更新时状态变 `notInCatalog`。这是可接受的——规则文件本身还在本地，能正常用。
4. **`PluginCatalogApi.getPluginList()` / `getPlugin(name)` 的旧签名**：保留为重载或改成取第一个启用仓库。优先选「删掉 `getPluginList()`，保留 `getPlugin(name)` 走默认 loader」，减少无用 API 面。具体在实现时按调用点确认——目前 `plugins_controller.dart:66-67` 是唯一的 tear-off 处。
5. **不支持私网鉴权。** 带 `user:pass@` 的一律拒绝（会以明文进 Hive 设置与 `DioLoggerInterceptor` 日志，且 dio 不会把它转成 `Authorization` 头，既泄漏又没用）。需要鉴权的私有仓库不在本次范围。
6. **不做仓库签名校验。** 靠「仅使用可信仓库」的文案和「第三方用不同颜色标出」来兜。

---

## 11. 实施顺序

1. `settings_keys.dart` 加键
2. `rule_repository.dart` 模型 + `RuleRepositoryList` + 单测（纯函数，独立可验）
3. `rules_repository_config.dart` + 单测
4. `plugin_http_module.dart` 加两个字段
5. `plugin_catalog_api.dart` 加按仓库取数的方法
6. `plugins_controller.dart`：聚合、去重、失败隔离、generation、按仓库分发 loader
7. `plugin_catalog_view.dart`：State 公开 + `reload()` + 来源 tag + 失败提示
8. `rule_repository_page.dart` 管理页 + 添加弹窗
9. `plugin_shop_page.dart` 入口与状态条
10. 空态/错误态文案、镜像开关描述
11. 全量 analyze + 手工回归

第 1-6 步完成后功能已闭环（可以改设置验证），7-10 是界面。

---

## 12. 与 PR #2487 的关系

PR #2487 解决的是「换一个仓库」，本设计是它的超集：单仓库场景退化为「列表里只有官方 + 一条自定义」。

可以直接借用的部分：`RulesRepositoryConfig` 的归一化逻辑（含 `pathSegments` 重建、userInfo 拒绝、github.com 拒绝）、generation 失效思路。

必须不同的部分：PR 把「官方地址归一化为空串」当作区分自定义的开关，多仓库下这个前提不成立；PR 的 `invalidatePluginCatalog` 只清缓存不含 generation，评审已指出竞态。
