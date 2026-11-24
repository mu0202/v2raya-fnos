# 测试套件

本目录是 v2rayA 飞牛 fnOS 应用包的验收测试。全部脚本可在本机以普通用户
（非 root）运行，不需要联网，不需要 sudo。

## 运行全部

```bash
bash tests/run-all.sh                 # 依次跑全部 7 个阶段
bash tests/run-all.sh --no-build      # 跳过构建，验收已有 dist/*.fpk
```

执行顺序：`lint` → `build` → `fpk-structure` → `smoke` → `gateway-sim` →
`reinstall-keepdata` → `core-start`，最后打印汇总表与总退出码。

## 单独运行

| 脚本 | 作用 | 依赖 |
| --- | --- | --- |
| `lint.sh` | 静态检查：JSON 合法性、manifest 字段、`cmd/*` 的 shebang / 执行位 / `bash -n`、图标尺寸与体积、`cmd/` 内硬编码 `/vol{n}`、`wizard/` 占用保留的 `TRIM_` 前缀、`app/ui/config` 未替换的占位符 | 无 |
| `smoke.sh` | 在 `/tmp` 模拟安装，跑 `cmd/main start` / `status` / `stop`，断言 `/app/v2raya/api/version` 返回 200 且含 `hasAccounts`、UI 可达、停止后 `status` 返回 3、无残留进程、start/stop 幂等 | 无 |
| `gateway-sim.sh` | 起一个保留完整路径的本地 TCP → Unix socket 代理，复现飞牛统一网关转发行为，证明 `/app/v2raya` 前缀不被剥离 | 无 |
| `fpk-structure.sh` | 断言产物结构：外层成员、`app.tgz` 内执行位、包内 manifest 的 `appname` / `platform` / `checksum`、包内 `app/ui/config`、`cmd/*` 执行位 | 需先 `build.sh` |
| `reinstall-keepdata.sh` | 保留数据卸载后重装：`$TRIM_PKGVAR/assets` 是符号链接，断言重装后仍可解析、GFWList 模式可保存 | 需先 `build.sh` |
| `core-start.sh` | 直接拉起真实内核二进制，断言其启动并监听入站；覆盖 geosite 资源查找、nftables 优先级兼容性 | 无 |
| `lib-test.sh` | 公共函数库（`pass` / `fail` / `blocked`、清理 trap、HTTP 与 PNG 探测）。被 source，不单独执行 | — |

```bash
bash tests/lint.sh
bash build.sh
bash tests/fpk-structure.sh "dist/v2raya_<version>_x86.fpk"
bash tests/smoke.sh
bash tests/gateway-sim.sh
bash tests/reinstall-keepdata.sh
bash tests/core-start.sh
```

测试产物一律放在 `/tmp` 下的临时目录并在退出时清理，不写入仓库。
所有脚本只终止自己启动的 PID，不影响机器上其他 v2rayA 实例。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 全部断言通过 |
| `1` | 有断言失败 |
| `77` | **BLOCKED** —— 被测对象缺失（`cmd/`、`manifest`、`wizard/` 未就绪，或还没有 `.fpk`）。这不代表通过，也不代表代码有问题 |

`77` 刻意区别于 `0`：缺失的输入不能被当成绿灯。`run-all.sh` 只要有阶段 BLOCKED，
总体即为 BLOCKED，不会报 PASS。

每个脚本逐条打印 `PASS` / `FAIL` / `SKIP` / `BLOCKED`，结尾给出
`passed=… failed=… skipped=… blocked=…` 统计。

## 运行前提

1. **payload 已就位。** `app/server/`（v2rayA 与内核二进制）、`app/assets/`（geoip / geosite）
   必须存在。若缺失，先取一次（需联网）：

   ```bash
   bash scripts/fetch-payload.sh
   ```

2. **验收产物需先构建。**

   ```bash
   bash build.sh          # -> dist/v2raya_<version>_x86.fpk
   ```

   `lint.sh`、`smoke.sh`、`gateway-sim.sh`、`core-start.sh` 不需要产物；
   `fpk-structure.sh` 与 `reinstall-keepdata.sh` 需要。

需要 `.fpk` 的脚本默认取 `dist/` 下最新产物，也可把路径作为第一个参数传入。
总体设计与进程模型见 [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)。
