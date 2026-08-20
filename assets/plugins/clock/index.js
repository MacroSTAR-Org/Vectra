// 时钟：每秒重绘一次。
//
// 两套排版：
//   - 3x3（够高够方）：仿安卓锁屏那种"时/分各占一行"的堆叠大字，
//     字号是拿真实字体量出来的（HarmonyOS Sans SC，见 git 历史里跑过
//     的诊断脚本），两行堆叠总高留了够的余量，不会顶穿卡片。
//   - 2x2 / 3x2 / 4x2（都是 2 行高，横排装不下堆叠版）：保持横排
//     "HH:MM"，但不再是一坨等重的数字墙——小时用粗体、冒号压淡、
//     分钟用细体，靠字重梯度做出"艺术字"的层次，尺寸沿用原来已经
//     验证过不会溢出的数字。
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

      // 跟"莫奈取色"联动：设置里开了"从壁纸取色"或"文字颜色也用取色"
      // 任意一个开关时，ctx.theme.accent 会是从当前壁纸实时算出来的
      // 强调色（Wallpaper.dominantColor，见 plugin_card_body.dart）；
      // 两个开关都没开时 ctx.theme.accent 是 null，退回写死的主题蓝。
      // draw() 本来就每秒重跑一次，这里直接读最新值，壁纸变了下一秒
      // 自然跟着变，不用另外接 onThemeChange。
      var ACCENT = (ctx.theme && ctx.theme.accent) || '#7CC7FF';

      // Material 3 Expressive 的一个核心手法：色彩不再只贴在文字上，而是
      // 变成一个"容器"（tonal chip/capsule）——日期这行原来是光秃秃的
      // 圆点+文字飘在卡片背景上，现在整行装进一个用主题色打底的圆角胶囊，
      // 变成一个有形状、有色彩的独立组件，而不是两段裸文字。
      var dateRow = { t: 'box', pad: [5, 10], radius: 14, bg: ACCENT + '1F',
        child: { t: 'row', gap: 7, cross: 'center', children: [
          { t: 'box', w: 5, h: 5, radius: 3, bg: ACCENT },
          { t: 'text', v: (now.getMonth() + 1) + ' 月 ' + now.getDate() + ' 日', size: 13, opacity: 0.7 },
          { t: 'text', v: week, size: 13, opacity: 0.7 }
        ] } };

      var stacked = ctx.grid.rows >= 3;

      if (stacked) {
        // 140：两行堆叠总高实测 238px，3x3 卡片能给的内容高度约 296px，
        // 扣掉日期行和间距还有 30px+ 的余量，不是拍脑袋的数字。
        var STACK_SIZE = 140;
        // 分钟这行直接用 ACCENT 上色——之前"联动"只碰了日期胶囊那个小
        // 装饰，真正占大头的数字本身颜色一直没变，跟安卓锁屏"数字本身
        // 带一点壁纸色调"的效果对不上。小时留白/黑默认色保持稳重，
        // 分钟上色制造一点呼应，两行不是同一个颜色更有层次。
        var minuteRow = [
          { t: 'text', v: two(now.getMinutes()), size: STACK_SIZE, weight: 300, mono: true, lh: 0.85, color: ACCENT }
        ];
        if (ctx.settings.seconds) {
          minuteRow.push({ t: 'box', pad: [0, 0, 0, 8], child: {
            t: 'text', v: two(now.getSeconds()), size: 20, weight: 400, mono: true, opacity: 0.4 } });
        }
        if (suffix) {
          minuteRow.push({ t: 'box', pad: [0, 0, 0, 10], child: {
            t: 'text', v: suffix, size: 16, weight: 600, opacity: 0.4 } });
        }
        ctx.render({
          t: 'col', main: 'center', cross: 'start', gap: 10,
          children: [
            { t: 'text', v: two(h), size: STACK_SIZE, weight: 300, mono: true, lh: 0.85, color: ACCENT },
            { t: 'row', cross: 'end', children: minuteRow },
            dateRow
          ]
        });
        return;
      }

      var big = ctx.grid.cols >= 3 ? 58 : 44;
      // 时:分拆成三个独立节点（原来是一个整串文字），才能分别给字重和
      // 颜色——小时粗体+默认色确立存在感，冒号压到 0.35 透明度弱化成
      // 分隔符而不是主角，分钟用细体 + ACCENT 上色收尾：字重和色彩两条
      // 线都在往"分钟更轻、更跟着壁纸走"这个方向走，不是等重同色的
      // 数字堆。
      var timeRow = [
        { t: 'text', v: two(h), size: big, weight: 900, mono: true, lh: 1.0, color: ACCENT },
        { t: 'box', pad: [0, 2], child: {
          t: 'text', v: ':', size: big, weight: 300, opacity: 0.35, mono: true, lh: 1.0 } },
        { t: 'text', v: two(now.getMinutes()), size: big, weight: 400, mono: true, lh: 1.0, color: ACCENT }
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
          dateRow
        ]
      });
    }

    draw();
    var timer = ctx.interval(draw, 1000);
    ctx.onCleanup(function () { ctx.clearTimer(timer); });
  },

  onSettingsChange: function () { /* 下一秒自然重绘 */ }
});
