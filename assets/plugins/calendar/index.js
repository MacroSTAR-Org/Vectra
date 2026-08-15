// 日历：月视图，每格上面公历、下面农历/节气/节日。
// 农历与节气的算法在 lunar.js（manifest 的 scripts 里先加载）。

// 每张卡片是一个独立的 QuickJS 运行时，所以这个模块级变量不会串卡片
var redraw = null;

lw.register({
  mount: function (ctx) {
    var today = new Date();
    var viewYear = today.getFullYear();
    var viewMonth = today.getMonth();   // 0-11

    var ACCENT = '#29B6F6';   // 今天的圆底
    var HOLIDAY = '#FF8A6B';  // 法定节假日
    var TERM = '#8FD6A0';     // 节气

    function sameYMD(d, y, m, day) {
      return d.getFullYear() === y && d.getMonth() === m && d.getDate() === day;
    }

    function draw() {
      var showLunar = ctx.settings.lunar !== false;
      var showFest = ctx.settings.festival !== false;
      var mondayFirst = ctx.settings.mondayFirst !== false;

      var heads = mondayFirst
        ? ['一','二','三','四','五','六','日']
        : ['日','一','二','三','四','五','六'];
      var weekendCols = mondayFirst ? [5, 6] : [0, 6];

      var first = new Date(viewYear, viewMonth, 1);
      var startDow = first.getDay();
      var lead = mondayFirst ? (startDow + 6) % 7 : startDow;

      // 固定 6 行 42 格：月份切换时高度不跳变
      var cells = [];
      for (var i = 0; i < 42; i++) {
        var d = new Date(viewYear, viewMonth, 1 - lead + i);
        var inMonth = d.getMonth() === viewMonth;
        var col = i % 7;
        cells.push(cell(d, inMonth, weekendCols.indexOf(col) >= 0,
                        showLunar, showFest));
      }

      var headCells = heads.map(function (h, i) {
        return { t: 'text', v: h, size: 12, align: 'center', weight: 500,
                 opacity: weekendCols.indexOf(i) >= 0 ? 0.55 : 0.38 };
      });

      var prev = ctx.on(function () {
        viewMonth--; if (viewMonth < 0) { viewMonth = 11; viewYear--; } draw();
      });
      var next = ctx.on(function () {
        viewMonth++; if (viewMonth > 11) { viewMonth = 0; viewYear++; } draw();
      });
      var reset = ctx.on(function () {
        viewYear = today.getFullYear(); viewMonth = today.getMonth(); draw();
      });

      var offMonth = !(viewYear === today.getFullYear() && viewMonth === today.getMonth());

      // key 变化时宿主做交叉淡入。只在真正换月时变，不会每次重绘都动画。
      var body = {
        t: 'col', gap: 10, key: viewYear + '-' + viewMonth, children: [
          { t: 'row', main: 'between', cross: 'center', children: [
            { t: 'tap', id: reset, child: {
              t: 'row', gap: 6, cross: 'center', children: [
                { t: 'text', v: viewYear + '年' + (viewMonth + 1) + '月',
                  size: 16, weight: 500 },
                offMonth
                  ? { t: 'box', pad: [2, 6], radius: 5, bg: '#FFFFFF14',
                      child: { t: 'text', v: '今天', size: 9, opacity: 0.6 } }
                  : { t: 'box' }
              ] } },
            { t: 'row', gap: 2, children: [
              { t: 'tap', id: prev, child: {
                t: 'box', w: 26, h: 22, center: true,
                child: { t: 'icon', v: 'up', size: 20, color: '#FFFFFF66' } } },
              { t: 'tap', id: next, child: {
                t: 'box', w: 26, h: 22, center: true,
                child: { t: 'icon', v: 'down', size: 20, color: '#FFFFFF66' } } }
            ] }
          ] },
          { t: 'grid', cols: 7, gap: 0, children: headCells },
          { t: 'flex', f: 1, child: {
              t: 'grid', cols: 7, gap: 2, fill: true, children: cells } }
        ]
      };

      // 尺寸分档：格子越多，能承载的信息越多。
      // 小档只放月历；中档加今日一行；大档在下方展开今日详情与近期节气/节日。
      var rows = ctx.grid.rows;
      if (rows >= 4) body.children.splice(1, 0, todayStrip());
      if (rows >= 5) body.children.push({ t: 'divider' }, upcoming());

      ctx.render(body);
    }

    // 今日一行：农历全称 + 干支生肖
    function todayStrip() {
      var l = Lunar.fromSolar(today.getFullYear(), today.getMonth() + 1, today.getDate());
      if (!l) return { t: 'box' };
      var parts = [
        { t: 'box', pad: [2, 7], radius: 6, bg: '#FFFFFF12', child: {
            t: 'text', v: l.monthText + l.dayText, size: 11 } },
        { t: 'text', v: Lunar.ganzhi(l.y) + '年', size: 11, opacity: 0.45 },
        { t: 'text', v: '属' + Lunar.zodiac(l.y), size: 11, opacity: 0.45 }
      ];
      var t = Lunar.termOf(today.getFullYear(), today.getMonth() + 1, today.getDate());
      if (t) {
        parts.push({ t: 'box', pad: [2, 7], radius: 6, bg: '#8FD6A022', child: {
          t: 'text', v: '今日' + t, size: 11, color: '#8FD6A0' } });
      }
      return { t: 'row', gap: 8, cross: 'center', children: parts };
    }

    // 大尺寸：下一个节气 + 本月剩余的节日
    function upcoming() {
      var y = today.getFullYear(), m = today.getMonth() + 1, d = today.getDate();
      var items = [];

      var nt = Lunar.nextTerm(y, m, d);
      if (nt) {
        items.push({ t: 'row', gap: 6, cross: 'center', children: [
          { t: 'box', w: 4, h: 4, radius: 2, bg: '#8FD6A0' },
          { t: 'text', v: nt.name, size: 11.5 },
          { t: 'text', v: nt.days + ' 天后', size: 11, opacity: 0.42 }
        ] });
      }

      // 本月内今天之后的节日，最多列 3 条
      var daysInMonth = new Date(y, m, 0).getDate();
      var listed = 0;
      for (var i = d + 1; i <= daysInMonth && listed < 3; i++) {
        var l = Lunar.fromSolar(y, m, i);
        var f = l ? Lunar.festivalOf(y, m, i, l) : null;
        if (!f) continue;
        items.push({ t: 'row', gap: 6, cross: 'center', children: [
          { t: 'box', w: 4, h: 4, radius: 2,
            bg: f.statutory ? '#FF8A6B' : '#FFFFFF44' },
          { t: 'text', v: f.name, size: 11.5,
            color: f.statutory ? '#FF8A6B' : null },
          { t: 'text', v: m + '月' + i + '日', size: 11, opacity: 0.42 }
        ] });
        listed++;
      }

      if (!items.length) {
        items.push({ t: 'text', v: '本月没有更多节日了', size: 11, opacity: 0.3 });
      }
      return { t: 'col', gap: 6, children: items };
    }

    // 一格：上面公历日，下面农历/节气/节日
    function cell(d, inMonth, weekend, showLunar, showFest) {
      var y = d.getFullYear(), m = d.getMonth() + 1, day = d.getDate();
      var isToday = sameYMD(today, y, m - 1, day);

      var lunar = Lunar.fromSolar(y, m, day);
      var term = Lunar.termOf(y, m, day);
      var fest = lunar ? Lunar.festivalOf(y, m, day, lunar) : null;

      // 下行文字的优先级：节日 > 节气 > 初一显示月份 > 农历日
      var sub = '', subColor = null;
      if (showFest && fest) {
        sub = fest.name;
        subColor = fest.statutory ? HOLIDAY : null;
      } else if (showFest && term) {
        sub = term;
        subColor = TERM;
      } else if (showLunar && lunar) {
        sub = lunar.d === 1 ? lunar.monthText : lunar.dayText;
      }

      // 节日/节气所在格给一个很淡的圆底，让它从一片数字里跳出来
      var marked = !isToday && inMonth && showFest && (fest || term);

      var dayColor = null, dayOpacity = 1;
      if (isToday) {
        dayColor = '#0B1116';
      } else if (!inMonth) {
        dayOpacity = 0.28;
      } else if (weekend) {
        dayColor = HOLIDAY;
        dayOpacity = 0.9;
      }

      var inner = {
        t: 'col', gap: 1, cross: 'center', main: 'center', children: [
          { t: 'text', v: '' + day, size: 15, weight: isToday ? 700 : 500,
            align: 'center', color: dayColor, opacity: dayOpacity },
          sub
            ? { t: 'text', v: sub, size: 9.5, align: 'center', maxLines: 1,
                color: isToday ? '#0B1116' : subColor,
                opacity: isToday ? 0.85 : (inMonth ? 0.5 : 0.22) }
            : { t: 'box' }
        ]
      };

      return { t: 'row', main: 'center', children: [
        { t: 'box', w: 36, h: 36, radius: 18, center: true,
          bg: isToday ? ACCENT : (marked ? '#FFFFFF12' : null),
          child: inner }
      ] };
    }

    draw();
    // 跨过午夜把"今天"挪过去
    var timer = ctx.interval(function () {
      var now = new Date();
      if (now.getDate() !== today.getDate()) { today = now; draw(); }
    }, 60000);
    ctx.onCleanup(function () { ctx.clearTimer(timer); });

    // 设置里改了开关要立刻反映出来
    redraw = draw;
  },

  onSettingsChange: function () {
    if (redraw) redraw();
  }
});
