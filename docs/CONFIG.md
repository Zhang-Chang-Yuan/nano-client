# 配置文件与加密设计

## 文件布局

```
<应用支持目录>/                      # 由 path_provider 决定
├── config/
│   ├── config.enc                  # 全部配置（AES-256-GCM 密文信封）
│   ├── .master_key                 # 仅在系统钥匙串不可用时出现（0600）
│   └── config.enc.corrupt-*.bak    # 读取失败时的备份
└── core/
    ├── sing-box                    # 从 assets 释放出来的内核
    ├── .core-version               # 内核版本标记，用于跳过重复释放
    ├── rule-set/*.srs              # 分流规则集
    ├── cache.db                    # sing-box 自身的缓存
    └── singbox-config.json         # 最近一次生成的配置（明文，供排查）
```

> `singbox-config.json` 是**内核实际读取的配置**，按设计就是明文 ——
> 它只包含节点参数，**不含账号密码**。账号凭据只存在于 `config.enc` 中。
> 如果你不希望它留在磁盘上，可以在断开连接后删除。

## 生命周期

```
启动
 ├─ 读取钥匙串中的主密钥
 │    └─ 不存在 -> Random.secure() 生成 256 位并写入
 ├─ 读取 config.enc
 │    ├─ 不存在            -> 用默认值初始化并落盘
 │    ├─ 解密 + 解析成功    -> 恢复配置
 │    └─ 解密/解析失败      -> 备份为 .corrupt-*.bak，重新初始化
 └─ 进入界面
```

任何一步失败都不会让应用起不来 —— 这是「读不到再初始化」的含义。

## 落盘格式

```json
{
  "v": 1,
  "alg": "AES-256-GCM",
  "nonce": "<base64, 12 字节, 每次加密随机生成>",
  "mac": "<base64, 16 字节认证标签>",
  "data": "<base64 密文>"
}
```

`data` 解密后是配置 JSON：

```json
{
  "schemaVersion": 1,
  "initialized": true,
  "onboardingCompleted": true,
  "panel":   { "apiBase": "...", "chatUrl": "...", "owUrl": "...", "configSource": "..." },
  "account": { "email": "...", "password": "...", "authData": "...", "rememberPassword": true },
  "proxy":   { "routeMode": "auto", "safeDns": false, "dnsProvider": "ali",
               "mixedPort": 7890, "clashPort": 9090, "selectedNodeTag": "..." },
  "startMinimized": false,
  "autoConnect": false
}
```

信封自带版本与算法标识，将来更换算法时可以按 `v` 做迁移，
旧文件仍能被识别并提示升级。

## 密钥管理

| 平台 | 存储位置 |
|---|---|
| Android | Keystore（AES-GCM + RSA-OAEP 包裹） |
| iOS / macOS | Keychain |
| Windows | Credential Manager（DPAPI 保护） |
| Linux | libsecret（gnome-keyring / KWallet） |

实现见 `lib/core/config/secure_key_store.dart`。

### Linux 降级路径

若系统没有可用的 keyring，`CompositeKeyStore` 会降级为
`FileFallbackKeyStore`：把主密钥写在 `config/.master_key`，权限 `0600`。

这一路径**安全性弱于系统钥匙串** —— 同机其它进程若读到该文件即可解密配置。
之所以保留它，是因为在很多精简版 Linux 桌面上没有 keyring，
若直接失败会导致配置永远无法保存。降级是显式且有记录的，
如需强制禁用可以只保留 `PlatformSecureKeyStore`。

## 威胁模型

| 场景 | 是否可防 |
|---|---|
| 只拷走 `config.enc` | ✅ 无法解密（主密钥在钥匙串） |
| 篡改 `config.enc` 内容 | ✅ GCM 认证标签会校验失败 |
| 重放旧版本配置 | ⚠️ 未做防重放，可加时间戳/计数器 |
| 攻击者已取得本用户在本机的完整权限 | ❌ 可读钥匙串，属所有本地方案共同边界 |
| Linux 无 keyring 时的降级路径 | ⚠️ 拿到 `.master_key` 即可解密 |
| 内核配置 `singbox-config.json` | ⚠️ 明文，但不含账号密码 |

## 密码处理

- 密码**只在登录界面输入**，不接受也不读取任何外部传入。
- 仅当用户勾选「记住密码」时才写入配置；取消勾选会立即把它从配置中抹掉。
- 无论是否记住，`config.enc` 整体都是密文。
- 未勾选时，密码仅存在于内存中的 `AppState`，直到下次登录。

## 主密钥与密码的区别

主密钥（钥匙串）保护的是**文件**，用户密码保护的是**面板账号**。
两者相互独立：即使把用户密码改成别的，`config.enc` 依然用同一主密钥加密；
反过来，换了电脑（钥匙串不同）则配置文件无法解密，会走重建流程 ——
这是预期行为，不是缺陷。
