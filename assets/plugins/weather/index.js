// 天气：小米天气 v3 API（免签硬编码 appKey）+ 中国天气网城市搜索 + 自动定位。
//
// 数据源说明（2026-08 实测）：
//   - v2 接口（wtr-v2/weather?cityId=）已废弃：返回的是"请更换接口"占位
//     数据，不能再用。v3（wtr-v3/weather/all）实测可用，appKey/sign 是
//     MIUI 天气 App 里逆向出来的硬编码常量，裸 GET 即可。
//   - v3 要求经纬度（只传 locationKey 会 400），所以坐标必填：手填城市
//     走 open-meteo geocoding 拿坐标，自动定位用 ipapi 的坐标。
//   - 城市码：中国天气网 toy1 搜出来的 9 位码（101250301 这种）拼上
//     "weathercn:" 前缀就是小米的 locationKey，两边正好对接。
//   - v3 的天气是数字代码（current.weather="1"），中文描述和图标按
//     代码表映射（表见下方 WEATHER_CODE，MIUI 内置表交叉验证过）。
//   - daily/hourly 数组没有日期字段：index 0 = 今天/起始小时，日期靠
//     下标 + pubTime 推算。
//
// 前脸：当前温度 + 体感/湿度/风/UV 徽章 + 5天预报
// 后脸：12 小时逐时预报（v3 有逐时数据了）+ 空气质量/UV 环境指数
// 每 8 秒自动翻转，也可点击卡片手动翻。
lw.register({
  mount: function (ctx) {
    var state = { status: 'loading', error: '', data: null, loc: null };
    var face = 'f';        // flipKey：'f' = 正面，'b' = 背面
    var flipTimer = null;

    // 小米天气代码表：代码 -> [中文描述, 图标]。MIUI 内置表，
    // 多个开源项目交叉验证过。
    var WEATHER_CODE = {
      0: ['晴', 'sun'], 1: ['多云', 'cloud'], 2: ['阴', 'cloud'], 3: ['阵雨', 'rain'],
      4: ['雷阵雨', 'storm'], 5: ['雷阵雨伴冰雹', 'storm'], 6: ['雨夹雪', 'sleet'],
      7: ['小雨', 'rain'], 8: ['中雨', 'rain'], 9: ['大雨', 'rain'], 10: ['暴雨', 'rain'],
      11: ['大暴雨', 'rain'], 12: ['特大暴雨', 'rain'], 13: ['阵雪', 'snow'],
      14: ['小雪', 'snow'], 15: ['中雪', 'snow'], 16: ['大雪', 'snow'], 17: ['暴雪', 'snow'],
      18: ['雾', 'fog'], 19: ['冻雨', 'rain'], 20: ['沙尘暴', 'fog'],
      21: ['小雨-中雨', 'rain'], 22: ['中雨-大雨', 'rain'], 23: ['大雨-暴雨', 'rain'],
      24: ['暴雨-大暴雨', 'rain'], 25: ['大暴雨-特大暴雨', 'rain'],
      26: ['小雪-中雪', 'snow'], 27: ['中雪-大雪', 'snow'], 28: ['大雪-暴雪', 'snow'],
      29: ['浮尘', 'fog'], 30: ['扬沙', 'fog'], 31: ['强沙尘暴', 'fog'],
      32: ['飑', 'storm'], 33: ['龙卷风', 'storm'], 34: ['高吹雪', 'snow'],
      35: ['轻雾', 'fog'], 53: ['霾', 'fog'], 99: ['未知', 'cloud']
    };
    function descOf(code) { return (WEATHER_CODE[code] || ['未知', 'cloud'])[0]; }
    function iconOf(code) { return (WEATHER_CODE[code] || ['未知', 'cloud'])[1]; }

    // 图标颜色跟着天气语义走：晴天暖、云雾中性、雨雪偏冷、雷暴带紫。
    var ICON_COLOR = {
      sun: '#FFD79A', cloud: '#B8C4D9', fog: '#C7CFD9',
      rain: '#7CC7FF', snow: '#DCEEFA', storm: '#B79CFF'
    };
    function iconColor(code) { return ICON_COLOR[iconOf(code)] || ICON_COLOR.cloud; }

    // ---- 前脸：当前天气 + 5 天预报 ----
    function buildFront(data, loc, grid) {
      var cur = data.current || {};
      var fd = data.forecastDaily || {};
      var compact = !grid || grid.rows <= 2;
      var curCode = parseInt(cur.weather, 10);
      if (isNaN(curCode)) curCode = 99;
      var kids = [
        { t: 'row', main: 'between', cross: 'start', children: [
          { t: 'col', gap: 3, children: [
            { t: 'row', gap: 6, cross: 'center', children: [
              { t: 'box', w: 4, h: 4, radius: 2, bg: '#7CC7FF' },
              { t: 'text', v: loc.name, size: 13, opacity: 0.55 } ] },
            { t: 'row', cross: 'start', children: [
              { t: 'text', v: '' + (cur.temperature && cur.temperature.value || '--'),
                size: 48, weight: 300, lh: 1.0, mono: true },
              { t: 'box', pad: [4, 0, 0, 2], child: {
                t: 'text', v: '\u00b0', size: 22, weight: 300, opacity: 0.5 } }
            ] }
          ] },
          { t: 'col', cross: 'end', gap: 6, children: [
            // 图标套一个跟自己同色、极淡的圆形底
            { t: 'box', w: 40, h: 40, radius: 20, center: true,
              bg: iconColor(curCode) + '26',
              child: { t: 'icon', v: iconOf(curCode), size: 22,
                color: iconColor(curCode) } },
            { t: 'text', v: descOf(curCode), size: 12, opacity: 0.65 }
          ] }
        ] }
      ];

      // 当前详情徽章：体感 / 湿度 / 风速 / UV（v3 全都有）
      var detail = [];
      if (cur.feelsLike && cur.feelsLike.value)
        detail.push({ icon: 'thermostat', v: '体感 ' + cur.feelsLike.value + '\u00b0' });
      if (cur.humidity && cur.humidity.value)
        detail.push({ icon: 'rain', v: cur.humidity.value + '%' });
      if (cur.wind && cur.wind.speed && cur.wind.speed.value)
        detail.push({ icon: 'air', v: cur.wind.speed.value + 'km/h' });
      if (cur.uvIndex && cur.uvIndex !== '')
        detail.push({ icon: 'sun', v: 'UV ' + cur.uvIndex });
      if (detail.length) {
        kids.push({ t: 'row', gap: 6, children: detail.map(function (it) {
          return { t: 'box', pad: [3, 8], radius: 9, bg: '#FFFFFF12',
            child: { t: 'row', gap: 4, cross: 'center', children: [
              { t: 'icon', v: it.icon, size: 11, opacity: 0.55 },
              { t: 'text', v: it.v, size: 11, opacity: 0.75 }
            ] } };
        }) });
      }

      // 5 天预报：forecastDaily 数组 index 0 = 今天，没有日期字段，
      // 星期用本地日期加下标推算。白天代码在 weather[i].from。
      var days = [];
      var temps = fd.temperature && fd.temperature.value || [];
      var wtrs = fd.weather && fd.weather.value || [];
      for (var i = 0; i < 5; i++) {
        var hi = temps[i] && temps[i].from;
        var lo = temps[i] && temps[i].to;
        var wcode = parseInt(wtrs[i] && wtrs[i].from, 10);
        if (isNaN(wcode)) wcode = 99;
        var d = new Date();
        d.setDate(d.getDate() + i);
        var label = i === 0 ? '今天' : ['日','一','二','三','四','五','六'][d.getDay()];
        var cellKids = [
          { t: 'text', v: label, size: 11, opacity: 0.45, align: 'center' },
          { t: 'icon', v: iconOf(wcode), size: 15, color: iconColor(wcode) }
        ];
        if (hi != null) {
          cellKids.push({ t: 'text', v: Math.round(hi) + '\u00b0', size: 12,
            align: 'center', weight: 600 });
          if (!compact && lo != null) {
            cellKids.push({ t: 'text', v: Math.round(lo) + '\u00b0', size: 11,
              align: 'center', opacity: 0.4 });
          }
        }
        // 5 个格子统一极淡底，"今天"稍强 + 细描边
        days.push({ t: 'box', pad: compact ? [2, 2] : [6, 2], radius: 10,
          bg: i === 0 ? '#FFFFFF1C' : '#FFFFFF0A',
          border: i === 0 ? '#FFFFFF2E' : null,
          child: { t: 'col', gap: 4, cross: 'center', children: cellKids } });
      }
      if (days.length) {
        kids.push({ t: 'divider' });
        kids.push({ t: 'grid', cols: 5, gap: 4, children: days });
      }
      // h + clip 兜底：钉死可用高度，顶多是最后一点被裁掉，不会顶穿卡片
      return { t: 'box', h: ctx.size.h, clip: true,
        child: { t: 'col', gap: 8, children: kids } };
    }

    // ---- 后脸：12 小时逐时 + 空气质量/UV 环境指数 ----
    //
    // v3 有逐时数据（forecastHourly），固定 12 小时（2 行 x 6 列），不再
    // 按卡片矮就砍成 6 小时——用户明确要求过看满 12 小时。矮卡片（rows<=2）
    // 腾空间靠不显示环境指数（下面 compact 分支），逐时数据本身不动。
    function buildBack(data, grid) {
      var fh = data.forecastHourly || {};
      var aqi = data.aqi || {};
      var compact = !grid || grid.rows <= 2;
      var kids = [];

      var hTemps = fh.temperature && fh.temperature.value || [];
      var hWtrs = fh.weather && fh.weather.value || [];
      if (hTemps.length) {
        // 起始小时从 pubTime 算，后面的按 index 递推
        var startDate = fh.temperature.pubTime
          ? new Date(fh.temperature.pubTime) : new Date();
        var cols = [];
        var hn = 12;
        for (var k = 0; k < hn && k < hTemps.length; k++) {
          var hd = new Date(startDate.getTime() + k * 3600000);
          var hc = parseInt(hWtrs[k], 10);
          if (isNaN(hc)) hc = 99;
          cols.push({ t: 'col', gap: 3, cross: 'center', children: [
            { t: 'text', v: hd.getHours() + '时', size: 10, opacity: 0.45 },
            { t: 'icon', v: iconOf(hc), size: 14, color: iconColor(hc) },
            { t: 'text', v: Math.round(hTemps[k]) + '\u00b0',
              size: 11.5, weight: 600, align: 'center' }
          ] });
        }
        kids.push({ t: 'text', v: '未来 ' + cols.length + ' 小时', size: 11, opacity: 0.45 });
        // 6 列：12 个小时格子自动排成 2 行 x 6 列。之前误写 cols.length（12），
        // 12 个全挤在一行。
        kids.push({ t: 'grid', cols: 6, gap: 4, children: cols });
        if (!compact) kids.push({ t: 'divider' });
      }

      // 环境指数：AQI 数值 + 一句话建议 + UV 等级。
      //
      // 之前紧凑模式把它整个隐藏了，结果 12 小时两行只占半张卡片，底下
      // 空出一大块。实测 3x2 卡片（内容区约 184px）装下"标题 + 2 行网格 +
      // 环境指数"还有余量——空间够就都显示，别让卡片空一半。
      // 紧凑模式不加 divider，省出那一条给文字。
      {
        var env = [];
        if (aqi.aqi) env.push('AQI ' + aqi.aqi);
        if (aqi.suggest) env.push(aqi.suggest);
        var uv = data.current && data.current.uvIndex;
        if (uv && uv !== '') {
          var uvN = parseInt(uv, 10);
          var uvLabel = uvN >= 11 ? '极强' : uvN >= 8 ? '很强' : uvN >= 6 ? '强'
            : uvN >= 3 ? '中等' : '弱';
          env.push('UV ' + uv + '（' + uvLabel + '）');
        }
        if (env.length) {
          if (!compact) kids.push({ t: 'divider' });
          kids.push({ t: 'col', gap: 4, children: env.map(function (s) {
            return { t: 'text', v: s, size: 11, opacity: 0.5 };
          }) });
        }
      }

      return { t: 'box', h: ctx.size.h, clip: true,
        child: { t: 'col', gap: 8, children: kids } };
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

    // ---- 城市定位 ----
    //
    // 中国天气网 toy1 的返回是 JSONP 包装：([{"ref":"101250301~hunan~株洲~Zhuzhou~..."}])
    // 不是纯 JSON，所以走 http.getText 拿原始文本自己剥括号。ref 用 ~ 分隔，
    // 第一个字段是城市码；结果里第一条通常是市级记录（9 位 code），后面
    // 跟着一堆乡镇（12 位 code），取第一个 9 位的。Referer 必须有——不带
    // 的话 toy1 只回一个空的 "()"。
    //
    // toy1 只给城市码不给坐标，而小米 v3 要求经纬度（只传 locationKey
    // 会 400）。所以坐标单独走 open-meteo geocoding 拿——手填城市用它，
    // 自动定位直接用 ipapi 的坐标，不用再查一遍。
    function searchCity(keyword) {
      var u = 'https://toy1.weather.com.cn/search?cityname='
        + encodeURIComponent(keyword);
      return ctx.http.getText(u, {
        headers: { 'Referer': 'https://www.weather.com.cn/' }
      }).then(function (r) {
        if (!r.ok || !r.data) return null;
        var m = String(r.data).match(/\[([\s\S]*)\]/);
        if (!m) return null;
        var arr;
        try { arr = JSON.parse('[' + m[1] + ']'); } catch (e) { return null; }
        for (var i = 0; i < arr.length; i++) {
          var ref = String(arr[i].ref || '').split('~');
          // 9 位 = 市级。城市名取 ref[2]（中文名），省在 ref[8]
          if (ref.length > 2 && ref[0].length === 9) {
            return { name: ref[2], cityId: ref[0], province: ref[8] || '' };
          }
        }
        return null;
      });
    }

    // 手填城市名的坐标：open-meteo geocoding，中英文都认
    function searchCoord(keyword) {
      var u = 'https://geocoding-api.open-meteo.com/v1/search?name='
        + encodeURIComponent(keyword) + '&count=1&language=zh&format=json';
      return ctx.http.getJSON(u).then(function (r) {
        if (!r.ok || !r.data || !r.data.results || !r.data.results.length) return null;
        var hit = r.data.results[0];
        return { lat: hit.latitude, lon: hit.longitude };
      });
    }

    function resolveLocation() {
      var city = (ctx.settings.city || '').trim();
      if (city) {
        // 手填城市名：toy1 拿城市码（拼 locationKey），open-meteo 拿坐标
        return searchCity(city).then(function (hit) {
          if (!hit) { fail('没找到城市「' + city + '」'); return null; }
          return searchCoord(city).then(function (coord) {
            if (!coord) { fail('城市「' + city + '」坐标解析失败'); return null; }
            hit.lat = coord.lat; hit.lon = coord.lon;
            return hit;
          });
        });
      }
      // 自动定位：ipapi 拿经纬度和城市名（英文/拼音），坐标直接用，
      // 再用拼音搜城市码。ipapi 偶尔不给 city 字段，那只能让用户手填。
      return ctx.http.getJSON('https://ipapi.co/json/').then(function (r) {
        if (!r.ok) { fail('自动定位失败：' + r.error + '（可在设置里手填城市）'); return null; }
        var d = r.data || {};
        if (typeof d.latitude !== 'number') { fail('定位没返回坐标，请手填城市'); return null; }
        var cityName = d.city || '';
        if (!cityName) { fail('定位没拿到城市名，请手填城市'); return null; }
        return searchCity(cityName).then(function (hit) {
          if (!hit) { fail('定位到的「' + cityName + '」查不到城市码，请手填城市'); return null; }
          hit.lat = d.latitude; hit.lon = d.longitude;
          return hit;
        });
      });
    }

    function load() {
      return resolveLocation().then(function (loc) {
        if (!loc) return null;
        state.loc = loc;
        // v3 主接口。appKey/sign 是逆向出的固定常量，isGlobal 中国城市
        // false。days 传 5（服务端实际会给更多，取前 5 天即可）。
        var u = 'https://weatherapi.market.xiaomi.com/wtr-v3/weather/all'
          + '?latitude=' + loc.lat + '&longitude=' + loc.lon
          + '&locationKey=' + encodeURIComponent('weathercn:' + loc.cityId)
          + '&days=5&appKey=weather20151024&sign=zUFJoAR2ZVrDy1vF3D07'
          + '&isGlobal=false&locale=zh_cn';
        return ctx.http.getJSON(u).then(function (r) {
          if (!r.ok) { fail('获取天气失败：' + r.error); return null; }
          if (!r.data || !r.data.current || !r.data.forecastDaily) {
            fail('天气数据不完整'); return null;
          }
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
