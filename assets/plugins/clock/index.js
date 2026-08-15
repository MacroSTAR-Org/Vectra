// 时钟：每秒重绘一次。
lw.register({
  mount: function (ctx) {
    function two(n) { return n < 10 ? '0' + n : '' + n; }

    function draw() {
      var now = new Date();
      var h = now.getHours();
      var suffix = '';
      if (!ctx.settings.hour24) {
        suffix = h < 12 ? 'AM' : 'PM';
        h = h % 12; if (h === 0) h = 12;
      }

      var week = ['周日','周一','周二','周三','周四','周五','周六'][now.getDay()];
      var big = ctx.grid.cols >= 3 ? 58 : 44;

      // 时:分 用细字重的大字，秒和 AM/PM 缩小跟在后面，
      // 避免整行数字过长把窄卡片撑破
      var timeRow = [
        { t: 'text', v: two(h) + ':' + two(now.getMinutes()),
          size: big, weight: 300, mono: true, lh: 1.0 }
      ];
      if (ctx.settings.seconds) {
        timeRow.push({ t: 'box', pad: [0, 0, 0, 4], child: {
          t: 'text', v: two(now.getSeconds()), size: Math.round(big * 0.42),
          weight: 400, mono: true, opacity: 0.45 } });
      }
      if (suffix) {
        timeRow.push({ t: 'box', pad: [0, 0, 0, 5], child: {
          t: 'text', v: suffix, size: Math.round(big * 0.3),
          weight: 600, opacity: 0.4 } });
      }

      ctx.render({
        t: 'col', main: 'center', cross: 'start', gap: 6,
        children: [
          { t: 'row', cross: 'end', children: timeRow },
          { t: 'row', gap: 7, cross: 'center', children: [
            { t: 'box', w: 4, h: 4, radius: 2, bg: '#7CC7FF' },
            { t: 'text', v: (now.getMonth() + 1) + ' 月 ' + now.getDate() + ' 日',
              size: 13, opacity: 0.5 },
            { t: 'text', v: week, size: 13, opacity: 0.5 }
          ] }
        ]
      });
    }

    draw();
    var timer = ctx.interval(draw, 1000);
    ctx.onCleanup(function () { ctx.clearTimer(timer); });
  },

  onSettingsChange: function () { /* 下一秒自然重绘 */ }
});
