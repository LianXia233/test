#!/usr/bin/env python3
"""在宿主机上跑一遍 rpcd ucode 后端（root/usr/share/rpcd/ucode/luci.esp32-screen）。

ucode 不是 node，但语法够接近：把 `import { x } from 'y'` 剥掉、顶层 return
包进函数，再用一组替身函数（type/length/sprintf/match/replace/json… 和一个
内存版 UCI cursor）喂给 node，就能把 get/set/probe 的真实逻辑跑一遍。

用法：  python3 tools/test_ucode.py
依赖：  node（只做 CommonJS/ESM 解析与执行，不需要任何 npm 包）
"""

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "root" / "usr" / "share" / "rpcd" / "ucode" / "luci.esp32-screen"

STUB = r"""
/* ---- ucode 内建函数的 node 替身 ---- */
function type(v){ if(v===null||v===undefined) return 'null'; if(Array.isArray(v)) return 'array';
  if(typeof v==='object') return 'object'; if(typeof v==='boolean') return 'bool';
  if(typeof v==='number') return Number.isInteger(v)?'int':'double'; return 'string'; }
function length(v){ return (v==null)?0:v.length; }
function trim(s){ return String(s==null?'':s).replace(/^\s+|\s+$/g,''); }
function substr(s,a,b){ return String(s).substr(a,b); }
function sprintf(f,...a){ let i=0; return String(f).replace(/%[sd]/g,()=>String(a[i++])); }
function match(s,re){ return String(s).match(re); }
function replace(s,re,r){ return String(s).replace(re,r); }
function json(s){ return JSON.parse(s); }

/* ---- 最小 UCI：只实现本脚本用到的 load/foreach/set/commit ---- */
let DB = [];
function parse(text){
  DB = []; let cur = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    let m = line.match(/^config\s+(\S+)(?:\s+'([^']*)')?/);
    if (m) { cur = { '.type': m[1], '.name': m[2] || ('cfg' + DB.length) }; DB.push(cur); continue; }
    m = line.match(/^option\s+'?([^'\s]+)'?\s+'([^']*)'/);
    if (m && cur) cur[m[1]] = m[2];
  }
}
function cursor(){ return {
  load(){ return true; },
  foreach(cfg, ty, cb){ for (const s of DB) if (s['.type'] === ty) cb(s); return true; },
  set(cfg, a, b, c){
    if (c === undefined) {                       /* 三段式 = 建命名段 */
      const s = DB.find(x => x['.name'] === a);
      if (s) { s['.type'] = b; } else DB.push({ '.type': b, '.name': a });
      return true;
    }
    const s = DB.find(x => x['.name'] === a);
    if (!s) throw new Error('set on missing section ' + a);
    s[b] = c; return true;
  },
  commit(){ return true; }
};}
function access(){ return false; }               /* 假装路由器上没有取数工具 */
function popen(){ return null; }
globalThis.__parse = parse;
"""

TEST = r"""
let fails = 0;
const eq = (a,b,n) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) fails++;
  console.log((ok ? '  ok  ' : '  FAIL') + '  ' + n +
    (ok ? '' : '   got=' + JSON.stringify(a) + '  want=' + JSON.stringify(b)));
};

/* 出厂配置：host 空着、push_interval 没写 */
__parse(`
config panel 'panel'
	option host ''
	option mdns 'openwrt-monitor'
	option enabled '1'
	option template 'overview'

config router 'router'
	option user 'root'
`);

const m = __API['luci.esp32-screen'];

let c = m.get.call({}).config;
eq(c.host, 'openwrt-monitor.local', 'get: 空 host 用 mDNS 拼出地址');
eq(c.host_source, 'mdns',           'get: host_source=mdns');
eq(c.template, 'overview',          'get: UCI 里的值');
eq(c.push_interval, '4',            'get: 缺失项回落默认值');
eq(c.user, 'root',                  'get: router 段');
eq(c.password, '',                  'get: 密码缺省空串');

let r = m.set.call({ args: { values: { host: '10.0.0.5', template: 'traffic', push_interval: 2, enabled: true } } });
eq(r.changed, 4, 'set: 写了 4 个键');
c = m.get.call({}).config;
eq(c.host, '10.0.0.5',   'set: host 生效');
eq(c.template, 'traffic','set: template 生效');
eq(c.push_interval, '2', 'set: 数字被转成字符串');
eq(c.enabled, '1',       'set: 布尔 true -> "1"');
eq(c.host_source, 'static','set: host_source 变 static');

r = m.set.call({ args: { values: { host: null } } });
eq(r.changed, 0, 'set: null 被跳过');
r = m.set.call({ args: { values: {} } });
eq(r.changed, 0, 'set: 空对象不写盘');
r = m.set.call({ args: { values: { evil: 'x' } } });
eq(r.changed, 0, 'set: 白名单外的键被忽略');

__parse('');
r = m.set.call({ args: { values: { host: '192.168.9.9' } } });
eq(r.changed, 1, 'set: 空配置也能自动建段');
eq(m.get.call({}).config.host, '192.168.9.9', 'set: 新建段后读回来');

let p = m.probe.call({ args: {} });
eq(typeof p.error, 'string', 'probe: 无取数工具时返回 error（不抛异常）');
eq(typeof m.probe.call({ args: { host: '' } }).error, 'string', 'probe: 空地址返回 error');

console.log(fails ? '\n' + fails + ' 项失败' : '\n全部通过');
process.exit(fails ? 1 : 0);
"""


def main() -> int:
    src = PLUGIN.read_text(encoding="utf-8")
    src = re.sub(r"^import \{[^}]*\} from '[^']*';\s*$", "", src, flags=re.M)
    wrapped = STUB + "\nfunction __main(){\n" + src + "\n}\n"
    wrapped += "const API = __main();\nglobalThis.__API = API;\n"

    with tempfile.TemporaryDirectory() as td:
        f = pathlib.Path(td) / "t.mjs"
        f.write_text(wrapped + TEST, encoding="utf-8")
        try:
            proc = subprocess.run(["node", str(f)], capture_output=True, text=True)
        except FileNotFoundError:
            print("需要 node 才能跑这个测试", file=sys.stderr)
            return 2
        print(proc.stdout, end="")
        if proc.stderr.strip():
            print(proc.stderr, file=sys.stderr)
        return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
