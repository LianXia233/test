#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — Debian 13 固件获取脚本
#
# 从 linux-firmware 官方仓库下载 H5000M 所需固件，放置到 build/rootfs/firmware/：
#   - MT7992 Wi-Fi       -> mediatek/mt7996/mt7992_*.bin
#   - MT7987 内置 2.5G PHY -> mediatek/mt7987/i2p5ge-phy-*.bin
#
# 说明：
#   - wireless-regdb 由 Debian 13 的 wireless-regdb 包安装（/usr/lib/firmware/wireless/），
#     不在此处重复下载。
#   - 跨平台：仅使用 Python 标准库（urllib / pathlib / argparse），
#     不依赖 curl / wget / git，Linux / Windows / macOS 均可运行。
#   - 失败策略：required=True 的固件下载失败即报错；可选固件失败仅告警，
#     避免网络抖动导致整包构建中断。
#
# 用法：
#   python3 scripts/fetch-firmware.py [--out build/rootfs/firmware]
#                                     [--branch master] [--skip-verify]

import argparse
import datetime
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# linux-firmware 仓库镜像源（按顺序回退）
# 注意：
#   - GitLab 镜像 kernel-firmware/linux-firmware 的默认分支是 main（不是 master），
#     走 API 通道（/repository/files/<quoted>/raw），路径需 URL 编码（/ -> %2F）。
#   - git.kernel.org 的 plain 接口不加 ?h= 参数（默认 HEAD）。
#   - 不使用 raw.githubusercontent.com/torvalds/linux-firmware：该仓库不存在。
MIRRORS = (
    "https://gitlab.com/api/v4/projects/48890189/repository/files/{quoted_path}/raw?ref=main",
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/{path}",
)

# 固件清单: 仓库相对路径 -> {"dest": 目标子目录, "required": 是否必需}
FIRMWARE = {
    # ---- MT7992 Wi-Fi（mt76/mt7996 驱动加载路径为 mediatek/mt7996/）----
    "mediatek/mt7996/mt7992_dsp_23.bin": {"dest": "mediatek/mt7996", "required": True},
    "mediatek/mt7996/mt7992_eeprom_23.bin": {"dest": "mediatek/mt7996", "required": True},
    "mediatek/mt7996/mt7992_eeprom_23_2i5i.bin": {"dest": "mediatek/mt7996", "required": True},
    "mediatek/mt7996/mt7992_rom_patch_23.bin": {"dest": "mediatek/mt7996", "required": True},
    "mediatek/mt7996/mt7992_wa_23.bin": {"dest": "mediatek/mt7996", "required": True},
    "mediatek/mt7996/mt7992_wm_23.bin": {"dest": "mediatek/mt7996", "required": True},
    # ---- MT7987 内置 2.5G PHY（mtk_2p5ge 驱动加载路径为 mediatek/mt7987/）----
    "mediatek/mt7987/i2p5ge-phy-DSPBitTb.bin": {"dest": "mediatek/mt7987", "required": True},
    "mediatek/mt7987/i2p5ge-phy-pmb.bin": {"dest": "mediatek/mt7987", "required": True},
}


def sha256_file(path: Path) -> str:
    """计算文件 sha256（分块读取，避免大文件占内存）。"""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, timeout: int = 60) -> None:
    """下载并原子写入目标文件。"""
    req = urllib.request.Request(url, headers={"User-Agent": "h5000m-debian13-firmware"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, dest.open("wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def fetch_one(rel_path: str, dest_subdir: str, out_dir: Path, branch: str,
              required: bool, skip_verify: bool) -> tuple[str, str | None]:
    """获取单个固件，返回 (状态, sha256)。状态为 ok / skip / fail。"""
    dest = out_dir / dest_subdir / Path(rel_path).name
    if dest.exists() and not skip_verify:
        print(f"  [SKIP] {rel_path} 已存在（如需强制刷新请删除 {dest}）")
        return "skip", sha256_file(dest)

    last_err = None
    for mirror in MIRRORS:
        url = mirror.format(branch=branch, path=rel_path,
                            quoted_path=urllib.parse.quote(rel_path, safe=""))
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + ".part")
            download(url, tmp)
            tmp.replace(dest)
            digest = sha256_file(dest)
            print(f"  [OK]   {rel_path} ({digest[:12]}…)")
            return "ok", digest
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as e:
            last_err = e
            print(f"  [..]   {rel_path} 从 {url} 获取失败：{e}")

    if required:
        raise RuntimeError(f"必需固件 {rel_path} 全部源获取失败: {last_err}")
    print(f"  [WARN] 可选固件 {rel_path} 获取失败，继续（{last_err}）")
    return "fail", None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Hiveton H5000M — Debian 13 固件获取脚本",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    script_dir = Path(__file__).resolve().parent
    default_out = script_dir.parent / "build" / "rootfs" / "firmware"
    parser.add_argument("--out", type=Path, default=default_out,
                        help="固件输出目录")
    parser.add_argument("--branch", default="master",
                        help="linux-firmware 分支/标签（如 master）")
    parser.add_argument("--skip-verify", action="store_true",
                        help="跳过已存在文件的校验")
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"[fetch-firmware] 输出目录: {out_dir}")
    print(f"[fetch-firmware] 镜像分支: {args.branch}")

    results = {"ok": [], "skip": [], "fail": []}
    for rel_path, meta in FIRMWARE.items():
        status, digest = fetch_one(
            rel_path, meta["dest"], out_dir, args.branch,
            meta["required"], args.skip_verify,
        )
        results[status].append({
            "path": rel_path,
            "dest": str(out_dir / meta["dest"] / Path(rel_path).name),
            "sha256": digest,
            "required": meta["required"],
        })

    manifest = out_dir / "firmware-manifest.json"
    manifest.write_text(
        json.dumps({
            "branch": args.branch,
            "source": "linux-firmware",
            "downloaded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "firmware": results,
        }, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    ok = len(results["ok"])
    skip = len(results["skip"])
    fail = len(results["fail"])
    print(f"\n[fetch-firmware] 完成: 新下载 {ok}，已存在 {skip}，失败 {fail}")
    print(f"[fetch-firmware] 清单: {manifest}")
    return 1 if fail and any(f["required"] for f in results["fail"]) else 0


if __name__ == "__main__":
    sys.exit(main())
