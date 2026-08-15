// LRC 解析的独立验证：node test/js/lrc_verify.js
//
// 和 lunar_verify.js 同一个路子——纯逻辑就该能脱离 Flutter 跑。
// 歌词解析错了不会崩，只会让整首歌错半拍，肉眼极难发现，所以必须有断言。
const path = require('path');
const LRC = require(path.join(__dirname, '..', '..', 'assets', 'plugins', 'lyrics', 'lrc.js'));

let pass = 0, fail = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log(`  ok   ${label}`); }
  else { fail++; console.log(`  FAIL ${label}\n       实际 ${a}\n       期望 ${e}`); }
}

console.log('— 时间戳解析 —');
eq(LRC.parse('[00:12.34]你好'), [{ t: 12340, s: '你好' }], '两位小数按百分秒');
eq(LRC.parse('[00:12.345]你好'), [{ t: 12345, s: '你好' }], '三位小数按毫秒');
eq(LRC.parse('[00:12.3]你好'), [{ t: 12300, s: '你好' }], '一位小数按十分之一秒');
eq(LRC.parse('[00:12]你好'), [{ t: 12000, s: '你好' }], '没有小数部分');
eq(LRC.parse('[01:02.50]x'), [{ t: 62500, s: 'x' }], '分钟进位');
eq(LRC.parse('[100:00.00]x'), [{ t: 6000000, s: 'x' }], '三位分钟（长音频）');
eq(LRC.parse('[00:12:34]你好'), [{ t: 12340, s: '你好' }], '冒号当小数点的变体');

console.log('— 一行多个时间戳 —');
eq(LRC.parse('[00:01.00][00:31.00]副歌'),
  [{ t: 1000, s: '副歌' }, { t: 31000, s: '副歌' }], '同一句展开成两条');

console.log('— 排序 —');
eq(LRC.parse('[00:20.00]后\n[00:10.00]先').map(x => x.t),
  [10000, 20000], '源文件乱序时按时间排好');

console.log('— 元信息与空行 —');
eq(LRC.parse('[ti:标题]\n[ar:歌手]\n[00:05.00]正文'),
  [{ t: 5000, s: '正文' }], '[ti:]/[ar:] 不当歌词');
eq(LRC.parse('\n\n[00:05.00]正文\n\n'), [{ t: 5000, s: '正文' }], '空行被跳过');
eq(LRC.parse('[00:05.00]'), [{ t: 5000, s: '' }], '空歌词行保留（间奏占位）');
eq(LRC.parse('没有时间戳的一行'), [], '无时间戳的行丢弃');
eq(LRC.parse(''), [], '空文本');
eq(LRC.parse(null), [], 'null 不炸');

console.log('— offset 时移 —');
eq(LRC.parse('[offset:500]\n[00:10.00]x'), [{ t: 9500, s: 'x' }], '正 offset 提前');
eq(LRC.parse('[offset:-500]\n[00:10.00]x'), [{ t: 10500, s: 'x' }], '负 offset 延后');

console.log('— 当前行定位 —');
const L = LRC.parse('[00:10.00]a\n[00:20.00]b\n[00:30.00]c');
eq(LRC.indexAt(L, 0), -1, '前奏返回 -1');
eq(LRC.indexAt(L, 9999), -1, '第一句前一毫秒仍是 -1');
eq(LRC.indexAt(L, 10000), 0, '正好落在第一句');
eq(LRC.indexAt(L, 19999), 0, '第一句持续到第二句之前');
eq(LRC.indexAt(L, 20000), 1, '第二句');
eq(LRC.indexAt(L, 999999), 2, '超出末尾停在最后一句');
eq(LRC.indexAt([], 100), -1, '空歌词');

console.log('— 翻译合并 —');
const main = LRC.parse('[00:10.00]hello\n[00:20.00]world');
const tr = LRC.parse('[00:10.00]你好');
eq(LRC.merge(main, tr),
  [{ t: 10000, s: 'hello', tr: '你好' }, { t: 20000, s: 'world', tr: '' }],
  '对得上时间戳的才合并');
eq(LRC.merge(main, []), main, '没有翻译时原样返回');

console.log('— 时间格式化 —');
eq(LRC.fmt(0), '0:00', '零');
eq(LRC.fmt(65000), '1:05', '一分零五秒');
eq(LRC.fmt(217333), '3:37', '实测那首泡泡的时长');
eq(LRC.fmt(3661000), '1:01:01', '超过一小时带小时位');
eq(LRC.fmt(-5), '0:00', '负数按零');

console.log(`\n结果：${pass} 通过，${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
