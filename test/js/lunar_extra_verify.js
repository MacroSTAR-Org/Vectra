const L = require('../../assets/plugins/calendar/lunar.js');
let p=0,f=0;
function eq(a,b,w){ if(a===b){p++;console.log('  通过  '+w+' = '+a);} else {f++;console.log('  失败  '+w+'：期望 '+b+'，实际 '+a);} }
eq(L.ganzhi(2026), '丙午', '2026 干支');
eq(L.zodiac(2026), '马', '2026 生肖');
eq(L.ganzhi(2024), '甲辰', '2024 干支');
eq(L.zodiac(2024), '龙', '2024 生肖');
const n = L.nextTerm(2026, 8, 10);
eq(n.name, '处暑', '2026-08-10 之后最近节气');
eq(n.days, 13, '距处暑天数');
console.log('\n通过 '+p+' / '+(p+f));
process.exit(f?1:0);
