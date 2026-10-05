# mt5700 预装产物来源说明（PROVENANCE）

本目录存放 Debian 13 RootFS 预装的 MT5700M 管理组件，**均为二进制/静态资源**，
由 CI 在构建 rootfs 时安装（见 `build/build-rootfs.sh`）。

| 文件 | 来源 | 版本/日期 | 说明 |
|---|---|---|---|
| `bin/mt5700-web` | H5000M udev 参考包镜像（`debian-13-h5000m-udev`，资料库节点）内 `/usr/bin/mt5700-web` | 2026-10-04 22:03 GMT+8 构建 | MT5700M 管理面板服务（"luci-app-mt5700 移植版"）。ELF aarch64，glibc 动态链接（NEEDED: libc.so.6, libgcc_s.so.1），适配 Debian 13。**该二进制暂无公开发布渠道**，暂以参考包镜像为唯一来源；后续建议在 luci-app-mt5700 或独立仓库发布 Release 后改为 CI 下载 |
| `www/**` | 同上参考包镜像 `/usr/share/mt5700-panel/www` | 2026-10-04 22:23 | 面板静态资源（自研外壳 index.html / panel-shell.css / menu.json + LuCI JS 运行时与 mt5700 视图） |

**不在本目录**的组件：

- `at-webserver-rust`（AT 后端）：CI 从 [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700) Release
  `v1.14.2` 的 aarch64 ipk 中提取（静态链接 musl，可直接运行于 Debian glibc），
  版本锁定见 `build-rootfs.sh` 的 `MT5700_IPK_URL`。该仓库仅发布 OpenWrt ipk/apk。
- `/etc/config/at-webserver`、systemd 单元：来自 ipk 同名配置 + 参考包单元，存放在
  `rootfs-overlay/`（文本，可评审）。

更新指引：

1. `mt5700-web` 有正式发布渠道后，删除本目录的 `bin/`，改为 CI 下载并校验；
2. `www/` 若随面板迭代，用新版本资源整体替换并同步本文件表格；
3. 校验方式：ELF 魔数（`7f 45 4c 46`）+ 可执行位，见 `build-rootfs.sh`。
