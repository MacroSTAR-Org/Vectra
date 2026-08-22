// launcher - 快捷启动器
// 展示 SDK：onLoad + widget.register + storage 持久化 + pickFile + launch
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
          // tap 节点的 id 必须是 ctx.on() 返回的处理器 id，点击才能路由回来
          var h = ctx.on(function () {
            ctx.launch(s.path).then(function (r) {
              if (r && r.ok === false) ctx.toast('启动失败：' + name);
            });
          });
          children.push({
            t: 'tap',
            id: h,
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
      var hAdd = ctx.on(function () {
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
      });
      children.push({
        t: 'tap', id: hAdd, child: {
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
