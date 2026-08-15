// 搜索结果挑选逻辑的验证：node test/js/pick_verify.js
//
// 单独一个文件，因为这里的每条用例都是真实踩过的坑，不是想出来的边界：
// 选错歌不会报错、不会崩，只会安静地显示另一首歌的歌词。
const path = require('path');
const LRC = require(path.join(__dirname, '..', '..', 'assets', 'plugins', 'lyrics', 'lrc.js'));

let pass = 0, fail = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log(`  ok   ${label}`); }
  else { fail++; console.log(`  FAIL ${label}\n       实际 ${a}\n       期望 ${e}`); }
}

console.log('— 坑一：伴奏版的时长比原曲还接近 —');
// 实测搜「泡泡 牛佳钰」的真实返回：纯伴奏与原曲只差 31ms。
// 只按时长最接近会选中伴奏，歌词对得上、歌是错的。
const bubbles = [
  { id: 1444879856, name: '泡泡', artists: [{ name: '牛佳钰' }], duration: 217333 },
  { id: 1446907950, name: '泡泡（吉他弹唱DEMO）', artists: [{ name: '牛佳钰' }], duration: 206666 },
  { id: 1444885128, name: '泡泡 伴奏', artists: [{ name: '牛佳钰' }], duration: 217364 },
  { id: 3409219157, name: '泡泡 (Remix)', artists: [{ name: '星华' }], duration: 220380 },
];
eq(LRC.pickSong(bubbles, '泡泡', '牛佳钰', 217333).id, 1444879856,
  '原曲胜过时长更接近的伴奏');
eq(LRC.pickSong([bubbles[2], bubbles[0]], '泡泡', '牛佳钰', 217333).id, 1444879856,
  '伴奏排在第一位也不该被选走');

console.log('— 坑二：播放器给繁体，曲库是简体 —');
// Spotify 上这首叫「陽光下的星星」，网易云曲库里是「阳光下的星星」。
// 按字面严格比会把正确结果挡在门外，卡片显示"没找到歌词"。
// 搜索引擎本身已经做过繁简归一（实测搜繁体能返回简体结果），
// 所以打分只该排除明显不对的，不该重做一遍模糊匹配。
const sunshine = [
  { id: 1, name: '阳光下的星星', artists: [{ name: '金海心' }], duration: 283520 },
  { id: 2, name: '阳光下的星星', artists: [{ name: '雷米克斯' }], duration: 101302 },
  { id: 3, name: '阳光下的星星（空悲切）', artists: [{ name: '林玖儿' }], duration: 165447 },
];
eq(LRC.pickSong(sunshine, '陽光下的星星', '金海心', 283000).id, 1,
  '繁体标题要能选中简体曲库里的同一首');

console.log('— 宁可没有，不要错 —');
eq(LRC.pickSong(sunshine, '完全不相干的歌', '某个人', 60000), null,
  '没有够格的就返回 null');
eq(LRC.pickSong([], '任意', '任意', 1000), null, '空结果集');
eq(LRC.pickSong(null, '任意', '任意', 1000), null, 'null 不炸');

console.log('— 浏览器场景：SMTC 常常给不出歌手 —');
eq(LRC.pickSong(sunshine, '阳光下的星星', '', 283000).id, 1,
  '没有歌手时靠标题+时长也能定位');
eq(LRC.pickSong(sunshine, '', '', 0), null,
  '标题歌手时长全都没有，就不该硬猜');

console.log('— 归一化 —');
eq(LRC.norm('泡泡 (Live)'), '泡泡', '去掉括号内容');
eq(LRC.norm('  A-B_C  '), 'abc', '去掉空格连接符并转小写');
eq(LRC.norm(null), '', 'null 归一成空串');

console.log(`\n结果：${pass} 通过，${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
