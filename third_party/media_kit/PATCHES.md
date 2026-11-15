# media_kit — 本地补丁说明

本目录是 `media_kit` commit `cd75bcfe94ba45ebb6f6b940c68e072d079aee14` 的本地副本。

## 本地改动

只改了 `hook/src/bundles.dart` 的 Windows 7z 解包路径：

- Windows 的 native bundle 使用 `.7z` 容器并采用 LZMA2 压缩；
- Windows 自带的 `bsdtar` 并不保证启用 LZMA/7z 解码；
- Windows + `7z` 格式现在明确调用 `7z.exe`；
- `tar.gz` 及非 Windows 平台仍沿用上游 `tar` 路径；
- 解包前仍逐项校验归档路径，避免路径穿越。

## 构建要求

Windows 构建机需要安装 7-Zip，或将 `7z.exe` 放入 `PATH`。hook 会依次检查：

1. `ProgramFiles/7-Zip/7z.exe`
2. `ProgramFiles(x86)/7-Zip/7z.exe`
3. `where.exe 7z.exe`

找不到时会直接报清晰错误，不会退回到不支持 LZMA 的 `tar`。

## 同步方式

上游更新 `media_kit` 时，重新复制对应 commit 的 package，再重新应用本补丁，并更新本文件中的 commit。
