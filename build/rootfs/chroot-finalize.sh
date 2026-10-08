#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# chroot 内的最终配置：hostname / locale / 口令 / sshd 放行范围 / Linux-Router
# 账号与数据目录 / 凭据文件 / motd / 服务 enable-disable 编排。
#
# 由 build/build-rootfs.sh 复制进 rootfs 后以 chroot 执行，参数顺序：
#   $1 HOSTNAME  $2 TIMEZONE  $3 ADMIN_PASSWORD  $4 ROOT_PASSWORD
#   $5 LINUX_ROUTER_DIR（chroot 内路径）  $6 LINUX_ROUTER_DATA（chroot 内路径）
#   $7 BOARD_ID  $8 BOARD_NAME  $9 BOARD_UPPER  $10 BOARD_DROPIN_PREFIX
#      （$7~$10 为多板化新增：用于生成板级 hostname/凭据/motd/drop-in 文件名）

# 【多板化说明】本脚本以固定位置参数接收板级信息，不再出现机型字面量。
# 承载板级配置的 overlay 机制（与旧实现的关键差异）：
#   rootfs-overlay/ 是"板级无关"的共用覆盖层，其上的板级参数由
#   rootfs-overlay/../boards/<board>.overlay.d/ 目录叠加（见 build-rootfs.sh
#   第 6.5 步）。systemd unit / 脚本的文件名统一改为 <drop-in 前缀>，
#   避免为每个板卡复制一整套 27 个文件。
#
# 为什么独立成文件：这段原先是 build-rootfs.sh 里的 `chroot ... bash -s <<'EOF'`
# heredoc。放在字符串里的代价是——shellcheck 完全看不到它，语法错误与引号陷阱
# 只能等到真机构建时才发现（例如 heredoc 内出现任何字面单引号就会提前闭合外层
# 字符串，报 "unexpected end of file"）。独立成文件后它进入 CI 的 shellcheck
# 与 bash -n 覆盖范围。
#
# 行尾：本文件为 LF。
set -eu
# 刻意不开 pipefail：这串命令在原 heredoc 里只受 `bash -e` 约束，贸然加上
# pipefail 会让 find -exec / grep 这类"末段非零但语义正常"的管道变成构建失败。

export DEBIAN_FRONTEND=noninteractive

HOSTNAME_="$1"
TIMEZONE_="$2"
ADMIN_PASSWORD_="$3"
ROOT_PASSWORD_="$4"
LINUX_ROUTER_DIR_="$5"
LINUX_ROUTER_DATA_="$6"
BOARD_ID_="${7:-}"
BOARD_NAME_="${8:-}"
BOARD_UPPER_="${9:-}"
BOARD_PREFIX_="${10:-}"
# 缺省前缀：$7 未传时退回 H5000M（保持旧调用方可用），传了则一律用板级前缀
[[ -n "$BOARD_PREFIX_" ]] || BOARD_PREFIX_="h5000m"

# LAN 网段：与 rootfs-overlay/etc/nftables.conf、router-init.sh
# 以及 linux-router 的 DEFAULT_LAN_NETWORK 保持一致，用于 SSH 口令登录白名单
LAN_NET_IPV4="192.168.88.0/24"
LAN_NET_IPV6="fd88:88::/64"

# hostname
printf '%s\n' "$HOSTNAME_" > /etc/hostname

# locale / timezone
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
ln -sf "/usr/share/zoneinfo/$TIMEZONE_" /etc/localtime
printf '%s\n' "$TIMEZONE_" > /etc/timezone

# root 口令（首次启动可通过 SSH/串口登录）
printf 'root:%s\n' "$ROOT_PASSWORD_" | chpasswd

# SSH：/etc/ssh/sshd_config 主配置的兜底在宿主机侧由 build-rootfs.sh 第 6 步
# 执行（ucf 模板落地需要 chroot 之外的环境），本脚本只写 drop-in。
mkdir -p /etc/ssh/sshd_config.d

# 【默认关闭口令登录，只对局域网网段放行】
# 出厂 root 口令是公开已知值，而设备的 WAN 侧一旦被接入上级网络（或未来
# 防火墙规则被改坏），全局 PasswordAuthentication yes 就等于把 root 口令
# 认证直接暴露到不可信网络。这里改成全局禁用 + Match 仅对 LAN 网段/ULA/
# 本机回环放行，和 nftables 的 input drop 形成两道独立防线。
cat > "/etc/ssh/sshd_config.d/90-${BOARD_PREFIX_}.conf" <<SSHD_LAN
# 由 build/build-rootfs.sh 调用 build/rootfs/chroot-finalize.sh 生成 —— 手工改动会在下次构建时被覆盖
PermitRootLogin yes

# 默认口令登录关闭；下方 Match 段仅对局域网放行
PasswordAuthentication no

Match address ${LAN_NET_IPV4},${LAN_NET_IPV6},127.0.0.1,::1
    PasswordAuthentication yes
SSHD_LAN
chmod 0644 "/etc/ssh/sshd_config.d/90-${BOARD_PREFIX_}.conf"

# Linux-Router 运行账号与数据目录
getent group router-panel >/dev/null 2>&1 || groupadd --system router-panel
id router-panel >/dev/null 2>&1 || useradd --system \
  --gid router-panel --home-dir "$LINUX_ROUTER_DATA_" \
  --no-create-home --shell /usr/sbin/nologin router-panel
install -d -o router-panel -g router-panel -m 0700 "$LINUX_ROUTER_DATA_"

# 初始化 Linux-Router 数据（auth.json / secret_key / 初始密码）
LINUX_ROUTER_DATA_DIR="$LINUX_ROUTER_DATA_" \
LINUX_ROUTER_INITIAL_PASSWORD="$ADMIN_PASSWORD_" \
  python3 -c "import sys; sys.path.insert(0, \"$LINUX_ROUTER_DIR_\"); import app"

chown -R router-panel:router-panel "$LINUX_ROUTER_DATA_"
chmod 0700 "$LINUX_ROUTER_DATA_"
find "$LINUX_ROUTER_DATA_" -type f -exec chmod 0600 {} +

# 首次登录凭据文件（root 可读）
cat > "/etc/${BOARD_PREFIX_}-initial-credentials" <<CRED
${BOARD_NAME_} - Debian 13 首次登录凭据
SSH / 串口: root  / $ROOT_PASSWORD_
WebUI      : http://192.168.88.1  admin / $ADMIN_PASSWORD_
（登录后请立即修改密码）
CRED
chmod 0600 "/etc/${BOARD_PREFIX_}-initial-credentials"

# motd 提示
cat > /etc/motd <<MOTD
Welcome to ${BOARD_NAME_} Debian 13 Router
LAN: 192.168.88.1  |  WebUI: http://192.168.88.1
模组面板: http://192.168.88.1:9000（MT5700M 5G 管理，WebUI + HTTP API，仅局域网可访问）
Wi-Fi: OWRT（2.4G / 5G 同名，与 LAN 同一二层网络）
初始凭据：cat /etc/${BOARD_PREFIX_}-initial-credentials
MOTD

# 服务编排（唯一控制面：Linux-Router；禁用冲突服务）
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable dnsmasq.service >/dev/null 2>&1 || true
systemctl enable nftables.service >/dev/null 2>&1 || true
# 【命名约定 — 2026-10-09 修正】这些 unit 的文件名**不含板级前缀**：
# 它们由通用层 rootfs-overlay/etc/systemd/system/router-*.service 提供，
# 板级差异通过 boards/overlay.d/<board>/etc/default/router*.conf 的
# **内容**体现（同名文件整体覆盖），而非文件名。因此这里必须 enable
# 字面量 "router-*.service"。
# 此前写的是 "${BOARD_PREFIX_}-router-init.service"（= h5000m-router-init.service），
# 该文件在改名为 router-*.service 后已不存在 → enable 静默失败，而这 5 个
# 服务的 systemctl enable 都带 `|| true`，错误被完全吞掉：
#   后果 = 首启网络编排 / 风扇 / 首启扩容 / LED 全部不启动（无任何报错）。
#   BOARD_PREFIX_ 仍用于 **文件名带前缀** 的资产（sshd drop-in、初始凭据）。
systemctl enable router-init.service >/dev/null 2>&1 || true
systemctl enable router-fancontrol.service >/dev/null 2>&1 || true
# 【为什么这三个必须在此显式 enable】覆盖层只拷贝 .service 文件、不携带
# .wants 软链，若不在此处 enable，首次启动 systemd 永远不会拉起它们：
#   router-grow-rootfs.service：首启 resize2fs 把 p5 引导层 ext4 扩满分区
#     （~7.2 GiB）。漏 enable 会让 /overlay 持久化空间永久锁死在镜像大小，
#     与 make-sd-image.sh / make-sysupgrade-tar.sh 注释描述的行为直接矛盾。
#     unit 自带 ConditionPathExists=!/var/lib/router-rootfs-grown，天然只跑一次。
#   router-led-boot.service（WantedBy=sysinit.target，早期蓝灯闪烁）与
#   router-led.service（WantedBy=multi-user.target，就绪后收尾熄灭）：
#     与清单内已验证可行的 router-fancontrol.service（同为 WantedBy=sysinit.target）同构。
systemctl enable router-grow-rootfs.service >/dev/null 2>&1 || true
systemctl enable router-led-boot.service >/dev/null 2>&1 || true
systemctl enable router-led.service >/dev/null 2>&1 || true
systemctl enable router-panel-agent.service >/dev/null 2>&1 || true
systemctl enable router-panel.service >/dev/null 2>&1 || true
systemctl enable at-webserver.service >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true

systemctl disable systemd-networkd.service systemd-networkd.socket \
  systemd-resolved.service >/dev/null 2>&1 || true
systemctl mask systemd-networkd.service systemd-resolved.service >/dev/null 2>&1 || true