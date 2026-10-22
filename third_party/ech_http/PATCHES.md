# ech_http — 本地补丁说明

这个目录是 **ech_http 0.2.3 的完整副本**，只改了一处：把 CA 证书打包方式改回 0.2.2 的分段拼接实现。
通过 `pubspec.yaml` 的 `dependency_overrides` 覆盖 pub.dev 的版本。

## 为什么需要这个补丁

**上游 0.2.3（2026-10-22 发布）破坏了 Windows / MSVC 构建。**

- `src/CMakeLists.txt:17-18` 用 `file(READ)` 把整个 `cacert.pem`（**200116 字节**）读进变量，再 `configure_file()` 塞进模板
- `src/ca_bundle.h.in:4` 是 `static const std::string roots = R"ECH_CA_BUNDLE(@EH_CA_PEM@)ECH_CA_BUNDLE";`
- 结果：一个 **200 KB 的原始字符串字面量**
- MSVC 单字符串字面量上限 16380 字节 → **`error C2026: string too big`**，编译直接失败

对照 **0.2.2** 的实现（`src/CMakeLists.txt:24-46` 区域），它本来是对的，注释里写得很清楚：

```cmake
# MSVC rejects a single string literal longer than 16380 bytes (C2026), and the
# bundled CA store is far bigger than that, so it is split into chunks that are
# joined at runtime. cacert.pem itself stays untouched.
set(EH_CA_CHUNK_SIZE 4000)
while(EH_CA_OFFSET LESS EH_CA_LEN)
  string(SUBSTRING "${EH_CA_PEM}" ${EH_CA_OFFSET} ${EH_CA_CHUNK_SIZE} EH_CA_CHUNK)
  string(APPEND EH_CA_BODY "    R\"ECH_CA_BUNDLE(${EH_CA_CHUNK})ECH_CA_BUNDLE\",\n")
  ...
```

**0.2.3 把它丢了。** GCC / Clang 对字符串字面量的上限远比 MSVC 宽松，所以 Android / Linux / macOS 都没事，
只有 Windows 挂——这就是为什么 2.5.2 的安卓包正常、桌面端构建失败。

## 改了什么

只有 `src/CMakeLists.txt` 一处：

| 行 | 改动 |
|---|---|
| `:17-23` | 新增 KAZUMI PATCH 注释块，说明原因 |
| `:24-50` | `configure_file()` 换回 0.2.2 的 `string(SUBSTRING)` 分段 + `file(WRITE)`，每 4000 字节一段，运行时 `joined += chunk` 拼回 |

`src/ca_bundle.h.in` **保留未删**（不再被引用，留着方便日后对照上游），`cacert.pem` **一个字没动**。

## 为什么不用降级到 0.2.2

0.2.3 唯一的实质改动是 **CA 根证书快照更新（2026-10-20）**，移除了 eMudhra 被攻破的中间证书，
涉及的根证书：emSign ECC Root CA - G3、emSign ECC Root CA - C3、emSign Root CA - C1。
降级会把这三张本该吊销的根证书放回信任库。保留 0.2.3 的 `cacert.pem`（200116 字节版本）更安全。

## 什么时候可以删掉这个目录

上游修好 C2026 之后。检查方式：

```powershell
# 看上游出新版没
Invoke-RestMethod https://pub.dev/api/packages/ech_http | Select-Object -ExpandProperty latest
```

新版出来后，确认 `src/CMakeLists.txt` 里恢复成 `string(SUBSTRING)` 分段实现（或其它规避手法），
然后：

1. 删掉 `pubspec.yaml` 里的整个 `dependency_overrides:` 段
2. 把 `ech_http: ^0.2.3` 升到新版本号
3. `flutter pub get`
4. 删掉 `third_party/ech_http/` 目录
5. 跑一次 `build_local.ps1 -Windows` 确认

## 同步上游

包里除 `src/CMakeLists.txt` 外全是 0.2.3 原样（53 个文件，514 KB）。
若上游只修这一处，也可以直接拿新版覆盖本目录，然后**只重打 CMakeLists 这一处补丁**。

## 上游 issue

待提：https://github.com/ech-research/ech_http/issues
标题建议：`0.2.3 breaks Windows builds: C2026 string too big (ca_bundle.h.in emits 200 KB literal)`
