// launcher - 快捷启动器
// 展示：flip 双面（启动面/编辑面）、ctx.launch 启动本地程序、pickFile、storage 持久化
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
    var face = 'front';   // front=启动面 edit=编辑面
    var renaming = -1;    // 编辑面上正在重命名的行号，-1 表示没有

    function save() {
      ctx.storage.set('shortcuts', JSON.stringify(list));
    }

    function draw() {
      ctx.render({
        t: 'box', pad: 10, child: {
          t: 'flip', flipKey: face, children: [frontFace(), editFace()]
        }
      });
    }

    // ---- 正面：启动格 ----
    function frontFace() {
      // 空列表时给个引导，别让新用户对着一块空板子猜
      if (list.length === 0) {
        var hAdd0 = ctx.on(pickAndAdd);
        var hEdit0 = ctx.on(function () { renaming = -1; face = 'edit'; draw(); });
        return {
          t: 'col', main: 'center', cross: 'center', gap: 10, children: [
            { t: 'text', v: '还没有快捷方式', size: 12, opacity: 0.5 },
            { t: 'text', v: '点下方按钮添加常用程序', size: 11, opacity: 0.35 },
            { t: 'row', gap: 14, children: [miniCell('add', '添加', hAdd0), miniCell('settings', '管理', hEdit0)] }
          ]
        };
      }

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

      // 尾格：添加 + 翻面管理
      var hAdd = ctx.on(pickAndAdd);
      var hEdit = ctx.on(function () { renaming = -1; face = 'edit'; draw(); });
      children.push({
        t: 'col', main: 'center', cross: 'center', gap: 8, children: [
          miniCell('add', '添加', hAdd),
          miniCell('settings', '管理', hEdit)
        ]
      });

      return { t: 'grid', cols: cols, gap: 8, children: children };
    }

    // ---- 背面：编辑面。行内重命名 / 上下移 / 删除，底部添加 + 完成 ----
    function editFace() {
      var rows = [];
      for (var i = 0; i < list.length; i++) {
        (function (idx) {
          var s = list[idx];
          var name = s.name || '???';
          var icon = name.charAt(0).toUpperCase();
          var iconBox = {
            t: 'box', w: 28, h: 28, radius: 8,
            bg: ctx.theme.accent ? ctx.theme.accent + '22' : '#ffffff15',
            center: true, child: { t: 'text', v: icon, size: 12, weight: 700 }
          };

          if (renaming === idx) {
            var hOk = ctx.on(function (p) {
              var v = p && p.value ? String(p.value).trim() : '';
              if (v) { s.name = v; save(); }
              renaming = -1;
              draw();
            });
            var hCancel = ctx.on(function () { renaming = -1; draw(); });
            rows.push({
              t: 'row', cross: 'center', gap: 6, children: [
                iconBox,
                { t: 'flex', child: { t: 'input', id: 'ren-' + idx, value: name, submit: hOk } },
                { t: 'tap', id: hOk, child: { t: 'icon', v: 'check', size: 14 } },
                { t: 'tap', id: hCancel, child: { t: 'icon', v: 'close', size: 14 } }
              ]
            });
            return;
          }

          // 点名字进入重命名；上移/下移/删除各一个 handler
          var hRen = ctx.on(function () { renaming = idx; draw(); });
          var hUp = ctx.on(function () {
            if (idx <= 0) return;
            var t = list[idx - 1]; list[idx - 1] = list[idx]; list[idx] = t;
            save(); draw();
          });
          var hDown = ctx.on(function () {
            if (idx >= list.length - 1) return;
            var t = list[idx + 1]; list[idx + 1] = list[idx]; list[idx] = t;
            save(); draw();
          });
          var hDel = ctx.on(function () {
            list.splice(idx, 1);
            renaming = -1;
            save(); draw();
          });
          rows.push({
            t: 'row', cross: 'center', gap: 6, children: [
              iconBox,
              { t: 'flex', child: { t: 'tap', id: hRen, child: { t: 'text', v: name, size: 12, maxLines: 1 } } },
              { t: 'tap', id: hUp, child: { t: 'icon', v: 'up', size: 14 } },
              { t: 'tap', id: hDown, child: { t: 'icon', v: 'down', size: 14 } },
              { t: 'tap', id: hDel, child: { t: 'icon', v: 'close', size: 14 } }
            ]
          });
        })(i);
      }

      if (rows.length === 0) {
        rows.push({ t: 'text', v: '列表是空的，先添加几个程序吧', size: 11, opacity: 0.4 });
      }

      var hAdd = ctx.on(pickAndAdd);
      var hDone = ctx.on(function () { renaming = -1; face = 'front'; draw(); });
      return {
        t: 'col', gap: 6, children: [
          { t: 'flex', child: { t: 'scroll', child: { t: 'col', gap: 8, children: rows } } },
          { t: 'row', main: 'end', gap: 12, children: [
            miniCell('add', '添加程序', hAdd),
            miniCell('check', '完成', hDone)
          ] }
        ]
      };
    }

    function miniCell(iconV, label, h) {
      return {
        t: 'tap', id: h, child: {
          t: 'col', main: 'center', cross: 'center', gap: 2, children: [
            { t: 'box', w: 32, h: 32, radius: 10, bg: '#ffffff0d', center: true,
              child: { t: 'icon', v: iconV, size: 16 } },
            { t: 'text', v: label, size: 10, opacity: 0.4 }
          ]
        }
      };
    }

    function pickAndAdd() {
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
          draw();
        }
      });
    }

    // ---- 初始化 ----
    // settings 里的 shortcuts 是老版本在设置面板配的 JSON（新版面板已移除该项），
    // storage 为空时导入一次，storage 永远优先
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
      draw();
    }).catch(function () {
      draw();
    });
  }
});
