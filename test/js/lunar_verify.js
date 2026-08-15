const L = require('../../assets/plugins/calendar/lunar.js');
let pass = 0, fail = 0;
function eq(actual, expect, what) {
  if (actual === expect) { pass++; console.log('  通过  ' + what + ' = ' + actual); }
  else { fail++; console.log('  失败  ' + what + '：期望 ' + expect + '，实际 ' + actual); }
}

console.log('--- 用户截图里的已知值（2026年8月）---');
eq(L.fromSolar(2026, 8, 10).dayText, '廿八', '2026-08-10 农历');
eq(L.fromSolar(2026, 8, 12).dayText, '三十', '2026-08-12 农历');
eq(L.fromSolar(2026, 8, 13).d, 1, '2026-08-13 是初一');
eq(L.fromSolar(2026, 8, 13).monthText, '七月', '2026-08-13 月份');
eq(L.termOf(2026, 8, 7), '立秋', '2026-08-07 节气');
eq(L.termOf(2026, 8, 23), '处暑', '2026-08-23 节气');
eq(L.fromSolar(2026, 7, 27).dayText, '十四', '2026-07-27 农历（上月拖尾）');
eq(L.fromSolar(2026, 9, 1).dayText, '二十', '2026-09-01 农历（下月开头）');
eq(L.fromSolar(2026, 8, 14).dayText, '初二', '2026-08-14 农历');
eq(L.fromSolar(2026, 8, 31).dayText, '十九', '2026-08-31 农历');

console.log('--- 其它独立基准 ---');
eq(L.fromSolar(2024, 2, 10).monthText + L.fromSolar(2024, 2, 10).dayText, '正月初一', '2024-02-10 春节');
eq(L.festivalOf(2024, 2, 10, L.fromSolar(2024, 2, 10)).name, '春节', '2024 春节');
eq(L.fromSolar(2025, 1, 29).monthText + L.fromSolar(2025, 1, 29).dayText, '正月初一', '2025-01-29 春节');
eq(L.fromSolar(2023, 9, 29).monthText + L.fromSolar(2023, 9, 29).dayText, '八月十五', '2023-09-29 中秋');
eq(L.termOf(2026, 4, 5) || L.termOf(2026, 4, 4), '清明', '2026 清明在 4/4 或 4/5');
eq(L.fromSolar(2023, 3, 22).monthText, '闰二月', '2023-03-22 闰二月');

console.log('\n通过 ' + pass + ' / ' + (pass + fail));
process.exit(fail ? 1 : 0);
