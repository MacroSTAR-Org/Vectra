// 天气：Open-Meteo（免费无 key）+ ipapi.co 自动定位。
// 前脸：当前温度 + 天气详情 + 5天预报
// 后脸：12小时逐时预报 + 日出日落 / UV / 降水量
// 每 8 秒自动翻转，也可点击卡片手动翻。
lw.register({
  mount: function (ctx) {
    var state = { status: 'loading', error: '', data: null, loc: null };
    var face = 'f';        // flipKey：'f' = 正面，'b' = 背面
    var flipTimer = null;

    var CODE = {
      0: ['晴', 'sun'], 1: ['大致晴朗', 'sun'], 2: ['多云', 'cloud'], 3: ['阴', 'cloud'],
      45: ['雾', 'fog'], 48: ['雾凇', 'fog'],
      51: ['毛毛雨', 'rain'], 53: ['小雨', 'rain'], 55: ['中雨', 'rain'],
      61: ['小雨', 'rain'], 63: ['中雨', 'rain'], 65: ['大雨', 'rain'],
      71: ['小雪', 'snow'], 73: ['中雪', 'snow'], 75: ['大雪', 'snow'],
      80: ['阵雨', 'rain'], 81: ['阵雨', 'rain'], 82: ['强阵雨', 'rain'],
      95: ['雷阵雨', 'storm'], 96: ['雷暴', 'storm'], 99: ['强雷暴', 'storm']
    };
    // 图标颜色跟着天气语义走，不再不分青红皂白统一刷一个暖橙色——一片
    // 雪花是橙色的，用户潜意识会觉得不对劲。颜色得顺着天气类型的直觉
    // 联想走：晴天暖、云雾中性、雨雪偏冷、雷暴带一点戏剧性的紫。
    var ICON_COLOR = {
      sun: '#FFD79A', cloud: '#B8C4D9', fog: '#C7CFD9',
      rain: '#7CC7FF', snow: '#DCEEFA', storm: '#B79CFF'
    };
    function desc(c) { return (CODE[c] || ['—', 'cloud'])[0]; }
    function icon(c) { return (CODE[c] || ['—', 'cloud'])[1]; }
    function iconColor(c) { return ICON_COLOR[icon(c)] || ICON_COLOR.sun; }

    // ---- 前脸：当前天气 + 5 天预报 ----
    function buildFront(data, loc, grid) {
      var cur = data.current;
      var daily = data.daily;
      var compact = !grid || grid.rows <= 2;
      var kids = [
        { t: 'row', main: 'between', cross: 'start', children: [
          { t: 'col', gap: 3, children: [
            { t: 'row', gap: 6, cross: 'center', children: [
              { t: 'box', w: 4, h: 4, radius: 2, bg: '#7CC7FF' },
              { t: 'text', v: loc.name, size: 13, opacity: 0.55 } ] },
            { t: 'row', cross: 'start', children: [
              { t: 'text', v: '' + Math.round(cur.temperature_2m),
                size: 48, weight: 300, lh: 1.0, mono: true },
              { t: 'box', pad: [4, 0, 0, 2], child: {
                t: 'text', v: '\u00b0', size: 22, weight: 300, opacity: 0.5 } }
            ] }
          ] },
          { t: 'col', cross: 'end', gap: 6, children: [
            // 图标套一个跟自己同色、极淡的圆形底——一个"徽章"，而不是
            // 光秃秃悬空的符号，这一下就有"设计过"的感觉。
            { t: 'box', w: 40, h: 40, radius: 20, center: true,
              bg: iconColor(cur.weather_code) + '26',
              child: { t: 'icon', v: icon(cur.weather_code), size: 22,
                color: iconColor(cur.weather_code) } },
            { t: 'text', v: desc(cur.weather_code), size: 12, opacity: 0.65 }
          ] }
        ] }
      ];

      // 当前详情行：体感 / 湿度 / 风速 / 降水。
      //
      // 原来是拿" · "拼成一整句文字，扫一眼分不清是几项独立数据。改成
      // 一排小徽章（图标+数值，各自一个圆角背景块）——徽章各自有边界，
      // 是"设计过的信息"而不是一句流水账，这是很多天气 App 的常见处理。
      var detail = [];
      if (cur.apparent_temperature != null)
        detail.push({ icon: 'thermostat', v: '体感 ' + Math.round(cur.apparent_temperature) + '\u00b0' });
      if (cur.relative_humidity_2m != null)
        detail.push({ icon: 'rain', v: Math.round(cur.relative_humidity_2m) + '%' });
      if (cur.wind_speed_10m != null)
        detail.push({ icon: 'air', v: Math.round(cur.wind_speed_10m) + 'km/h' });
      if (cur.precipitation != null && cur.precipitation > 0)
        detail.push({ icon: 'rain', v: cur.precipitation + 'mm' });
      if (detail.length) {
        kids.push({ t: 'row', gap: 6, children: detail.map(function (it) {
          return { t: 'box', pad: [3, 8], radius: 9, bg: '#FFFFFF12',
            child: { t: 'row', gap: 4, cross: 'center', children: [
              { t: 'icon', v: it.icon, size: 11, opacity: 0.55 },
              { t: 'text', v: it.v, size: 11, opacity: 0.75 }
            ] } };
        }) });
      }

      // 5 天预报：竖向紧张时去掉每格的内边距和"最低温"那一行，
      // 省出一截高度（2 行高的卡片之前实测这里会顶出卡片底边）
      if (daily && daily.time) {
        var days = [];
        var n = Math.min(5, daily.time.length);
        for (var i = 0; i < n; i++) {
          var d = new Date(daily.time[i]);
          var cellKids = [
            { t: 'text', v: (i === 0 ? '今天' : ['日','一','二','三','四','五','六'][d.getDay()]),
              size: 11, opacity: 0.45, align: 'center' },
            { t: 'icon', v: icon(daily.weather_code[i]), size: 15, color: iconColor(daily.weather_code[i]) },
            { t: 'text', v: Math.round(daily.temperature_2m_max[i]) + '\u00b0',
              size: 12, align: 'center', weight: 600 }
          ];
          if (!compact) {
            cellKids.push({ t: 'text', v: Math.round(daily.temperature_2m_min[i]) + '\u00b0',
              size: 11, align: 'center', opacity: 0.4 });
          }
          // 5 个格子统一给一层极淡的底，不再只有"今天"孤零零高亮、其它 4
          // 天光秃秃飘在外面——一整排是"一套卡片"而不是"一个高亮+四段
          // 文字"，"今天"用稍强一点的底和细描边继续保持存在感。
          days.push({ t: 'box', pad: compact ? [2, 2] : [6, 2], radius: 10,
            bg: i === 0 ? '#FFFFFF1C' : '#FFFFFF0A',
            border: i === 0 ? '#FFFFFF2E' : null,
            child: { t: 'col', gap: 4, cross: 'center', children: cellKids } });
        }
        kids.push({ t: 'divider' });
        kids.push({ t: 'grid', cols: 5, gap: 4, children: days });
      }
      // h + clip 兜底：ctx.size.h 是这张卡真正能用的高度（已经扣掉卡片壳
      // 的内边距，见 surface.dart）。不管上面这堆内容的估算是不是精确，
      // 钉死这个高度就不会顶穿卡片底边——顶多是最后一点内容被干净裁掉，
      // 好过整块顶出卡片外面。
      // gap 从 10 收到 8：kids 有 4 项、3 条 gap，光这一处就能省 6px——
      // 真机截图测出来"5天预报"底部溢出 8px，配合上面详情徽章内边距
      // 4→3 再省 2px，8px 刚好对上，不是拍脑袋的数字，是拿真实字体在
      // flutter_test 里复现这张 3x2 卡片实测出来的（见 git 历史里跑过的
      // 诊断脚本）。
      return { t: 'box', h: ctx.size.h, clip: true,
        child: { t: 'col', gap: 8, children: kids } };
    }

    // ---- 后脸：12 小时逐时 + 日出日落 / UV / 降水 ----
    //
    // grid 是卡片当前的行列规格（ctx.grid，挂载/改尺寸时会拿到新的一份）。
    // 逐时预报固定显示 12 小时（2 行 x 6 列），不再按卡片矮就砍成 6 小时——
    // 用户明确要看满 12 小时。矮卡片（rows<=2）腾空间靠去掉分割线和
    // 日出日落/UV 信息块（下面 compact 分支），而不是砍逐时数据本身；
    // 万一某些极端尺寸还是不够，靠结尾那层 h+clip 兜底裁切，不会再顶穿
    // 卡片底边。
    function buildBack(data, grid) {
      var hourly = data.hourly;
      var daily = data.daily;
      var kids = [];
      var compact = !grid || grid.rows <= 2;

      // 逐时预报：固定 12 小时，2 行 x 6 列
      if (hourly && hourly.time) {
        var now = new Date();
        var start = 0;
        for (var j = 0; j < hourly.time.length; j++) {
          if (new Date(hourly.time[j]) >= now) { start = j; break; }
        }
        var cols = [];
        var hn = Math.min(12, hourly.time.length - start);
        for (var k = 0; k < hn; k++) {
          var idx = start + k;
          var ht = new Date(hourly.time[idx]);
          cols.push({ t: 'col', gap: 3, cross: 'center', children: [
            { t: 'text', v: ht.getHours() + '时', size: 10, opacity: 0.45 },
            { t: 'icon', v: icon(hourly.weather_code[idx]), size: 14, color: iconColor(hourly.weather_code[idx]) },
            { t: 'text', v: Math.round(hourly.temperature_2m[idx]) + '\u00b0',
              size: 11.5, weight: 600, align: 'center' },
            { t: 'text',
              v: (hourly.precipitation_probability[idx] || 0) + '%',
              size: 9.5,
              color: (hourly.precipitation_probability[idx] || 0) > 30
                ? '#7CC7FF' : null,
              opacity: (hourly.precipitation_probability[idx] || 0) > 30
                ? 0.9 : 0.35 }
          ] });
        }
        kids.push({ t: 'text', v: '未来 ' + hn + ' 小时', size: 11, opacity: 0.45 });
        kids.push({ t: 'grid', cols: 6, gap: 4, children: cols });
        if (!compact) kids.push({ t: 'divider' });
      }

      // 日出日落 / UV / 日降水量：紧凑模式下没地方放，让给逐时预报
      if (!compact && daily && daily.time) {
        var info = [];
        if (daily.sunrise && daily.sunrise[0]) {
          var sr = new Date(daily.sunrise[0]);
          var ss = new Date(daily.sunset[0]);
          info.push('日出 ' + sr.getHours() + ':' + ('0'+sr.getMinutes()).slice(-2)
            + '  日落 ' + ss.getHours() + ':' + ('0'+ss.getMinutes()).slice(-2));
        }
        if (daily.uv_index_max != null && daily.uv_index_max[0] != null) {
          var uv = Math.round(daily.uv_index_max[0] * 10) / 10;
          var uvLabel = uv >= 11 ? '极强' : uv >= 8 ? '很强' : uv >= 6 ? '强'
            : uv >= 3 ? '中等' : '弱';
          info.push('UV ' + uv + '（' + uvLabel + '）');
        }
        if (daily.precipitation_sum != null && daily.precipitation_sum[0] != null
            && daily.precipitation_sum[0] > 0) {
          info.push('今日降水 ' + daily.precipitation_sum[0] + 'mm');
        }
        if (info.length) {
          kids.push({ t: 'col', gap: 4, children: info.map(function (s) {
            return { t: 'text', v: s, size: 11, opacity: 0.5 };
          }) });
        }
      }

      // 同前脸一样兜底裁一刀，见上面 buildFront 结尾的注释。
      return { t: 'box', h: ctx.size.h, clip: true,
        child: { t: 'col', gap: 10, children: kids } };
    }

    // ---- 主渲染 ----
    function draw() {
      if (state.status === 'loading') {
        ctx.render({ t: 'col', main: 'center', children: [
          { t: 'text', v: '正在获取天气…', size: 12, opacity: 0.45 }] });
        return;
      }
      if (state.status === 'error') {
        var retry = ctx.on(function () { state.status = 'loading'; draw(); load(); });
        ctx.render({ t: 'col', gap: 10, main: 'center', children: [
          { t: 'row', gap: 6, cross: 'center', children: [
            { t: 'box', w: 4, h: 4, radius: 2, bg: '#FF9E7D' },
            { t: 'text', v: '天气不可用', size: 12, weight: 600 } ] },
          { t: 'text', v: state.error, size: 10.5, opacity: 0.5, maxLines: 3 },
          { t: 'tap', id: retry, child: { t: 'box', pad: [5, 12], radius: 8,
            bg: '#FFFFFF14', child: { t: 'text', v: '重试', size: 11 } } }
        ] });
        return;
      }

      var flipId = ctx.on(function () { face = face === 'f' ? 'b' : 'f'; draw(); });

      ctx.render({
        t: 'tap', id: flipId,
        child: { t: 'flip', flipKey: face, children: [
          buildFront(state.data, state.loc, ctx.grid),
          buildBack(state.data, ctx.grid)
        ] }
      });
    }

    // ---- 翻转定时器 ----
    function startFlipTimer() {
      if (flipTimer) ctx.clearTimer(flipTimer);
      flipTimer = ctx.interval(function () {
        face = face === 'f' ? 'b' : 'f';
        draw();
      }, 8000);
    }

    function fail(msg) { state.status = 'error'; state.error = msg; draw(); }

    function resolveLocation() {
      var city = (ctx.settings.city || '').trim();
      if (city) {
        var u = 'https://geocoding-api.open-meteo.com/v1/search?name='
          + encodeURIComponent(city) + '&count=1&language=zh&format=json';
        return ctx.http.getJSON(u).then(function (r) {
          if (!r.ok) { fail('城市检索失败：' + r.error); return null; }
          var hit = r.data && r.data.results && r.data.results[0];
          if (!hit) { fail('没有找到城市「' + city + '」'); return null; }
          return { name: hit.name, lat: hit.latitude, lon: hit.longitude };
        });
      }
      return ctx.http.getJSON('https://ipapi.co/json/').then(function (r) {
        if (!r.ok) { fail('自动定位失败：' + r.error + '（可在设置里手填城市）'); return null; }
        var d = r.data || {};
        if (typeof d.latitude !== 'number') { fail('定位没返回坐标，请手填城市'); return null; }
        return { name: d.city || '当前位置', lat: d.latitude, lon: d.longitude };
      });
    }

    function load() {
      return resolveLocation().then(function (loc) {
        if (!loc) return null;
        state.loc = loc;
        var url = 'https://api.open-meteo.com/v1/forecast'
          + '?latitude=' + loc.lat + '&longitude=' + loc.lon
          + '&current=temperature_2m,weather_code'
          + ',apparent_temperature,relative_humidity_2m,wind_speed_10m,precipitation'
          + '&hourly=temperature_2m,weather_code,precipitation_probability'
          + '&daily=weather_code,temperature_2m_max,temperature_2m_min'
          + ',sunrise,sunset,uv_index_max,precipitation_sum'
          + '&timezone=auto&forecast_days=5';
        return ctx.http.getJSON(url).then(function (r) {
          if (!r.ok) { fail('获取天气失败：' + r.error); return null; }
          state.data = r.data;
          state.status = 'ok';
          state.error = '';
          face = 'f';
          ctx.storage.setLocal('cache', { data: r.data, loc: loc });
          draw();
          startFlipTimer();
          return null;
        });
      });
    }

    draw();
    ctx.storage.getLocal('cache', null).then(function (c) {
      if (c && c.data) {
        state.data = c.data;
        state.loc = c.loc;
        state.status = 'ok';
        draw();
        startFlipTimer();
      }
      load();
    });

    var mins = Number(ctx.settings.refreshMin) || 30;
    var refreshTimer = ctx.interval(load, Math.max(5, mins) * 60000);
    ctx.onCleanup(function () {
      ctx.clearTimer(refreshTimer);
      if (flipTimer) ctx.clearTimer(flipTimer);
    });
  },

  onSettingsChange: function () { /* 城市改了下次刷新生效 */ }
});
