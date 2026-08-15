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
    function desc(c) { return (CODE[c] || ['—', 'cloud'])[0]; }
    function icon(c) { return (CODE[c] || ['—', 'cloud'])[1]; }

    // ---- 前脸：当前天气 + 5 天预报 ----
    function buildFront(data, loc) {
      var cur = data.current;
      var daily = data.daily;
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
          { t: 'col', cross: 'end', gap: 5, children: [
            { t: 'icon', v: icon(cur.weather_code), size: 28, color: '#FFD79A' },
            { t: 'text', v: desc(cur.weather_code), size: 12, opacity: 0.65 }
          ] }
        ] }
      ];

      // 当前详情行：体感 / 湿度 / 风速 / 降水
      var detail = [];
      if (cur.apparent_temperature != null)
        detail.push('体感 ' + Math.round(cur.apparent_temperature) + '\u00b0');
      if (cur.relative_humidity_2m != null)
        detail.push('湿度 ' + Math.round(cur.relative_humidity_2m) + '%');
      if (cur.wind_speed_10m != null)
        detail.push('风速 ' + Math.round(cur.wind_speed_10m) + 'km/h');
      if (cur.precipitation != null && cur.precipitation > 0)
        detail.push('降水 ' + cur.precipitation + 'mm');
      if (detail.length) {
        kids.push({ t: 'text', v: detail.join(' \u00b7 '), size: 11, opacity: 0.5 });
      }

      // 5 天预报
      if (daily && daily.time) {
        var days = [];
        var n = Math.min(5, daily.time.length);
        for (var i = 0; i < n; i++) {
          var d = new Date(daily.time[i]);
          days.push({ t: 'box', pad: [6, 2], radius: 8,
            bg: i === 0 ? '#FFFFFF10' : null,
            child: { t: 'col', gap: 4, cross: 'center', children: [
              { t: 'text', v: (i === 0 ? '今天' : ['日','一','二','三','四','五','六'][d.getDay()]),
                size: 11, opacity: 0.45, align: 'center' },
              { t: 'icon', v: icon(daily.weather_code[i]), size: 15, color: '#FFD79A' },
              { t: 'text', v: Math.round(daily.temperature_2m_max[i]) + '\u00b0',
                size: 12, align: 'center', weight: 600 },
              { t: 'text', v: Math.round(daily.temperature_2m_min[i]) + '\u00b0',
                size: 11, align: 'center', opacity: 0.4 }
            ] } });
        }
        kids.push({ t: 'divider' });
        kids.push({ t: 'grid', cols: 5, gap: 4, children: days });
      }
      return { t: 'col', gap: 10, children: kids };
    }

    // ---- 后脸：12 小时逐时 + 日出日落 / UV / 降水 ----
    function buildBack(data) {
      var hourly = data.hourly;
      var daily = data.daily;
      var kids = [];

      // 12 小时逐时预报
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
            { t: 'icon', v: icon(hourly.weather_code[idx]), size: 14, color: '#FFD79A' },
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
        kids.push({ t: 'text', v: '未来 12 小时', size: 11, opacity: 0.45 });
        kids.push({ t: 'grid', cols: 6, gap: 4, children: cols });
        kids.push({ t: 'divider' });
      }

      // 日出日落 / UV / 日降水量
      if (daily && daily.time) {
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

      return { t: 'col', gap: 10, children: kids };
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
          buildFront(state.data, state.loc),
          buildBack(state.data)
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
          + '&timezone=auto&forecast_days=2';
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
