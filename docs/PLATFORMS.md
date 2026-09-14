# 各平台支持情况

本应用是 Flutter 单代码库，五个平台共用同一套业务逻辑。
但「把流量导入代理」这一步在不同平台上需要不同的内核接入方式，
因此各平台的完成度不同。**下表如实反映当前状态。**

| 平台 | 界面 | 登录/节点/配置 | 系统级代理 | 说明 |
|---|---|---|---|---|
| Linux | ✅ | ✅ | ✅ 子进程 | |
| Windows | ✅ | ✅ | ✅ 子进程 | |
| macOS | ✅ | ✅ | ✅ 子进程 | |
| Android | ✅ | ✅ | ⚠️ 待接入 | 需 `VpnService` + `libbox` |
| iOS | ✅ | ✅ | ⚠️ 待接入 | 需 `NetworkExtension` + `libbox` |

---

## 桌面端（Linux / Windows / macOS）

内核以**独立子进程**方式运行：

```
Flutter 进程  ──写入配置──>  singbox-config.json
      │                            │
      └── 启动 ──> sing-box run -c ... ──> 127.0.0.1:7890 (mixed)
      │
      └── Clash API (127.0.0.1:9090)  <── 切换节点 / 查询状态
```

实现见 `lib/core/proxy/proxy_core.dart` 的 `ProcessProxyCore`。

内核可执行文件在构建前由 `dart run tool/fetch_core.dart` 下载到
`assets/bin/`，首次运行时由 `CoreProvisioner` 释放到应用支持目录并赋予可执行权限，
之后按版本号缓存，不重复释放。

---

## 移动端（Android / iOS）

移动端无法像桌面那样「起一个本地混合代理就算接管全局」——
操作系统要求应用通过 VPN API 接管流量：

- **Android**：`VpnService` + 把 TUN 文件描述符交给内核
- **iOS**：`NetworkExtension`（`NEPacketTunnelProvider`）

这两条路都要求 sing-box 以 **库**（`libbox`，gomobile 产物）的形式链接进应用，
而不是作为外部可执行文件。原因是：

1. Android 10+ 的 W^X 限制使得从应用数据目录执行二进制不可靠；
2. TUN 文件描述符必须由系统交给 VPN 服务，再传给内核；
3. iOS 根本不允许启动外部进程。

### 需要做的工作

1. 用 gomobile 从 sing-box 源码构建 `libbox.aar`：

   ```bash
   git clone --depth 1 --branch v1.14.0 https://github.com/SagerNet/sing-box
   cd sing-box
   go install golang.org/x/mobile/cmd/gomobile@latest
   gomobile init
   gomobile bind -target=android/arm64,android/arm,android/amd64 \
     -androidapi 21 -o libbox.aar ./experimental/libbox
   ```

2. 把 `libbox.aar` 放进 `android/app/libs/`，在 `build.gradle.kts` 中引入。

3. 在 `android/app/src/main/kotlin/` 下实现 `VpnService`，
   通过 MethodChannel 接收 Dart 侧下发的配置 JSON。

4. 用一个 `LibboxProxyCore implements ProxyCore` 替换桌面端的 `ProcessProxyCore`，
   上层 UI 无需改动 —— `ProxyCore` 接口就是为此抽象的。

> 之所以把内核访问收敛到 `ProxyCore` 一个接口，
> 就是为了让移动端接入不影响已有的业务逻辑与测试。

### 当前移动端能做到什么

即使尚未接入 VPN，Android / iOS 产物仍然可以：
完成初始化、登录、拉取并解析节点、选择节点、生成 sing-box 配置。
点击「连接」时会明确提示内核不可用，而不是静默失败。
