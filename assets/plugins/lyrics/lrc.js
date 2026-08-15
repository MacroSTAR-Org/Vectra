/**
 * LRC 歌词解析（纯函数，可单独用 node 跑验证：test/js/lrc_verify.js）
 *
 * 单独成文件是为了能脱离 QuickJS 测——里面全是边界条件：一行多个时间戳、
 * 毫秒 2 位还是 3 位、[ti:]/[ar:] 这类元信息、时间戳乱序、空行。
 * 这些错了不会崩，只会让歌词错半拍，肉眼很难发现，所以必须有断言兜着。
 */

/* global globalThis */
(function (root) {
  'use strict';

  // [mm:ss.xx] 或 [mm:ss:xx]（少数源用冒号）或 [mm:ss]
  var TIME_RE = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;

  // 元信息行：[ti:标题] [ar:歌手] [al:专辑] [by:] [offset:] 等
  var META_RE = /^\[[a-zA-Z]+:/;

  /**
   * 把 LRC 文本解析成按时间升序的数组。
   * @param {string} text
   * @returns {Array<{t:number, s:string}>} t 是毫秒
   */
  function parse(text) {
    if (typeof text !== 'string' || !text) return [];
    var out = [];
    var lines = text.split(/\r?\n/);
    var offset = 0;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line) continue;

      // [offset:-500] 是整体时移，正数表示歌词提前
      var om = /^\[offset:\s*([+-]?\d+)\s*\]/i.exec(line);
      if (om) {
        offset = parseInt(om[1], 10) || 0;
        continue;
      }

      TIME_RE.lastIndex = 0;
      var stamps = [];
      var m;
      while ((m = TIME_RE.exec(line)) !== null) {
        var min = parseInt(m[1], 10);
        var sec = parseInt(m[2], 10);
        var frac = m[3];
        var ms = 0;
        if (frac !== undefined) {
          // "5" -> 500ms，"50" -> 500ms，"500" -> 500ms
          // 两位是百分秒（绝大多数 LRC），三位才是毫秒
          if (frac.length === 1) ms = parseInt(frac, 10) * 100;
          else if (frac.length === 2) ms = parseInt(frac, 10) * 10;
          else ms = parseInt(frac, 10);
        }
        stamps.push(min * 60000 + sec * 1000 + ms);
      }

      if (stamps.length === 0) continue;

      // 去掉所有时间戳后剩下的才是正文
      var textPart = line.replace(TIME_RE, '').trim();
      // 元信息行（[ti:...]）不会匹配上 TIME_RE，所以走不到这儿；
      // 但有的源会写成 [00:00.00][ti:xxx]，兜一下
      if (META_RE.test(textPart)) continue;

      for (var k = 0; k < stamps.length; k++) {
        out.push({ t: stamps[k] - offset, s: textPart });
      }
    }

    // 源文件不保证有序（一行多时间戳就必然乱序）
    out.sort(function (a, b) { return a.t - b.t; });
    return out;
  }

  /**
   * 找出 posMs 时刻应该高亮第几行。
   * 返回 -1 表示还没到第一句（前奏）。
   *
   * 用二分而不是遍历：这个函数每 100ms 调一次，歌词可能上百行。
   */
  function indexAt(lines, posMs) {
    if (!lines || lines.length === 0) return -1;
    if (posMs < lines[0].t) return -1;
    var lo = 0, hi = lines.length - 1, ans = 0;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (lines[mid].t <= posMs) { ans = mid; lo = mid + 1; }
      else { hi = mid - 1; }
    }
    return ans;
  }

  /**
   * 把网易云的原文与翻译两段 LRC 合成一段：翻译接在原文后面。
   * 时间戳对不上的翻译行直接丢掉——宁可不显示，也不要错位显示。
   */
  function merge(main, trans) {
    if (!trans || trans.length === 0) return main;
    var map = {};
    for (var i = 0; i < trans.length; i++) map[trans[i].t] = trans[i].s;
    var out = [];
    for (var k = 0; k < main.length; k++) {
      var tr = map[main[k].t];
      out.push({
        t: main[k].t,
        s: main[k].s,
        tr: tr && tr !== main[k].s ? tr : ''
      });
    }
    return out;
  }

  /** 毫秒 -> "m:ss"，超过一小时才带小时位 */
  function fmt(ms) {
    if (!isFinite(ms) || ms < 0) ms = 0;
    var total = Math.floor(ms / 1000);
    var s = total % 60;
    var m = Math.floor(total / 60) % 60;
    var h = Math.floor(total / 3600);
    var mm = h > 0 && m < 10 ? '0' + m : String(m);
    var ss = s < 10 ? '0' + s : String(s);
    return h > 0 ? h + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  /** 归一化：比较标题/歌手时忽略大小写、空格、标点和括号里的内容 */
  function norm(s) {
    return String(s || '')
      .toLowerCase()
      .replace(/[（(\[].*?[)）\]]/g, '')
      .replace(/[\s\-_·,，.。!！?？'"“”‘’]/g, '');
  }

  // 伴奏 / remix / 现场版之类的衍生版本
  var JUNK = /(伴奏|instrumental|remix|dj版|纯享|翻自|cover|live|现场|demo|加速|减速|钢琴版|吉他版)/i;

  /**
   * 从搜索结果里挑一首。
   *
   * 两条实测教训写在这里，别再踩：
   *   1. 只按时长最接近会选错。搜「泡泡 牛佳钰」时，纯伴奏版与原曲只差 31ms，
   *      光比时长会挑中伴奏——歌词是对的，歌是错的。所以要给伴奏/Remix 扣分。
   *   2. 标题不能按字面严格比。播放器给的常是繁体（Spotify 上「陽光下的星星」），
   *      而曲库里是简体「阳光下的星星」，字面永远对不上。搜索引擎自己已经做过
   *      繁简归一了（实测搜繁体能返回简体结果），所以这里的打分只负责**排除
   *      明显不对的**，不该再去重做一遍模糊匹配——否则会把正确结果挡在门外。
   *
   * @param {Array} songs 网易云搜索返回的 songs
   * @param {string} title @param {string} artist @param {number} durMs 来自 SMTC
   * @returns {object|null} 选中的 song，或 null 表示没有够格的
   */
  function pickSong(songs, title, artist, durMs) {
    if (!songs || !songs.length) return null;
    var nt = norm(title), na = norm(artist);
    var best = null, bestScore = -1e9;

    for (var i = 0; i < songs.length; i++) {
      var s = songs[i];
      var names = [];
      for (var k = 0; k < (s.artists || []).length; k++) names.push(s.artists[k].name);
      var an = norm(names.join('/'));
      var sn = norm(s.name);
      var score = 0;

      // 歌手是最硬的信号：对上加分，明确对不上重扣，取不到就不表态
      if (na && an) {
        if (an.indexOf(na) >= 0 || na.indexOf(an) >= 0) score += 60;
        else score -= 40;
      }

      // 时长：3 秒内视为一致
      if (durMs > 0 && s.duration > 0) {
        var diff = Math.abs(s.duration - durMs);
        if (diff <= 3000) score += 50;
        else score -= Math.min(50, (diff - 3000) / 1000 * 3);
      }

      // 标题只加分不重扣（繁简、异体字、副标题都会让字面对不上）
      if (sn === nt) score += 40;
      else if (sn.indexOf(nt) >= 0 || nt.indexOf(sn) >= 0) score += 25;

      // 原曲名里本来就写着 Live/Remix 时不该扣
      if (JUNK.test(s.name) && !JUNK.test(title)) score -= 70;

      // 搜索引擎的排序本身就是信息，靠前的略微加分
      score += Math.max(0, 10 - i * 2);

      if (score > bestScore) { bestScore = score; best = s; }
    }
    // 够不到门槛就宁可显示"没找到"，也不要贴一首别的歌的歌词
    return bestScore >= 60 ? best : null;
  }

  var api = {
    parse: parse,
    indexAt: indexAt,
    merge: merge,
    fmt: fmt,
    norm: norm,
    pickSong: pickSong
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;   // node 跑验证时用
  } else {
    root.LRC = api;         // QuickJS 里挂到全局，index.js 直接用
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
