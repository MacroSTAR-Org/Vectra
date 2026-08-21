// launcher - 快捷启动器
// 展示 SDK：onLoad + lifecycle.on + widget.register + storage 持久化 + pickFile
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

      // 添加按钮
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
            { t: 'grid', cols: cols, gap: 8, children: children }
          ]
        }
      });
    }

    // ---- 事件 ----
    var hTap = ctx.on(function (e) {
      if (!e.id) return;

      // 启动应用
      if (e.id.indexOf('launch:') === 0) {
        var idx = parseInt(e.id.split(':')[1]);
        if (idx >= 0 && idx < list.length) {
          ctx.openExternal(list[idx].path);
        }
        return;
      }

      // 添加快捷方式：打开文件选择器
      if (e.id === 'add') {
        ctx.pickFile({
          title: '选择要添加的程序',
          ext: ['exe', 'lnk', 'bat', 'cmd', 'msc']
        }).then(function (res) {
          if (res && res.ok && res.path) {
            // 从路径提取文件名（去掉扩展名）
            var parts = res.path.replace(/\\/g, '/').split('/');
            var fileName = parts[parts.length - 1] || res.path;
            var name = fileName.replace(/\.(exe|lnk|bat|cmd|msc|ps1)$/i, '');
            list.push({ name: name, path: res.path });
            save();
            render();
          }
        });
        return;
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
