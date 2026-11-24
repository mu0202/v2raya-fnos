# 架构

本文说明这个包如何把 v2rayA 接入飞牛 fnOS：包由什么组成、进程怎么起、
请求怎么从桌面到达 v2rayA、构建流水线做了什么。

---

## 1. 定位与边界

这是一个**平台适配层**，不是 v2rayA 的分支。

| 范围 | 内容 |
| --- | --- |
| 本包负责 | 打包格式、网关接入、生命周期、路径与运行时环境、预置资源、构建与验收 |
| 本包不负责 | 代理协议、路由、DNS、TUN、透明代理、局域网共享——全部是 v2rayA 自身功能，在其 Web 界面配置 |

这条边界决定了实现风格：`cmd/main` 只做「以正确参数启动 v2rayA」，
不创建 TUN 设备、不写 iptables/nft 规则、不改 `ip_forward`。
网络层完全交给 v2rayA 和 v2ray-core，避免两套实现互相覆盖。

---

## 2. 包结构

`.fpk` 外层是 gzip 压缩的 tar，由 `fnpack` 生成：

```
v2raya_<version>_x86.fpk          # gzip tar
├── manifest                      # 应用元数据
├── ICON.PNG                      # 64×64
├── ICON_256.PNG                  # 256×256
├── app.tgz                       # 应用主体（tar.gz）
├── cmd/                          # 生命周期脚本
│   ├── main                      # start | stop | status
│   ├── install_init / install_callback
│   ├── upgrade_init / upgrade_callback
│   ├── uninstall_init / uninstall_callback
│   └── config_init / config_callback
├── config/
│   ├── privilege                 # run-as: root
│   └── resource                  # 数据共享目录声明
└── wizard/
    ├── install                   # 安装向导
    ├── config                    # 设置页
    └── uninstall                 # 卸载向导
```

`app.tgz` 解包到 `$TRIM_APPDEST`（即 `/vol{n}/@appcenter/v2raya/target`）：

```
target/
├── server/
│   ├── v2raya                    # 主程序，755
│   └── v2raya_core               # 内核，755
├── assets/
│   ├── geoip.dat
│   ├── geosite.dat
│   └── LoyalsoldierSite.dat
├── ui/
│   ├── config                    # 桌面入口定义
│   └── images/icon_{64,256}.png
└── www/index.html                # 兜底说明页，非桌面入口
```

两个二进制都是静态链接，不依赖系统 Go 运行时或动态库。

---

## 3. 网关接入

飞牛不在固定 TCP 端口上暴露应用。桌面点击图标时，系统统一网关先校验登录态，
再把请求转发到应用自己声明的 Unix socket。

声明在 `app/ui/config`：

```json
{
    "gatewayPrefix": "/app/v2raya",
    "gatewaySocket": "app.sock",
    "url": "/app/v2raya/",
    "type": "iframe"
}
```

关键点：

1. **网关保留完整路径**。请求 `/app/v2raya/api/version` 到上游仍是 `/app/v2raya/api/version`，
   前缀不会被剥掉。因此 v2rayA 必须以 `--baseurl /app/v2raya` 启动，由它自己提供带前缀的路由。
2. **`url` 必须带尾斜杠**。v2rayA 对 `/app/v2raya` 返回 301，对 `/app/v2raya/` 直接 200。
3. **不声明 `service_port`**。应用只监听 Unix socket，`manifest` 里 `checkport = false`。

由此得到的效果：应用不占用系统端口，访问入口与飞牛其他应用一致，
登录态由网关统一管理。

---

## 4. 进程模型

```
fnOS 系统网关
   │  转发 /app/v2raya/*，保留路径
   ▼
$TRIM_APPDEST/app.sock        （Unix socket，唯一入口）
   ▲
   │  监听
v2raya                        （由 cmd/main 以 root 拉起）
   │  派生
   ▼
v2raya_core                   （xray 内核，执行实际代理与网络规则）
```

`cmd/main start` 的启动命令：

```bash
v2raya \
  --socket "$TRIM_APPDEST/app.sock" \
  --baseurl /app/v2raya \
  --config "$TRIM_PKGVAR/data" \
  --v2ray-bin "$TRIM_APPDEST/server/v2raya_core" \
  --v2ray-assetsdir "$TRIM_APPDEST/assets" \
  --log-file "$TRIM_PKGVAR/logs/v2raya.log" \
  --nftables-support off
```

几个不易察觉但必须的细节：

- **`--v2ray-bin` 必填**。不指定时 v2rayA 会去 `PATH` 找 `v2ray`，包内路径不会被自动发现。
- **`XRAY_LOCATION_ASSET` 必须导出**。`--v2ray-assetsdir` 只作用于 v2rayA 进程本身，
  不会传给 `v2raya_core` 子进程；内核默认从自己的工作目录找 `geosite.dat`/`geoip.dat`。
  启动前 export `XRAY_LOCATION_ASSET` 与 `V2RAY_LOCATION_ASSET` 指向 assets 目录。
- **`--nftables-support off`**。fnOS 的 nftables 只接受命名优先级常量，
  v2rayA 生成的 `priority dstnat - 1` 会被解析器拒绝；走 iptables 路径可产生等价规则。
- **以 root 运行**。TUN 与透明代理需要 `CAP_NET_ADMIN` 和 `/dev/net/tun` 写权限，
  非 root 时内核会因权限不足直接退出。

---

## 5. 生命周期

`cmd/main` 支持三个动作，退出码由 fnOS 约定：

| 动作 | 行为 | 退出码 |
| --- | --- | --- |
| `start` | 已在运行则直接返回；否则清理残留 socket、启动、等待就绪 | 0 成功，1 失败 |
| `stop` | SIGTERM，超时后 SIGKILL，删除 pidfile 与 socket | 0 |
| `status` | 运行中 0，未运行 3 | 0 / 3 |

「就绪」的判定是 `--unix-socket` 请求 `/app/v2raya/api/version` 返回 200，
最长等待 30 秒；失败时把日志尾部写入 `$TRIM_TEMP_LOGFILE` 供用户查看。

**幂等性**：三个动作都可重复执行。`start` 两次仍返回 0，`stop` 两次仍返回 0。

**进程归属**：停止时只操作 pidfile 中的进程，以及命令行指向本安装 socket 路径的进程。
不按进程名 `pkill`——同一台机器上可能存在另一个 v2rayA 实例，按名杀会误伤。

其余脚本职责单一，全部幂等：

| 脚本 | 职责 |
| --- | --- |
| `install_init` | 校验架构与系统版本，不匹配则拒绝安装 |
| `install_callback` | 建立数据目录与默认配置，不联网 |
| `upgrade_init` | 停止旧实例，避免二进制占用 |
| `upgrade_callback` | 保留用户数据，仅补建缺失文件 |
| `uninstall_init` | 停止实例 |
| `uninstall_callback` | 按向导选择清理或保留 `$TRIM_PKGVAR` |
| `config_init` | 把当前配置暴露给设置页作为默认值 |
| `config_callback` | 持久化设置并重启使生效 |

---

## 6. 数据与日志

| 路径 | 内容 | 卸载时 |
| --- | --- | --- |
| `@appcenter/v2raya` | 程序本体 | 平台删除 |
| `@appdata/v2raya` | 数据库、日志、pid | 按向导选择 |
| `@appconf/v2raya` | 设置页持久化的运行参数（`v2raya.conf`） | 平台管理 |
| `@apphome/v2raya` | 应用家目录 | 平台管理 |
| `@apptemp/v2raya` | 临时文件与错误输出 | 平台清理 |

本包的卸载脚本只处理 `$TRIM_PKGVAR`（即 `@appdata/v2raya`），其余目录由平台负责。

数据库在 `$TRIM_PKGVAR/data`，包含账户、节点、订阅与全部 v2rayA 设置。
卸载向导默认「保留数据」，重新安装后账户与节点无需重建。

日志两份，都在 `$TRIM_PKGVAR/logs/`：

- `v2raya.log` — v2rayA 自身日志，按 `--log-max-days` 轮转
- `v2raya.stdout.log` — 进程 stdout/stderr，用于启动失败排查

`$TRIM_PKGVAR/assets` 是指向 `$TRIM_APPDEST/assets` 的软链接，用 `ln -sfn` 建立：
保留数据重装时旧链接会悬空（目标目录被删），必须原地替换而不是跳过。

---

## 7. 关键取舍

每条的完整理由见代码注释，这里只列结论。

| 取舍 | 理由 |
| --- | --- |
| 统一网关而非 TCP 端口 | 复用飞牛登录态，不占用系统端口 |
| `run-as: root` | TUN/透明代理需要 `CAP_NET_ADMIN` 与 `/dev/net/tun` |
| `--nftables-support off` | fnOS nftables 不接受 v2rayA 生成的数值优先级 |
| 预置 geoip/geosite | 首次启动不联网；受限网络下运行时下载会卡住 |
| `LoyalsoldierSite.dat` 与 `geosite.dat` 同格式 | GFWList 模式按 `ext:LoyalsoldierSite.dat:gfw` 读取 |
| 显式 `--v2ray-bin` | 否则内核路径找不到 |
| `checkport = false` | 只监听 Unix socket |
| 不做数据库迁移 | `transparentType` 由用户在设置页选择，包不猜测旧值 |

---

## 8. 构建流水线

```bash
bash scripts/fetch-payload.sh   # 下载第三方二进制与规则库
bash build.sh                   # 产出 dist/*.fpk
bash tests/run-all.sh           # 验收
```

`fetch-payload.sh` 拉取 v2rayA 发布产物与规则库，并**派生** `LoyalsoldierSite.dat`
（与 `geosite.dat` 同内容）。这些文件约 108 MB，不提交到仓库。

`build.sh` 的流程：

1. **前置检查** —— `fnpack` 存在；两个二进制可执行且能打印版本；规则库大小合理；
   图标尺寸与体积合规
2. **静态校验** —— 所有 JSON 可解析；`manifest` 字段齐全且不含禁用键；
   `cmd/*` 有执行位且通过 `bash -n`；无硬编码 `/vol{n}` 路径
3. **归一化暂存副本** —— 把源树复制到临时目录，统一目录 755、文件 644、
   恢复必要执行位，再交给 `fnpack`。直接打包源树会因 ACL 与字面 mode 位错乱而失败
4. **打包** —— 在暂存目录内执行 `fnpack build`，产物落在产物目录
5. **校验产物** —— 解开 `.fpk` 确认必需成员存在、版本号一致、`checksum` 已注入、
   执行位保留

两个 `fnpack` 行为需要在脚本层面防守：

- **打包失败仍退出 0**。不能只看退出码，必须检查输出文件是否真的生成。
- **`-d` 只指定源目录**，产物始终落在当前工作目录。脚本因此切换工作目录执行，
  避免产物误落到源码树。

版本号用 `x.y.z-r` 形式（如 `2.5.16-9`），`fnpack` 不接受四段的 `x.y.z.r`。

---

## 9. 验收

`tests/` 分七个阶段，由 `run-all.sh` 串联：

| 阶段 | 验证内容 |
| --- | --- |
| `lint` | 静态检查：JSON、manifest 字段、脚本语法、图标、路径 |
| `build` | 打包成功并产出可用的 `.fpk` |
| `fpk-structure` | 产物结构、权限位、内嵌文件完整性 |
| `smoke` | 模拟安装：start / 探活 / status / stop 与退出码 |
| `gateway-sim` | 网关保留前缀转发的完整链路 |
| `reinstall-keepdata` | 保留数据重装后资产链接仍有效 |
| `core-start` | 内核真的启动、绑定入站、TUN 权限正常 |

`core-start` 是唯一验证「内核能跑」的阶段。UI 正常、设置能保存，都不代表
`v2raya_core` 能启动——两者是独立的失败点。
