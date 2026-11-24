# v2rayA for fnOS

将 [v2rayA](https://github.com/v2rayA/v2rayA) 打包为飞牛 fnOS 原生 `.fpk` 应用。
从桌面点击图标即可打开其 Web 界面，通过系统统一网关接入，复用飞牛登录态，
不额外占用系统端口。

![仪表板](docs/images/screenshot-dashboard.png)

## 特性

- **统一网关接入** —— 走飞牛登录态与访问域名，应用只监听 Unix socket
- **TUN / 透明代理** —— 以 root 运行，支持 `tun`、`tproxy`、`redirect` 三种方式
- **离线可用** —— 内置 geoip/geosite 规则库，首次启动不联网下载
- **静态二进制** —— v2rayA 与内核静态链接打包，不依赖系统运行时
- **生命周期完整** —— 安装 / 升级 / 卸载 / 设置向导，卸载可选择保留数据

本仓库只做**飞牛平台适配**，不修改也不扩展 v2rayA 的功能。
代理协议、路由、DNS、TUN、局域网访问等全部由 v2rayA 自身提供。

## 安装

1. 从 [Releases](https://github.com/mu0202/v2raya-fnos/releases/latest) 下载 `v2raya_<version>_x86.fpk`
2. 飞牛 **应用中心 → 手动安装**，选择该文件
3. 首次打开时在页面内创建管理员账户

支持 x86_64，要求 fnOS ≥ 1.1.3100。

## 使用

完整说明见 [使用文档](docs/USAGE.md)。要点：

- **代理模式** —— 在 v2rayA 的 **设置 → 透明代理/系统代理** 选择 `tun` / `tproxy` / `redirect`
- **局域网访问** —— 打开 v2rayA 的 **允许局域网的连接**，客户端指向 `NAS地址:20170`（SOCKS5）或 `:20171`（HTTP）
- **DNS / DoH** —— 在 **订阅 → 配置 → 节点 DNS** 填入完整 URL，如 `https://1.1.1.1/dns-query`
- **本包设置页** —— 只有日志级别与 IPv6 开关两项

## 从源码构建

仓库不包含第三方二进制与规则库（约 108 MB），构建前先拉取：

```bash
bash scripts/fetch-payload.sh   # 下载 v2raya / v2raya_core / geoip / geosite
bash build.sh                   # 产出 dist/*.fpk
```

需要 `fnpack`（飞牛官方打包工具）与 `python3`。

## 测试

```bash
bash tests/run-all.sh           # 全部七个阶段
```

| 套件 | 覆盖内容 |
| --- | --- |
| `lint.sh` | 静态检查：JSON、manifest 字段、脚本语法、图标、路径 |
| `fpk-structure.sh` | 产物结构、权限位、内嵌文件完整性 |
| `smoke.sh` | 模拟安装：start / stop / status 与退出码契约 |
| `gateway-sim.sh` | 网关保留前缀的转发链路 |
| `reinstall-keepdata.sh` | 保留数据重装后资产链接仍有效 |
| `core-start.sh` | 内核启动、入站绑定、TUN 权限 |

说明见 [tests/README.md](tests/README.md)。

## 项目结构

```
├── app/
│   ├── server/          # v2raya + v2raya_core（构建时下载）
│   ├── assets/          # geoip / geosite（构建时下载）
│   ├── ui/config        # 桌面入口（统一网关）
│   └── www/             # 兜底说明页
├── cmd/                 # 生命周期脚本
├── config/              # 权限与资源声明
├── wizard/              # 安装 / 设置 / 卸载向导
├── scripts/             # 依赖拉取
├── tests/               # 验收套件
├── docs/                # 架构与用法文档
└── build.sh             # 打包入口
```

## 文档

- [架构说明](docs/ARCHITECTURE.md) —— 包结构、网关接入、进程模型、构建流水线
- [使用说明](docs/USAGE.md) —— 安装、代理模式、局域网、DNS、升级卸载、排障

## 许可

适配代码采用 [MIT](LICENSE)。构建产物内含 GPL-3.0 的 v2rayA 二进制，
整体分发时受 GPL-3.0 约束，详见 [LICENSE-note.md](LICENSE-note.md)。
