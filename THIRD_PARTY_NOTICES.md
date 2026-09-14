# 第三方组件声明

## 运行时捆绑

### sing-box

- 项目：https://github.com/SagerNet/sing-box
- 许可证：**GPL-3.0-or-later**
- 使用方式：发行产物在构建时由 `dart run tool/fetch_core.dart` 下载官方
  release 的可执行文件，放入 `assets/bin/`，运行时释放到应用支持目录，
  以**独立子进程**方式启动（`sing-box run -c <config>`），
  通过配置文件与 HTTP（Clash API）通信。
- 源码获取：https://github.com/SagerNet/sing-box （对应 tag 见 `assets/bin/VERSION`）

> 本仓库**不包含** sing-box 的二进制或源码，只包含下载脚本。
> 由于发行包会一并分发该 GPL 程序，本项目整体采用 GPL-3.0-or-later，
> 以避免任何许可歧义。

### 分流规则集

`assets/rule-set/*.srs` 随仓库提交（合计约 90KB），来自：

- https://github.com/SagerNet/sing-geosite （GPL-3.0-or-later）
- https://github.com/SagerNet/sing-geoip （GPL-3.0-or-later）

可用 `dart run tool/fetch_core.dart --rules-only` 更新。

## 直接依赖

| 包 | 许可证 | 用途 |
|---|---|---|
| [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) | MIT | 状态管理 |
| [dio](https://pub.dev/packages/dio) | MIT | HTTP 客户端 |
| [cryptography](https://pub.dev/packages/cryptography) | Apache-2.0 | AES-256-GCM |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) | BSD-3-Clause | 系统钥匙串访问 |
| [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause | 平台目录 |
| [package_info_plus](https://pub.dev/packages/package_info_plus) | BSD-3-Clause | 版本信息 |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons) | MIT | 图标 |

开发依赖：

| 包 | 许可证 | 用途 |
|---|---|---|
| [flutter_lints](https://pub.dev/packages/flutter_lints) | BSD-3-Clause | 静态检查规则 |
| [archive](https://pub.dev/packages/archive) | MIT | 内核压缩包解压 |

完整的传递依赖与许可证文本由 `flutter pub deps` 与各包仓库提供。

## 参考项目

- [Hiddify](https://github.com/hiddify/hiddify-app) —— 仅参考其**技术选型**
  （Flutter + Riverpod + Material 3 的工程组织方式）。
  **未复制任何代码**。Hiddify 采用 GPL-3.0 附加条款
  （要求衍生作品作为其 fork、必须通过 GitHub Actions 发布等），
  直接复用会引入额外义务，因此本项目刻意独立实现。
