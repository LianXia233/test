#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_charsets.py —— 生成中文字库的字符集（tools/gen_fonts.sh 的第一步）。

思路：不去手写一份「界面要用哪些字」的清单（一定会漏），而是取三个来源的并集：

  1. GB2312 **一级汉字 3755 个**（0xB0A1 ~ 0xD7F9）
     这批字覆盖了日常用字的绝大多数，一个中文界面基本逃不出这个范围。
     代价是"多塞一些可能一辈子用不上的字"，收益是"改文案基本不用重新生成字库"。
  2. 中文标点（GB2312 的符号区，不在一级字里）
  3. **源码里出现过的所有汉字** —— 扫 OpenWrtMonitor.ino / ui_theme.h / ui_fonts.h
     这一步保证了「重新生成字库」之后 `check_font.py` 不会反而开始报漏字

另外再写一份 cn_small.txt，给 24px 那个大字库用：只有数字、单位、少量按键文案。

用法
----
    python3 tools/gen_charsets.py [输出目录]        # 默认写到 ../fonts
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_FILES = ['OpenWrtMonitor.ino', 'ui_theme.h', 'ui_fonts.h']

# ---------------------------------------------------------------- 一级汉字
def gb2312_level1():
    """GB2312 一级字库：16 区到 55 区，每区 94 位，共 3755 字。"""
    out = []
    for hi in range(0xB0, 0xD8):          # 区：16~55
        for lo in range(0xA1, 0xFF):      # 位：1~94
            try:
                out.append(bytes([hi, lo]).decode('gb2312'))
            except UnicodeDecodeError:
                continue
    return out


# ---------------------------------------------------------------- 标点 / 单位
# LV_SYMBOL_BULLET 用的圆点（U+2022）不在一级字里，单独记上
PUNCT = "、。，．；：？！…—～（）《》〈〉「」『』【】〔〕·々•" \
        "＋－×÷＝＜＞≤≥±°′″％‰￥＄" \
        "←↑→↓√∞＃＠※☆★●○■□▲▼"

UNITS = "毫秒分钟小时天周月年字节兆吉太百分等级度刻"

# 一些将来大概率会用上的字，提前兜进去，省得动不动就要重生成
EXTRA = (
    "开关启停加删改查新的旧大小高低快慢好坏有无是否对错成功错误警告信息调试"
    "请输入确认取消忽略重试详情全部清隐advanced显示隐藏帮助关于版本更新"
)

# 24px 大字库：只放数字、单位、少量按键文案，多一个都嫌贵。
# 注意：凡是用 UI_F_L / UI_F_NUM 画的字面文案，字必须在这里，否则屏上是方框。
CN_SMALL_PREFIX = "0123456789%./: -+KMBGT"
CN_SMALL_HAN = "天时分秒确定退格返回保存取消" \
                "等待推送画面正在投屏已停止"      # 推屏页的大状态字


def source_han():
    """把源码里写过的汉字全捞出来（含注释，宁多勿少）。"""
    han = set()
    for name in SRC_FILES:
        p = ROOT / name
        if not p.exists():
            continue
        for m in re.finditer(r'[　-鿿＀-￯]', p.read_text(encoding='utf-8')):
            han.add(m.group(0))
    return han


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT.parent / 'fonts'
    outdir.mkdir(parents=True, exist_ok=True)

    src = source_han()
    chars = set(gb2312_level1()) | set(PUNCT) | set(UNITS) | {c for c in EXTRA if ord(c) > 127} | src

    full = ''.join(sorted(chars))
    small = ''.join(sorted(set(CN_SMALL_PREFIX) | set(CN_SMALL_HAN)))

    (outdir / 'cn_full.txt').write_text(full, encoding='utf-8')
    (outdir / 'cn_small.txt').write_text(small, encoding='utf-8')

    print('GB2312 一级字   %5d' % len(gb2312_level1()))
    print('源码里出现的字 %5d' % len(src))
    print('cn_full.txt     %5d 字 -> %s' % (len(full), outdir / 'cn_full.txt'))
    print('cn_small.txt    %5d 字 -> %s' % (len(small), outdir / 'cn_small.txt'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
