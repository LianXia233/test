#!/usr/bin/env bash
# =============================================================================
# gen_fonts.sh —— 中文字库流水线（思源黑体 → LVGL 子集 .c）
#
# 产物：
#   ui_font_cn_16.c   16px，界面正文/标签，3995 字形，进 flash 约 331KB
#   ui_font_cn_24.c   24px，大数字/大字，  238 字形，进 flash 约  23KB
#
# 依赖：
#   pip3 install fonttools brotli      （pyftsubset）
#   npm i -g lv_font_conv              （lv_font_conv）
#   字体源：Noto Sans CJK（NotoSansCJK-Regular.ttc，或单独的 NotoSansSC-Regular.otf）
#
# 用法：
#   ./tools/gen_fonts.sh                          # 用默认路径
#   SRC_FONT=/path/to/xxx.otf ./tools/gen_fonts.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="${WORK:-$ROOT/.fontbuild}"

SRC_FONT="${SRC_FONT:-}"
CHAR_DIR="${CHAR_DIR:-$WORK}"
OUT_16="$ROOT/ui_font_cn_16.c"
OUT_24="$ROOT/ui_font_cn_24.c"

# 拉丁/标点区间也一并打进去：ASCII、Latin-1 补充、常用标点。
# 两个工具写法不一样，别写成一份：pyftsubset 用 --unicodes=U+XXXX-YYYY，
# lv_font_conv 用 -r 0xXXXX-0xYYYY（而且必须四位，写 0x00A0-00FF 会被拒）
UNI_RANGE="U+0020-007E,U+00A0-00FF,U+2010-203B"
RANGES="-r 0x20-0x7E -r 0xA0-0xFF -r 0x2010-0x203B"

# 24px 那个大字库只要 ASCII：多带上 0xA0-0xFF / 0x2010-0x203B 会掺进几个很高的字形
# （¶ ‾ 之类），line_height 会从 29 涨到 32 —— 而 ui_theme.h 里的 UI_LH_24 是 29，
# 所有卡片高度都按它算的，一涨就全乱。所以这里刻意只给 ASCII。
RANGES_24="-r 0x20-0x7E"

say() { printf '\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

command -v pyftsubset >/dev/null || die "缺 pyftsubset：pip3 install fonttools brotli"
command -v lv_font_conv >/dev/null || die "缺 lv_font_conv：npm i -g lv_font_conv"

# ---------------------------------------------------------------- 0. 找字体源
if [ -z "$SRC_FONT" ]; then
  for c in \
    /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc \
    /usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc \
    /usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf \
    /usr/share/fonts/opentype/noto/NotoSansSC-Regular.otf \
    "$WORK/NotoSansCJK-Regular.ttc" \
    "$WORK/NotoSansSC-Regular.otf"
  do
    [ -f "$c" ] && SRC_FONT="$c" && break
  done
fi
[ -f "${SRC_FONT:-}" ] || die "找不到思源黑体，用 SRC_FONT=/path/to/font 指定"

mkdir -p "$WORK"
say "字体源：$SRC_FONT"

# ---------------------------------------------------------------- 1. 字符集
say "生成字符集"
python3 "$HERE/gen_charsets.py" "$CHAR_DIR"
CN_FULL="$CHAR_DIR/cn_full.txt"
CN_SMALL="$CHAR_DIR/cn_small.txt"
[ -s "$CN_FULL" ] || die "cn_full.txt 是空的"

# ---------------------------------------------------------------- 2. 拆 TTC
# .ttc 里有 SC/TC/JP/KR 好几个面，直接喂给 pyftsubset 会挑错，先抽出简体那一面
BASE="$WORK/subset-base.otf"
case "$SRC_FONT" in
  *.ttc|*.TTC)
    say "从 TTC 里抽简体面"
    python3 - "$SRC_FONT" "$BASE" <<'PY'
import sys
from fontTools.ttLib import TTCollection
src, dst = sys.argv[1], sys.argv[2]
ttc = TTCollection(src, lazy=True)
want = None
for f in ttc.fonts:
    name = f['name'].getDebugName(1) or ''
    print('  面：%s' % name)
    if 'SC' in name.upper() or 'HANS' in name.upper():
        want = f
        break
if want is None:
    raise SystemExit('!! 这个 TTC 里没有简体面')
want.save(dst)
print('  -> %s' % dst)
PY
    ;;
  *)
    cp "$SRC_FONT" "$BASE"
    ;;
esac

# ---------------------------------------------------------------- 3. 子集化
# --no-hinting 去掉指令，--desubroutinize 摊平 CFF，两个都是为了缩小体积
say "pyftsubset：只留用得到的字形"
python3 -m fontTools.subset "$BASE" \
  --text-file="$CN_FULL" --unicodes="$UNI_RANGE" \
  --no-hinting --desubroutinize --drop-tables+=GSUB,GPOS \
  --output-file="$WORK/sub16.otf"
python3 -m fontTools.subset "$BASE" \
  --text-file="$CN_SMALL" --unicodes="$UNI_RANGE" \
  --no-hinting --desubroutinize --drop-tables+=GSUB,GPOS \
  --output-file="$WORK/sub24.otf"

# ---------------------------------------------------------------- 4. 转 LVGL
say "lv_font_conv：16px / 4bpp -> ui_font_cn_16.c"
lv_font_conv --font "$WORK/sub16.otf" --size 16 --bpp 4 --format lvgl \
  --no-kerning $RANGES --symbols "$(cat "$CN_FULL")" \
  -o "$OUT_16" --lv-font-name ui_font_cn_16 --lv-include "lvgl.h"

say "lv_font_conv：24px / 4bpp -> ui_font_cn_24.c"
lv_font_conv --font "$WORK/sub24.otf" --size 24 --bpp 4 --format lvgl \
  --no-kerning $RANGES_24 --symbols "$(cat "$CN_SMALL")" \
  -o "$OUT_24" --lv-font-name ui_font_cn_24 --lv-include "lvgl.h"

# ---------------------------------------------------------------- 5. 收尾核对
say "结果"
for f in "$OUT_16" "$OUT_24"; do
  printf '  %-22s 文本 %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  grep -m1 'line_height' "$f" | sed 's/^/    /'
done

say "校字（漏一个屏幕上就是一个方框）"
python3 "$HERE/check_font.py" "$ROOT" "$OUT_16" "$OUT_24"

cat <<'TIP'

提示：.c 文件看着几 MB 纯属文本膨胀（每个字形都是一长串十六进制字面量），
真正的 flash 占用大约只有它的 1/9，见 README 第 8 节。
TIP
