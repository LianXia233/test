#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Validate the p5 boot-layer image used by this repository.
set -Eeuo pipefail

die() { printf '[rootfs-image-check] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <rootfs.ext4>"
image="$1"
[[ -f "$image" ]] || die "rootfs 镜像不存在：$image"
command -v debugfs >/dev/null 2>&1 || \
  die "缺少 debugfs（安装 e2fsprogs 后重试）"

stat_path() {
  debugfs -R "stat $1" "$image" 2>/dev/null || true
}

for path in /sbin/init /usr/bin/busybox; do
  metadata="$(stat_path "$path")"
  [[ "$metadata" == *"Type: regular"* ]] && \
    grep -Eq 'Mode:[[:space:]]*0755([[:space:]]|$)' <<<"$metadata" || \
    die "$path 缺失或不可执行；这个 p5 必须是本项目的 Debian 引导层 ext4 镜像"
done

metadata="$(stat_path /squashfs/rootfs.squashfs)"
[[ "$metadata" == *"Type: regular"* && "$metadata" == *"Size:"* ]] || \
  die "/squashfs/rootfs.squashfs 缺失；这个 p5 不是本项目的引导层镜像"

init_contents="$(debugfs -R 'cat /sbin/init' "$image" 2>/dev/null || true)"
init_shebang="${init_contents%%$'\n'*}"
[[ "$init_shebang" == '#!/usr/bin/busybox sh' ]] || \
  die "/sbin/init shebang 不匹配；预期 #!/usr/bin/busybox sh"

printf '[rootfs-image-check] [OK] 可执行 init、BusyBox 与 SquashFS 根文件系统齐全：%s\n' "$image"
