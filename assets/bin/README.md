# 内核目录

本目录用于存放 sing-box 内核可执行文件：

| 平台 | 文件名 |
|---|---|
| Linux / macOS | `sing-box` |
| Windows | `sing-box.exe` |

**二进制不提交到仓库**（见根目录 `.gitignore`）。构建前请执行：

```bash
dart run tool/fetch_core.dart
```

CI 会在各平台构建前自动下载对应版本，并把版本号写入 `assets/bin/VERSION`。

缺少内核时，应用仍可完成配置、登录与节点拉取，只在点击连接时给出明确提示。
