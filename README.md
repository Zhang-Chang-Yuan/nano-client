# Nano Client

跨平台代理客户端，对接 **V2Board** 面板，内置 **sing-box** 内核。

界面基于 **Flutter + Riverpod + Material 3**，支持 Linux / Windows / macOS / Android / iOS。

> 本项目的技术方案参考了开源项目 [Hiddify](https://github.com/hiddify/hiddify-app) 的
> 技术选型（Flutter + Riverpod + Material 3），但**未复制其任何代码**，为独立实现。
> Hiddify 采用 GPL-3.0 附加条款，直接复用其代码会带来额外的合规义务，故刻意避开。

---

## 特性

| 能力 | 说明 |
|---|---|
| 账号密码登录 | 对接 V2Board 面板，密码**只在界面输入** |
| 节点获取 | 解析订阅中的分享链接，支持 11 种协议 |
| 三种路由模式 | 自动分流 / 全局代理 / 安全模式（私密 DNS） |
| 加密配置 | 全部配置（含服务器与账号）落盘即密文，AES-256-GCM |
| 主密钥托管 | 系统钥匙串（Keystore / Keychain / DPAPI / libsecret） |
| 一键切换节点 | 通过 Clash API 运行时切换，无需重启内核 |
| 多平台构建 | GitHub Actions 全自动出包 |

---

## 快速开始

```bash
git clone <your-fork-url>
cd nano_client

# 1) 下载 sing-box 内核与分流规则集（内核不进仓库）
dart run tool/fetch_core.dart

# 2) 安装依赖
flutter pub get

# 3) 运行
flutter run -d linux     # 或 windows / macos
```

打包：

```bash
flutter build linux --release
flutter build windows --release
flutter build apk --release --split-per-abi
```

---

## 使用

1. **初始化**：首次启动进入向导，点「自动获取」从配置源拉取面板地址，也可手动填写。
2. **登录**：输入邮箱与密码。勾选「记住密码」后密码会随配置一起**加密**保存，下次免输。
3. **选节点**：在主页节点列表中点选。
4. **连接**：点中央电源按钮，本地会开启 `127.0.0.1:7890` 的 SOCKS5 + HTTP 混合代理。

```bash
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
curl -sS https://api.ipify.org
```

### 三种模式

| 模式 | 路由 | DNS |
|---|---|---|
| **自动**（默认） | 国内域名/IP 直连，其余走代理 | 明文 UDP，直连 |
| **全局** | 除局域网外全部走代理 | 私密 DoT，经代理隧道 |
| **安全** | 自动分流 | 私密 DoT，经代理隧道 |

「安全」对应原 App 的 `safeDns`（*Use private DNS service*）开关：
DNS 查询在代理隧道内完成，本地 ISP 既看不到内容也无从劫持。

> **为什么 bootstrap 解析器固定用国内明文 DNS？**
> 它只负责解析「代理节点自身的域名」，必须直连且稳定；若跟着 DNS 提供商走
> （例如明文 UDP 到 `8.8.8.8`），在国内会被污染，结果是根本连不上节点。
> 它只暴露节点域名，不暴露用户访问的域名。详见 [`docs/CONFIG.md`](docs/CONFIG.md)。

---

## 配置与安全

所有配置统一保存在一个加密文件里，**启动时读取，读不到就初始化**：

```
<应用支持目录>/config/config.enc     # AES-256-GCM 密文信封（JSON）
<系统钥匙串>/nano.master_key.v1      # 256 位主密钥
```

**威胁模型（请如实理解其边界）：**

- ✅ 配置文件被单独拷走时无法解密，因为主密钥在系统钥匙串里。
- ✅ 密文带 GCM 认证标签，任何篡改都会被发现。
- ✅ 主密钥由 `Random.secure()` 生成，每次加密使用独立 nonce。
- ⚠️ 攻击者若已取得当前用户在本机的完整权限（可读钥匙串），仍可解密 ——
  这是所有本地存凭据方案的共同边界。
- ⚠️ Linux 上若没有 `gnome-keyring` / `kwallet`，会降级为 0600 权限的密钥文件，
  安全性弱于系统钥匙串。

细节见 [`docs/CONFIG.md`](docs/CONFIG.md)。

---

## 项目结构

```
lib/
├── main.dart                     启动：加载/初始化配置 -> 注入 Provider
├── app.dart                      MaterialApp 与路由分流
├── core/
│   ├── crypto/crypto_service.dart        AES-256-GCM 信封
│   ├── config/
│   │   ├── app_config.dart               配置模型（纯数据）
│   │   ├── config_repository.dart        读取 / 初始化 / 原子写入
│   │   └── secure_key_store.dart         主密钥托管与降级
│   ├── api/
│   │   ├── panel_api.dart                V2Board 协议客户端
│   │   └── dio_transport.dart            可替换的 HTTP 传输层
│   ├── subscription/proxy_node.dart      分享链接解析
│   └── proxy/
│       ├── singbox_config.dart           sing-box 配置生成
│       ├── proxy_core.dart               内核进程管理 + Clash API
│       └── core_provisioner.dart         内核资源释放
├── features/                     按界面划分：setup / login / home / settings
└── state/app_controller.dart     Riverpod 状态与业务编排
```

---

## 协议实现说明

本客户端对接的面板协议来自对 Android 客户端 `Nano_x86.apk` 的逆向与真实账号实测。
其中三处与「标准 V2Board」不同，**自行实现时请务必注意**：

1. **User-Agent 白名单**：面板要求 UA 包含 `dart`（不区分大小写），
   否则返回 **HTTP 200 但 body 为空** —— 极易被误判成接口故障。
2. **授权头不能加 `Bearer`**：必须把登录返回的 JWT `auth_data` 原样放进
   `Authorization`。加前缀会被判为未登录。
3. **订阅地址不可缓存**：`subscribe_url` 的出口 IP 会轮换，每次都要重新获取。

登录载荷为**明文 JSON**，面板不做加密；订阅正文是 **base64 编码的分享链接列表**。

> ⚠️ 本项目只实现与面板的协议互操作，不包含任何面板服务端代码或密钥。

---

## 平台支持

| 平台 | 状态 |
|---|---|
| Linux / Windows / macOS | ✅ 完整可用：内置 sing-box 子进程 + Clash API |
| Android / iOS | ⚠️ 见 [`docs/PLATFORMS.md`](docs/PLATFORMS.md)：系统级代理需把 sing-box 编译为 `libbox` 并经 `VpnService` 接入 |

---

## 开发

```bash
flutter analyze          # 静态分析（本项目启用了较严格的规则）
flutter test             # 单元测试
dart format lib test tool
```

CI 位于 `.github/workflows/build.yml`，包含一条所有平台共用的质量门禁
（格式检查 + 静态分析 + 单元测试）与五个平台构建任务。

---

## 支持项目

如果这个项目对你有用，欢迎通过以下方式支持：

<p>
  <img src="support/WeiXin.png" alt="微信收款码" width="220">
  &nbsp;&nbsp;
  <img src="support/ZhiFuBao.jpg" alt="支付宝收款码" width="220">
</p>

也可以使用下面的邀请链接注册账号，作者会获得一定的推广额度：

<https://16.76.177.124/auth/register?code=YHW9HKLq>

> 二维码原图位于 [`support/`](support/)。感谢支持。

---

## 许可证

**GPL-3.0-or-later**，见 [`LICENSE`](LICENSE)。

之所以与 sing-box 采用同一许可证：发行产物会捆绑 sing-box 内核
（虽以独立进程运行，但为避免任何许可歧义，整体采用同一许可证）。
若你计划以宽松许可发布**不含内核**的本体，请先阅读 [`LICENSE-NOTE.md`](LICENSE-NOTE.md)。

第三方组件详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
