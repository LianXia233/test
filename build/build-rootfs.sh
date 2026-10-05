#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — Debian 13 (Trixie) ARM64 RootFS 构建脚本
#
# 功能：
#   1. 执行 scripts/fetch-firmware.py 拉取 MT7992 / MT7987 PHY 固件
#   2. debootstrap --arch=arm64 --foreign trixie + qemu-user-static 第二阶段
#   3. 安装 build/rootfs/packages.list 全部软件包（Debian 13 稳定版，不使用 Testing/Unstable）
#   4. 应用 rootfs-overlay/ 覆盖层（网络、systemd 服务、Linux-Router 集成）
#   5. 预装 luci-app-mt5700（at-webserver-rust AT 后端 + MT5700M 管理面板，局域网可访问）
#   6. 预初始化 Linux-Router（用户、数据目录、初始密码、WebUI 凭据）
#   7. 安装内核产物（Image / DTB / modules）到 /boot 与 /lib/modules
#   8. 输出 debian13-arm64-rootfs.tar.zst
#
# 用法：
#   sudo bash build/build-rootfs.sh \
#     --out /path/to/out \
#     --hostname h5000m-debian \
#     [--kernel-dir /path/to/out/kernel] \
#     [--admin-password 初始WebUI密码] [--root-password root密码] \
#     [--mirror http://deb.debian.org/debian] [--timezone Asia/Shanghai]
#
# 平台：仅 Linux（debootstrap / qemu-user-static 为 Linux 专用）。
#       Windows 请使用 WSL2，macOS 建议使用 Docker/Linux VM。
# 行尾：本文件为 LF。

set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac

if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[build-rootfs] 错误：debootstrap / qemu-user-static 仅支持 Linux。"
  echo "[build-rootfs] Windows 请使用 WSL2，macOS 建议使用 Docker/Linux VM。"
  echo "[build-rootfs] 当前平台：$BUILD_PLATFORM"
  exit 1
fi

# ---------------------------------------------------------------- 参数与默认值
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
KERNEL_DIR="$OUT_DIR/kernel"
HOSTNAME="h5000m-debian"
SUITE="trixie"                       # Debian 13 稳定版（固定，不允许 Testing/Unstable）
ARCH="arm64"
MIRROR="http://deb.debian.org/debian"
TIMEZONE="Asia/Shanghai"
ADMIN_PASSWORD=""                    # 为空则使用默认密码 password
ROOT_PASSWORD=""                     # 为空则使用默认密码 password
OVERLAY_DIR="$PROJECT_ROOT/rootfs-overlay"
PACKAGES_FILE="$PROJECT_ROOT/build/rootfs/packages.list"
FIRMWARE_DIR="$PROJECT_ROOT/build/rootfs/firmware"
LINUX_ROUTER_SRC="$PROJECT_ROOT/linux-router/vendor"
LINUX_ROUTER_DIR="/opt/linux-router"
LINUX_ROUTER_DATA="/var/lib/linux-router"
# luci-app-mt5700 预装（AT 后端经 Release ipk 下发；面板二进制/资源 vendor 入库，见 PROVENANCE.md）
MT5700_VENDOR_DIR="$PROJECT_ROOT/build/rootfs/vendor/mt5700"
MT5700_IPK_URL="https://github.com/LianXia233/luci-app-mt5700/releases/download/v1.14.2/aarch64_generic-luci-app-mt5700_1.14.2-r1_aarch64_generic.ipk"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)            OUT_DIR="$2"; shift 2 ;;
    --hostname)       HOSTNAME="$2"; shift 2 ;;
    --kernel-dir)     KERNEL_DIR="$2"; shift 2 ;;
    --mirror)         MIRROR="$2"; shift 2 ;;
    --timezone)       TIMEZONE="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --root-password)  ROOT_PASSWORD="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

ROOTFS_DIR="$OUT_DIR/rootfs/rootfs"
BOOT_DIR="$OUT_DIR/rootfs/boot"
ROOTFS_TAR="$OUT_DIR/rootfs/debian13-arm64-rootfs.tar.zst"
mkdir -p "$ROOTFS_DIR" "$BOOT_DIR" "$OUT_DIR/rootfs"

# 密码兜底：未指定时使用默认密码 password（交付时写入 /etc/h5000m-initial-credentials）
[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="password"
[[ -n "$ROOT_PASSWORD"  ]] || ROOT_PASSWORD="password"

log() { printf '[build-rootfs] %s\n' "$*"; }
die() { printf '[build-rootfs] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 构建机依赖检查
for tool in debootstrap qemu-aarch64-static rsync zstd python3; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install debootstrap qemu-user-static rsync zstd python3"
done
[[ -e /usr/bin/qemu-aarch64-static ]] || \
  die "缺少 /usr/bin/qemu-aarch64-static。请安装 qemu-user-static 并确认 binfmt 支持。"

[[ -f "$PACKAGES_FILE" ]] || die "缺少软件包清单 $PACKAGES_FILE"
[[ -d "$OVERLAY_DIR" ]]   || die "缺少覆盖层目录 $OVERLAY_DIR"
[[ -d "$LINUX_ROUTER_SRC" ]] || die "缺少 Linux-Router 源码目录 $LINUX_ROUTER_SRC"
[[ -d "$KERNEL_DIR" ]] || {
  log "警告：未找到内核产物目录 $KERNEL_DIR，将跳过内核安装。"
  log "      可先用 build/build-kernel.sh 构建，或用 --kernel-dir 指定。"
  KERNEL_DIR=""
}

# ---------------------------------------------------------------- 1. 固件
log "第 1 步：拉取 MT7992 / MT7987 PHY 固件"
python3 "$PROJECT_ROOT/scripts/fetch-firmware.py" --out "$FIRMWARE_DIR"
[[ -d "$FIRMWARE_DIR/mediatek" ]] || die "固件拉取失败：$FIRMWARE_DIR/mediatek 不存在"

# ---------------------------------------------------------------- 2. debootstrap
if [[ -x "$ROOTFS_DIR/bin/sh" ]]; then
  log "已存在 rootfs（$ROOTFS_DIR），跳过 debootstrap（如需重建请删除该目录）"
else
  log "第 2 步：debootstrap --arch=$ARCH --foreign $SUITE（$MIRROR）"
  debootstrap --arch="$ARCH" --foreign "$SUITE" "$ROOTFS_DIR" "$MIRROR"

  log "第 3 步：第二阶段（qemu-aarch64-static）"
  install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
  chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
fi

# ---------------------------------------------------------------- 4. 软件源与软件包
log "第 4 步：配置 Debian 13 软件源"
# 绑定宿主机 resolv.conf 供 chroot 内 apt 使用（构建期 DNS）
mkdir -p "$ROOTFS_DIR/etc/apt/sources.list.d"
install -m 0644 /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" || true

cat > "$ROOTFS_DIR/etc/apt/sources.list" <<EOF
# Debian 13 (Trixie) stable — H5000M 固定使用，禁止混用 Testing/Unstable
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free-firmware
EOF

log "第 5 步：apt-get update 并安装软件包"
cp "$PACKAGES_FILE" "$ROOTFS_DIR/packages.list"
chroot "$ROOTFS_DIR" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends $(grep -vE '^\s*#' /packages.list | tr "\n" " " | sed "s/  */ /g")
  apt-get clean
'

# ---------------------------------------------------------------- 6. 覆盖层
log "第 6 步：应用 rootfs-overlay 覆盖层"
rsync -a --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r "$OVERLAY_DIR/" "$ROOTFS_DIR/"
chmod 0755 "$ROOTFS_DIR/usr/local/sbin/h5000m-router-init.sh"
chmod 0755 "$ROOTFS_DIR/usr/local/sbin/h5000m-fancontrol"
chmod 0755 "$ROOTFS_DIR/etc/NetworkManager/dispatcher.d/90-h5000m-wan-dns"

# ---------------------------------------------------------------- 7. luci-app-mt5700 预装
log "第 7 步：预装 luci-app-mt5700（at-webserver-rust + MT5700M 管理面板）"
command -v curl >/dev/null 2>&1 || die "缺少 curl（下载 luci-app-mt5700 Release）"
[[ -x "$MT5700_VENDOR_DIR/bin/mt5700-web" ]] || die "缺少 vendor 面板二进制 $MT5700_VENDOR_DIR/bin/mt5700-web（见 PROVENANCE.md）"

MT5700_TMP="$(mktemp -d)"
trap 'rm -rf "$MT5700_TMP"' EXIT

# 7.1 AT 后端：luci-app-mt5700 Release ipk 内的 at-webserver-rust 为静态链接 musl，
#     可直接运行于 Debian glibc；配置与 systemd 单元来自 rootfs-overlay（不在 ipk 内覆盖）。
log "  下载 luci-app-mt5700 Release ipk：$MT5700_IPK_URL"
curl -fL --retry 3 --retry-delay 2 -o "$MT5700_TMP/mt5700.ipk" "$MT5700_IPK_URL" \
  || die "luci-app-mt5700 ipk 下载失败：$MT5700_IPK_URL"
tar -xzf "$MT5700_TMP/mt5700.ipk" -C "$MT5700_TMP" \
  || die "ipk 解包失败（非标准 ipk 结构）"
tar -xzf "$MT5700_TMP/data.tar.gz" -C "$MT5700_TMP" \
  || die "data.tar.gz 解包失败"
[[ -f "$MT5700_TMP/usr/bin/at-webserver-rust" ]] || die "ipk 内未找到 usr/bin/at-webserver-rust（Release 资产结构变更？）"

install -d -m 0755 "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/libexec/at-webserver"
install -m 0755 "$MT5700_TMP/usr/bin/at-webserver-rust" "$ROOTFS_DIR/usr/bin/at-webserver-rust"
install -m 0755 "$MT5700_TMP/usr/libexec/at-webserver/on-uplink.sh" \
  "$ROOTFS_DIR/usr/libexec/at-webserver/on-uplink.sh"

# 7.2 MT5700M 管理面板（vendor 二进制 + 静态资源；面板绑定 0.0.0.0:8181，LAN 可访问，
#     WAN/5G 上行由 nftables input 策略 drop 拦截）
install -m 0755 "$MT5700_VENDOR_DIR/bin/mt5700-web" "$ROOTFS_DIR/usr/bin/mt5700-web"
mkdir -p "$ROOTFS_DIR/usr/share/mt5700-panel"
rsync -a --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r \
  "$MT5700_VENDOR_DIR/www/" "$ROOTFS_DIR/usr/share/mt5700-panel/www/"

# 7.3 产物自检：ELF 魔数 + aarch64 架构（构建机无需运行二进制）
python3 - "$ROOTFS_DIR/usr/bin/at-webserver-rust" "$ROOTFS_DIR/usr/bin/mt5700-web" <<'PYEOF'
import struct, sys
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        hdr = f.read(20)
    if hdr[:4] != b"\x7fELF":
        raise SystemExit(f"[build-rootfs] ERROR: {path} 不是 ELF 文件")
    if struct.unpack_from("<H", hdr, 18)[0] != 183:  # EM_AARCH64
        raise SystemExit(f"[build-rootfs] ERROR: {path} 非 aarch64 架构")
print("[build-rootfs]   [OK] 预装二进制 ELF/aarch64 校验通过")
PYEOF
log "  [OK] at-webserver-rust + mt5700-web + 面板静态资源已预装"

# ---------------------------------------------------------------- 8. Linux-Router 集成
log "第 8 步：集成 Linux-Router 到 $LINUX_ROUTER_DIR"
install -d -m 0755 "$ROOTFS_DIR$LINUX_ROUTER_DIR"
rsync -a \
  --exclude tests --exclude data --exclude ".git*" --exclude "*.pyc" --exclude __pycache__ \
  "$LINUX_ROUTER_SRC/" "$ROOTFS_DIR$LINUX_ROUTER_DIR/"
chmod 0644 "$ROOTFS_DIR$LINUX_ROUTER_DIR"/router-panel.service \
           "$ROOTFS_DIR$LINUX_ROUTER_DIR"/router-panel-agent.service

# ---------------------------------------------------------------- 9. 内核产物
if [[ -n "$KERNEL_DIR" ]]; then
  log "第 9 步：安装内核产物"
  [[ -f "$KERNEL_DIR/Image" ]] && install -m 0644 "$KERNEL_DIR/Image" "$ROOTFS_DIR/boot/Image"
  [[ -f "$KERNEL_DIR/mt7987a-hiveton-h5000m.dtb" ]] && \
    install -m 0644 "$KERNEL_DIR/mt7987a-hiveton-h5000m.dtb" "$ROOTFS_DIR/boot/mt7987a-hiveton-h5000m.dtb"
  if [[ -f "$KERNEL_DIR/modules.tar.zst" ]]; then
    mkdir -p "$ROOTFS_DIR/lib/modules"
    # Debian 13 为 usrmerge 布局（/lib 是指向 /usr/lib 的符号链接）。
    # tar 解压存档中的 lib/ 目录条目时，会默认删除目标上的符号链接并重建真实
    # 目录，导致 /lib 不再指向 /usr/lib、/lib/ld-linux-aarch64.so.1 消失，后续
    # chroot 报 "Could not open '/lib/ld-linux-aarch64.so.1'"。
    # --keep-directory-symlink 让 tar 跟随符号链接写入（模块落到 /usr/lib/modules）。
    tar --keep-directory-symlink -I zstd -xf "$KERNEL_DIR/modules.tar.zst" -C "$ROOTFS_DIR"
  fi
  # distro boot（U-Boot 支持 extlinux 时的备用入口）
  mkdir -p "$ROOTFS_DIR/boot/extlinux"
  cat > "$ROOTFS_DIR/boot/extlinux/extlinux.conf" <<EOF
DEFAULT h5000m
LABEL h5000m
    LINUX /Image
    FDT /mt7987a-hiveton-h5000m.dtb
    APPEND earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
EOF
fi

# ---------------------------------------------------------------- 10. chroot 内最终配置
log "第 10 步：chroot 内最终配置（hostname / locale / 服务 / Linux-Router 预初始化）"
# 主机会改变 /etc/hosts 中 hostname 行
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" "$ROOTFS_DIR/etc/hosts" 2>/dev/null || true

chroot "$ROOTFS_DIR" /bin/bash -e -c '
  export DEBIAN_FRONTEND=noninteractive
  HOSTNAME="'"$HOSTNAME"'"
  TIMEZONE="'"$TIMEZONE"'"
  ADMIN_PASSWORD="'"$ADMIN_PASSWORD"'"
  ROOT_PASSWORD="'"$ROOT_PASSWORD"'"
  LINUX_ROUTER_DIR="'"$LINUX_ROUTER_DIR"'"
  LINUX_ROUTER_DATA="'"$LINUX_ROUTER_DATA"'"

  # hostname
  printf "%s\n" "$HOSTNAME" > /etc/hostname

  # locale / timezone
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  sed -i "s/^# *zh_CN.UTF-8/zh_CN.UTF-8/" /etc/locale.gen
  locale-gen >/dev/null 2>&1 || true
  update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  printf "%s\n" "$TIMEZONE" > /etc/timezone

  # root 密码（首次启动可通过 SSH/串口登录）
  printf "root:%s\n" "$ROOT_PASSWORD" | chpasswd

  # SSH：允许首次启动 root 密码登录（交付物同时提供 h5000m-initial-credentials）
  mkdir -p /etc/ssh/sshd_config.d
  printf "PermitRootLogin yes\nPasswordAuthentication yes\n" \
    > /etc/ssh/sshd_config.d/90-h5000m.conf
  chmod 0644 /etc/ssh/sshd_config.d/90-h5000m.conf

  # Linux-Router 运行账号与数据目录
  getent group router-panel >/dev/null 2>&1 || groupadd --system router-panel
  id router-panel >/dev/null 2>&1 || useradd --system \
    --gid router-panel --home-dir "$LINUX_ROUTER_DATA" \
    --no-create-home --shell /usr/sbin/nologin router-panel
  install -d -o router-panel -g router-panel -m 0700 "$LINUX_ROUTER_DATA"

  # 初始化 Linux-Router 数据（auth.json / secret_key / 初始密码）
  LINUX_ROUTER_DATA_DIR="$LINUX_ROUTER_DATA" \
  LINUX_ROUTER_INITIAL_PASSWORD="$ADMIN_PASSWORD" \
    python3 -c "import sys; sys.path.insert(0, \"$LINUX_ROUTER_DIR\"); import app"

  chown -R router-panel:router-panel "$LINUX_ROUTER_DATA"
  chmod 0700 "$LINUX_ROUTER_DATA"
  find "$LINUX_ROUTER_DATA" -type f -exec chmod 0600 {} +

  # 首次登录凭据文件（root 可读）
  cat > /etc/h5000m-initial-credentials <<CRED
Hiveton H5000M - Debian 13 首次登录凭据
SSH / 串口: root  / $ROOT_PASSWORD
WebUI      : http://192.168.88.1  admin / $ADMIN_PASSWORD
（登录后请立即修改密码）
CRED
  chmod 0600 /etc/h5000m-initial-credentials

  # motd 提示
  cat > /etc/motd <<MOTD
Welcome to Hiveton H5000M Debian 13 Router
LAN: 192.168.88.1  |  WebUI: http://192.168.88.1
模组面板: http://192.168.88.1:8181（MT5700M 5G 管理，仅局域网可访问）
Wi-Fi: OWRT（2.4G / 5G 同名，与 LAN 同一二层网络）
初始凭据：cat /etc/h5000m-initial-credentials
MOTD

  # 服务编排（唯一控制面：Linux-Router；禁用冲突服务）
  systemctl enable NetworkManager.service >/dev/null 2>&1 || true
  systemctl enable dnsmasq.service >/dev/null 2>&1 || true
  systemctl enable nftables.service >/dev/null 2>&1 || true
  systemctl enable h5000m-router-init.service >/dev/null 2>&1 || true
  systemctl enable h5000m-fancontrol.service >/dev/null 2>&1 || true
  systemctl enable router-panel-agent.service >/dev/null 2>&1 || true
  systemctl enable router-panel.service >/dev/null 2>&1 || true
  systemctl enable at-webserver.service >/dev/null 2>&1 || true
  systemctl enable mt5700-web.service >/dev/null 2>&1 || true
  systemctl enable ssh.service >/dev/null 2>&1 || true
  systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true

  systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-resolved.service >/dev/null 2>&1 || true
  systemctl mask systemd-networkd.service systemd-resolved.service >/dev/null 2>&1 || true
'

# 清理构建期文件
rm -f "$ROOTFS_DIR/packages.list"
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# ---------------------------------------------------------------- 11. 打包
log "第 11 步：打包 rootfs"
# 预生成凭据清单副本（供构建机/交付查看，不含密钥文件本身）
cat > "$OUT_DIR/rootfs/initial-credentials.txt" <<CRED
root(SSH/串口): $ROOT_PASSWORD
WebUI admin:    $ADMIN_PASSWORD
CRED
chmod 0600 "$OUT_DIR/rootfs/initial-credentials.txt"

log "压缩中（zstd）..."
tar --numeric-owner --xattrs --acls -C "$ROOTFS_DIR" -c . | zstd -q -T0 -o "$ROOTFS_TAR"

log "完成。RootFS: $ROOTFS_TAR"
ls -lh "$ROOTFS_TAR"
log "初始凭据已写入 $OUT_DIR/rootfs/initial-credentials.txt"
