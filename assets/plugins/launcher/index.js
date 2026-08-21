// launcher - 快捷启动器
// 展示 SDK：onLoad + lifecycle.on + widget.register + storage 持久化
lw.register({
  onLoad: function (api) {
    api.sdk.widget.register({
      id: 'launcher',
      name: '快捷启动',
      description: '常用程序一键启动',
      icon: '🚀',
      sizes: ['2x2', '3x2', '3x3', '4x3'],
      defaultSize: '2x2'
    });
  },

  mount: function (ctx) {
    var list = [];
    var inputVal = '';
    var cols = Math.max(1, ctx.grid.cols);

    function save() {
      ctx.storage.set('shortcuts', JSON.stringify(list));
    }

    function render() {
      var children = [];
      for (var i = 0; i < list.length; i++) {
        (function (idx) {
          var s = list[idx];
          var name = s.name || '???';
          var icon = name.charAt(0).toUpperCase();
          children.push({
            t: 'tap',
            id: 'launch:' + idx,
            child: {
              t: 'col', main: 'center', cross: 'center', gap: 2, children: [
                { t: 'box', w: 36, h: 36, radius: 10,
                  bg: ctx.theme.accent ? ctx.theme.accent + '22' : '#ffffff15',
                  center: true, child: { t: 'text', v: icon, size: 16, weight: 700 } },
                { t: 'text', v: name, size: 11, maxLines: 1 }
              ]
            }
          });
        })(i);
      }

      children.push({
        t: 'tap', id: 'add', child: {
          t: 'col', main: 'center', cross: 'center', children: [
            { t: 'box', w: 36, h: 36, radius: 10, bg: '#ffffff0d', center: true,
              child: { t: 'icon', v: 'add', size: 18 } },
            { t: 'text', v: '添加', size: 11, opacity: 0.4 }
          ]
        }
      });

      ctx.render({
        t: 'box', pad: 12, child: {
          t: 'col', gap: 8, children: [
            { t: 'grid', cols: cols, gap: 8, children: children },
            {
              t: 'input', id: 'path-input', value: inputVal,
              placeholder: '输入路径后回车添加（如 D:\\app\\note.exe）',
              submit: 'submit-path'
            }
          ]
        }
      });
    }

    // ---- 事件 ----
    var hSubmit = ctx.on(function (e) {
      if (e.id === 'submit-path' && e.value && e.value.trim()) {
        var parts = e.value.trim().split(/[\\/]/);
        var fileName = parts[parts.length - 1] || e.value.trim();
        var name = fileName.replace(/\.(exe|lnk|bat|cmd|ps1|msc)$/i, '');
        list.push({ name: name, path: e.value.trim() });
        save();
        inputVal = '';
        render();
      }
    });

    var hLaunch = ctx.on(function (e) {
      if (e.id && e.id.indexOf('launch:') === 0) {
        var idx = parseInt(e.id.split(':')[1]);
        if (idx >= 0 && idx < list.length) {
          ctx.openExternal(list[idx].path);
        }
      }
    });

    var hAdd = ctx.on(function (e) {
      if (e.id === 'add') {
        // 点击添加：把焦点给输入框（用户直接打字即可）
      }
    });

    // ---- 初始化 ----
    var raw = ctx.settings.shortcuts;
    if (raw) {
      try {
        var parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) list = parsed;
      } catch (e) {}
    }

    ctx.storage.get('shortcuts', null).then(function (v) {
      if (v) {
        try {
          var arr = JSON.parse(v);
          if (Array.isArray(arr)) list = arr;
        } catch (e) {}
      }
      render();
    }).catch(function () {
      render();
    });
  }
});
