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
# 【供应链安全：版本 pin + 强制 sha256】
#   此前默认跟随镜像的默认分支（GitLab 写死 ref=main，git.kernel.org 走 plain=HEAD），
#   且 --branch 参数因为没出现在 URL 模板里而完全无效 —— 同一份脚本在不同日期跑
#   会拉到不同的二进制，构建不可复现，也无法察觉上游被投毒/误改。现在：
#     * 默认 pin 到 linux-firmware 的发布 tag（PINNED_REF），可用 --ref 覆盖；
#     * 每个固件都有登记在案的 sha256，下载后强制比对，不匹配即丢弃并报错；
#     * 已存在的文件在 SKIP 之前也会校验，本地副本被改坏同样会被拦住。
#   确需更换版本时：先改 PINNED_REF，再照打印出的实际摘要更新 EXPECTED_SHA256。
#
# 用法：
#   python3 scripts/fetch-firmware.py [--out build/rootfs/firmware]
#                                     [--ref 20260916] [--skip-verify]

import argparse
import datetime
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------- 版本 pin
# linux-firmware 的发布 tag（https://gitlab.com/kernel-firmware/linux-firmware/-/tags）
PINNED_REF = "20260916"

# linux-firmware 仓库镜像源（按顺序回退）
# 注意：
#   - GitLab 镜像 kernel-firmware/linux-firmware 走 API 通道
#     （/repository/files/<quoted>/raw），路径需 URL 编码（/ -> %2F）。
#   - git.kernel.org 的 plain 接口用 ?h= 指定 ref。
#   - 不使用 raw.githubusercontent.com/torvalds/linux-firmware：该仓库不存在。
#   - 两个模板都必须带 {ref}，否则 --ref 会被静默忽略（历史 bug）。
MIRRORS = (
    "https://gitlab.com/api/v4/projects/48890189/repository/files/{quoted_path}/raw?ref={ref}",
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/{path}?h={ref}",
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

# ------------------------------------------------- 供应链基线（sha256 白名单）
# 取自 linux-firmware tag 20260916。任何一处不匹配都会让构建失败，
# 而不是把来路不明的二进制打进固件镜像。
EXPECTED_SHA256 = {
    "mediatek/mt7996/mt7992_dsp_23.bin":
        "43f2db9152dd9aaeb9c27848215445ee8a48978fb2d2f15b13a3af5ecb77e631",
    "mediatek/mt7996/mt7992_eeprom_23.bin":
        "ccc92839a805320e5f3708dcd9559bbfe5f741b4e8628f384e9f500aaf372275",
    "mediatek/mt7996/mt7992_eeprom_23_2i5i.bin":
        "f88ad725f82aa54269eba65f8e10b7eb9d652a3da46edde53c6a48f3960c7376",
    "mediatek/mt7996/mt7992_rom_patch_23.bin":
        "1577fb68e31bb6535ec7d5757fa07d0df5aa0c0024f6fa9d2da1423b3ca73248",
    "mediatek/mt7996/mt7992_wa_23.bin":
        "667a345e351d1a3c3d0d34989794aa8c615e478dc6b785a1fe5f9aee1f587c20",
    "mediatek/mt7996/mt7992_wm_23.bin":
        "74dc06194134a79e30d8ebd1d1fbe0a62f1deabda9efa592a4a0d32743811381",
    "mediatek/mt7987/i2p5ge-phy-DSPBitTb.bin":
        "1f7b7fd1c243576e04c16b98c649db1e3326f6a715556c2a56094bcd7d300d71",
    "mediatek/mt7987/i2p5ge-phy-pmb.bin":
        "941e3118493d5cb14323968ebc1193b23411d7c330a566014eeeb51c5ea7ed45",
}


def sha256_file(path: Path) -> str:
    """计算文件 sha256（分块读取，避免大文件占内存）。"""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_digest(rel_path: str, dest: Path, required: bool) -> tuple[bool, str]:
    """比对下载结果是否与登记的基线一致。不一致时立即删除，避免污染构建树。"""
    if rel_path not in EXPECTED_SHA256:
        print(f"  [WARN] {rel_path} 未登记 sha256 基线，跳过校验")
        return True, sha256_file(dest)

    digest = sha256_file(dest)
    expected = EXPECTED_SHA256[rel_path]
    if digest == expected:
        return True, digest

    try:
        dest.unlink()
    except OSError:
        pass
    message = (
        f"{rel_path} 校验失败：期望 {expected}，实际 {digest}。"
        f"已删除 {dest}；若确需升级请同步更新 EXPECTED_SHA256 与 PINNED_REF"
    )
    if required:
        raise RuntimeError(message)
    print(f"  [WARN] {message}")
    return False, digest


def download(url: str, dest: Path, timeout: int = 60) -> None:
    """下载并原子写入目标文件。"""
    req = urllib.request.Request(url, headers={"User-Agent": "h5000m-debian13-firmware"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, dest.open("wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def fetch_one(rel_path: str, dest_subdir: str, out_dir: Path, ref: str,
              required: bool, skip_verify: bool) -> tuple[str, str | None]:
    """获取单个固件，返回 (状态, sha256)。状态为 ok / skip / fail。"""
    dest = out_dir / dest_subdir / Path(rel_path).name
    if dest.exists() and not skip_verify:
        # 已存在的文件同样要过基线：半截下载或被改坏的本地副本不该被静默复用
        try:
            ok, digest = verify_digest(rel_path, dest, required)
        except RuntimeError as exc:
            print(f"  [..]   {rel_path} 本地副本校验失败，重新下载（{exc}）")
            ok, digest = False, None
        if ok:
            print(f"  [SKIP] {rel_path} 已存在且校验通过（如需强制刷新请删除 {dest}）")
            return "skip", digest

    last_err = None
    for mirror in MIRRORS:
        url = mirror.format(ref=ref, path=rel_path,
                            quoted_path=urllib.parse.quote(rel_path, safe=""))
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + ".part")
            download(url, tmp)
            tmp.replace(dest)
            ok, digest = verify_digest(rel_path, dest, required)
            if not ok:
                last_err = RuntimeError(f"{rel_path} sha256 不匹配")
                continue
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
    parser.add_argument("--ref", default=PINNED_REF,
                        help="linux-firmware 的 tag / 分支 / commit")
    parser.add_argument("--skip-verify", action="store_true",
                        help="跳过已存在文件的校验")
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"[fetch-firmware] 输出目录: {out_dir}")
    print(f"[fetch-firmware] 镜像 ref : {args.ref}")
    if args.ref != PINNED_REF:
        print(f"[fetch-firmware] 警告：已指定非登记 ref（登记值 {PINNED_REF}），"
              f"sha256 基线可能不匹配，请同步更新 EXPECTED_SHA256")

    results = {"ok": [], "skip": [], "fail": []}
    for rel_path, meta in FIRMWARE.items():
        status, digest = fetch_one(
            rel_path, meta["dest"], out_dir, args.ref,
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
            "ref": args.ref,
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
