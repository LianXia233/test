#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# luci-app-mt5700（Debian 分支）at-webserver 交叉编译与预装 staging 脚本
#
# 来源：https://github.com/LianXia233/luci-app-mt5700/tree/Debian（GPL-3.0）
#   单一 Rust 后端 at-webserver：HTTP API(0.0.0.0:9000) + WebSocket + 静态
#   WebUI 托管；移除 OpenWrt/LuCI/ubus/rpcd/UCI 依赖。依赖全部为纯 Rust
#   （tokio/serde/rustls），交叉编译无 C 库依赖。
#
# 固定源码版本（MT5700_COMMIT）保证构建可复现；升级插件时同步更新该值。
#
# 流程：
#   1. 获取源码（--src-dir 指定已有克隆优先；否则浅克隆固定 commit）
#   2. cargo 交叉编译 aarch64：
#        gnu（默认）：动态链接 glibc（需 gcc-aarch64-linux-gnu）；构建机 glibc
#                     版本不得高于目标机（Debian 13 = 2.41），GitHub runner
#                     ubuntu-24.04（2.39）满足；rootfs 已含 libgcc-s1
#        musl        ：静态自包含链接（rust-lld）；但 rustls → ring 含 C/asm
#                     代码，需要 aarch64-linux-musl-gcc（apt 无此包），仅在
#                     具备该工具链的环境使用
#   3. staging 到 $OUT_DIR/mt5700/：
#        at-webserver               aarch64 二进制（ELF 自检）
#        webui/                     静态 WebUI 资源
#        debian/config.json         默认配置（http_bind=0.0.0.0、:9000）
#        debian/on-uplink.sh        拨号就绪钩子
#        debian/at-webserver.service  systemd 单元（与上游 install.sh 布局一致）
#   4. 输出供 build/build-rootfs.sh --mt5700-dir 消费
#
# 用法：
#   bash build/build-mt5700.sh --out out [--src-dir /path/to/luci-app-mt5700] [--target gnu|musl]
#
# 平台：Linux/macOS（仅编译，不触碰目标 rootfs）。
# 行尾：本文件为 LF。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
SRC_DIR=""
MT5700_REPO="https://github.com/LianXia233/luci-app-mt5700.git"
# luci-app-mt5700 Debian 分支 head（feat!: Debian 分支——独立 WebUI + HTTP API 后端）
MT5700_COMMIT="76d1f82e5a00b6622da15ffb64d8be630073ffb2"
TARGET_KIND="gnu"         # gnu=动态 glibc（默认，见头注释）；musl=需 aarch64-linux-musl-gcc

log() { printf '[build-mt5700] %s\n' "$*"; }
die() { printf '[build-mt5700] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT_DIR="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --target)  TARGET_KIND="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

command -v cargo >/dev/null 2>&1 || die "缺少 cargo（Rust 工具链）。安装：curl https://sh.rustup.rs -sSf | sh -s -- -y"
command -v git    >/dev/null 2>&1 || die "缺少 git"

case "$TARGET_KIND" in
  gnu)
    RUST_TARGET="aarch64-unknown-linux-gnu"
    command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || \
      die "gnu 目标需要交叉链接器：sudo apt-get install gcc-aarch64-linux-gnu"
    ;;
  musl)
    # rustls → ring 的 C/asm 代码需要 musl 交叉 C 编译器（apt 无此包，需自备）
    RUST_TARGET="aarch64-unknown-linux-musl"
    command -v aarch64-linux-musl-gcc >/dev/null 2>&1 || \
      die "musl 目标需要 aarch64-linux-musl-gcc（ring 的 C 代码编译；无此工具链请用 --target gnu）"
    ;;
  *) die "未知 --target：$TARGET_KIND（可选 gnu|musl）" ;;
esac

# ---------------------------------------------------------------- 1. 获取源码
TMP_CLONE=""
cleanup() { [[ -n "$TMP_CLONE" ]] && rm -rf "$TMP_CLONE" || true; }
trap cleanup EXIT

if [[ -n "$SRC_DIR" ]]; then
  log "使用指定源码目录：$SRC_DIR"
else
  TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/mt5700-src.XXXXXX")"
  log "浅克隆 luci-app-mt5700（Debian 分支，固定 commit ${MT5700_COMMIT:0:12}）"
  git init -q "$TMP_CLONE/repo"
  git -C "$TMP_CLONE/repo" remote add origin "$MT5700_REPO"
  # fetch 固定 commit（GitHub 支持 allow-any-sha1-in-want），保证版本可复现
  git -C "$TMP_CLONE/repo" fetch -q --depth 1 origin "$MT5700_COMMIT" \
    || die "拉取 $MT5700_COMMIT 失败（仓库/网络/commit 是否有效？）"
  git -C "$TMP_CLONE/repo" checkout -q FETCH_HEAD
  SRC_DIR="$TMP_CLONE/repo"
fi

for need in src/rust/Cargo.toml webui debian/config.json debian/on-uplink.sh debian/at-webserver.service; do
  [[ -e "$SRC_DIR/$need" ]] || die "源码结构缺失：$SRC_DIR/$need（是否为 Debian 分支？）"
done
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
log "  源码 commit：$ACTUAL_COMMIT"

# ---------------------------------------------------------------- 2. 交叉编译
# rustup 管理的工具链需显式安装目标平台 std；非 rustup（如发行版 apt）则要求
# 系统已带该 target，编译失败会自然报错。
if command -v rustup >/dev/null 2>&1; then
  log "安装 Rust 目标平台 std：$RUST_TARGET"
  rustup target add "$RUST_TARGET"
fi

log "cargo 编译（--release --target $RUST_TARGET，opt-level=s + LTO + strip）"
BUILD_LOG="$OUT_DIR/mt5700-build.log"
mkdir -p "$OUT_DIR"
case "$TARGET_KIND" in
  gnu)
    RUSTFLAGS="-C linker=aarch64-linux-gnu-gcc" \
      cargo build --release --target "$RUST_TARGET" \
      --manifest-path "$SRC_DIR/src/rust/Cargo.toml" >"$BUILD_LOG" 2>&1 \
      || { tail -40 "$BUILD_LOG" >&2; die "cargo 编译失败（详见 $BUILD_LOG）"; }
    ;;
  musl)
    RUSTFLAGS="-C linker=aarch64-linux-musl-gcc" \
      cargo build --release --target "$RUST_TARGET" \
      --manifest-path "$SRC_DIR/src/rust/Cargo.toml" >"$BUILD_LOG" 2>&1 \
      || { tail -40 "$BUILD_LOG" >&2; die "cargo 编译失败（详见 $BUILD_LOG）"; }
    ;;
esac

BIN="$SRC_DIR/src/rust/target/$RUST_TARGET/release/at-webserver"
[[ -f "$BIN" ]] || die "编译产物未找到：$BIN"

# ---------------------------------------------------------------- 3. staging
STAGE="$OUT_DIR/mt5700"
log "staging → $STAGE"
rm -rf "$STAGE"
install -d -m 0755 "$STAGE"
install -m 0755 "$BIN" "$STAGE/at-webserver"
cp -r "$SRC_DIR/webui" "$STAGE/webui"
find "$STAGE/webui" -type d -exec chmod 0755 {} +
find "$STAGE/webui" -type f -exec chmod 0644 {} +
install -d -m 0755 "$STAGE/debian"
install -m 0644 "$SRC_DIR/debian/config.json"        "$STAGE/debian/config.json"
install -m 0755 "$SRC_DIR/debian/on-uplink.sh"       "$STAGE/debian/on-uplink.sh"
install -m 0644 "$SRC_DIR/debian/at-webserver.service" "$STAGE/debian/at-webserver.service"

# 记录来源（与仓库内 PROVENANCE 惯例一致）
cat > "$STAGE/PROVENANCE.txt" <<EOF
at-webserver（luci-app-mt5700 Debian 分支）
repo:    $MT5700_REPO
branch:  Debian
commit:  $ACTUAL_COMMIT
target:  $RUST_TARGET
build:   cargo build --release（opt-level=s / LTO / strip）
license: GPL-3.0（上游仓库 LICENSE）
EOF

# ---------------------------------------------------------------- 4. ELF 自检
# 构建机无需运行 aarch64 二进制：校验 ELF 魔数 + EM_AARCH64 + 静态性
python3 - "$STAGE/at-webserver" "$TARGET_KIND" <<'PYEOF'
import struct, sys
path, kind = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    hdr = f.read(64)
if hdr[:4] != b"\x7fELF":
    raise SystemExit(f"[build-mt5700] ERROR: {path} 不是 ELF 文件")
if struct.unpack_from("<H", hdr, 18)[0] != 183:  # EM_AARCH64
    raise SystemExit(f"[build-mt5700] ERROR: {path} 非 aarch64 架构")
e_type = struct.unpack_from("<H", hdr, 16)[0]
print(f"[build-mt5700]   [OK] at-webserver ELF/aarch64 校验通过（e_type={e_type}, target={kind}）")
PYEOF

if command -v readelf >/dev/null 2>&1; then
  if readelf -l "$STAGE/at-webserver" 2>/dev/null | grep -q "INTERP"; then
    [[ "$TARGET_KIND" == "gnu" ]] || log "  [WARN] musl 目标产物含 INTERP（非预期，请检查）"
  else
    log "  [OK] 产物为静态链接（无动态链接器依赖）"
  fi
fi

log "完成。staging 产物："
ls -lh "$STAGE" "$STAGE/debian"
log "下一步：build/build-rootfs.sh --mt5700-dir $STAGE"
