#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — Debian 13 (Trixie) ARM64 RootFS 构建脚本
#
# 功能：
#   1. 执行 scripts/fetch-firmware.py 拉取 MT7992 / MT7987 PHY 固件
#   2. debootstrap trixie：arm64 宿主走 native 一次完成；x86 宿主走 --foreign + qemu 第二阶段
#   3. 安装 build/rootfs/packages.list 全部软件包（Debian 13 稳定版，不使用 Testing/Unstable）
#   4. 应用 rootfs-overlay/ 覆盖层（网络、systemd 服务、Linux-Router 集成）
#   5. 预装 luci-app-mt5700（Debian 分支 at-webserver 单服务：WebUI + HTTP API :9000）
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
#     [--mirror https://deb.debian.org/debian] [--timezone Asia/Shanghai] \
#     [--skip-tar] [--apt-cache-dir /path/to/deb-cache]
#
# 构建模式（自动判定）：
#   native ：宿主本身就是 arm64/aarch64（如 ubuntu-24.04-arm runner）→ debootstrap 一次
#            完成，不需要 qemu 二进制翻译，RootFS 构建耗时大幅下降。
#   foreign：宿主为 x86_64 → debootstrap --foreign + qemu-aarch64-static 第二阶段。
#
# --apt-cache-dir：仅缓存"下载层"（.deb 归档），不缓存构建产物本身。命中时跳过所有
#            包下载；产物仍每次真实 dpkg 安装，保证结果等同无缓存构建。
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
MIRROR="https://deb.debian.org/debian"
TIMEZONE="Asia/Shanghai"
ADMIN_PASSWORD=""                    # 为空则使用默认密码 password
ROOT_PASSWORD=""                     # 为空则使用默认密码 password
OVERLAY_DIR="$PROJECT_ROOT/rootfs-overlay"
PACKAGES_FILE="$PROJECT_ROOT/build/rootfs/packages.list"
# chroot 内最终配置脚本（原先是本文件里的 heredoc，抽出后进入 CI 静态检查覆盖）
CHROOT_FINALIZE_SCRIPT="$PROJECT_ROOT/build/rootfs/chroot-finalize.sh"
FIRMWARE_DIR="$PROJECT_ROOT/build/rootfs/firmware"
LINUX_ROUTER_SRC="$PROJECT_ROOT/linux-router/vendor"
LINUX_ROUTER_DIR="/opt/linux-router"
LINUX_ROUTER_DATA="/var/lib/linux-router"
# luci-app-mt5700（Debian 分支）预装 staging 目录：
#   由 build/build-mt5700.sh 交叉编译产出（at-webserver + webui/ + debian/ 配置），
#   来源仓库与固定 commit 见该脚本头注释与 staging 内 PROVENANCE.txt
MT5700_DIR="$OUT_DIR/mt5700"
SKIP_TAR=0                      # 1 = 跳过 tar.zst 打包（SquashFS 方案直接消费树；CI 传 --skip-tar）
APT_CACHE_DIR=""                # .deb 下载层缓存目录（仅缓存下载，不缓存构建产物）

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
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
    --mt5700-dir)     MT5700_DIR="$2"; shift 2 ;;
    --skip-tar)       SKIP_TAR=1; shift ;;
    --apt-cache-dir)  APT_CACHE_DIR="$2"; shift 2 ;;
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
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || \
  die "hostname 格式无效：仅允许字母、数字、点和连字符"
[[ "$MIRROR" == https://* ]] || die "Debian mirror 必须使用 HTTPS：$MIRROR"

# ---------------------------------------------------------------- 构建机依赖检查
# qemu-aarch64-static 只在 foreign（宿主非 arm64）模式下必需。
HOST_ARCH="$(uname -m)"
IS_NATIVE=0
if [[ "$ARCH" == "arm64" && ( "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ) ]]; then
  IS_NATIVE=1
fi

for tool in debootstrap rsync zstd python3; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install debootstrap rsync zstd python3"
done
if [[ "$IS_NATIVE" -eq 0 ]]; then
  command -v qemu-aarch64-static >/dev/null 2>&1 || \
    die "缺少 qemu-aarch64-static（foreign 模式需要）。请安装 qemu-user-static，或改用 arm64 宿主走 native 模式。"
  [[ -e /usr/bin/qemu-aarch64-static ]] || \
    die "缺少 /usr/bin/qemu-aarch64-static。请安装 qemu-user-static 并确认 binfmt 支持。"
fi

[[ -f "$PACKAGES_FILE" ]] || die "缺少软件包清单 $PACKAGES_FILE"
[[ -f "$CHROOT_FINALIZE_SCRIPT" ]] || die "缺少 chroot 最终配置脚本 $CHROOT_FINALIZE_SCRIPT"
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
  # debootstrap 下载层缓存：把 .deb 统一存到 --cache-dir，跨次构建复用（不缓存产物）
  DEB_CACHE_ARGS=()
  if [[ -n "$APT_CACHE_DIR" ]]; then
    mkdir -p "$APT_CACHE_DIR"
    DEB_CACHE_ARGS+=(--cache-dir "$APT_CACHE_DIR")
    log "  deb 下载层缓存：$APT_CACHE_DIR（已有 $(ls -1 "$APT_CACHE_DIR"/*.deb 2>/dev/null | wc -l) 个包）"
  fi

  if [[ "$IS_NATIVE" -eq 1 ]]; then
    # native：宿主即 arm64，debootstrap 一套流程直接完成，无需二期 qemu 翻译。
    # 这是 CI 提速的关键路径（原 foreign 第二阶段在 qemu 下耗时占大头）。
    log "第 2 步：debootstrap --arch=$ARCH $SUITE（native 模式，宿主 $HOST_ARCH 免 qemu）"
    debootstrap "${DEB_CACHE_ARGS[@]}" --arch="$ARCH" "$SUITE" "$ROOTFS_DIR" "$MIRROR"
  else
    log "第 2 步：debootstrap --arch=$ARCH --foreign $SUITE（$MIRROR）"
    debootstrap "${DEB_CACHE_ARGS[@]}" --arch="$ARCH" --foreign "$SUITE" "$ROOTFS_DIR" "$MIRROR"

    log "第 3 步：第二阶段（qemu-aarch64-static）"
    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
    chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
  fi
fi

log "构建模式：$([[ "$IS_NATIVE" -eq 1 ]] && echo native || echo foreign)（宿主 Arch=$HOST_ARCH）"

# foreign 模式下，树内必须存在 qemu 静态解释器才能 chroot 执行 arm64 命令。
# 该注入原先只在 debootstrap 阶段做：若树已存在而跳过 debootstrap（本地迭代常见），
# 后续 chroot apt/chpasswd 会以 "Exec format error" 直接失败。此处统一前置保证，
# 末尾统一清理（见"清理构建期文件"）。
if [[ "$IS_NATIVE" -eq 0 ]]; then
  install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
  log "  qemu-aarch64-static 已注入树内（foreign 模式 chroot 依赖）"
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
deb https://security.debian.org/debian-security $SUITE-security main contrib non-free-firmware
EOF

log "第 5 步：apt-get update 并安装软件包"
# 下载层缓存命中时可免去全部网络拉取；安装动作本身始终真实执行，
# 产物与无缓存构建完全一致（不做产出层缓存）。
if [[ -n "$APT_CACHE_DIR" ]]; then
  mkdir -p "$APT_CACHE_DIR" "$ROOTFS_DIR/var/cache/apt/archives"
  if compgen -G "$APT_CACHE_DIR"/*.deb >/dev/null 2>&1; then
    CACHED_N="$(ls -1 "$APT_CACHE_DIR"/*.deb 2>/dev/null | wc -l)"
    log "  预置 $CACHED_N 个缓存 .deb → chroot archives（免重复下载）"
    cp -n "$APT_CACHE_DIR"/*.deb "$ROOTFS_DIR/var/cache/apt/archives/" 2>/dev/null || true
  fi
fi
cp "$PACKAGES_FILE" "$ROOTFS_DIR/packages.list"
chroot "$ROOTFS_DIR" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends $(grep -vE '^\s*#' /packages.list | tr "\n" " " | sed "s/  */ /g")
'
# 先回存本轮下载的 .deb（含依赖），再 clean——顺序不可颠倒，
# 否则 apt-get clean 清空 archives 后无包可存。
if [[ -n "$APT_CACHE_DIR" ]]; then
  cp -n "$ROOTFS_DIR"/var/cache/apt/archives/*.deb "$APT_CACHE_DIR"/ 2>/dev/null || true
  log "  deb 缓存已回存，当前共 $(ls -1 "$APT_CACHE_DIR"/*.deb 2>/dev/null | wc -l) 个包"
fi
chroot "$ROOTFS_DIR" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get clean'

# ---------------------------------------------------------------- 6. 覆盖层
log "第 6 步：应用 rootfs-overlay 覆盖层"
# --chmod 只约束目录，文件保留覆盖层自身的权限位。
# 此前的 Fu=rw,Fg=r,Fo=r 会把每个文件强制成 644，把覆盖层脚本的 x 位一起剥掉
# （git 对这些文件记录的 mode 本来就不一致），事后只能靠 shebang 扫描补回。
rsync -a --chmod=Du=rwx,Dg=rx,Do=rx "$OVERLAY_DIR/" "$ROOTFS_DIR/"

# 固件下载在构建树中，不会随 overlay 自动进入 Debian rootfs。
# MT7992 与 MT7987 内置 2.5G PHY 都在运行时从 /usr/lib/firmware 加载。
log "  安装 MT7992 / MT7987 固件到 Debian rootfs"
install -d -m 0755 "$ROOTFS_DIR/usr/lib/firmware/mediatek"
cp -a "$FIRMWARE_DIR/mediatek/." "$ROOTFS_DIR/usr/lib/firmware/mediatek/"
for firmware in \
  mt7996/mt7992_dsp_23.bin \
  mt7996/mt7992_eeprom_23.bin \
  mt7996/mt7992_eeprom_23_2i5i.bin \
  mt7996/mt7992_rom_patch_23.bin \
  mt7996/mt7992_wa_23.bin \
  mt7996/mt7992_wm_23.bin \
  mt7987/i2p5ge-phy-DSPBitTb.bin \
  mt7987/i2p5ge-phy-pmb.bin; do
  [[ -s "$ROOTFS_DIR/usr/lib/firmware/mediatek/$firmware" ]] || \
    die "固件未进入 rootfs 或为空：/usr/lib/firmware/mediatek/$firmware"
done

# 【为什么还要「扫描」——h5000m-led.sh 曾因漏列变成不可执行】
# 原先依赖硬编码白名单逐条 chmod 0755，恰好漏了 h5000m-led.sh，于是 systemd 直接报：
#     h5000m-led-boot.service: Main process exited, code=exited, status=203/EXEC
#     h5000m-led-boot.service: Failed with result 'exit-code'
# （QEMU 虚拟机已复现；注意 bash -n 语法检查不读执行位，测不出来这类问题。）
# 白名单每新增一个脚本就要记得同步，是不可持续的做法 → 改为按内容判定：
# 凡覆盖层里带 shebang 的脚本一律 0755，永不遗漏；纯数据文件（如 sshd_config）
# 首行不是 #!，不受影响，保持 0644。
#
# 扫描范围已扩大到**整个覆盖层**（原先只扫 usr/local/{sbin,bin} 与 NM dispatcher.d，
# 落在 etc/mt5700、etc/systemd 等处的钩子脚本同样会因缺 x 位报 203/EXEC）。
# 清单先在宿主机侧的 $OVERLAY_DIR 上算出来，rsync 之后再按清单 chmod，
# 因此不会误改 Debian 包自带文件的权限位。
OVERLAY_SCRIPT_LIST="$(mktemp)"
( cd "$OVERLAY_DIR" && find . -type f -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
    head -c 2 "$f" 2>/dev/null | grep -q '#!' && printf '%s\n' "$f"
  done ) > "$OVERLAY_SCRIPT_LIST"

log "  按 shebang 扫描并修复覆盖层脚本可执行位（范围：整个覆盖层）"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$ROOTFS_DIR/${rel#./}"
    [ -f "$f" ] || continue
    if [ ! -x "$f" ]; then
        chmod 0755 "$f"
        log "    +x ${rel#./}"
    fi
done < "$OVERLAY_SCRIPT_LIST"

# 幂等自检：覆盖层内不得残留「有 shebang 却无执行位」的脚本，否则 systemd 必报 203/EXEC
BAD_EXEC=$(while IFS= read -r rel; do
               [ -n "$rel" ] || continue
               f="$ROOTFS_DIR/${rel#./}"
               [ -f "$f" ] || continue
               [ -x "$f" ] || printf '%s\n' "${rel#./}"
           done < "$OVERLAY_SCRIPT_LIST")
rm -f "$OVERLAY_SCRIPT_LIST"
if [ -n "$BAD_EXEC" ]; then
    echo "[build-rootfs] 警告：以下脚本缺可执行位，systemd 将报 203/EXEC："
    echo "$BAD_EXEC" | sed 's/^/    /'
else
    log "  覆盖层脚本可执行位校验通过"
fi

# ---- SSH 主配置兜底（必须在宿主机侧执行，勿搬进 chroot 脚本）----
# 【为什么不能写进第 10 步的 chroot bash -c '...'】
# 第 10 步整段脚本本体是单引号字符串（chroot "$ROOTFS_DIR" /bin/bash -e -c ' ... '），
# 里面靠 '"$VAR"' 这种技巧注入变量。任何字面单引号都会提前闭合外层串，
# 使后续内容泄漏到外层 shell —— 曾导致 CI "unexpected end of file" 直接构建失败
# （run 37386212969）。故凡涉及引号较复杂的操作，一律放在宿主机侧用 $ROOTFS_DIR 前缀处理。
#
# 【为什么必须有这段】OpenSSH ≥ 9.9 / Debian 13 起 sshd_config 不再是 dpkg conffile，
# 官方模板位于 /usr/share/openssh/sshd_config，需 postinst 经 ucf 落地，而 debootstrap
# + chroot 链路不会触发该环节。主配置缺失 → sshd 直接 "No such file or directory" 退出
# → restart limit hit → headless 设备刷完无法管理。
SSHD_CFG="$ROOTFS_DIR/etc/ssh/sshd_config"
SSHD_TMPL="$ROOTFS_DIR/usr/share/openssh/sshd_config"
if [ ! -f "$SSHD_CFG" ] && [ -f "$SSHD_TMPL" ]; then
    log "  警告：$SSHD_CFG 缺失，回落到 openssh 官方模板"
    install -m 0644 "$SSHD_TMPL" "$SSHD_CFG"
fi
# 主配置必须 Include sshd_config.d，否则 90-h5000m.conf 的定制会被静默忽略
if [ -f "$SSHD_CFG" ] && ! grep -q "^Include /etc/ssh/sshd_config.d/" "$SSHD_CFG"; then
    sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" "$SSHD_CFG"
    log "  已为 sshd_config 补 Include /etc/ssh/sshd_config.d/*.conf"
fi
if [ -f "$SSHD_CFG" ]; then
    log "  sshd_config 主配置就位（$SSHD_CFG）"
else
    echo "[build-rootfs] 警告：sshd_config 仍然缺失，SSH 将无法启动"
fi

# ---------------------------------------------------------------- 7. luci-app-mt5700（Debian 分支）预装
# 单服务架构：at-webserver 一体化承载 WebUI + HTTP API + WebSocket（0.0.0.0:9000），
# 移除 OpenWrt/LuCI/ubus/rpcd/UCI 依赖；安装布局与上游 debian/install.sh 一致。
log "第 7 步：预装 luci-app-mt5700 at-webserver（Debian 分支，:9000）"
for f in "$MT5700_DIR/at-webserver" \
         "$MT5700_DIR/debian/config.json" \
         "$MT5700_DIR/debian/on-uplink.sh" \
         "$MT5700_DIR/debian/at-webserver.service"; do
  [[ -f "$f" ]] || die "缺少 $f。请先运行 build/build-mt5700.sh（或用 --mt5700-dir 指定 staging 目录）"
done
[[ -d "$MT5700_DIR/webui" ]] || die "缺少 $MT5700_DIR/webui（staging 不完整，重新运行 build/build-mt5700.sh）"

install -d -m 0755 "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/etc/mt5700" \
                   "$ROOTFS_DIR/usr/share/mt5700" "$ROOTFS_DIR/etc/systemd/system"
# 后端二进制 + WebUI 静态资源（后端经 web_root 直接托管）
install -m 0755 "$MT5700_DIR/at-webserver" "$ROOTFS_DIR/usr/bin/at-webserver"
rsync -a --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r \
  "$MT5700_DIR/webui/" "$ROOTFS_DIR/usr/share/mt5700/webui/"
# 配置与拨号钩子（config.json: http_bind=0.0.0.0 / http_port=9000，LAN 可直达；
# WAN/5G 上行侧由 nftables input policy drop 拦截，见 rootfs-overlay/etc/nftables.conf）
install -m 0644 "$MT5700_DIR/debian/config.json"        "$ROOTFS_DIR/etc/mt5700/config.json"
install -m 0755 "$MT5700_DIR/debian/on-uplink.sh"       "$ROOTFS_DIR/etc/mt5700/on-uplink.sh"
# H5000M 由 NetworkManager 独占管理 eth2；避免插件沙箱内另起 DHCP 客户端抢 lease。
install -m 0755 "$OVERLAY_DIR/etc/mt5700/on-uplink.sh" "$ROOTFS_DIR/etc/mt5700/on-uplink.sh"
# systemd 单元（SupplementaryGroups=dialout 串口权限 + ProtectSystem=strict 安全基线）
install -m 0644 "$MT5700_DIR/debian/at-webserver.service" "$ROOTFS_DIR/etc/systemd/system/at-webserver.service"

# 产物自检：ELF 魔数 + aarch64 架构（构建机无需运行二进制）
python3 - "$ROOTFS_DIR/usr/bin/at-webserver" <<'PYEOF'
import struct, sys
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        hdr = f.read(20)
    if hdr[:4] != b"\x7fELF":
        raise SystemExit(f"[build-rootfs] ERROR: {path} 不是 ELF 文件")
    if struct.unpack_from("<H", hdr, 18)[0] != 183:  # EM_AARCH64
        raise SystemExit(f"[build-rootfs] ERROR: {path} 非 aarch64 架构")
print("[build-rootfs]   [OK] at-webserver ELF/aarch64 校验通过")
PYEOF
log "  [OK] at-webserver + webui + /etc/mt5700 配置已预装（来源见 $MT5700_DIR/PROVENANCE.txt）"

# ---------------------------------------------------------------- 8. Linux-Router 集成
log "第 8 步：集成 Linux-Router 到 $LINUX_ROUTER_DIR"
install -d -m 0755 "$ROOTFS_DIR$LINUX_ROUTER_DIR"
# install.sh / uninstall 属于部署期工具，随镜像分发等于给设备留一个
# 可被滥用的 root 级安装/卸载入口；文档同理，只占空间。运行镜像只需要运行时代码。
rsync -a \
  --exclude tests --exclude data --exclude ".git*" --exclude "*.pyc" --exclude __pycache__ \
  --exclude install.sh --exclude uninstall.sh --exclude "*.md" \
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
HOSTNAME="$HOSTNAME" awk '
  /^127\.0\.1\.1([[:space:]]|$)/ { print "127.0.1.1\t" ENVIRON["HOSTNAME"]; next }
  { print }
' "$ROOTFS_DIR/etc/hosts" > "$ROOTFS_DIR/etc/hosts.new" && \
  mv -f "$ROOTFS_DIR/etc/hosts.new" "$ROOTFS_DIR/etc/hosts"

# 整段 chroot 配置已抽到 build/rootfs/chroot-finalize.sh：它原先是本文件里的
# heredoc 字符串，shellcheck 完全看不到，语法错误要等真机构建才暴露。
# 现在它进入 CI 的 bash -n 与 shellcheck 覆盖范围。
install -m 0755 "$CHROOT_FINALIZE_SCRIPT" "$ROOTFS_DIR/tmp/chroot-finalize.sh"
chroot "$ROOTFS_DIR" /bin/bash /tmp/chroot-finalize.sh \
  "$HOSTNAME" "$TIMEZONE" "$ADMIN_PASSWORD" "$ROOT_PASSWORD" \
  "$LINUX_ROUTER_DIR" "$LINUX_ROUTER_DATA"
rm -f "$ROOTFS_DIR/tmp/chroot-finalize.sh"

# 清理构建期文件
rm -f "$ROOTFS_DIR/packages.list"
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# ---------------------------------------------------------------- 11. 打包
log "第 11 步：打包"
# 预生成凭据清单副本（供构建机/交付查看，不含密钥文件本身）
cat > "$OUT_DIR/rootfs/initial-credentials.txt" <<CRED
root(SSH/串口): $ROOT_PASSWORD
WebUI admin:    $ADMIN_PASSWORD
CRED
chmod 0600 "$OUT_DIR/rootfs/initial-credentials.txt"

if [[ "$SKIP_TAR" -eq 1 ]]; then
  log "跳过 tar.zst 打包（--skip-tar）：SquashFS 方案由 build/make-squashfs.sh 直接消费树 $ROOTFS_DIR"
else
  log "压缩中（zstd）..."
  tar --numeric-owner --xattrs --acls -C "$ROOTFS_DIR" -c . | zstd -q -T0 -o "$ROOTFS_TAR"
  log "完成。RootFS: $ROOTFS_TAR"
  ls -lh "$ROOTFS_TAR"
fi
log "初始凭据已写入 $OUT_DIR/rootfs/initial-credentials.txt"
