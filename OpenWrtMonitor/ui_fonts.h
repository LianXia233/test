/*
 * ui_fonts.h - 中文字体声明钩子
 * ==============================
 * 为什么字体要单独放一个头文件：
 *   lv_conf.h 是在 lvgl.h 最前面被包含的，那时候 `lv_font_t` 这个类型还不存在，
 *   直接在 lv_conf.h 里写 `extern const lv_font_t ui_font_cn_16;` 会编译报错。
 *   LVGL 官方给的钩子是 LV_FONT_CUSTOM_INCLUDE —— 这个头文件由 lv_font.h 在
 *   末尾（所有类型都定义完之后）包含，时机正好。
 *
 * 字体本体在 ui_font_cn_16.c / ui_font_cn_24.c，由 tools/gen_fonts.sh 生成。
 */
#pragma once

/* 让 LVGL 在正确的位置替我们声明这两个字体 */
#define LV_FONT_CUSTOM_DECLARE  \
    LV_FONT_DECLARE(ui_font_cn_16)  \
    LV_FONT_DECLARE(ui_font_cn_24)

/* 全局默认字体 = 中文 16px。
   lv_conf_internal.h 已经先给了个 Montserrat 的默认值，这里要先撤掉再定义，
   否则编译器会报 "redefined"，而且用哪个值取决于谁后生效 —— 得明确。 */
#undef LV_FONT_DEFAULT
#define LV_FONT_DEFAULT  &ui_font_cn_16
