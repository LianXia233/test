#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 OpenWrtMonitor 的 LVGL 图标资源 (ui_icons.h)

产出：24x24 单色图标 -> LV_IMG_CF_ALPHA_8BIT 位图 + lv_img_dsc_t 描述符。
8bit alpha 没有颜色信息，运行时用 lv_obj_set_style_img_recolor() 着色，
所以同一份图可以按状态染成"选中蓝 / 未选中灰 / 告警红"。

用法: python3 gen_icons.py > ui_icons.h
"""

from PIL import Image, ImageDraw

SIZE = 24
SS = 4                      # 超采样倍数（做抗锯齿）
W = SIZE * SS
# 图标 stos 统一线宽（24px 画布上 2px 视觉最清晰）
LW = 2.0


def new_canvas():
    return Image.new("L", (W, W), 0)


def s(v):
    """24 空间坐标 -> 超采样画布坐标"""
    return v * SS


def line(d, pts, w=LW, fill=255, joint="curve"):
    d.line([(s(x), s(y)) for x, y in pts], fill=fill, width=int(w * SS), joint=joint)


def poly(d, pts, fill=255):
    d.polygon([(s(x), s(y)) for x, y in pts], fill=fill)


def ellipse_box(x0, y0, x1, y1):
    return [s(x0), s(y0), s(x1), s(y1)]


def ellipse(d, box, w=LW, fill=255, outline=255):
    d.ellipse(ellipse_box(*box), outline=outline, width=int(w * SS))


def disc(d, cx, cy, r, fill=255):
    d.ellipse(ellipse_box(cx - r, cy - r, cx + r, cy + r), fill=fill)


def ring(d, cx, cy, r, w=LW, start=0, end=360):
    d.arc(ellipse_box(cx - r, cy - r, cx + r, cy + r),
          start, end, fill=255, width=int(w * SS))


def rounded(d, x0, y0, x1, y1, r, w=LW, fill=None):
    d.rounded_rectangle(ellipse_box(x0, y0, x1, y1), radius=int(r * SS),
                        outline=255 if fill is None else None,
                        fill=fill,
                        width=int(w * SS))


def arrow_head(d, cx, cy, r, ang, ccw=False, size=3.4):
    """把箭头画在圆弧 (cx,cy,r) 上角度 ang 处，方向沿切线。
    PIL 的角度是"从 +x 轴顺时针"(y 轴向下)，所以切线方向直接用三角函数算。"""
    import math
    a = math.radians(ang)
    px, py = cx + r * math.cos(a), cy + r * math.sin(a)
    # 顺时针前进的切线；ccw=True 则取反
    tx, ty = -math.sin(a), math.cos(a)
    if ccw:
        tx, ty = -tx, -ty
    nx, ny = -ty, tx                      # 法线
    tip = (px + tx * size, py + ty * size)
    b1 = (px + nx * size * 0.95, py + ny * size * 0.95)
    b2 = (px - nx * size * 0.95, py - ny * size * 0.95)
    poly(d, [tip, b1, b2])


# ---------------------------------------------------------------- 图标定义
def ic_home():
    """房子：斜屋顶 + 墙体 + 门"""
    im, d = new_canvas(), None
    d = ImageDraw.Draw(im)
    line(d, [(2.5, 11.5), (12, 3.5), (21.5, 11.5)], joint="curve")
    line(d, [(5.5, 9.5), (5.5, 20.5), (18.5, 20.5), (18.5, 9.5)], joint="curve")
    rounded(d, 10, 14, 14, 20.5, 1.2, fill=255)
    return im


def ic_chip():
    """CPU：外框 + 内核 + 三边引脚"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    rounded(d, 5, 5, 19, 19, 2)
    rounded(d, 9.2, 9.2, 14.8, 14.8, 1.2, fill=255)
    for y in (8.4, 12, 15.6):
        line(d, [(1.6, y), (5, y)])
        line(d, [(19, y), (22.4, y)])
    for x in (8.4, 12, 15.6):
        line(d, [(x, 1.6), (x, 5)])
        line(d, [(x, 19), (x, 22.4)])
    return im


def ic_mem():
    """内存条：长条 + 金手指 + 颗粒"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    rounded(d, 2.6, 6.4, 21.4, 15.6, 1.8)
    # 四颗颗粒
    for x0 in (5.0, 8.8, 12.6, 16.4):
        rounded(d, x0, 9.0, x0 + 2.8, 13.0, 0.8, fill=255)
    # 金手指
    for x in (4.8, 8.4, 12.0, 15.6, 19.2):
        line(d, [(x, 15.6), (x, 19.2)], w=1.6)
    line(d, [(3.2, 19.2), (20.8, 19.2)], w=1.6)
    return im


def ic_flow():
    """流量：上下双箭头 + 中轴"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    # 上行箭头
    line(d, [(6.5, 11), (6.5, 20)], joint="curve")
    poly(d, [(6.5, 5.4), (3.2, 9.8), (9.8, 9.8)])
    # 下行箭头
    line(d, [(17.5, 4), (17.5, 13)], joint="curve")
    poly(d, [(17.5, 18.6), (14.2, 14.2), (20.8, 14.2)])
    return im


def ic_globe():
    """地球：WAN / 外网"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 12, 9.2)
    line(d, [(3.2, 9.2), (20.8, 9.2)])
    line(d, [(3.2, 14.8), (20.8, 14.8)])
    # 经线：两条弧
    d.arc(ellipse_box(12 - 4.2, 3, 12 + 4.2, 21), 270, 90, fill=255, width=int(1.6 * SS))
    d.arc(ellipse_box(12 - 8.8, 3, 12 + 8.8, 21), 270, 90, fill=255, width=int(1.6 * SS))
    return im


def ic_wifi():
    """WiFi：三层弧 + 圆点"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    disc(d, 12, 19.2, 1.7)
    ring(d, 12, 19.2, 5.4, start=225, end=315)
    ring(d, 12, 19.2, 9.6, start=228, end=312)
    ring(d, 12, 19.2, 13.8, start=230, end=310)
    return im


def ic_users():
    """客户端：两个人"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    # 后排（右后，稍小、稍高）
    d.arc(ellipse_box(11.0, 12.0, 22.0, 22.0), 200, 340, fill=255, width=int(LW * SS))
    disc(d, 16.6, 7.2, 2.9)
    # 前排（左前，稍大）
    d.arc(ellipse_box(2.6, 13.4, 14.6, 23.4), 200, 340, fill=255, width=int(LW * SS))
    disc(d, 8.6, 9.0, 3.3)
    # 两个人之间的缝隙：用底色擦一道，避免糊成一团
    line(d, [(12.0, 4.0), (10.4, 22.0)], w=2.6, fill=0)
    return im


def ic_settings():
    """齿轮：外环 + 8 齿 + 内孔"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 12, 6.6, w=3.0)
    import math
    for i in range(8):
        a = i * math.pi / 4
        line(d, [(12 + math.cos(a) * 7.6, 12 + math.sin(a) * 7.6),
                 (12 + math.cos(a) * 9.8, 12 + math.sin(a) * 9.8)], w=2.8)
    # 内孔掏空，避免变成实心饼
    ImageDraw.Draw(im).ellipse(ellipse_box(12 - 2.6, 12 - 2.6, 12 + 2.6, 12 + 2.6), fill=0)
    return im


def ic_router():
    """路由器：机身 + 双天线 + 指示灯"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    rounded(d, 2.5, 11, 21.5, 20, 2.4)
    line(d, [(6.6, 11.4), (5.4, 4.4)], joint="curve")
    line(d, [(17.4, 11.4), (18.6, 4.4)], joint="curve")
    disc(d, 7.4, 16.6, 1.25)
    disc(d, 12.0, 16.6, 1.25)
    disc(d, 16.6, 16.6, 1.25)
    return im


def ic_refresh():
    """刷新：圆环 + 箭头"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 12, 8.2, start=292, end=246, w=2.2)
    arrow_head(d, 12, 12, 8.2, 292, ccw=False, size=3.6)
    return im


def ic_back():
    """返回：左箭头"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    line(d, [(14.5, 4.6), (6.6, 12), (14.5, 19.4)], joint="curve")
    return im


def ic_clock():
    """时钟：运行时间"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 12, 9.0)
    line(d, [(12, 12), (12, 6.6)])
    line(d, [(12, 12), (16.2, 13.6)])
    return im


def ic_power():
    """电源：重启 / 开关机"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 13, 7.4, start=302, end=238, w=2.2)
    line(d, [(12, 3.2), (12, 12.0)], w=2.2)
    return im


def ic_info():
    """信息 / 关于"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    ring(d, 12, 12, 9.0)
    disc(d, 12, 7.2, 1.5)
    line(d, [(12, 11), (12, 17.6)])
    return im


def ic_thermo():
    """温度计（设备负载/温度）"""
    im = new_canvas()
    d = ImageDraw.Draw(im)
    rounded(d, 10.2, 3.4, 13.8, 16.6, 3.0)
    disc(d, 12, 18.6, 3.4)
    line(d, [(12, 14.6), (12, 8.4)], w=2.2)
    for y in (5.6, 8.2, 10.8):
        line(d, [(16.6, y), (18.6, y)], w=1.4)
    return im


ICONS = [
    ("home",     ic_home),
    ("chip",     ic_chip),
    ("mem",      ic_mem),
    ("flow",     ic_flow),
    ("globe",    ic_globe),
    ("wifi",     ic_wifi),
    ("users",    ic_users),
    ("settings", ic_settings),
    ("router",   ic_router),
    ("refresh",  ic_refresh),
    ("back",     ic_back),
    ("clock",    ic_clock),
    ("power",    ic_power),
    ("info",     ic_info),
    ("thermo",   ic_thermo),
]


def to_alpha_bytes(im):
    """超采样画布 -> SIZE*SIZE 的 8bit alpha 字节"""
    small = im.resize((SIZE, SIZE), Image.BOX)
    return list(small.tobytes()), small


HEADER = """/*
 * ui_icons.h - OpenWrtMonitor 图标资源（tools/gen_icons.py 生成，勿手改）
 * ===================================================================
 * 全部 24x24、LV_IMG_CF_ALPHA_8BIT（只有 8bit 透明度，没有颜色信息），
 * 运行时通过 img_recolor 着色 —— 同一张图可以在"选中/未选中/告警"三种
 * 状态之间切换颜色，不用为每个颜色存一份位图。
 *
 * 每个图标 576 字节，%d 个共约 %d 字节常量数据（存在 flash，不占 RAM）。
 *
 * 用法：
 *   lv_obj_t* img = lv_img_create(parent);
 *   lv_img_set_src(img, &ic_home);
 *   lv_obj_set_style_img_recolor(img, lv_color_hex(UI_C_ACCENT), 0);
 *   lv_obj_set_style_img_recolor_opa(img, LV_OPA_COVER, 0);
 */
#pragma once

#include <stdint.h>
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef LV_ATTRIBUTE_MEM_ALIGN
#define LV_ATTRIBUTE_MEM_ALIGN
#endif
#ifndef LV_ATTRIBUTE_LARGE_CONST
#define LV_ATTRIBUTE_LARGE_CONST
#endif

"""


def main():
    out = []
    total = 0
    maps = []
    for name, fn in ICONS:
        im = fn()
        data, small = to_alpha_bytes(im)
        assert len(data) == SIZE * SIZE, (name, len(data))
        total += len(data)
        maps.append((name, data))

    out.append(HEADER % (len(ICONS), total))

    # 1) 位图数据
    for name, data in maps:
        out.append("/* ic_%s  24x24  ALPHA_8 */\n" % name)
        out.append("static const LV_ATTRIBUTE_MEM_ALIGN LV_ATTRIBUTE_LARGE_CONST uint8_t ic_%s_map[] = {\n" % name)
        per = 16
        for i in range(0, len(data), per):
            chunk = data[i:i + per]
            # 每行内的游程压缩：连续的 0x00 用注释标出不好读，直接铺开即可
            out.append("    " + " ".join("0x%02x," % b for b in chunk) + "\n")
        out.append("};\n\n")

    # 2) 描述符
    out.append("/* ---------------------------------------------------------------- 描述符 */\n")
    for name, data in maps:
        out.append("static const lv_img_dsc_t ic_%s = {\n" % name)
        out.append("    .header = {\n")
        out.append("        .cf = LV_IMG_CF_ALPHA_8BIT,\n")
        out.append("        .always_zero = 0,\n")
        out.append("        .reserved = 0,\n")
        out.append("        .w = %d,\n" % SIZE)
        out.append("        .h = %d,\n" % SIZE)
        out.append("    },\n")
        out.append("    .data_size = %d,\n" % len(data))
        out.append("    .data = ic_%s_map,\n" % name)
        out.append("};\n\n")

    out.append("#ifdef __cplusplus\n}\n#endif\n")
    print("".join(out), end="")


if __name__ == "__main__":
    main()
