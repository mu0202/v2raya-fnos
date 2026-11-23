<!-- 本文件说明许可证归属，不是许可证正文。 -->

## 本仓库的许可

本仓库中的**适配代码**（`cmd/`、`build.sh`、`tests/`、`scripts/`、`config/`、`wizard/`、
`app/ui/`、`docs/` 等本项目原创部分）采用 **MIT 许可证**，见 [LICENSE](LICENSE)。

## 第三方组件

本仓库**不包含**以下第三方二进制与数据（由 `scripts/fetch-payload.sh` 在构建时下载）：

| 组件 | 来源 | 许可证 |
| --- | --- | --- |
| `v2raya` / `v2raya_core` | [v2rayA/v2rayA](https://github.com/v2rayA/v2rayA) | GPL-3.0 |
| `geoip.dat` / `geosite.dat` | [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) | 见上游仓库 |
| xray-core（编译进 v2raya_core） | [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 |

**重要**：因此，由本项目打包生成的 `.fpk` **整体分发时受 GPL-3.0 约束**（因为它内含
GPL-3.0 的 v2rayA 二进制）。若你要公开分发构建产物，请遵守 GPL-3.0：
提供对应源码、保留版权声明。

本仓库不含 v2rayA 源码，只提供飞牛 fnOS 的平台适配层。
