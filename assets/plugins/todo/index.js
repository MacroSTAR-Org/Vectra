// 待办：验证 storage 通路与输入框事件。数据按实例存（每张卡片一份清单）。
lw.register({
  mount: function (ctx) {
    var items = [];

    function save() { ctx.storage.setLocal('items', items); }

    function draw() {
      var hideDone = ctx.settings.hideDone === true;
      var shown = hideDone ? items.filter(function (i) { return !i.done; }) : items;
      var left = items.filter(function (i) { return !i.done; }).length;

      var rows = shown.map(function (item) {
        var toggle = ctx.on(function () {
          item.done = !item.done; save(); draw();
        });
        var remove = ctx.on(function () {
          items = items.filter(function (x) { return x.id !== item.id; });
          save(); draw();
        });
        return { t: 'box', pad: [5, 6], radius: 8,
          bg: item.done ? '#FFFFFF08' : '#FFFFFF12',
          child: { t: 'row', gap: 8, cross: 'center', children: [
            { t: 'tap', id: toggle, child: {
              t: 'icon', v: item.done ? 'check_circle' : 'circle', size: 16,
              color: item.done ? '#7CE38B' : '#FF7A7A' } },
            { t: 'flex', f: 1, child: {
              t: 'text', v: item.text, size: 13, maxLines: 1,
              strike: item.done, opacity: item.done ? 0.4 : 0.95 } },
            { t: 'tap', id: remove, child: {
              t: 'box', w: 18, h: 18, radius: 9, center: true, bg: '#D9000000',
              child: { t: 'icon', v: 'close', size: 12, color: '#FFFFFF' } } }
          ] } };
      });

      var submit = ctx.on(function (p) {
        var text = (p.value || '').trim();
        if (!text) return;
        items.push({ id: Date.now() + '-' + Math.random().toString(36).slice(2, 6),
                     text: text, done: false });
        save(); draw();
      });

      ctx.render({
        t: 'col', gap: 10, children: [
          { t: 'row', main: 'between', cross: 'center', children: [
            { t: 'row', gap: 7, cross: 'center', children: [
              { t: 'box', w: 4, h: 4, radius: 2, bg: '#7CE38B' },
              { t: 'text', v: '待办', size: 13, weight: 600 }
            ] },
            { t: 'box', pad: [2, 7], radius: 8, bg: '#FFFFFF12', child: {
              t: 'text', v: left > 0 ? left + ' 项未完成' : '全部完成',
              size: 11, opacity: 0.6 } }
          ] },
          { t: 'input', id: 'new', value: '', placeholder: '添加一项，回车确认',
            submit: submit },
          { t: 'flex', f: 1, child: {
            t: 'scroll', child: { t: 'col', gap: 5,
              children: rows.length ? rows
                : [{ t: 'box', pad: [10, 0], child: {
                    t: 'text', v: '还没有待办', size: 11, opacity: 0.28 } }] } } }
        ]
      });
    }

    // 先画一次空的，别让卡片在加载期间是空白
    draw();
    ctx.storage.getLocal('items', []).then(function (saved) {
      if (saved && saved.length) { items = saved; }
      draw();
    });
  },

  onSettingsChange: function () { /* 勾选项变化下次绘制生效 */ }
});
