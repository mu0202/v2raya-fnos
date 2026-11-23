# 决策记录（DECISIONS）

记录所有「有多种做法、最后只能选一个」的地方，以及**支持该决定的实测证据**。
目的是让后来的人不用重新踩一遍。

---

## D-01 用统一网关（Unix Socket）而不是 TCP 端口服务

**决定**：`app/ui/config` 用 `gatewayPrefix: /app/v2raya` + `gatewaySocket: app.sock`，
v2rayA 以 `--socket` 启动，只监听 Unix socket。

**为什么不暴露 TCP 端口**：
- 端口服务（`type: url` + `port`）会让 v2rayA 直接暴露在局域网上，绕过飞牛登录态，
  任何人扫到端口就能打开管理界面。代理工具的管理界面等于「出口凭据」，不能这么放。
- 网关模式由 fnOS 校验 NAS 会话后才转发，并且能注入可信身份头。

**实测证据**：`--socket` 单独使用时 socket 正常创建，TCP 端口不监听；网关模拟转发链路返回 200。

**代价**：入口只能经由飞牛桌面/系统域名访问，不能给外部的标准 v2rayA 客户端直连。

---

## D-02 `--baseurl /app/v2raya`（v2rayA 自己带前缀路由）

**决定**：显式传 `--baseurl /app/v2raya`。

**原因**：飞牛网关**保留完整路径**转发给应用（不含前缀剥离）。参考实现里有一句原文注释：

> `upstream sees /app/... and answers 404`

也就是说，如果 v2rayA 以 `/` 为 base 启动，网关转过来的 `/app/v2raya/api/version`
在 v2rayA 里就是 404。让 v2rayA 自己认这个前缀，是最少改动、不引入中间代理层的做法
（对比 EasyTier-Web 的做法：额外跑一个 `gateway-proxy` 二进制做前缀剥离——
我们不需要，因为 v2rayA 原生支持 baseurl）。

**实测证据**（同一 socket 上）：

| 请求 | 结果 |
| --- | --- |
| `GET /app/v2raya/` | 200（HTML） |
| `GET /app/v2raya/api/version` | 200 JSON |
| `GET /app/v2raya/static/v2raya-icon.svg` | 200 |
| `GET /app/v2raya`（无尾斜杠） | 301 |
| `GET /` | 404 |

最后一行很重要：它证明前缀确实是 v2rayA 自己在处理，而不是被剥掉了。

---

## D-03 桌面入口 URL 带尾斜杠：`/app/v2raya/`

**决定**：`"url": "/app/v2raya/"`，结尾必须有 `/`。

**原因**：实测无尾斜杠时 v2rayA 返回 301。虽然浏览器会跟随跳转，但在 iframe 里多一次
重定向会让首屏变慢，个别情况下还会因为相对路径基准变化导致静态资源请求错位。直接给带斜杠的
URL，命中 200。

---

## D-04（已废弃，见 D-16）不传 `--passcheckroot`，接受 lite 模式

**决定**：不传该参数。v2rayA 以 package 用户运行时自动进入 lite 模式。

**这是本次适配最重要的一个取舍，理由如下（A/B 实测）：**

| | 不带 `--passcheckroot` | 带 `--passcheckroot` |
| --- | --- | --- |
| `/api/version` → `lite` | `1` | `0` |
| `/api/version` → `isRoot` | `false` | `false` |
| 日志 | 明确提示 "lite mode, without transparent proxy" | 无提示 |
| 是否真的能透明代理 | 否 | **仍然否** |

关键点：`--passcheckroot` 只是**跳过权限检查**，它并不会真的给进程 root 权限。
结果是 v2rayA 报告自己是完整模式（`lite:0`），但 `isRoot` 依然是 `false`——
它会去尝试做 nftables/iptables/tproxy 这些它实际做不到的事，然后失败，
而且**界面上不会再有任何「你不具备此能力」的提示**。

这是一种典型的静默失败：用户开透明代理 → 看起来开启成功 → 实际没有任何流量被代理 →
排查方向完全错误。

因此选择诚实的 lite 模式：能力边界写在界面上，而不是藏起来。

**契约 §6.1 的原文**：「若加参数导致启动异常，则去掉它并接受 lite 模式」。
本次的理由比「启动异常」更强：它能启动，但**谎报能力**。

**lite 模式仍然完整可用的功能**（实测）：创建账户、登录、JWT 下发、
`/api/version`、`/api/touch`、`/api/outbound(s)`、`/api/outboundSelection`、
`/api/setting`、`/api/ports`、`/api/customInbound`、`/api/subscription`、`/api/import` 等
全部正常返回 `SUCCESS`。可用的是完整的 Web 管理 + SOCKS5/HTTP 入站代理。

---

## D-05 明确不采用 root 运行模式

**决定**：`config/privilege` 固定 `run-as: package`，不提供 root 选项、不提供设置项。

**原因**：官方文档明确「普通应用运行时不建议使用 Root 模式」，且长期对外提供访问的进程
不应 root。为一个代理工具开 root，等于把「任意网页漏洞 → 设备 root」这条链路送出去。
透明代理的缺失不构成升级权限的理由。

---

## D-06 预置 geoip/geosite，禁止首次启动联网下载

**决定**：把 `geoip.dat`（23MB）、`geosite.dat`（2.4MB）打进包内，启动时传
`--v2ray-assetsdir $TRIM_APPDEST/assets`。

**原因**：实测首次启动若不提供资源目录，v2rayA 会去 `github.com` 下载
`geoip.dat`/`geosite.dat`，在**没有外网或 GitHub 不通的环境下会长时间卡住**，
表现为「应用启动了但界面一直转圈」。国内 NAS 场景下这是高频问题。

**代价**：包体积增加约 26MB。可接受——换来的是首启确定性。

---

## D-07 `--v2ray-bin` 显式指定内核路径

**决定**：显式传 `--v2ray-bin $TRIM_APPDEST/server/v2raya_core`。

**原因**：不指定时 v2rayA 会在 `PATH` 里找 `v2ray`/`xray`。飞牛系统上大概率不存在，
或者更糟——存在一个**版本不匹配**的系统 v2ray，导致 `coreVersionValid:false` 和难以定位的
启动失败。显式指定路径把这件事钉死。

**实测**：显式指定后 `/api/version` 返回 `coreVersion: 2.5.16`、`coreVersionValid: true`。

---

## D-08 二进制 vendored 进包，不依赖系统运行时

**决定**：`v2raya` 与 `v2raya_core` 直接放在 `app/server/`。

**原因**：两者均为静态链接（`file` 实测：`ELF 64-bit LSB executable ... statically linked`），
无动态库依赖，且 `platform = x86` 与目标架构一致。不依赖 `install_dep_apps`，
避免引入运行时版本漂移。

---

## D-09 `checkport = false`，不声明 `service_port`

**决定**：manifest 中 `checkport = false`，且**不写** `service_port`。

**原因**：本应用不监听固定 TCP 端口（只监听 Unix socket）。若声明 `service_port`，
飞牛会在启动前检查该端口占用，并且启动失败时给出误导性报错。既然没有端口，就不声明。

---

## D-10 共享目录只暴露一个 `v2raya`

**决定**：`config/resource` 只声明 `{"name": "v2raya"}`，不暴露内部数据目录。

**原因**：用户需要的是「能导出/备份自己的配置」，而不是能直接翻数据库文件
（`v2raya.db` 里有订阅链接、节点密码）。内部数据留在 `$TRIM_PKGVAR`。

---

## D-11 `allUsers: false` + `accessPerm: readonly`

**决定**：入口只对管理员可见，且设置不可被普通用户改。

**原因**：管理代理出口的人 = 能决定整台设备流量走向的人。这是管理员级能力，
不应下放给普通 NAS 用户。`readonly` 防止用户把入口改成对所有人开放。

---

## D-12 版本号用 `2.5.16-1`（不是四段的 `2.5.16.1`）

**决定**：manifest `version = 2.5.16-1`。

**原因**：前两位/三位对齐上游 v2rayA 版本，便于一眼看出基于哪个上游；`-1` 是本项目自己的
打包修订号。上游升级到 2.5.17 时，本项目版本变为 `2.5.17-1`，仍保持语义清晰。

**为什么不是 `2.5.16.1`（契约 §3 最初的写法）**：**fnpack 1.2.4 不接受四段版本号**。
实测直接报错：

```
Packing failed. Invalid version "2.5.16.1".
Expected format: x.y.z[-r] , where x , y , z , and r are integers.
```

所以用 fnpack 的 `-r` 语法表达同一个意图（上游版本 + 整数修订号）。
本机所有已安装飞牛应用也都用 `x.y.z` 或 `x.y.z-<tag>` 形式，与平台惯例一致。

**对契约的修订**：§3 原写 `2.5.16.<fpk-rev>`，现按本决策改为 `2.5.16-<fpk-rev>`。
`build.sh` 仍兼容四段写法的自动转换（便于日后有人误写时不至于构建失败），
但**源 manifest 使用可直接打包的写法**，避免「源文件里一个版本、产物里另一个版本」的认知负担。

---

## D-13 必须同时预置 `LoyalsoldierSite.dat`（GFWList 模式所需）

**决定**：`app/assets/` 里除 `geoip.dat`、`geosite.dat` 外，**还必须**带
`LoyalsoldierSite.dat`。

**问题现场**：首版只带了前两个。真机安装后，用户在设置页选择 GFWList 模式并保存，弹出：

> 无法保存设置：目录 /vol1/@appcenter/v2raya/assets 中缺少 GFWList。

**根因**（复现原样错误后定位）：

```
{"code":"FAIL","errorCode":"GFWLIST_MISSING",
 "message":"GFWList mode needs LoyalsoldierSite.dat, which is missing from <assets>; update GFWList first",
 "params":{"dir":"<assets>"}}
```

v2rayA 的 GFWList 模式**不是**从 `geosite.dat` 里读 `gfw` 标签，而是要一个独立文件
`LoyalsoldierSite.dat`。只带 `geosite.dat` 时，UI 里其它模式都正常，唯独 GFWList 模式存不下去
——这正是它容易被漏掉的原因：它不是启动错误，只有用户切到那个模式才炸。

**文件来源**：v2rayA 官方规则仓 `v2rayA/dist-v2ray-rules-dat` 的 `geosite.dat`
（该仓的产物本身就是 Loyalsoldier 格式的 site 数据）。取的是 tag `202611032326`，
11,375,004 字节。v2rayA 自带更新器下载的也是这个文件，只是改名为 `LoyalsoldierSite.dat`。

**为什么不能靠"运行时更新"解决**：`PUT /api/gfwList` 会去
`raw.githubusercontent.com` 拉取，实测在本机网络下直接失败：

```
ASSET_UNREACHABLE: Get "https://raw.githubusercontent.com/.../geosite.dat":
read: connection reset by peer
```

也就是说，依赖运行时下载就等于把「GFWList 模式能不能用」交给用户的网络环境。
预置进包内才是确定的。

**修复后的验证**：从真实 `.fpk` 解包、按 fnOS 布局安装后调用
`PUT /api/setting {"transparent":"gfwlist"}` → `SUCCESS`，
`localGFWListVersion` 从空串变为 `2026-11-23`；`close/whitelist/gfwlist/pac`
四种模式全部 `SUCCESS`。

**代价**：包体积 29MiB → 33MiB。可接受。

**教训（已写入校验）**：资产完整性检查不能只查"文件够大"，还要覆盖**功能路径会用到哪些文件**。
`cmd/main`、`install_callback`、`upgrade_callback`、`build.sh`、`tests/lint.sh`、
`tests/fpk-structure.sh` 现已全部把第三个文件列为必需项。

---

## D-14 「保留数据」重装后必须修复悬空的 assets 软链接

**决定**：`$TRIM_PKGVAR/assets` 的创建一律用 `ln -sfn`，不再用 `[ ! -e ] && ln -s`。

**问题现场**：真机上卸载旧版本时选择了**保留数据**，随后安装新版。数据目录
`/vol1/@appdata/v2raya` 留下了 `assets` 软链接，它指向
`/vol1/@appcenter/v2raya/assets` —— 而这个目录已随卸载被删除，于是成为**悬空链接**。

**为什么原写法必然失败**（实测复现）：

```bash
# 原逻辑
if [ ! -e "${PKGVAR}/assets" ]; then ln -s "${ASSETS}" "${PKGVAR}/assets" || true; fi
```

`-e` 会**跟随**符号链接判断目标是否存在，目标已被删除 → `-e` 返回假 → 进入分支 →
但链接名仍然被占用，`ln -s` 报 `File exists` 失败 → 又被 `|| true` 吞掉 →
**悬空链接原样留下**。结果就是 `assets` 下的 `LoyalsoldierSite.dat` 不可达，
GFWList 模式再次触发 D-13 那个报错。

对照实测：

| 写法 | 悬空链接下的结果 |
| --- | --- |
| `[ ! -e ] && ln -s` | `ln: File exists`，静默失败，**仍悬空** |
| `ln -sfn` | 成功替换，**恢复可解析** |

`-f` 就地替换已存在的名字；`-n` 防止 `ln` 把软链接当成目录去解引用。

**改动范围**：`cmd/main`、`cmd/install_callback`、`cmd/upgrade_callback` 三处全部改为 `ln -sfn`。

**回归测试**：新增 `tests/reinstall-keepdata.sh` 并接入 `tests/run-all.sh`，完整走
「安装 → 保留数据卸载（断言确实产生悬空链接）→ 重装 → 启动 → 保存 GFWList 模式」
这条链路，16 项断言。它锁死了「卸载时保留数据」这个 fnOS 上非常常见的用户路径。

**教训**：`|| true` 与 `[ ! -e ]` 组合在一起，会同时掩盖"真正的失败"和"本该执行的分支"。
凡是创建链接/目录这类幂等操作，优先用工具自带的幂等标志（`-f`/`-p`），
而不是自己用存在性判断包一层。

---

## D-15 核心启动失败的两个独立原因（用户可见：「v2raya_core exited right after starting」）

真机点「启动核心」报：`无法启动核心：无法启动 v2raya_core: v2raya_core exited right after starting`。
**两个互不相干的原因同时存在**，只修一个仍然会失败。这是本项目最值得记的一次教训：
前六个测试套件全部通过，却完全没覆盖到"核心进程能否真的跑起来"。

### 原因一：包内 `geosite.dat` 缺少 `gfw` 分类

最初用的是 v2fly `domain-list-community` 的 `dlc.dat`（2.4MB）。它能启动、能解析
`geosite:cn`/`geosite:google`，但**没有 `gfw` 分类**。而 v2rayA 的 GFWList 模式会生成
`geosite:gfw` 路由规则 → 核心构建路由配置时直接失败：

```
illegal domain rule: geosite:gfw > common/geodata: failed to check code GFW from geosite.dat > EOF
```

注意它报的是 `EOF` 而不是 "not found"，极易误导成"文件损坏"。

**对照实测**（同一核心二进制，只换 geosite.dat）：

| 分类 | 旧 2.4MB (v2fly dlc.dat) | 新 11.0MB (Loyalsoldier) |
| --- | --- | --- |
| `geosite:gfw` | `illegal domain rule` ❌ | `Xray started` ✅ |
| `geosite:cn` | `Xray started` ✅ | `Xray started` ✅ |
| `geosite:google` | `Xray started` ✅ | `Xray started` ✅ |

只测 `cn`/`google` 会完全看不出问题——这就是它逃过前几轮验证的原因。

**修复**：`app/assets/geosite.dat` 换成 Loyalsoldier/v2ray-rules-dat 的 `geosite.dat`
（11,482,331 字节，含 `gfw` 分类，也是 v2rayA 官方更新器实际下载的同一来源）。

### 原因二：`--v2ray-assetsdir` 不会传给核心进程

`--v2ray-assetsdir` 只告诉 **v2rayA 自己**去哪里管理/下载地理数据，**不会**传播给
`v2raya_core` 子进程。核心默认在自己的工作目录找 `geosite.dat`/`geoip.dat`：

```
stat <v2rayA 工作目录>/geosite.dat: no such file or directory
```

我们的 `cmd/main` 把工作目录设在 `$TRIM_PKGVAR`，而资产在 `$TRIM_APPDEST/assets`，
两者不同 → 核心永远找不到地理数据。

**修复**：启动前导出两个环境变量（核心认这两个名字）：

```bash
export XRAY_LOCATION_ASSET="${ASSETS}"
export V2RAY_LOCATION_ASSET="${ASSETS}"
```

实测：只设 `V2RAY_LOCATION_ASSET` 无效（核心是 xray 分支，只认 `XRAY_LOCATION_ASSET`）；
两个都设最稳妥。

### 最终验证（从真实 `.fpk` 解包，用包内核心与资产）

```
core: Xray 26.10.31 started
LISTEN *:20170   (socks)
LISTEN *:20171   (http)
process alive: YES
```

**新增回归测试** `tests/core-start.sh`（12 项断言），覆盖：
资产齐全 → 核心接受 `geosite:gfw`/`geosite:cn` 规则 → 核心启动并真的绑定 20170/20171 →
SIGTERM 干净退出 → `cmd/main` 仍导出两个 LOCATION_ASSET 变量。
用旧资产跑该测试会失败（已反向验证：报 `illegal domain rule ... EOF`），
所以它能真正拦住回归。

### 教训（已写进测试设计）

**"UI 能打开、设置能保存" 不等于 "代理能用"。** 前六个套件全在验证 HTTP 面，
没有一条断言触碰过 `v2raya_core` 进程。核心是独立二进制、独立失败模式，
必须单独测：启动、绑定端口、干净退出。凡是"主程序 + 子进程"的架构，
测试必须深入到子进程。

---

## D-16 改为 root 运行，启用 TUN / 透明代理（推翻 D-05 与 D-04 的取向）

**决定**：`config/privilege` 从 `run-as: package` 改为 **`run-as: root`**。

**触发原因**：用户明确要求使用 **TUN 模式**，而此前交付一直跑在 lite 模式下，
点「启动核心」持续报：

> 无法启动核心：无法启动 v2raya_core: v2raya_core exited right after starting

**根因（本机实测，与非 root 完全相关）**：

```bash
# 普通用户 + TUN 入站
$ v2raya_core run -c tun.json
Failed to start: app/proxyman/inbound: failed to start proxy > operation not permitted

# 提升到 root 等价权限（user+net namespace）+ 同一配置
$ unshare -r -n v2raya_core run -c tun.json
[Warning] core: Xray 26.10.31 started
```

TUN 需要 `CAP_NET_ADMIN` 并写 `/dev/net/tun`。注意 `/dev/net/tun` 本身是
`crw-rw-rw-`（所有用户可打开），所以**「能 open」不代表「能建 tun 接口」**——
权限卡在 netlink 层，错误就是 `operation not permitted`。

**对 D-05 / D-04 的修正**：
- D-05 当时判断「为一个 Web 应用开 root 风险过大」，前提是**只用代理端口**。
  该判断在「需要 TUN」的需求下不再成立：TUN 在架构上就必须 root，
  没有「更窄的方案」可退。
- D-04 判断「`--passcheckroot` 会谎报能力」依然正确，**继续不传它**。
  现在是真的 root（`isRoot:true`），v2rayA 会自然进入完整模式，不需要也不应该
  再用 `--passcheckroot` 去骗过检查。

**安全代价（如实记录，未消解）**：root 运行的 v2rayA 拥有系统级权限，
Web 界面若被攻破，影响面是整台设备。缓解措施：管理界面仅在飞牛登录态后可达
（统一网关，不暴露 TCP 端口）、`allUsers: false` 仅管理员可见。
但这是**风险降低，不是消除**。README 中已明确提示用户在内网使用并设强密码。

**验证**：`tests/core-start.sh` 新增第 5 节，三点断言：
`config/privilege` 为 root、提权后 TUN 能 `started`、非特权下 TUN 报 EPERM。
这样「为什么必须 root」这件事本身被测试固定住，不会再被悄悄改回 package
而导致 TUN 静默失效。

---

## D-17 `LoyalsoldierSite.dat` 必须是 geosite 格式（真机日志定位到的真凶）

**这是「无法启动核心：v2raya_core exited right after starting」的最终根因。**
前两次修复（D-15 的两个原因）都是真实问题，但不是这个报错的直接原因。

**真机日志原文**（`/vol1/@appdata/v2raya/logs/v2raya.log`）：

```
Failed to start: main: failed to load config files:
  [/vol1/@appdata/v2raya/data/config.json]
  > infra/conf: failed to build routing configuration
  > infra/conf: invalid field rule
  > common/geodata: illegal domain rule: ext:LoyalsoldierSite.dat:gfw
  > common/geodata: failed to check code GFW from LoyalsoldierSite.dat
  > common/geodata: invalid body length: 2186385218
v2ray-core: exit status 23
```

**关键点**：v2rayA 生成的路由规则不是 `geosite:gfw`，而是
**`ext:LoyalsoldierSite.dat:gfw`** —— 它把 `LoyalsoldierSite.dat` 当作一个
**geosite 格式**的文件来解析。D-13 中我把 v2rayA 官方 `dist-v2ray-rules-dat`
仓库里的 `geosite.dat`（11,375,004 字节）直接复制成 `LoyalsoldierSite.dat`，
而那个文件虽然也叫 geosite.dat，**二进制布局与 xray 的 geosite 格式不同**：

| 文件 | 首字节 | 核心能否用 `ext:` 解析 |
| --- | --- | --- |
| xray geosite 格式（Loyalsoldier `geosite.dat` release） | `0a 5f 0a 07 42 4f 59 4c 4f 56 45` (tag 长度 ≤ 127，单字节) | ✅ started |
| 另一种编码（dist-v2ray-rules-dat 版） | `0a c2 8f 08 0a 08 41 49 52 43 48 49 4e 41` (varint 长度错位) | ❌ `invalid body length: 2186385218` |

`2186385218` 就是错位读出来的伪长度——**报错数字本身就是格式不匹配的指纹**。

**修复**：`LoyalsoldierSite.dat` 直接使用与 `geosite.dat` 相同的 geosite 格式文件
（两者内容相同，11,482,331 字节）。同一份文件可以同时满足
`geosite:xxx` 与 `ext:LoyalsoldierSite.dat:xxx` 两种语法——已实测确认：

```
rules: [ ext:LoyalsoldierSite.dat:gfw, geosite:cn, geosite:gfw ]
-> core: Xray 26.10.31 started
```

**为什么之前没测出来**：我只测了 `geosite:gfw` 语法（D-15 的做法），
那条路径确实能用旧文件通过。而 v2rayA 在 **GFWList 模式**下生成的是 `ext:` 语法，
两者是**不同的代码路径**。测试必须同时覆盖两种语法。

**回归测试**：`tests/core-start.sh` 第 2 节现在有两个独立探针——
`geosite:gfw` 与 `ext:LoyalsoldierSite.dat:gfw`。用错误格式的文件跑会失败
（已反向验证：报 `invalid body length`）。

**教训**：同名文件 ≠ 同格式。D-13 里我看到文件名对得上就当成同一个东西用了，
没有验证「核心实际用哪种语法读它」。**日志里的错误码是唯一可信的判据**，
这次正是靠真机日志里的 `ext:` 语法和 `invalid body length` 才定位到。

---

## D-18 不做运行时的数据库迁移：把 `transparentType` 交还给用户

**决定**：`cmd/main` **不**在启动时改写 `v2raya.db`。旧版遗留的
`transparentType="system_proxy"` 由用户在下一次打开 UI 时自行选成
`tun` / `tproxy` / `redirect` 并保存。

**背景**：从 lite 版升级到 root 版的用户，库里会留着 lite 时代的
`system_proxy`。root 模式下 v2rayA 明确拒绝该值：

```
writeTransparentProxyRules: could not set up transparent proxy in system proxy
mode: system proxy is only supported in lite mode on Linux
```

而我方一旦在启动时自动改写，就等于**替用户决定代理模式**。

**为什么不该自动迁移**（这是放弃该方案的真正理由）：

1. **`transparentType` 是用户意图，不是实现细节。** 它决定流量怎么进代理：
   `tun`（虚拟网卡，全局接管）、`tproxy`（TPROXY 透明代理）、
   `redirect`（REDIRECT，仅 TCP）、`system_proxy`（设环境变量，只影响配合的程序）。
   往 `tproxy` 猜一个，可能不是用户想要的——尤其本项目正是因为用户要 **TUN** 才改的 root。
2. **迁移代码只在升级路径上跑，是最难测、最少被执行的分支。**
   它需要读 sqlite，等于给运行时引入 python3 依赖（或额外二进制），
   却只为处理一次性的历史脏数据。
3. **上游自己就能处理。** 用户打开设置页，模式选项会按当前运行模式重新列出，
   选一次即修复。这是 v2rayA 的正常流程，不需要我们插手。

**代价**：升级用户首次启动仍需在 UI 里点一次模式并保存。已写在 README 升级说明中。

**同时移除**：`cmd/main` 中的 `migrate_lite_settings` 函数及其调用点，
`cmd/` 目录因此**完全没有 python 依赖**（`grep -r python cmd/` 为空）。

**回归测试**：`tests/core-start.sh` 第 6 节改为**反向断言**——
`cmd/main` 不得包含 `migrate_lite_settings`、不得出现 `python`。
这样以后有人"顺手加回一个自动迁移"会立刻被测试拦下。

---

## D-19 禁用 nftables（`--nftables-support off`）：fnOS 的 nft 不认命名优先级

**症状**：用户选 `redirect` 或 `tproxy` 时报

```
could not redirect DNS to the DNS module: ExecCommandWithInput: nft -f -:
/dev/stdin:3:30-48: Error: invalid priority expression value in this context.
  type nat hook output priority dstnat - 1; policy accept;
                       ^^^^^^^^^^^^^^^^^^^ : exit status 1
```

而 `tun` 正常。

**根因（真机 root 实测，逐项对照）**：fnOS 自带 `nftables 1.0.6-2+deb12u2`，
它的解析器**只认 `filter` 一个命名优先级常量**，其余全部报
`invalid priority expression value`：

| 写法 | 结果 |
| --- | --- |
| `priority dstnat` | ❌ invalid priority expression |
| `priority dstnat - 1` | ❌ 同上（就是 v2rayA 生成的） |
| `priority dstnat-5` / `srcnat` / `prerouting` / `input` / `forward` / `output` / `postrouting` | ❌ 同上 |
| `priority filter` | ✅ |
| `priority -100` / `-101` / `-150` / `0` / `100` | ✅ 数字形式可用 |

v2rayA 只有 **DNS 重定向**那条链用命名形式（`priority dstnat - 1`），
而 `redirect` / `tproxy` 都需要劫持 DNS，`tun` 不需要 nat hook —— 这正好解释了
「为什么只有 tun 能用」。

**为什么不是 lite 的问题**：用户当时怀疑是 lite 模式残留。实测 `lite=0`、`isRoot=true`，
`redirect` / `tproxy` 本来就是 root 模式下才提供的选项，与 lite 无关。

**修复**：启动参数加 `--nftables-support off`，走 iptables 路径。

实测对照（真机 root）：

| | nftables（默认） | `--nftables-support off`（iptables） |
| --- | --- | --- |
| 添加 DNS REDIRECT 规则 | ❌ invalid priority | ✅ rc=0，规则正常写入 |
| 日志 `invalid priority` 计数 | >0 | **0** |

**代价**：走 iptables 而非 nftables，功能等价（v2rayA 两条路径生成的规则语义相同）。
fnOS 的 iptables 本身是 nf_tables 后端（`iptables v1.8.9 (nf_tables)`），所以底层仍是 nftables，
只是绕开了 v2rayA 裸写 nft 语法的那段。

**回归测试**：`tests/core-start.sh` 第 7 节断言 `cmd/main` 含 `--nftables-support off`，
并尝试用 `nft -c` 复验该不兼容是否仍存在。无 `CAP_NET_ADMIN` 的环境会记为 SKIP 而不是假装通过。

**何时该回退**：若将来 fnOS 升级到能识别命名优先级的 nftables（≥ 1.0.7 或修复版），
可去掉该参数让 v2rayA 回到原生 nftables 路径。测试里那条 `nft -c` 探针会在届时给出提示。

---

## D-20（已废弃，见 D-23）局域网共享：曾自行添加转发与 NAT

**症状**：局域网内其他设备把本机设为网关后无法上网。

**排查（真机 root 实测）**：

| 检查项 | 结果 |
| --- | --- |
| `net.ipv4.ip_forward` | `1`（转发已开，不是问题） |
| `tun0` 设备 | 存在，`10.0.85.2/30` |
| 本机走代理 | ✅ 正常（`gstatic/generate_204` → 204） |
| 策略路由 | 表 2020 `default dev tun0`，`ip rule` 正常 |
| **`FORWARD` 链策略** | **`DROP`，已丢弃 ~38452 个包** ← 问题所在 |
| **LAN 网段的 MASQUERADE** | **不存在** ← 问题所在 |

TUN 模式只让**本机**走代理（靠 `ip rule` + 表 2020）。它不碰 `FORWARD` 链，
而 fnOS 的 `FORWARD` 策略是 `DROP`，局域网设备的包进来就被静默丢弃。

**注意**：v2rayA UI 里的「允许局域网的连接」(`portSharing`) 是让 SOCKS/HTTP
入站监听 `0.0.0.0`，**对 TUN 模式无效**——那个开关只解决"别的程序来连代理端口"，
不解决"别的设备以我为网关"。

**修复**（`lan_gateway=on` 时，在应用启动就绪后安装）：

```
FORWARD      lan -> tun        ACCEPT
FORWARD      tun -> lan        ACCEPT (RELATED,ESTABLISHED)
nat POSTROUTING lan -> tun     MASQUERADE
nat PREROUTING  lan -> :53     REDIRECT --to-ports <core dns port>
```

**DNS 为什么要单独处理**：v2rayA 的 DNS 模块只监听
`127.2.0.17:53`（回环）和 `dnsListenAddr`（默认 `*:52353`）。
局域网设备把 DNS 指向 NAS 的 `192.168.3.22:53` 时**没有任何进程在监听**，
解析必然失败。所以把 LAN 发往 53 的请求 REDIRECT 到核心的 DNS 端口
（`lan_dns_port()` 从 `config.json` 的 `dnsListenAddr` 读取，缺省 52353）。

**两个实现陷阱（都踩过并已修正）**：

1. `iptables -S | grep ... | while read` 删除规则不生效——循环体在子 shell，
   且读取的是不会刷新的快照。改为每次 `head -n 1` 取一条、当前 shell 内删除、
   循环重查，最多 20 轮。
2. `${line#-A }` 只去掉 `-A`，留下 `FORWARD`，导致
   `iptables -D FORWARD FORWARD ...` 报 `Invalid rule number 'FORWARD'`。
   必须去掉整段 `-A FORWARD ` 前缀。

**规则隔离**：所有规则带 `--comment v2raya-lan-gw`，清理时只删带这个标记的，
绝不碰用户的其它防火墙配置。已验证：安装 5 条 → 清理后剩 0 条，且重复安装幂等。

**新增设置项**：`wizard_lan_gateway`（设置页开关，默认 `off`），持久化到
`$TRIM_PKGETC/v2raya.conf`，`config_callback` 保存后自动重启生效。

**回归测试**：`tests/core-start.sh` 第 8 节，检查函数存在、设置项接线、
规则带标记、`lan_gateway_down` 覆盖 PREROUTING（这一条曾漏过），
并在有 iptables 权限时实际跑一遍安装/清理。

---

## D-21 关于 DoH：v2rayA 把它设计成 DNS 上游 URL，不是独立开关

用户反馈"设置里没有 DNS over HTTPS 选项"。查证结论：**这不是缺陷，是 v2rayA 的设计**。

DoH 在 2.5.16 里不是一个布尔开关，而是填写在 DNS 上游地址里。官方帮助原文：

> For DoH, enter a full URL with the endpoint path, for example
> `https://1.1.1.1/dns-query`

入口位置：
- **订阅 → 配置 → 节点 DNS**：决定订阅里节点主机名如何解析，
  可填纯 IP 的 UDP/TCP/TLS/HTTPS 端点，DoH 就是 `https://.../dns-query` 形式
- 该设置仅在 `dnsMode=hijack` 时生效；`off`/`service` 模式下节点解析仍走系统解析器

当前设备实际配置：`dnsMode=hijack`、`dnsListenAddr=0.0.0.0:52353`、`dnsHijack=yes`，
即劫持模式已开启，具备使用 DoH 的前提。

**因此不做任何代码改动**。若用户需要 DoH，是在上述位置填 URL，而不是找一个开关。
本机实测 DNS 模块工作正常（`dig -p 52353 @127.0.0.1 www.google.com` 有应答）。

---

## D-22 `wizard/` 不支持 `switch` 字段类型（fnpack 1.2.4）

**症状**：加了「局域网共享」开关后，`fnpack build` 报

```
Packing failed. File "config" is not valid due to JSON format or content validation failure.
```

**定位过程**（容易走弯路的点）：报错说 `File "config"`，但这个 `"config"` **不是**
`config/privilege` 或 `config/resource`，也不是 `app/ui/config`——逐个替换成
scaffold 原版后依然报错。真正原因是 `wizard/config`（同一个名字，容易混淆）。

**根因**：官方文档列出的字段类型里有 `switch`，但 **fnpack 1.2.4 实际不接受**
（打包期校验直接判整个文件无效）。同一位置换成 `select` 两选项即可通过：

```json
{
  "type": "select",
  "field": "wizard_lan_gateway",
  "initValue": "off",
  "options": [
    { "label": "关闭（默认）", "value": "off" },
    { "label": "开启", "value": "on" }
  ]
}
```

**教训**：文档写的字段类型不一定被当前打包器实现。凡是改 `wizard/`，必须真的跑一次
`fnpack build` 验证——静态 JSON 校验（`python3 -m json.tool`）发现不了这类问题，
JSON 完全合法但打包器不认。

**已接入校验**：`build.sh` 的打包步骤会捕获 `Packing failed.` 并以非零退出
（fnpack 本身仍 exit 0，这个怪癖见 D-15 附注）。

---

## D-23 只做飞牛适配，不自造功能（推翻 D-20）

**决定**：删除 `cmd/main` 中所有自行实现的网络功能，包括转发规则、NAT、DNS 重定向
和「局域网共享」开关。本包只做**飞牛平台适配**，不做功能扩展。

**为什么推翻 D-20**：D-20 的推理链本身没错（fnOS `FORWARD` 策略为 `DROP`，
TUN 只装本机策略路由），但结论越界了——我据此给应用**加了一个 v2rayA 没有的功能**，
并且要求用户通过我们的开关去使用它。这带来三个问题：

1. **与上游职责重叠**。转发/NAT 属于"这台机器要不要当路由器"的决策，
   是系统级网络配置，不属于一个代理客户端的打包层。
2. **升级会失配**。上游一旦调整透明代理实现（例如自己处理转发），我们的规则会与之打架。
3. **用户被两套逻辑迷惑**。v2rayA 自己有 `portSharing`（让 SOCKS/HTTP 监听 0.0.0.0），
   我们再加一套语义不同的"局域网共享"，用户无法判断该用哪个。

**读源码后确认的官方事实**（v2rayA v2.5.16）：

| 事实 | 源码位置 |
| --- | --- |
| TUN 只装本机策略路由（`ip rule` + 表 2020），不碰 FORWARD/NAT | `service/kernel/v2ray/tun_core_linux.go` |
| `portSharing` 仅把 SOCKS/HTTP 入站监听地址由 `127.0.0.1` 改为 `0.0.0.0` | `service/kernel/v2ray/template_inbound.go:184` |
| TUN 模式下核心**原生拦截**进入 TUN 的 53 端口查询并转给 DNS 模块 | `tunDnsTarget()`，`service/kernel/v2ray/tun_core.go:39` |
| Linux 下 DNS 走 `resolv.conf` 劫持到 `127.2.0.17`，只服务本机 | `template_dns.go:74` |

也就是说：**局域网设备使用 `portSharing` 暴露的 SOCKS/HTTP 端口是官方路径**，
需要它们时用官方开关即可；而"把本机做成透明网关"是系统层面的用法，
不属于本包的适配范围。

**保留的适配内容**（都是"让 v2rayA 能在飞牛上跑起来"的必要工作，不是新功能）：

- 统一网关接入（`gatewayPrefix` + Unix socket + `--baseurl`）
- `--v2ray-bin` / `--v2ray-assetsdir` / `XRAY_LOCATION_ASSET` 等路径修正
- `--nftables-support off`（绕过 fnOS nftables 1.0.6 的解析器缺陷）
- 预置 geoip/geosite/LoyalsoldierSite.dat（避免首启联网下载）
- `run-as: root`（TUN 需要 CAP_NET_ADMIN）
- 生命周期脚本、向导、数据保留/清理

**回归测试**：`tests/core-start.sh` 第 8 节改为反向断言——
`cmd/main` 不得调用 `iptables`/`ip6tables`/`nft`、不得做 53 重定向、不得改内核转发参数
（均排除注释行）。这样以后有人再"顺手加个功能"会被立刻拦下。
