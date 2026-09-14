# 排障指南

这里记录的都是**实际踩到过**的问题，以及当时的定位过程。
每一条都写明「现象 → 原因 → 怎么办」，避免下次再从头查。

---

## 1. 点连接后提示「内核启动超时，Clash API 未就绪」

**原因**：最常见的是**端口被占用**。内核默认用 `127.0.0.1:7890`（混合代理）
和 `127.0.0.1:9090`（Clash API），而其它代理客户端（Clash、v2rayN、另一个
sing-box）也默认用这两个端口。

**怎么办**：新版会在启动前预检端口，直接提示「混合代理端口 7890 已被占用，
请在设置 → 代理里换一个端口后重试」。按提示换端口即可。

也可以自己查：

```bash
ss -ltnp | grep -E '7890|9090'
```

---

## 2. 代理起来了，但打不开谷歌等境外站点

### 2a. 先确认流量到底有没有进代理

**桌面端「连接」只是在本地开了一个代理端口，不会自动接管所有程序。**
用这个命令直接验证代理本身通不通：

```bash
curl -x http://127.0.0.1:7890 https://www.cloudflare.com/cdn-cgi/trace
```

看 `loc=` 是不是境外。如果是，说明代理没问题，问题在「某个程序没走代理」。

### 2b. 浏览器打不开海外站点 → 先重启浏览器

**浏览器只在启动时读取一次系统代理设置**，之后再改不会跟随。
表现为：应用显示「已接管系统代理」，但浏览器依然直连。

判断方法 —— 看浏览器有没有连到代理端口：

```bash
python3 - <<'PY'
import os, re
inodes=set()
for pid in os.listdir('/proc'):
    if not pid.isdigit(): continue
    try: comm=open(f'/proc/{pid}/comm').read().strip()
    except Exception: continue
    if 'firefox' not in comm: continue   # 换成你的浏览器进程名
    try:
        for fd in os.listdir(f'/proc/{pid}/fd'):
            try:
                t=os.readlink(f'/proc/{pid}/fd/{fd}')
                m=re.match(r'socket:\[(\d+)\]', t)
                if m: inodes.add(m.group(1))
            except Exception: pass
    except Exception: pass
n=0
for f in ('/proc/net/tcp','/proc/net/tcp6'):
    try: lines=open(f).read().splitlines()[1:]
    except Exception: continue
    for l in lines:
        p=l.split()
        if p[9] in inodes and int(p[2].split(':')[1],16)==7890: n+=1
print(f'浏览器到 7890 的连接数: {n}（0 表示没走代理）')
PY
```

连接数为 0 就重启浏览器（菜单 → **退出**，不是关窗口）。

### 2c. Flatpak 版浏览器**看不到系统代理**

这是本机实测踩到的坑，比较隐蔽：

- Firefox / Chromium 的 Flatpak 版本运行在沙箱里，
  **默认没有读取 GNOME/dconf 系统代理的权限**；
- 于是它那句「跟随系统代理」在沙箱内读到的是默认值（等于无代理），**永远直连**；
- 重启浏览器也没用，因为问题不在缓存。

验证：在沙箱里读系统代理，会得到默认值而不是你在 GNOME 里设的值。

```bash
flatpak run --command=sh org.mozilla.firefox -c \
  'gsettings get org.gnome.system.proxy mode'
# 沙箱内输出 'none'，而宿主是 'manual' → 就是这个问题
```

**办法**：给浏览器写它自己的代理配置，不要依赖系统代理。

Firefox（Flatpak）的 profile 在
`~/.var/app/org.mozilla.firefox/config/mozilla/firefox/<profile>/user.js`：

```js
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", 7890);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", 7890);
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1");
```

改完需重启浏览器。应用关闭后若要恢复正常上网，删掉 `user.js` 再重启即可。

> 想彻底不折腾每个程序的代理设置，用 **TUN 模式**（见第 4 节）。

---

## 3. 境外域名被 DNS 投毒（已在 v1 修复，记录原理）

**现象**：代理链路正常（Cloudflare 能通），但谷歌死活不通。

**原因**：早期版本在自动分流模式下，**所有域名都走本地明文 DNS**。
明文查询境外域名会被投毒：

```
阿里 DNS(223.5.5.5) 解析 www.google.com → 104.244.42.197   ← 一个 Twitter 的 IP
本机默认解析                            → 2001::1           ← 典型污染结果
经代理用 Google DoH                     → 142.251.150.119   ← 真实 IP
```

内核拿着假 IP 去连，TLS 必然失败。

**现在的做法**：DNS 按域名分流

| 域名 | 解析方式 |
|---|---|
| 国内（`geosite-cn`） | 本地明文 DNS，直连（快） |
| 其余 | **加密 DoT，经代理隧道**（ISP 看不到，无从投毒） |
| 拿不到规则集时 | 全部走加密解析，**绝不回落成明文** |

---

## 4. `ping` 不通

**这是正常的，不是故障。** `ping` 走 ICMP，而 HTTP/SOCKS 代理
**只转发 TCP/UDP，不转发 ICMP**。

想让 ping 也通，必须用 **TUN 模式**（网络层接管全部流量）：
设置 → 代理 → 打开「TUN 模式」。它需要管理员权限。

TUN 模式的好处是不用再关心任何程序是否「支持代理」——
Flatpak 沙箱、游戏、ping 全都自动生效。

---

## 5. 点「测速」会直接连上吗？

**不会**（早期版本会，已修）。

- **未连接**时点测速：用 TCP 握手耗时测延迟，**不启动内核、不碰系统代理**
- **已连接**时点测速：走 Clash API，由内核经该节点实测，更贴近真实体验

未连接时的 TCP 延迟测的是「到节点入口的往返时延」，
节点挂在 CDN 后面时测到的是 CDN 边缘，用来挑快慢足够，但不等于整条链路的表现。

---

## 6. 看内核日志

内核的 stdout/stderr 会被完整捕获到界面上的「内核日志」里（带颜色转义已剥离），
启动失败时也会自动把 `FATAL`/`ERROR` 那行带进错误提示。

配置与内核落在应用支持目录：

```
~/.local/share/com.nanocloud.nano_client/
├── config/config.enc                 # 加密配置
└── core/
    ├── sing-box                      # 释放出来的内核
    ├── singbox-config.json           # 本次生成的实际配置（明文，供排查）
    └── rule-set/*.srs
```

`singbox-config.json` 是内核真正读取的内容，排查分流问题时直接看它最快。
