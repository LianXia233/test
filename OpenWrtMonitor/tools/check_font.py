#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_font.py —— 校验固件文案里的每个字是否都已经打进 lv_font_conv 生成的子集里。

背景
----
中文字体是按「用得到的字」子集后打进固件的，漏一个字屏幕上就是一个漏字方框，
而且编译、烧录都看不出来。这个脚本把 C 源里的中文字全部提出来，
再去解析 ui_font_cn_16.c / ui_font_cn_24.c 的 cmap 表，交叉对比。

用法
----
    python3 tools/check_font.py [源码目录] [字体文件...]

缺省是校验 OpenWrtMonitor.ino 里 ui_*() 调用到的字面文案。
加 --all 会把整个文件（含注释里的中文）一起算进去，用来提前给字体挑字。

lv_font_conv 的 cmap 编码（对应 LVGL 的 get_glyph_dsc_id()）：
    FORMAT0_TINY   : 连续区间，glyph = glyph_id_start + (cp - range_start)
    SPARSE_TINY    : unicode_list[i] == cp - range_start，glyph = glyph_id_start + i
    SPARSE_FULL    : 同上，但 glyph = glyph_id_start + glyph_id_ofs_list[i]
"""
import re
import sys
from pathlib import Path

CMAP_RE = re.compile(
    r'\{\s*\.range_start\s*=\s*(\d+)\s*,\s*\.range_length\s*=\s*(\d+)\s*,'
    r'\s*\.glyph_id_start\s*=\s*(\d+)\s*,'
    r'\s*\.unicode_list\s*=\s*(\w+)\s*,\s*\.glyph_id_ofs_list\s*=\s*(\w+)\s*,'
    r'\s*\.list_length\s*=\s*(\d+)\s*,\s*\.type\s*=\s*LV_FONT_FMT_TXT_CMAP_(\w+)',
    re.S)

LIST_RE = lambda name: re.compile(
    r'static const uint16_t %s\[\] = \{(.*?)\};' % name, re.S)


def parse_font(path):
    """把 .c 字体文件里出现过的所有 Unicode 码位读出来。"""
    src = path.read_text(encoding='utf-8', errors='replace')

    def read_list(name):
        m = LIST_RE(name).search(src)
        if not m:
            return []
        return [int(x.strip(), 16) for x in m.group(1).replace('\n', ' ').split(',')
                if x.strip()]

    cps = set()
    for rs, rl, gis, ulist, ofslist, llen, ctype in CMAP_RE.findall(src):
        rs, rl, gis, llen = int(rs), int(rl), int(gis), int(llen)
        vals = read_list(ulist) if ulist != 'NULL' else []
        if ctype == 'FORMAT0_TINY' or ctype == 'FORMAT0_FULL':
            cps |= set(range(rs, rs + rl))
        else:                                   # SPARSE_*
            cps |= {rs + v for v in vals}
    return cps


def iter_src_texts(path, all_text=False):
    """从 C/C++ 源码里捞出 UI 字面文案。"""
    src = path.read_text(encoding='utf-8', errors='replace')
    if all_text:                                # 连注释里的中文一起算
        yield from re.findall(r'"([^"\\\n]*)"', src)
        return
    # 只认放置在 UI 构造函数里的字符串
    call = re.compile(
        r'\b(?:ui_label|ui_kv|ui_title_row|ui_button|ui_toast|ui_set_text|'
        r'lv_label_set_text|lv_textarea_set_placeholder_text|'
        r'lv_msdbox\w*|snprintf)\s*\(([^;]*?)\);', re.S)
    for m in call.finditer(src):
        yield from re.findall(r'"([^"\\]*)"', m.group(1))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    all_text = '--all' in sys.argv
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    fonts = [Path(a) for a in args[1:]] or sorted(root.glob('ui_font_cn_*.c'))
    srcs = sorted(root.glob('*.ino')) + sorted(root.glob('*.h'))

    if not fonts:
        print('!! 找不到字体文件', file=sys.stderr)
        return 2

    have = set()
    report = []
    for f in fonts:
        cps = parse_font(f)
        have |= cps
        report.append('  %-22s %5d 字形' % (f.name, len(cps)))

    print('== 字体 ==')
    print('\n'.join(report))
    print('  合计                    %5d 字形（去重后）' % len(have))

    need = set()
    for s in srcs:
        for t in iter_src_texts(s, all_text):
            need |= {c for c in t if ord(c) > 127}

    # 注意：have 里存的是「码位 int」，need 里是「字符 str」，做差集前先统一成字符
    covered = {chr(cp) for cp in have}
    miss = sorted(need - covered)
    print('\n== 文案 -> 字形 ==')
    print('  源码用到的非 ASCII 字符：%d' % len(need))
    if miss:
        print('  缺失 %d 个：%s' % (len(miss), ''.join(miss)))
        print('  补进去的办法：把上面这些字符追加到 cn_full.txt，重跑 tools/gen_fonts.sh')
        return 1
    print('  全部命中 ✓')
    return 0


if __name__ == '__main__':
    sys.exit(main())
