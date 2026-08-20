/**
 * 歌词插件
 *
 * 数据分两路，这是设计上的关键：
 *   「正在放什么」全部来自 Windows 系统媒体控件（SMTC）——标题、歌手、专辑、
 *     封面、进度、能不能上/下一首、能不能拖进度，都是播放器自己注册进系统的。
 *     所以不需要给每个播放器写适配，也不用去扒它的私有接口。
 *   「歌词」来自网络（网易云 / LRCLIB），因为 SMTC 根本不提供歌词。
 *
 * 位置为什么要自己外推：native 每 250ms 才采样一次 SMTC，直接拿那个值画进度条
 * 会一顿一顿的。快照里带了"读到这个位置时的本地时刻"，播放中按流逝时间往前推
 * 即可，切歌/暂停/拖动时快照会纠正回来。
 */
lw.register({
  mount: function (ctx) {
    var S = ctx.settings || {};
    var W = ctx.size.w, H = ctx.size.h;

    // ---- 界面尺寸：按卡片高度缩放，小尺寸也不至于挤成一团 ----
    var PAD = 12;
    // ---- 左列：封面 / 歌名 / 歌手 ----
    //
    // 文字块的高度按字号估算过两次都估少了（先 46 后 54），结果都是歌手那行
    // 被卡片底边切掉半截。中文字体的实际行高比字号大不少，与其继续凑数字，
    // 不如给足余量——封面小一点没人介意，字被切一半很难看。
    var TEXT_BLOCK = 70;
    // 封面也别占太宽，右边留给歌词。
    //
    // 封面和文字块之间还有一条 8px 的 gap（见下面 left 列的 col gap:8），
    // 之前算 artSize 时漏了这一段，导致左列总高度 = artSize + 8 + TEXT_BLOCK
    // 永远比"能用的高度"多 8px，卡片矮的时候这条缝正好就是溢出的那几像素。
    var ART_GAP = 8;
    var artSize = Math.min(H - PAD * 2 - TEXT_BLOCK - ART_GAP, Math.round(W * 0.24));
    if (artSize < 52) artSize = 52;

    // ---- 右列：按钮 + 进度条 + 歌词 ----
    var lyricSize = H >= 380 ? 15.5 : (H >= 260 ? 14 : 13);
    // 行高：不再用"字号乘系数"去猜真实字体的行高——这条路已经错过三次
    // （TEXT_BLOCK 猜过两次都少了，这里的 *1.35 公式后来实测也不够）。
    // 下面这张表是拿真机同款字体（HarmonyOS Sans SC）实际量出来的单行/
    // 双语组合高度（量法见 test/lyric_line_measure_test.dart），三档字号
    // 和上面 lyricSize 的三个断点一一对应。+8 是行内 pad:[4,0] 的上下留白，
    // 量出来的是纯文字高度，边距要另外算；再加 2px 做很小的容错余量。
    var LINE_METRICS = {
      13:   { single: 21, bilingual: 37 },
      14:   { single: 23, bilingual: 41 },
      15.5: { single: 25, bilingual: 45 }
    };
    var metrics = LINE_METRICS[lyricSize] || LINE_METRICS[13];
    // 只有"正在唱"的这一行值得占双语的高度——上下文行本来就压到 0.14~0.55
    // 的透明度，译文在那个淡度下基本看不清，之前每一行都按双语预留高度，
    // 白白吃掉大半空间。改成只有当前行显示译文（下面 lyricArea 里按
    // dist===0 判断），上下文行只留单行高度，矮卡片也能多挤出一两行。
    var LINE_CONTEXT = metrics.single + 10;
    var LINE_CURRENT = (S.trans ? metrics.bilingual : metrics.single) + 10;
    // 歌词占位符（找不到歌词时显示的提示语）沿用上下文行的高度就够。
    var LINE_H = LINE_CONTEXT;
    // 右列上半部分（按钮 + 进度条 + 时间 + 各处间隔）占掉的高度。
    //
    // 这个数原来写死 113，注释说是"从截图上量的"——用同样的手法（拿真实
    // 字体在 flutter_test 里量，见 test/lyrics_head_measure_test.dart）
    // 重新量了一遍，三个按钮 + 两条 gap:6 + 进度条 + 时间行实际只要 73，
    // 113 多出来的 40 白白占掉了本该留给歌词的空间。改回量出来的数字，
    // 只加 3px 容错（不同缩放/DPI 下取整的误差），不再多加"保险余量"。
    var CTRL_SIDE = 26;   // 上一首 / 下一首
    var CTRL_MAIN = 34;   // 播放 / 暂停
    var CTRL_BOX = 42;    // 三个按钮共用的方盒子边长
    var HEAD_H = 76 + (CTRL_BOX - 42);
    // 行数按实际剩余高度算，而不是写死几档——卡片拉多大就显示多少行。
    //
    // 窗口里只有 1 行是"当前行"（占 LINE_CURRENT），其余都是上下文行
    // （占 LINE_CONTEXT），按这个组合去解能放几行，而不是不管三七二十一
    // 用同一个行高乘个数——那样要么当前行装不下、要么上下文行浪费空间。
    //
    // 这里之前强制"至少 3 行"，本意是不想让卡片矮的时候歌词区显得太空，
    // 但矮而宽的卡片（比如默认的 5x2）开着双语歌词时，物理上就是装不下
    // 3 行（头部 + 1 行双语当前行就已经用掉大半高度），却依然被强制塞
    // 3 行，这才是"歌词区顶穿卡片底边"反复出现的真正原因。宁可矮卡片上
    // 歌词行数少（至少 1 行，保证当前唱的这句总能完整露出来），也不要
    // 为了凑够 3 行去撑爆卡片——嫌行数太少，把卡片拉高或者关掉"显示翻译"
    // 就能多显示几行，这是空间的物理限制，不是能靠算法凑出来的。
    var avail = H - PAD * 2 - HEAD_H - 12;
    var lyricLines = Math.floor((avail - LINE_CURRENT) / LINE_CONTEXT) + 1;
    if (lyricLines < 1) lyricLines = 1;
    // 上限只是防呆。之前写死 10，结果 6x4 的卡片底下空了一大块。
    if (lyricLines > 20) lyricLines = 20;

    // ---- 运行时状态 ----
    var media = null;        // 最近一次「有歌在放」的 SMTC 快照
    var lyrics = [];         // [{t, s, tr}]
    var lyricState = 'idle'; // idle | loading | ok | none
    var trackKey = '';       // 当前歌的标识（含时长），变了就重新找歌词
    var viewKey = 'idle';    // 整卡内容版本：切歌（歌名/歌手）变化时整卡交叉淡入
    var idleMs = 0;          // SMTC 连续无效的毫秒数，超过宽限才认定停播
    var IDLE_GRACE = 3000;   // 切歌/刷新间隙的宽限：期内保留旧画面，不闪空
    var lastPaint = '';      // 上一帧的可见内容指纹，没变就不重绘
    var lastPos = 0;         // 上一次算出来的位置，用于压掉小幅回跳

    // ---- 事件处理器（id 在树里引用）----
    var hPrev = ctx.on(function () { ctx.media.prev(); });
    var hToggle = ctx.on(function () { ctx.media.toggle(); });
    var hNext = ctx.on(function () { ctx.media.next(); });
    var hSeek = ctx.on(function (p) {
      if (!media || !media.duration) return;
      lastPos = 0;   // 定位是大跳，先解除单调保护
      ctx.media.seek(p.value * media.duration);
    });
    // 点某一行歌词跳到那一句。行数按卡片高度算，最多 20 行，handler 必须备齐
    var hLine = [];
    for (var i = 0; i < lyricLines; i++) {
      hLine.push(ctx.on((function (slot) {
        return function () {
          var idx = window_.base + slot;
          if (idx >= 0 && idx < lyrics.length) { lastPos = 0; ctx.media.seek(lyrics[idx].t); }
        };
      })(i)));
    }
    // 当前显示的是歌词的哪一段，供上面的点击换算成绝对行号
    var window_ = { base: 0 };

    // ------------------------------------------------------------------
    // 取歌词
    // ------------------------------------------------------------------

    // 网易云是非官方接口，带上正常的 UA/Referer 降低被限流的概率。
    // 实测目前不带也能通，但它随时可能收紧。
    var NE_HEADERS = {
      headers: {
        'Referer': 'https://music.163.com/',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
      }
    };

    // 网易云的歌词开头常有一串「作词 : X」「编曲 : Y」，它们也带时间戳，
    // 会占掉开头十几秒的显示。设置里可以关掉。
    var CREDIT_RE = /^\s*(作词|作曲|编曲|制作人|monitor|录音|混音|母带|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|企划|出品|发行|监制|制作|营销|策划|录音室|Producer|Composer|Lyricist|Arranger|Mixing|Mastering)\s*[:：]/i;

    function stripCredits(arr) {
        if (S.credits) return arr;
        var out = arr.filter(function (l) { return !CREDIT_RE.test(l.s || ''); });
        // 万一整首歌被当成名单滤空了，宁可原样显示也别显示空白
        return out.length >= 4 ? out : arr;
    }

    // 搜索结果的挑选逻辑放在 lrc.js 里，因为它是纯函数、而且极易悄悄选错
    // （实测踩过两次：伴奏版时长更接近、繁体标题字面对不上）。
    // 放那边才能用 node 跑断言，见 test/js/lrc_verify.js。
    var pickSong = LRC.pickSong;

    function fetchNetease(title, artist, durMs) {
      var q = encodeURIComponent((title + ' ' + artist).trim());
      var url = 'https://music.163.com/api/search/get?s=' + q + '&type=1&limit=10';
      return ctx.http.getJSON(url, NE_HEADERS).then(function (r) {
        if (!r.ok || !r.data || !r.data.result) return null;
        var songs = r.data.result.songs || [];
        if (!songs.length) return null;
        var song = pickSong(songs, title, artist, durMs);
        if (!song) return null;
        var lu = 'https://music.163.com/api/song/lyric?id=' + song.id + '&lv=1&kv=1&tv=-1';
        return ctx.http.getJSON(lu, NE_HEADERS).then(function (r2) {
          if (!r2.ok || !r2.data || !r2.data.lrc) return null;
          var main = stripCredits(LRC.parse(r2.data.lrc.lyric || ''));
          if (!main.length) return null;
          if (S.trans && r2.data.tlyric) {
            return LRC.merge(main, LRC.parse(r2.data.tlyric.lyric || ''));
          }
          return main;
        });
      });
    }

    function fetchLrclib(title, artist, durMs) {
      var u = 'https://lrclib.net/api/get?track_name=' + encodeURIComponent(title) +
        '&artist_name=' + encodeURIComponent(artist);
      if (durMs > 0) u += '&duration=' + Math.round(durMs / 1000);
      return ctx.http.getJSON(u).then(function (r) {
        // 找不到时 LRCLIB 返回 404，宿主会包成 {ok:false}
        if (!r.ok || !r.data) return null;
        var synced = r.data.syncedLyrics;
        if (!synced) return null;   // 只有无时间轴的纯文本就当没有
        var arr = stripCredits(LRC.parse(synced));
        return arr.length ? arr : null;
      });
    }

    function loadLyrics(title, artist, durMs, key) {
      // 只在没有旧歌词时设 loading（首次加载），有旧歌词时保留原状态，
      // 避免 lyricState 变化触发重绘导致闪白。
      if (!lyrics.length) lyricState = 'loading';
      // 缓存键就是这首歌的标识：标题|歌手|时长秒，含时长。
      //
      // 时长是版本的区分依据：同名同歌手的现场版与录音室版时长不同，歌词的
      // 时间轴也对不上，共用一份缓存会串。代价是 SMTC 报时长有个过程（先 0，
      // 再真实值，偶尔还抖动），同一首歌可能落成几个键、各自抓一次——用
      // 缓存容量换准确度。
      var cacheKey = key;

      ctx.storage.cacheGet(cacheKey).then(function (cached) {
        if (trackKey !== key) return;             // 加载期间已经换歌了
        if (cached && cached.length) {
          lyrics = cached;
          lyricState = 'ok';
          paint(true);
          return;
        }
        var src = S.source || 'auto';
        var chain;
        if (src === 'lrclib') {
          chain = fetchLrclib(title, artist, durMs);
        } else if (src === 'netease') {
          chain = fetchNetease(title, artist, durMs);
        } else {
          chain = fetchNetease(title, artist, durMs).then(function (r) {
            return r || fetchLrclib(title, artist, durMs);
          });
        }
        chain.then(function (arr) {
          if (trackKey !== key) return;
          if (arr && arr.length) {
            lyrics = arr;
            lyricState = 'ok';
            saveCache(cacheKey, arr);
          } else {
            lyrics = [];
            lyricState = 'none';
          }
          paint(true);
        }, function () {
          if (trackKey !== key) return;
          lyrics = [];
          lyricState = 'none';
          paint(true);
        });
      });
    }

    /**
     * 歌词缓存。
     *
     * 用 cacheSet 而不是 set：缓存是一条一个文件，写一首只动那 4KB，也不用
     * 自己记账淘汰——超量由宿主按时间清理。以前塞在键值存储里，每存一首都
     * 要重写整份文件，只好把上限压到 20 首并手写一套 LRU；现在两个理由都
     * 没有了，那套记账已经删掉。
     */
    function saveCache(key, arr) {
      ctx.storage.cacheSet(key, arr);
    }

    /**
     * 一次性清掉旧版留在键值存储里的歌词缓存。
     *
     * 旧版把歌词存成 lrc:* 键并用 lru 数组记账。缓存本身不搬迁——重抓即可，
     * 不值得为此留一段永久的迁移代码；这里只把键清掉，让 lyrics.json 缩回
     * 该有的大小。lru 数组正好就是当时还活着的那些键的清单。
     * 存量的 null 墓碑由宿主在加载时清理。
     */
    function purgeLegacyCache() {
      ctx.storage.get('lru', null).then(function (lru) {
        if (!lru || !lru.length) return;
        for (var i = 0; i < lru.length; i++) ctx.storage.set(lru[i], null);
        ctx.storage.set('lru', null);
      });
    }

    // ------------------------------------------------------------------
    // 采样与绘制
    // ------------------------------------------------------------------

    /** 播放中按流逝时间外推位置，把 250ms 的采样间隔抹平 */
    function nowPos() {
      if (!media || !media.available) return 0;
      var p = media.position || 0;
      if (media.status === 4) {
        // 两段都要补，缺一段秒数就会一跳一跳：
        //   positionAge 是播放器上报这个位置到 native 采样之间的时间。播放器
        //     并不逐帧更新 SMTC，实测 Spotify 约 4.5 秒才推一次，只用原始值
        //     界面就是"5 秒一步进"。
        //   __localAt 是 Dart 收到快照到现在（本地 100ms 轮询一次）。
        p += media.positionAge || 0;
        if (media.__localAt) p += Date.now() - media.__localAt;
      }
      if (p < 0) p = 0;
      if (media.duration > 0 && p > media.duration) p = media.duration;
      // 小幅回跳压掉。实测播放器暂停时也会周期性刷新 LastUpdatedTime，
      // 万一某个播放器播放中也这么干，补出来的位置就会锯齿状往回跳。
      // 只压 2 秒以内的倒退——真正的拖动定位是大跳，必须放过去。
      if (lastPos > 0 && p < lastPos && lastPos - p < 2000) p = lastPos;
      lastPos = p;
      return p;
    }

    function tick() {
      ctx.media.state().then(function (r) {
        if (!r || !r.ok) return;
        var d = r.data;

        if (d.available && d.title) {
          // 快照只在「确实有歌」时才生效。切歌间隙不少播放器会把 available
          // 翻成 false 或清空 title（实测网易云 / Spotify 都有），拿那种
          // 快照去画，整卡会先闪一下「没有正在播放」再跳回来。
          d.__localAt = Date.now();
          media = d;
          idleMs = 0;

          var key = d.title + '|' + d.artist + '|' + Math.round((d.duration || 0) / 1000);
          if (key !== trackKey) {
            trackKey = key;
            // 整卡内容版本只跟「哪首歌」走，不跟时长走：切歌才整卡交叉淡入，
            // 同一首歌的时长从 0 刷新到正常值不会触发第二次整卡过渡（否则闪两次）。
            viewKey = d.title + '|' + (d.artist || '');
            lastPos = 0;
            // 不清空 lyrics：保留旧歌词直到新歌词加载完成，
            // 避免加载期间出现空白闪屏。新歌词到达时直接整块替换。
            window_.base = 0;
            loadLyrics(d.title, d.artist, d.duration || 0, key);
          }
        } else if (idleMs < IDLE_GRACE) {
          // 信号短暂丢失（切歌间隙 / 播放器刷新元数据）：保持上一份快照
          // 和旧歌词原地继续显示，任何一帧都不允许出现空白。
          idleMs += 100;
        } else if (media) {
          // 连续 IDLE_GRACE 没有有效信号：认定停播，切回空态。
          // 歌词**不清空**——万一是超长切歌间隙，新歌来了旧歌词还能继续
          // 顶着显示，直到新歌词就绪，歌词区绝不出现空白。
          media = null;
          lyricState = 'idle';
        }
        paint(false);
      });
    }

    /**
     * 只有可见内容真的变了才 render。
     *
     * 这个函数每 100ms 调一次，而 render 会把整棵树 JSON 序列化一遍再让宿主
     * 重建 widget。指纹里放的就是"肉眼能看出来的东西"：当前歌词行、秒数、
     * 播放状态、进度条的像素位置。进度条按像素取整——一条 300px 的条，
     * 位置变化不到 1px 时重绘是纯浪费。
     */
    function paint(force) {
      var pos = nowPos();
      var idx = LRC.indexAt(lyrics, pos);
      var barPx = media && media.duration > 0
        ? Math.round(pos / media.duration * 300) : 0;
      var sig = [
        media && media.available ? 1 : 0,
        trackKey, lyricState, idx, barPx,
        Math.floor(pos / 1000), media ? media.status : -1
      ].join('\u0001');
      if (!force && sig === lastPaint) return;
      lastPaint = sig;
      ctx.render(view(pos, idx));
    }

    // ------------------------------------------------------------------
    // 视图
    // ------------------------------------------------------------------

    function txt(v, size, color, opacity, extra) {
      var n = { t: 'text', v: v, size: size, color: color, opacity: opacity };
      if (extra) for (var k in extra) n[k] = extra[k];
      return n;
    }

    /**
     * 一个控制按钮。
     *
     * 三个按钮的图标大小不一样（播放键比前后曲大一圈），所以每个都塞进
     * **同样大小**的方盒子里居中，让三者的中心落在同一条水平线上。
     * 只靠 padding 的话盒子高度就跟着图标走，行内会一高一矮。
     */
    function iconBtn(name, handler, size, enabled, box) {
      var icon = {
        t: 'icon',
        v: name,
        size: size,
        color: enabled ? '#FFFFFF' : '#7A7A7A'
      };
      var cell = { t: 'box', w: box, h: box, center: true, child: icon };
      return enabled ? { t: 'tap', id: handler, child: cell } : cell;
    }

    /** 没有任何播放器在放歌 */
    function idleView() {
      return {
        // key 固定为 'idle'：与播放视图的 key（歌名|歌手）不同，
        // 停播/开播切换时整卡交叉淡入，而不是原地硬切
        key: 'idle',
        t: 'box', pad: PAD, center: true,
        child: {
          t: 'col', gap: 8, cross: 'center',
          children: [
            { t: 'icon', v: 'music', size: 26, color: '#FFFFFF', opacity: 0.25 },
            txt('没有正在播放的音乐', 12, null, 0.45),
            txt('支持 SMTC 的播放器都能读到（网易云 / QQ 音乐 / Spotify / 浏览器）',
              10, null, 0.25, { align: 'center', maxLines: 2 })
          ]
        }
      };
    }

    function lyricArea(idx) {
      // 当前行偏上显示：上方留约 1/3、下方留 2/3——主流播放器都把正在唱的
      // 那句放在窗口上半部，给接下来的歌词留出更多空间
      var before = Math.max(0, Math.floor((lyricLines - 1) / 3));
      var base = idx < 0 ? 0 : idx - before;
      if (base > lyrics.length - lyricLines) base = lyrics.length - lyricLines;
      if (base < 0) base = 0;
      window_.base = base;

      var rows = [];
      for (var i = 0; i < lyricLines; i++) {
        var li = base + i;
        if (li >= lyrics.length) {
          rows.push({ t: 'box', h: LINE_CONTEXT });
          continue;
        }
        var line = lyrics[li];
        var dist = Math.abs(li - idx);
        var isCurrent = dist === 0;
        // 焦点层级：越远越淡
        var op, trOp, sz, wt;
        if (dist === 0) {
          op = 1; trOp = 0.7; sz = lyricSize + 2; wt = 700;
        } else if (dist === 1) {
          op = 0.55; trOp = 0.35; sz = lyricSize; wt = 400;
        } else if (dist === 2) {
          op = 0.32; trOp = 0.2; sz = lyricSize; wt = 400;
        } else {
          op = 0.14; trOp = 0.08; sz = lyricSize; wt = 400;
        }
        var body = txt(line.s || '·', sz, null, op,
          { maxLines: 1, weight: wt });
        // 译文只在"正在唱"的这一行显示：上下文行本来就压到很淡的透明度，
        // 译文在那个淡度下基本看不清，全部显示只是白白占空间（见上面
        // LINE_CONTEXT/LINE_CURRENT 的说明）。
        var cell = (isCurrent && line.tr)
          ? { t: 'col', gap: 2, children: [body, txt(line.tr, lyricSize - 3, null, trOp, { maxLines: 1 })] }
          : body;
        // h + clip：每一行都钉死在各自的高度预算内，超出的部分（比如字号/
        // 字重估算的一两像素误差）直接裁掉，而不是把整个歌词区顶高、拖累
        // 外层 Column 整体溢出到卡片底边外。
        rows.push({
          t: 'tap', id: hLine[i],
          child: {
            t: 'box', h: isCurrent ? LINE_CURRENT : LINE_CONTEXT,
            clip: true, pad: [4, 0], child: cell
          }
        });
      }
      return { t: 'box', child: { t: 'col', gap: 0, children: rows } };
    }

    function lyricPlaceholder() {
      var msg = lyricState === 'loading' ? '正在找歌词…' : '没找到这首歌的歌词';
      return {
        // 高度必须和真有歌词时一致：1 个当前行的高度 + 其余都是上下文行。
        // 写少了会让"没找到歌词"的占位比正常状态矮一截，切歌时整块跳一下。
        t: 'box', center: true,
        h: LINE_CURRENT + LINE_CONTEXT * (lyricLines - 1),
        child: txt(msg, 12, null, 0.35)
      };
    }

    function view(pos, idx) {
      if (!media || !media.available) return idleView();

      var playing = media.status === 4;
      var dur = media.duration || 0;

      var left = {
        t: 'col', gap: 8, cross: 'start',
        children: [
          { t: 'image', key: media.artKey || '', w: artSize, h: artSize, radius: 10 },
          {
            t: 'col', gap: 1,
            children: [
              txt(media.title || '未知曲目', 13, null, 0.95, { maxLines: 1, weight: 600 }),
              txt(media.artist || '未知艺术家', 11, null, 0.5, { maxLines: 1 })
            ]
          }
        ]
      };

      // cross:'center' 是必须的：row 默认按顶端对齐，而三个按钮盒子等高之前
      // 是一高两矮，前后曲会比播放键高出几像素，看着就是没对齐。
      var controls = {
        t: 'row', gap: 10, main: 'center', cross: 'center',
        children: [
          iconBtn('prev', hPrev, CTRL_SIDE, media.canPrev, CTRL_BOX),
          iconBtn(playing ? 'pause' : 'play', hToggle, CTRL_MAIN,
            playing ? media.canPause : media.canPlay, CTRL_BOX),
          iconBtn('next', hNext, CTRL_SIDE, media.canNext, CTRL_BOX)
        ]
      };

      var bar = {
        t: 'col', gap: 2,
        children: [
          {
            t: 'slider', id: hSeek, h: 3,
            v: dur > 0 ? pos / dur : 0,
            color: '#FFFFFF',
            bg: '#FFFFFF33',   // 注意是 RRGGBBAA，alpha 在后
            // 播放器不支持定位时置灰，而不是让人拖了没反应
            enabled: media.canSeek === true && dur > 0
          },
          {
            t: 'row', main: 'between',
            children: [
              txt(LRC.fmt(pos), 9.5, null, 0.4, { mono: true }),
              txt(LRC.fmt(dur), 9.5, null, 0.4, { mono: true })
            ]
          }
        ]
      };

      var right = {
        t: 'col', gap: 6,
        children: [
          controls,
          bar,
          // 换行/换词直接原地替换内容（宿主 animKey 动画已因真实渲染闪白禁用，
          // 见 node.dart _child 注释）：不传 animKey，内容平移到新位置，不闪。
          { t: 'flex', f: 1, child: lyrics.length ? lyricArea(idx) : lyricPlaceholder() }
        ]
      };

      return {
        // key 挂「歌名|歌手」：切歌时整卡交叉淡入。宿主 AnimatedSwitcher 的
        // 过渡期新旧两棵树并存（旧树淡出、新树淡入），物理上不存在空白帧。
        // 不挂含时长的 trackKey——切歌后时长从 0 刷新到正常值会触发第二次
        // 整卡过渡，反而闪两下。歌词换行/换词是歌词区原地替换，不依赖这里。
        key: viewKey,
        t: 'box', pad: PAD,
        child: {
          t: 'row', gap: 14, cross: 'start',
          children: [
            { t: 'box', w: artSize, child: left },
            { t: 'flex', f: 1, child: right }
          ]
        }
      };
    }

    // ------------------------------------------------------------------

    ctx.render(idleView());
    purgeLegacyCache();
    tick();
    var timer = ctx.interval(tick, 100);

    return {
      unmount: function () { ctx.clearTimer(timer); }
    };
  },

  // onCleanup 在当前宿主里是死代码（从不触发），所以清理写在 mount 的返回值里
  unmount: function () {}
});
