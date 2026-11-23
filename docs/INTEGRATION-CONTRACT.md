# v2rayA → 飞牛 fnOS 适配契约（唯一事实来源）

本文件是所有实现与验收的**唯一契约**。任何实现与本文冲突，以本文为准；确有必要改动契约时，
先改本文并在 `docs/DECISIONS.md` 记录理由。

目标产物：`v2raya-fnos-fpk`，appname `v2raya`，装到飞牛 fnOS 后可在桌面点击打开
v2rayA 的 Web UI，能正常登录、添加节点、启动代理。

---

## 1. 已核实的平台事实（实测，勿凭猜测改动）

| 事实 | 证据 |
| --- | --- |
| 包装格式 = 外层 `.fpk` 是 **gzip 压缩的 tar**，内含 `app.tgz`（tar.gz）、`manifest`、`cmd/`、`config/`、`wizard/`、`ICON.PNG`、`ICON_256.PNG` | `file` / 魔数 `1f 8b` 实测；与第三方真实 `.fpk` 一致。`tar -tf` 自动识别 gzip，所以早期只用 `tar -tf` 会看不出这层压缩 |
| `fnpack build`（v1.2.4，已装在 `/usr/local/bin/fnpack`）负责打这个包，并在打包时写入 `checksum` | 实测 |
| `fnpack build` 会把 `app/` 打成 `app.tgz`，`app/ui/config` 里的 `{display_name}`/`{port}`/`{url-path}` 等占位符**不会被替换**，需构建脚本自行处理 | 实测 tar 内容 |
| **`fnpack build` 失败时仍然 `exit 0`**（只打印 "Packing failed."） | 5 种失败模式实测：缺 ICON_256 / 缺 manifest / 缺 cmd/main / 缺 app/ui/config / privilege JSON 非法，全部 `exit 0`。**构建脚本绝不能只信退出码** |
| `fnpack build -d <dir>` 的 `-d` 只指定**源目录**，产物始终落在**当前目录** | 实测：仓库根执行 `-d<tmp>` 仍把 `.fpk` 落在仓库根 |
| `fnpack` 复刻源目录的字面 mode 位；本仓库曾出现目录 mode `000`（靠 btrfs ACL 放行），直接打包会 `mkdir ... permission denied` | 实测；构建脚本改为**打包一份 mode 归一化的暂存副本**，仓库目录树本身也已整为 755 |
| manifest 版本号只接受 `x.y.z` 或 `x.y.z-r`（四段 `x.y.z.r` 被拒） | 实测 `Invalid version "2.5.16.1". Expected format: x.y.z[-r]` |
| 统一网关：`app/ui/config` 声明 `gatewayPrefix` + `gatewaySocket`，fnOS 校验登录态后把请求转发到 `$TRIM_APPDEST/<gatewaySocket>` | 官方文档 + 参考实现 |
| **网关转发时保留完整路径**（含 `/app/xxx` 前缀），应用必须自己按前缀提供路由 | 参考网关实现注释原文：`upstream sees /app/... and answers 404` |
| 网关注入身份头 `X-Trim-Userid` / `X-Trim-Isadmin` / `X-Trim-Username` | 官方文档 |
| 必须用 `run-as: package`（专用用户）运行；root 模式不建议 | 官方文档 |
| 应用安装后目录：`target→/vol{n}/@appcenter/{appname}`、`etc→@appconf`、`var→@appdata`、`home→@apphome`、`tmp→@apptemp` | 实测 `/var/apps/*` |
| 生命周期脚本由 `cmd/` 下的 `install_init`、`install_callback`、`main`（start/stop/status）、`upgrade_*`、`uninstall_*`、`config_*` 组成 | 官方文档 |
| `cmd/main status` 必须：运行中 `exit 0`，未运行 `exit 3` | 官方文档 |
| 生命周期脚本失败时把用户可读错误写入 `$TRIM_TEMP_LOGFILE` | 官方文档 |
| 图标：`ICON.PNG` 64×64、`ICON_256.PNG` 256×256，≤1024KB，圆角风格 | 官方文档 |

### 1.1 v2rayA 侧已核实事实

| 事实 | 证据 |
| --- | --- |
| `--socket <path>` 可只监听 Unix socket（不监听 TCP） | 实测，socket 出现、TCP 端口无用 |
| `--baseurl /app/v2raya` 会**自带前缀路由**：`/app/v2raya/` → 200，`/` → 404 | 实测 |
| 静态资源与 API 都在该前缀下正常工作（`/app/v2raya/static/...`、`/app/v2raya/api/version` → 200） | 实测 |
| 非 root 启动自动进入 **lite 模式**（`"lite":1`）：透明代理/TUN 不可用，其余功能正常 | 实测 `/api/version` 返回 |
| `--v2ray-bin` 必须显式指定，否则它会去 PATH 找 | 实测 |
| 首次启动若缺 geoip/geosite 会**联网下载**（国内网络下会卡住）→ 必须预置资源并传 `--v2ray-assetsdir` | 实测 |
| **GFWList 模式除 `geosite.dat` 外还需要独立的 `LoyalsoldierSite.dat`**；缺它时保存该模式会返回 `GFWLIST_MISSING` | 实测复现：`GFWList mode needs LoyalsoldierSite.dat, which is missing from <dir>`。只影响 GFWList 模式，其它模式存活，故极易漏测 |
| **`geosite.dat` 必须包含 `gfw` 分类**，否则核心构建 `geosite:gfw` 路由时拒绝并立即退出 | 实测：v2fly `dlc.dat`(2.4MB) 报 `illegal domain rule: geosite:gfw ... EOF`；Loyalsoldier 版(11MB) 正常。`geosite:cn`/`google` 两者都能过，故单测常用分类看不出问题 |
| **`--v2ray-assetsdir` 不会传给 `v2raya_core` 子进程**；核心从自己的工作目录找 `geosite.dat`/`geoip.dat` | 实测：父进程 environ 无 `V2RAY_/XRAY_LOCATION_ASSET`。必须在启动时导出（核心只认 `XRAY_LOCATION_ASSET`，两者都设为稳妥） |
| 核心启动是**独立失败点**：UI 正常、设置能存，不等于核心能跑 | 真机报 `CORE_START_FAILED` / `v2raya_core exited right after starting`。必须单独测核心启动与端口绑定 |
| **v2rayA 在 GFWList 模式生成 `ext:LoyalsoldierSite.dat:gfw` 规则**，该文件必须按 **geosite 格式**编码 | 真机日志：`illegal domain rule: ext:LoyalsoldierSite.dat:gfw > invalid body length: 2186385218`。`geosite:gfw` 与 `ext:...` 是两条不同代码路径，必须都测 |
| TUN / 透明代理需要 root（`CAP_NET_ADMIN` + `/dev/net/tun`）；`/dev/net/tun` 虽为 0666，但建 tun 接口卡在 netlink | 实测：非 root `operation not permitted`；提权后 `Xray started` |
| `PUT /api/gfwList` 的运行时更新走 `raw.githubusercontent.com`，本机实测被重置 → **不能依赖运行时下载补齐该文件** | 实测 `ASSET_UNREACHABLE: connection reset by peer` |
| SIGTERM 可干净退出 | 实测 |
| 二进制 `v2raya` + `v2raya_core`：静态链接、无动态依赖，可直接放进包内（不依赖系统库） | `file` 实测 |
| `--log-file` 会写文件；`--log-max-days` 控制保留天数 | 实测 |

## 2. 目录与文件契约

打包源目录 `<repo>/v2raya-fnos/`：

```
v2raya-fnos/
├── manifest                     # 应用元数据
├── ICON.PNG                     # 64×64
├── ICON_256.PNG                 # 256×256
├── app/
│   ├── server/
│   │   ├── v2raya               # 主程序（vendored, 755）
│   │   └── v2raya_core          # 内核（vendored, 755）
│   ├── assets/
│   │   ├── geoip.dat            # 预置，禁运行时联网下载
│   │   └── geosite.dat
│   ├── ui/
│   │   ├── config               # 桌面入口（网关型）
│   │   └── images/
│   │       ├── icon_64.png
│   │       └── icon_256.png
│   └── www/
│       └── index.html           # 兜底页（见 §5）
├── cmd/                         # 生命周期脚本，全部 755
│   ├── main
│   ├── install_init
│   ├── install_callback
│   ├── upgrade_init
│   ├── upgrade_callback
│   ├── uninstall_init
│   ├── uninstall_callback
│   ├── config_init
│   └── config_callback
├── config/
│   ├── privilege                # {"defaults":{"run-as":"package"}}
│   └── resource                 # 共享目录声明
├── wizard/
│   ├── install                  # 安装向导
│   └── config                   # 设置页
├── build.sh                     # 打包入口
└── tests/                       # 验收脚本
```

## 3. manifest 契约

```
appname               = v2raya
version               = 2.5.16-<fpk-rev>   # 本次交付为 2.5.16-2
display_name          = v2rayA
desc                  = <HTML 描述>
platform              = x86
source                = thirdparty
maintainer            = ...
maintainer_url        = https://github.com/v2rayA/v2rayA
distributor           = ...
os_min_version        = 1.1.3100
desktop_uidir         = ui
desktop_applaunchname = v2raya.Application
checkport             = false
ctl_stop              = true
micro_app             = true
```

- **不要**写 `service_port`：本应用只走 Unix socket，不监听固定 TCP 端口。
- **不要**写 `install_dep_apps`：无运行时依赖（二进制静态链接，资源已预置）。

## 4. 桌面入口契约（`app/ui/config`）

必须**原样写入以下内容**（这是解析后的最终值，不含占位符）：

```json
{
    ".url": {
        "v2raya.Application": {
            "title": "v2rayA",
            "icon": "images/icon_{0}.png",
            "type": "iframe",
            "protocol": "",
            "gatewayPrefix": "/app/v2raya",
            "gatewaySocket": "app.sock",
            "url": "/app/v2raya/",
            "allUsers": false,
            "control": {
                "accessPerm": "readonly"
            }
        }
    }
}
```

理由：
- `gatewayPrefix`/`gatewaySocket` → 走统一网关，复用系统访问域名，无需暴露额外端口。
- `type: iframe` → 在飞牛桌面窗口内打开。
- `protocol: ""` → 网关入口忽略该字段，留空避免误判。
- `url: "/app/v2raya/"`（**带尾斜杠**）→ v2rayA 对无尾斜杠的路径返回 301，带斜杠直接 200。
- `allUsers: false` + `accessPerm: readonly` → 代理工具属于管理员级应用，不对普通用户开放。

## 5. 兜底页 `app/www/index.html`

网关只负责转发，不用它。此页仅用于 `index.cgi` 之外的人工排查（可选保留）。
**要求**：不得作为桌面入口；桌面入口只走网关。

## 6. 生命周期脚本契约

所有脚本：`#!/bin/bash` + `set -u`，**只使用** `TRIM_*` 环境变量与向导变量，
不硬编码 `/vol{n}` 路径。错误一律写 `$TRIM_TEMP_LOGFILE` 后 `exit 1`。

### 6.1 `cmd/main`

```
start:
  - 已在运行 → exit 0（幂等）
  - 准备目录：$TRIM_PKGVAR/{data,logs}、$TRIM_PKGVAR/assets（软链到 $TRIM_APPDEST/assets）
  - 清理残留 socket：$TRIM_APPDEST/app.sock
  - 启动：
      $TRIM_APPDEST/server/v2raya \
        --socket "$TRIM_APPDEST/app.sock" \
        --baseurl /app/v2raya \
        --config "$TRIM_PKGVAR/data" \
        --v2ray-bin "$TRIM_APPDEST/server/v2raya_core" \
        --v2ray-assetsdir "$TRIM_APPDEST/assets" \
        --log-file "$TRIM_PKGVAR/logs/v2raya.log" \
        --log-max-days 3 \
        --log-level info \
        --ipv6-support auto \
        --passcheckroot            # 见下
  - 写 pid 到 $TRIM_PKGVAR/app.pid
  - 健康检查：最多等 N 秒直到 socket 可连且 /app/v2raya/api/version 返回 200
  - 失败 → 把日志尾部写 TRIM_TEMP_LOGFILE，exit 1

stop:
  - 按 pid 先 TERM，最多等 10s，再 KILL；删 pidfile 与残留 socket；幂等

status:
  - 运行中 exit 0；否则 exit 3
```

`--passcheckroot` 说明：应用以 package 用户运行，v2rayA 检测不到 root 会进 lite 模式。
加上该参数后仍需确认实际行为（**由实现者实测**：带与不带、`/api/version` 的 `lite` 字段、
以及是否会因为尝试透明代理而报错）。若加参数导致启动异常，则去掉它并接受 lite 模式，
在 `docs/DECISIONS.md` 记录实测结论。**不要**为了透明代理使用 root 模式。

### 6.2 `install_init` / `install_callback` / `upgrade_*` / `uninstall_*` / `config_*`

- 全部必须**幂等**，可重复执行。
- `install_init`：检查架构 `TRIM_SYS_ARCH`、OS 版本；不满足写 `TRIM_TEMP_LOGFILE` 并 exit 1。
- `install_callback`：创建数据目录、生成默认配置；**不**联网。
- `upgrade_*`：保留 `$TRIM_PKGVAR/data` 用户数据；版本比对仅记日志。
- `uninstall_init`：停止进程；`uninstall_callback`：按向导选择清理 `$TRIM_PKGVAR`。
- `config_*`：处理设置页变更（端口前缀不开放修改；仅日志级别、IPv6 开关等）。

## 7. 配置与资源

`config/privilege`：
```json
{
    "defaults": {
        "run-as": "package"
    }
}
```

`config/resource`：**只**声明一个数据共享目录
```json
{
    "data-share": {
        "shares": [
            { "name": "v2raya" }
        ]
    }
}
```
（用于用户备份/导入自定义配置；不暴露内部数据目录）

## 8. wizard 契约

`wizard/install`（单步）：提示「v2rayA 以 lite 模式运行（无透明代理/TUN）。账户在首次打开时创建。」
可选字段：无必填项。**不要**收集密码（v2rayA 首次打开自行创建账户）。

`wizard/config`（设置页）：只放**真正生效**的字段，且每个字段都必须在 `cmd/main` 或
`config_callback` 里被消费（不允许"摆设字段"）。

## 9. 构建契约（`build.sh`）

- 前置检查：`fnpack` 存在；`app/server/v2raya`、`v2raya_core` 存在且可执行；geo 资源存在；
  `ICON.PNG`/`ICON_256.PNG` 尺寸正确。
- 校验所有 JSON 合法（`python3 -m json.tool`）。
- 校验所有 `cmd/*` 有执行位且 `bash -n` 通过。
- 写 `manifest.version`、调用 `fnpack build`。
- 产物：`dist/v2raya_<version>_x86.fpk`。
- 全程可重复执行、无交互。

## 10. 验收（`tests/`）

必须能**在本机**（飞牛 fnOS 1.2.1102 / x86_64）无 root 跑通：

1. `bash tests/lint.sh`：JSON 合法、manifest 字段齐全、脚本 `bash -n`、图标尺寸/大小、
   无硬编码 `/vol`、无 `TRIM_` 前缀的自定义变量。
2. `bash tests/smoke.sh`：在**临时目录**模拟 `TRIM_*` 环境执行 `cmd/main start`，
   断言 `/app/v2raya/api/version` 200 且 `hasAccounts` 字段存在；再 `status`（0）、`stop`
   后再 `status`（3）；断言无残留进程。
3. `bash tests/gateway-sim.sh`：起一个模拟网关（node 或 shell），验证「保留前缀转发 → socket」
   这条链路能把 `/app/v2raya/` 正常送达 v2rayA（对齐 fnOS 网关行为）。
4. 产出 `.fpk` 后：`tar -tf` 结构断言 + 包内必需文件存在性断言。

## 11. 安全底线

- 不把 v2rayA 暴露到 TCP 公网端口；只走 Unix socket + 网关登录态。
- 文件路径、请求参数按不可信处理；不 `eval`、不拼接命令。
- 日志不打印订阅链接/密码/token。
- 生命周期脚本以 package 用户运行，不擅自 sudo。
