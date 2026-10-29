#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_lz4.py —— 在主机上验证 OpenWrtMonitor.ino 里那个手写的流式 LZ4 解码器。

为什么需要它
------------
投屏的 LZ4 解码是自己在固件里写的（为了不落地 153KB 整帧缓冲），
语法检查只能保证它编得过，保证不了它解对。这个脚本做三件事：

  1. 从 OpenWrtMonitor.ino 里原样切出「像素 sink + LZ4 解码」这段代码
  2. 配一套极薄的桩（假 tft / 假 Serial / 假 ESP）编成一个主机可执行程序
  3. 用参考压缩器造几張有代表性的帧，跑 round-trip 逐字节比对

用法
----
    python3 tools/test_lz4.py              # 跑全部用例
    python3 tools/test_lz4.py -v           # 打印每条用例的压缩率

依赖：系统 g++（ESP32 toolchain 不需要）。

覆盖的几个坑：
  · 全字面量帧（随机噪声）—— 长度扩展用满了 15 + 一串 255 的那种写法
  · 超长重叠匹配（整行同色）—— 匹配复制必须逐字节来，不能 memcpy
  · 超过 64KB 的输出 —— 环形回看窗口会绕回去，最老的数据还没被覆盖
  · 长度不是整帧 —— 最后一行为补齐的情况
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'OpenWrtMonitor.ino'

START_MARK = 'static uint16_t castRowBuf[CAST_MAX_W];'
END_MARK = '/* ---------------------------------------------------------- JPEG'

STUBS = r'''
#pragma once
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <vector>
#define CAST_MAX_W 640
#define CAST_MAX_H 480
#define CAST_MAX_SRC 262144u
#define SCREEN_W 320
#define SCREEN_H 240

struct TftStub {
  std::vector<uint16_t> out;
  void startWrite() {}
  void endWrite() {}
  void setAddrWindow(int32_t x, int32_t y, uint32_t w, uint32_t h) { (void)x;(void)y;(void)w;(void)h; }
  void fillScreen(uint16_t) {}
  void pushColors(uint16_t* p, uint32_t n, bool) { for (uint32_t i=0;i<n;i++) out.push_back(p[i]); }
};
static TftStub tft;
static bool castLive = false;
static bool castActive = false;
static uint32_t castFrames = 0;
static uint32_t castLastFrameMs = 0;
static inline uint32_t millis() { return 0; }
struct SerialC { int printf(const char*, ...) { return 0; } };
static SerialC Serial;
struct EspStub { uint32_t getFreeHeap() { return 200000; } };
static EspStub ESP;
'''

MAIN = r'''
#include "castcore.h"
int main(int argc, char** argv) {
  if (argc < 3) return 2;
  FILE* f = fopen(argv[1], "rb");
  if (!f) return 2;
  fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> src(len);
  if (fread(src.data(), 1, len, f) != (size_t)len) return 2;
  fclose(f);

  FILE* e = fopen(argv[2], "rb");
  if (!e) return 2;
  fseek(e, 0, SEEK_END); long elen = ftell(e); fseek(e, 0, SEEK_SET);
  std::vector<uint8_t> exp(elen);
  if (fread(exp.data(), 1, elen, e) != (size_t)elen) return 2;
  fclose(e);

  castFrameBegin(SCREEN_W, SCREEN_H);
  bool ok = castLz4Prepended(src.data(), src.size());
  castFrameEnd();
  if (!ok) { fprintf(stderr, "DECODE FAIL\n"); return 1; }

  std::vector<uint8_t> got;
  for (uint16_t px : tft.out) { got.push_back((uint8_t)(px >> 8)); got.push_back((uint8_t)(px & 0xFF)); }
  if (got.size() != exp.size()) {
    fprintf(stderr, "SIZE MISMATCH got=%zu exp=%zu\n", got.size(), exp.size());
    return 1;
  }
  for (size_t i = 0; i < got.size(); i++) {
    if (got[i] != exp[i]) { fprintf(stderr, "BYTE MISMATCH at %zu\n", i); return 1; }
  }
  printf("OK %zu\n", got.size());
  return 0;
}
'''


# ---------------------------------------------------------------- 参考压缩器
def lz4_block(src: bytes) -> bytes:
    """一个够用的参考 LZ4 压缩器：只要产出合法的 LZ4 块就行。"""
    out = bytearray()
    n = len(src)
    table = {}
    i = 0
    lit = bytearray()
    min_match, last_literals, mflimit, window = 4, 5, 12, 65535

    def key(s, p):
        return None if p + 4 > len(s) else s[p:p + 4]

    while True:
        best_off = best_len = 0
        remain = n - i
        if remain > mflimit:
            cand = table.get(key(src, i))
            if cand is not None and 1 <= i - cand <= window:
                off = i - cand
                maxl = min(remain - last_literals, window + 19)
                ln = 0
                while ln < maxl and src[cand + ln] == src[i + ln]:
                    ln += 1
                if ln >= min_match:
                    best_off, best_len = off, ln
        if best_len >= min_match:
            ll = len(lit)
            ml = best_len - min_match
            out.append((min(ll, 15) << 4) | min(ml, 15))
            if ll >= 15:
                e = ll - 15
                while e >= 255:
                    out.append(255)
                    e -= 255
                out.append(e)
            out += lit
            lit = bytearray()
            out.append(best_off & 0xFF)
            out.append((best_off >> 8) & 0xFF)
            if ml >= 15:
                e = ml - 15
                while e >= 255:
                    out.append(255)
                    e -= 255
                out.append(e)
            for j in range(i - best_len + 1, i + 1):
                k = key(src, j)
                if k is not None:
                    table[k] = j
            i += best_len
        else:
            if i >= n:
                break
            lit.append(src[i])
            table[key(src, i)] = i
            i += 1
    ll = len(lit)
    out.append(min(ll, 15) << 4)
    if ll >= 15:
        e = ll - 15
        while e >= 255:
            out.append(255)
            e -= 255
        out.append(e)
    out += lit
    return bytes(out)


# ---------------------------------------------------------------- 用例
def make_cases():
    rnd = random.Random(20241029)
    fb = 320 * 240 * 2
    yield '全黑', bytes(fb)

    yield '随机噪声', bytes(rnd.getrandbits(8) for _ in range(fb))

    rows = []
    for _ in range(240):
        v = rnd.getrandbits(16)
        rows.append(bytes([v >> 8, v & 0xFF]) * 320)
    yield '整行同色（长重叠匹配）', b''.join(rows)

    img = bytearray()
    for y in range(240):
        base = (y * 7) & 0xFFFF
        for x in range(320):
            v = (base + x * 3) & 0xFFFF
            img.append(v >> 8)
            img.append(v & 0xFF)
    yield '渐变图（大量短匹配）', bytes(img)

    pool = [bytes(rnd.getrandbits(8) for _ in range(4)) for _ in range(64)]
    small = bytearray()
    for _ in range(fb // 4):
        small += pool[rnd.randrange(64)]
    yield '四字节块乱拼', bytes(small)

    yield '小帧 160x120', bytes(rnd.getrandbits(8) for _ in range(160 * 120 * 2))


def main():
    verbose = '-v' in sys.argv
    text = SRC.read_text(encoding='utf-8')
    if START_MARK not in text or END_MARK not in text:
        print('!! 在 %s 里找不到投屏代码的切分区段' % SRC, file=sys.stderr)
        print('!! 需要标记：%r / %r' % (START_MARK, END_MARK), file=sys.stderr)
        return 2

    core = text[text.index(START_MARK):text.index(END_MARK)].rstrip() + '\n'
    tmp = Path(tempfile.mkdtemp(prefix='cast-lz4-'))
    (tmp / 'castcore.h').write_text(STUBS + core, encoding='utf-8')
    (tmp / 'main.cpp').write_text(MAIN, encoding='utf-8')

    build = subprocess.run(['g++', '-std=gnu++17', '-O1', '-w', '-o', str(tmp / 'lz4test'),
                            str(tmp / 'main.cpp')], capture_output=True, text=True)
    if build.returncode != 0:
        print('!! 编译失败：', file=sys.stderr)
        print(build.stderr[:4000], file=sys.stderr)
        return 2

    print('== LZ4 流式解码 round-trip ==')
    bad = 0
    for name, data in make_cases():
        block = lz4_block(data)
        (tmp / 'in.bin').write_bytes(struct.pack('<I', len(data)) + block)
        (tmp / 'exp.bin').write_bytes(data)
        r = subprocess.run([str(tmp / 'lz4test'), str(tmp / 'in.bin'), str(tmp / 'exp.bin')],
                           capture_output=True, text=True)
        ok = r.returncode == 0
        bad += 0 if ok else 1
        line = '  %-24s %s' % (name, (r.stdout or r.stderr).strip() if ok else '失败 ' + r.stderr.strip())
        if verbose:
            line += '   raw=%7d lz4=%7d  压缩率 %.2f' % (len(data), len(block),
                                                        len(block) / max(1, len(data)))
        print(line)

    print('\n%s（%d/%d 通过）' % ('全部通过' if bad == 0 else '有用例失败',
                                len(list(make_cases())) - bad, len(list(make_cases()))))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
