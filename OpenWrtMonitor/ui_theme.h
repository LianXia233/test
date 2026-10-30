/*
 * ui_theme.h - OpenWrtMonitor 设计系统（LVGL 9.6 / 320x240 / 中文）
 * ==================================================================
 * 风格：深色玻璃拟态 —— 深蓝渐变底、半透明卡片、1px 描边、蓝紫强调、圆角胶囊。
 *
 * 全部界面都只用这里的构建器搭，改配色 / 圆角 / 间距 / 字体只改这一个文件。
 *
 * 布局栅格（横屏 320x240）：
 *   y   0..28    状态栏（SSID / 同步状态 / 时钟）
 *   y  28..194   内容区（各页面自己排，可滚动）   高 166
 *   y 194..240   底部导航（5 个页签，图标 + 中文标签）
 *
 * 字体只有两档：16px 中文（正文/标签）和 24px（大数值）。
 * 24px 只包含界面用字 + 数字英文，缺字自动 fallback 到 16px。
 */
#pragma once

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "lvgl.h"

/* 外部提供的中文字体（ui_font_cn_16.c / ui_font_cn_24.c 由 tools/ 生成） */
extern const lv_font_t ui_font_cn_16;
extern const lv_font_t ui_font_cn_24;

/* ------------------------------------------------------------------ 设计令牌 */
#define UI_C_BG          0x070A14   /* 页面底色 */
#define UI_C_BG_2        0x101733   /* 页面渐变下沿 */
#define UI_C_CARD        0x151D36   /* 卡片上沿 */
#define UI_C_CARD_2      0x1D2748   /* 卡片渐变下沿 */
#define UI_C_CARD_HI     0x1B2547   /* 重点卡上沿 */
#define UI_C_BORDER      0x2C3860   /* 1px 描边 */
#define UI_C_TEXT        0xEAF0FF   /* 主文字 */
#define UI_C_TEXT_DIM    0x96A3C6   /* 次要文字 */
#define UI_C_TEXT_MUTE   0x5D6A8E   /* 单位 / 占位 */
#define UI_C_ACCENT      0x4F8CFF   /* 强调蓝 */
#define UI_C_ACCENT_2    0x8B5CF6   /* 强调紫 */
#define UI_C_CYAN        0x22D3EE   /* 冷色点缀 */
#define UI_C_OK          0x22C55E   /* 正常 / 在线 */
#define UI_C_WARN        0xF59E0B   /* 警告 */
#define UI_C_DANGER      0xEF4444   /* 危险 / 断线 */
#define UI_C_WARM        0xFF8A3D   /* 暖色（上传） */

/* 布局常量：240px 高度下这三段是硬约束，改之前先算总高 */
#define UI_W             320
#define UI_H             240
#define UI_STATUS_H      28
#define UI_NAV_H         46
#define UI_CONTENT_Y     UI_STATUS_H
#define UI_CONTENT_H     (UI_H - UI_STATUS_H - UI_NAV_H)   /* 166 */

#define UI_PAD           8    /* 页面外边距 */
#define UI_GAP           6    /* 卡片间距 */
#define UI_RADIUS        10   /* 卡片圆角 */
#define UI_RADIUS_S      7    /* 小控件圆角 */

/* 行高：这两个值是 lv_font_conv 实际写进字体里的 line_height，别拍脑袋改。
   中文是方块字，16px 的字行高就有 21，比拉丁字体占地方得多，
   所有卡片高度都得按这两个数往上加。 */
#define UI_LH_16         21   /* ui_font_cn_16 的 line_height */
#define UI_LH_24         29   /* ui_font_cn_24 的 line_height */

/* ------------------------------------------------------------------ 字体 */
#define UI_F_XS    (&ui_font_cn_16)   /* 16px：标签 / 单位 / 次要 */
#define UI_F_S     (&ui_font_cn_16)   /* 16px：正文 / 键值 */
#define UI_F_M     (&ui_font_cn_16)   /* 16px：强调值 */
#define UI_F_L     (&ui_font_cn_24)   /* 24px：大数值 */
#define UI_F_NUM   (&ui_font_cn_24)   /* 24px：大数值 */

/* ------------------------------------------------------------------ 基础工具 */
static inline lv_color_t ui_col(uint32_t hex) { return lv_color_hex(hex); }

/** 去掉默认白底/边框/内边距（LVGL 容器默认样式） */
static inline void ui_clean(lv_obj_t* o) {
  lv_obj_remove_style_all(o);
  lv_obj_set_style_bg_opa(o, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(o, 0, 0);
  lv_obj_set_style_pad_all(o, 0, 0);
  lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE);
}

/** 上下渐变填充 */
static inline void ui_grad(lv_obj_t* o, uint32_t top, uint32_t bottom) {
  lv_obj_set_style_bg_color(o, ui_col(top), 0);
  lv_obj_set_style_bg_grad_color(o, ui_col(bottom), 0);
  lv_obj_set_style_bg_grad_dir(o, LV_GRAD_DIR_VER, 0);
  lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
}

/** 值没变就不写标签：每秒刷新时能省掉大量无意义的重绘 */
static inline void ui_set_text(lv_obj_t* lbl, const char* txt) {
  if (!lbl || !txt) return;
  const char* cur = lv_label_get_text(lbl);
  if (cur && strcmp(cur, txt) == 0) return;
  lv_label_set_text(lbl, txt);
}

/** 同上，格式化版本（LVGL 自带 printf 不支持 %f，这里用 libc 的） */
static inline void ui_set_text_fmt(lv_obj_t* lbl, const char* fmt, ...) {
  if (!lbl || !fmt) return;
  char buf[96];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  ui_set_text(lbl, buf);
}

/* ------------------------------------------------------------------ 容器 */
/** 屏幕根：铺满 + 渐变底 + 不滚动（滚动交给内容区） */
static inline lv_obj_t* ui_screen_root(lv_obj_t* scr) {
  ui_clean(scr);
  ui_grad(scr, UI_C_BG, UI_C_BG_2);
  lv_obj_set_size(scr, UI_W, UI_H);
  return scr;
}

/** 卡片：渐变底 + 1px 描边 + 圆角。不加阴影（软件渲染下模糊阴影很贵） */
static inline lv_obj_t* ui_card(lv_obj_t* parent) {
  lv_obj_t* c = lv_obj_create(parent);
  ui_clean(c);
  ui_grad(c, UI_C_CARD, UI_C_CARD_2);
  lv_obj_set_style_radius(c, UI_RADIUS, 0);
  lv_obj_set_style_border_width(c, 1, 0);
  lv_obj_set_style_border_color(c, ui_col(UI_C_BORDER), 0);
  lv_obj_set_style_border_opa(c, LV_OPA_80, 0);
  lv_obj_set_style_pad_all(c, 6, 0);
  lv_obj_set_style_pad_row(c, 2, 0);
  lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(c, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
  lv_obj_clear_flag(c, LV_OBJ_FLAG_SCROLLABLE);
  return c;
}

/** 重点卡：稍亮的底 + 蓝色描边，用来放"主角"数据 */
static inline lv_obj_t* ui_card_hi(lv_obj_t* parent) {
  lv_obj_t* c = ui_card(parent);
  ui_grad(c, UI_C_CARD_HI, UI_C_CARD_2);
  lv_obj_set_style_border_color(c, ui_col(UI_C_ACCENT), 0);
  lv_obj_set_style_border_opa(c, LV_OPA_40, 0);
  return c;
}

/** 透明横向/纵向 flex 容器 */
static inline lv_obj_t* ui_box(lv_obj_t* parent, bool row) {
  lv_obj_t* b = lv_obj_create(parent);
  ui_clean(b);
  lv_obj_set_size(b, LV_PCT(100), LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(b, row ? LV_FLEX_FLOW_ROW : LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(b, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_row(b, 2, 0);
  lv_obj_set_style_pad_column(b, UI_GAP, 0);
  return b;
}

/** 可滚动内容区（放不下时手指可以滑） */
static inline lv_obj_t* ui_scroll_col(lv_obj_t* parent, int w, int h) {
  lv_obj_t* b = lv_obj_create(parent);
  ui_clean(b);
  lv_obj_set_size(b, w, h);
  lv_obj_set_flex_flow(b, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(b, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
  lv_obj_set_style_pad_row(b, UI_GAP, 0);
  lv_obj_add_flag(b, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scroll_dir(b, LV_DIR_VER);
  lv_obj_set_scrollbar_mode(b, LV_SCROLLBAR_MODE_AUTO);
  /* 滚动条做窄但可见：原来宽度 0 全隐藏，用户看不出页面能滑 */
  lv_obj_set_style_width(b, 3, LV_PART_SCROLLBAR);
  lv_obj_set_style_radius(b, 2, LV_PART_SCROLLBAR);
  lv_obj_set_style_pad_right(b, 1, 0);
  lv_obj_set_style_bg_color(b, ui_col(UI_C_ACCENT), LV_PART_SCROLLBAR);
  lv_obj_set_style_bg_opa(b, LV_OPA_50, LV_PART_SCROLLBAR);
  return b;
}

static inline void ui_scrollbar_hide(lv_obj_t* o) {
  lv_obj_set_scrollbar_mode(o, LV_SCROLLBAR_MODE_OFF);
}

/* ------------------------------------------------------------------ 文本 / 图标 */
static inline lv_obj_t* ui_label(lv_obj_t* parent, const char* txt, const lv_font_t* f, uint32_t color) {
  lv_obj_t* l = lv_label_create(parent);
  lv_label_set_text(l, txt);
  lv_obj_set_style_text_font(l, f, 0);
  lv_obj_set_style_text_color(l, ui_col(color), 0);
  lv_obj_set_style_text_letter_space(l, 0, 0);
  return l;
}

/** 图标：24x24 A8 位图 + recolor 着色
 *  LVGL 9 里缩放是 1/16 定点：256 = 原尺寸，171 ≈ 16px，128 ≈ 12px */
static inline lv_obj_t* ui_icon(lv_obj_t* parent, const lv_image_dsc_t* src, uint32_t color) {
  lv_obj_t* i = lv_image_create(parent);
  lv_image_set_src(i, src);
  lv_obj_set_style_image_recolor(i, ui_col(color), 0);
  lv_obj_set_style_image_recolor_opa(i, LV_OPA_COVER, 0);
  lv_obj_clear_flag(i, LV_OBJ_FLAG_CLICKABLE);
  return i;
}

/** 缩放图标：size 是目标像素边长 */
static inline void ui_icon_size(lv_obj_t* i, int size) {
  lv_image_set_scale(i, (uint32_t)(256 * size / 24));
}

/** 卡片里最常见的一行：图标 + 标签 + 大数值，横着排。
 *  中文一行 21、大字一行 29，竖着堆一张卡就得 60+，横着排 30 就够。 */
static inline void ui_mk_stat(lv_obj_t* card, const lv_image_dsc_t* icon, const char* cap,
                              uint32_t col, lv_obj_t** out_val) {
  lv_obj_t* t = lv_obj_create(card);
  ui_clean(t);
  lv_obj_set_size(t, LV_PCT(100), UI_LH_24);
  lv_obj_set_flex_flow(t, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(t, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(t, 4, 0);
  lv_obj_t* i = ui_icon(t, icon, col);
  lv_image_set_pivot(i, 12, 12);
  ui_icon_size(i, 15);
  ui_label(t, cap, UI_F_XS, UI_C_TEXT_DIM);
  lv_obj_t* sp = lv_obj_create(t);
  ui_clean(sp);
  lv_obj_set_flex_grow(sp, 1);
  lv_obj_set_height(sp, 1);
  *out_val = ui_label(t, "--", UI_F_L, col);
}

/** 图标 + 文字（卡片标题行） */
static inline lv_obj_t* ui_title_row(lv_obj_t* parent, const lv_image_dsc_t* icon, const char* txt,
                                     uint32_t icon_color) {
  lv_obj_t* r = lv_obj_create(parent);
  ui_clean(r);
  lv_obj_set_size(r, LV_PCT(100), UI_LH_16);
  lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(r, 4, 0);
  if (icon) {
    lv_obj_t* i = ui_icon(r, icon, icon_color);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 15);
  }
  ui_label(r, txt, UI_F_XS, UI_C_TEXT_DIM);
  return r;
}

/** 胶囊标签 */
static inline lv_obj_t* ui_chip(lv_obj_t* parent, const char* txt, uint32_t color) {
  lv_obj_t* c = lv_label_create(parent);
  lv_label_set_text(c, txt);
  lv_obj_set_style_text_font(c, UI_F_XS, 0);
  lv_obj_set_style_text_color(c, ui_col(color), 0);
  lv_obj_set_style_bg_color(c, ui_col(color), 0);
  lv_obj_set_style_bg_opa(c, LV_OPA_20, 0);
  lv_obj_set_style_radius(c, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_pad_hor(c, 5, 0);
  lv_obj_set_style_pad_ver(c, 1, 0);
  lv_obj_set_style_border_width(c, 1, 0);
  lv_obj_set_style_border_color(c, ui_col(color), 0);
  lv_obj_set_style_border_opa(c, LV_OPA_40, 0);
  return c;
}

/* ------------------------------------------------------------------ 控件 */
/** 键值行：左灰色键、右亮色值。返回整行，值标签通过 out 带出 */
static inline lv_obj_t* ui_kv(lv_obj_t* parent, const char* key, const char* val,
                              uint32_t val_color, lv_obj_t** out_val) {
  lv_obj_t* r = lv_obj_create(parent);
  ui_clean(r);
  lv_obj_set_size(r, LV_PCT(100), LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(r, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(r, 6, 0);
  ui_label(r, key, UI_F_XS, UI_C_TEXT_MUTE);
  lv_obj_t* v = ui_label(r, val, UI_F_S, val_color);
  lv_obj_set_size(v, 176, UI_LH_16);   /* 宽高都固定，DOTS 才会生效（见无线页名字的注释） */
  lv_label_set_long_mode(v, LV_LABEL_LONG_MODE_DOTS);
  lv_obj_set_style_text_align(v, LV_TEXT_ALIGN_RIGHT, 0);
  if (out_val) *out_val = v;
  return r;
}

/** 细进度条（内存、负载占比这类） */
static inline lv_obj_t* ui_bar(lv_obj_t* parent, uint32_t color) {
  lv_obj_t* b = lv_bar_create(parent);
  lv_obj_set_size(b, LV_PCT(100), 5);
  lv_bar_set_range(b, 0, 100);
  lv_bar_set_value(b, 0, LV_ANIM_OFF);
  lv_obj_set_style_bg_color(b, ui_col(UI_C_BORDER), LV_PART_MAIN);
  lv_obj_set_style_bg_opa(b, LV_OPA_60, LV_PART_MAIN);
  lv_obj_set_style_radius(b, LV_RADIUS_CIRCLE, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, ui_col(color), LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(b, LV_OPA_COVER, LV_PART_INDICATOR);
  lv_obj_set_style_radius(b, LV_RADIUS_CIRCLE, LV_PART_INDICATOR);
  lv_obj_clear_flag(b, LV_OBJ_FLAG_CLICKABLE);
  return b;
}

/** 圆弧仪表：270° 开口朝下，无旋钮 */
static inline lv_obj_t* ui_arc(lv_obj_t* parent, int size, uint32_t color, int range_max) {
  lv_obj_t* a = lv_arc_create(parent);
  lv_obj_set_size(a, size, size);
  lv_arc_set_rotation(a, 135);
  lv_arc_set_bg_angles(a, 0, 270);
  lv_arc_set_range(a, 0, range_max);
  lv_arc_set_value(a, 0);
  lv_obj_remove_style(a, NULL, LV_PART_KNOB);
  lv_obj_clear_flag(a, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_style_arc_color(a, ui_col(UI_C_BORDER), LV_PART_MAIN);
  lv_obj_set_style_arc_opa(a, LV_OPA_70, LV_PART_MAIN);
  lv_obj_set_style_arc_width(a, 7, LV_PART_MAIN);
  lv_obj_set_style_arc_color(a, ui_col(color), LV_PART_INDICATOR);
  lv_obj_set_style_arc_width(a, 7, LV_PART_INDICATOR);
  lv_obj_set_style_arc_rounded(a, true, LV_PART_MAIN);
  lv_obj_set_style_arc_rounded(a, true, LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(a, LV_OPA_TRANSP, LV_PART_MAIN);
  lv_obj_set_style_pad_all(a, 0, LV_PART_MAIN);
  return a;
}

/** 按钮：图标 + 文字，按下时高亮 */
static inline lv_obj_t* ui_button(lv_obj_t* parent, const lv_image_dsc_t* icon, const char* txt,
                                  uint32_t bg, lv_event_cb_t cb, void* ud) {
  lv_obj_t* b = lv_btn_create(parent);
  lv_obj_set_style_bg_color(b, ui_col(bg), 0);
  lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(b, ui_col(bg), LV_STATE_PRESSED);
  lv_obj_set_style_bg_opa(b, LV_OPA_70, LV_STATE_PRESSED);
  lv_obj_set_style_radius(b, UI_RADIUS_S, 0);
  lv_obj_set_style_border_width(b, 0, 0);
  lv_obj_set_style_shadow_width(b, 0, 0);
  lv_obj_set_style_pad_all(b, 4, 0);
  lv_obj_set_style_pad_column(b, 4, 0);
  lv_obj_set_flex_flow(b, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(b, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_clear_flag(b, LV_OBJ_FLAG_SCROLLABLE);
  if (icon) {
    lv_obj_t* i = ui_icon(b, icon, UI_C_TEXT);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 15);
  }
  if (txt) ui_label(b, txt, UI_F_S, UI_C_TEXT);
  if (cb) lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, ud);
  return b;
}

/** 列表行：左图标 + 标题 + 右侧值，整行可点 */
static inline lv_obj_t* ui_list_row(lv_obj_t* parent, const lv_image_dsc_t* icon, const char* title,
                                    const char* value, lv_event_cb_t cb, void* ud) {
  lv_obj_t* r = lv_obj_create(parent);
  ui_clean(r);
  lv_obj_set_size(r, LV_PCT(100), 32);
  lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(r, 6, 0);
  lv_obj_set_style_pad_hor(r, 6, 0);
  lv_obj_set_style_radius(r, UI_RADIUS_S, 0);
  lv_obj_set_style_bg_color(r, ui_col(UI_C_ACCENT), LV_STATE_PRESSED);
  lv_obj_set_style_bg_opa(r, LV_OPA_20, LV_STATE_PRESSED);
  lv_obj_add_flag(r, LV_OBJ_FLAG_CLICKABLE);
  if (icon) {
    lv_obj_t* i = ui_icon(r, icon, UI_C_ACCENT);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 16);
  }
  ui_label(r, title, UI_F_S, UI_C_TEXT);
  lv_obj_t* sp = lv_obj_create(r);
  ui_clean(sp);
  lv_obj_set_flex_grow(sp, 1);
  lv_obj_set_height(sp, 1);
  lv_obj_t* v = ui_label(r, value ? value : "", UI_F_XS, UI_C_TEXT_DIM);
  lv_obj_set_style_text_align(v, LV_TEXT_ALIGN_RIGHT, 0);
  lv_obj_set_style_max_width(v, 120, 0);
  lv_label_set_long_mode(v, LV_LABEL_LONG_MODE_CLIP);
  if (cb) lv_obj_add_event_cb(r, cb, LV_EVENT_CLICKED, ud);
  return r;
}

/** 1px 分隔线 */
static inline void ui_divider(lv_obj_t* parent) {
  lv_obj_t* d = lv_obj_create(parent);
  ui_clean(d);
  lv_obj_set_size(d, LV_PCT(100), 1);
  lv_obj_set_style_bg_color(d, ui_col(UI_C_BORDER), 0);
  lv_obj_set_style_bg_opa(d, LV_OPA_70, 0);
}

/** 弹层提示（toast）：1.8 秒后自动消失
 *  定时器用 repeat_count=1，LVGL 跑到次数会自己删定时器，所以回调里只删对象。 */
static lv_obj_t* g_toastObj = nullptr;

static void ui_toast_timer(lv_timer_t* t) {
  (void)t;
  if (g_toastObj) { lv_obj_del(g_toastObj); g_toastObj = nullptr; }
}

static inline void ui_toast(const char* msg) {
  lv_obj_t* cur = g_toastObj;
  if (cur) { lv_obj_del(cur); g_toastObj = nullptr; }
  lv_obj_t* box = lv_obj_create(lv_layer_top());
  ui_clean(box);
  lv_obj_set_style_bg_color(box, ui_col(0x0B1220), 0);
  lv_obj_set_style_bg_opa(box, LV_OPA_90, 0);
  lv_obj_set_style_border_width(box, 1, 0);
  lv_obj_set_style_border_color(box, ui_col(UI_C_ACCENT), 0);
  lv_obj_set_style_border_opa(box, LV_OPA_50, 0);
  lv_obj_set_style_radius(box, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_pad_hor(box, 12, 0);
  lv_obj_set_style_pad_ver(box, 6, 0);
  lv_obj_set_size(box, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  ui_label(box, msg, UI_F_S, UI_C_TEXT);
  lv_obj_align(box, LV_ALIGN_BOTTOM_MID, 0, -54);
  g_toastObj = box;
  lv_timer_t* t = lv_timer_create(ui_toast_timer, 1800, nullptr);
  lv_timer_set_repeat_count(t, 1);
}
