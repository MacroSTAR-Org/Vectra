/// 注入到每个插件 QuickJS 运行时里的引导脚本。
///
/// QuickJS 是干净的 ES2020 引擎：没有 DOM、没有 fetch、没有 setInterval。
/// 宿主能力全部通过 lw.call(method, args) 发到 Dart，再由 Dart 回调 lw.__resolve。
/// 之所以不用 sendMessage 的返回值：flutter_js 的 onMessage 处理器返回值被丢弃，
/// 只能走"单向发 + 回调"这一条路。
library;

const String kPrelude = r'''
// QuickJS 里没有时区数据库，本地时间等同 UTC：实测时钟显示 06:42 而本地是
// 14:43，正好差 8 小时。宿主会在这段之前注入 __LW_TZ_MS（本地时区偏移毫秒）。
//
// 只修正**无参** new Date()：它代表"此刻"，需要偏移成本地时间。
// new Date(y, m, d) 之类保持原样——QuickJS 按 UTC 构造，getDate() 取回来
// 还是同一个数，日历的月份计算不受影响。
(function () {
  var Orig = Date;
  var off = (typeof __LW_TZ_MS === 'number') ? __LW_TZ_MS : 0;
  function LWDate(a, b, c, d, e, f, g) {
    if (!(this instanceof LWDate)) return new Orig(Orig.now() + off).toString();
    switch (arguments.length) {
      case 0: return new Orig(Orig.now() + off);
      case 1: return new Orig(a);
      default: return new Orig(a, b, c === undefined ? 1 : c, d || 0, e || 0, f || 0, g || 0);
    }
  }
  LWDate.now = function () { return Orig.now(); };
  LWDate.parse = Orig.parse;
  LWDate.UTC = Orig.UTC;
  LWDate.prototype = Orig.prototype;
  Date = LWDate;
})();

var lw = (function () {
  var pending = {};      // 宿主调用的回调
  var seq = 0;
  var timers = {};       // 由 Dart 持有真实定时器，这里只存函数
  var handlers = {};     // 声明式 UI 里的事件处理器
  var handlerSeq = 0;
  var impl = null;
  var ctx = null;

  function post(payload) {
    sendMessage('lw', JSON.stringify(payload));
  }

  function call(method, args) {
    var id = 'c' + (++seq);
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      post({ method: method, args: args === undefined ? null : args, cb: id });
    });
  }

  // ---- Dart 回调入口（下面几个都由宿主 evaluate 调用）----
  function __resolve(id, json) {
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    p.resolve(json);
  }

  function __timer(id) {
    var fn = timers[id];
    if (fn) fn();
  }

  function __event(hid, payload) {
    var fn = handlers[hid];
    if (fn) fn(payload || {});
  }

  function __settings(s) {
    if (ctx) ctx.settings = s;
    if (impl && impl.onSettingsChange) impl.onSettingsChange(s, ctx);
  }

  function __resize(w, h, cols, rows) {
    if (ctx) { ctx.size = { w: w, h: h }; ctx.grid = { cols: cols, rows: rows }; }
    if (impl && impl.onResize) impl.onResize(w, h, ctx);
  }

  // "莫奈取色"实时变化时更新 ctx.theme。accent 为 null 表示用户关掉了
  // 取色开关，插件自己决定怎么兜底（通常是退回写死的颜色）。
  function __theme(accent) {
    if (ctx) { ctx.theme = { accent: accent }; }
    if (impl && impl.onThemeChange) impl.onThemeChange(ctx.theme, ctx);
  }

  function __unmount() {
    if (impl && impl.unmount) { try { impl.unmount(ctx); } catch (e) {} }
    // ctx.onCleanup 登记的收尾函数。定时器宿主会统一回收，但插件登记的**别的**
    // 收尾动作（卸载前存一次状态之类）没有第二条路径能跑到。
    // 倒序执行：后登记的通常依赖先登记的，先拆后装的那个才安全。
    // 每个都单独 try：一个收尾函数抛异常不该让后面的都不执行。
    if (ctx && ctx.__cleanups) {
      for (var i = ctx.__cleanups.length - 1; i >= 0; i--) {
        try { ctx.__cleanups[i](); } catch (e) {}
      }
      ctx.__cleanups = [];
    }
    timers = {}; handlers = {}; pending = {};
  }

  // ---- 定时器：Dart 持有句柄，卸载时统一回收 ----
  var timerSeq = 0;
  function setInterval(fn, ms) {
    var id = 't' + (++timerSeq);
    timers[id] = fn;
    post({ method: 'timer.set', args: { id: id, ms: ms, repeat: true } });
    return id;
  }
  function setTimeout(fn, ms) {
    var id = 't' + (++timerSeq);
    timers[id] = function () { delete timers[id]; fn(); };
    post({ method: 'timer.set', args: { id: id, ms: ms, repeat: false } });
    return id;
  }
  function clearTimer(id) {
    delete timers[id];
    post({ method: 'timer.clear', args: { id: id } });
  }

  // ---- 事件处理器登记：树里只放 id，函数留在这边 ----
  function on(fn) {
    var id = 'h' + (++handlerSeq);
    handlers[id] = fn;
    return id;
  }

  function register(x) { impl = x; }

  // ---- SDK 扩展点 ----
  var sdk = {
    node: {
      register: function (type, renderFn) {
        post({ method: '__sdk.node.register', args: { type: type, render: renderFn } });
      }
    },
    capability: {
      register: function (name, handler) {
        post({ method: '__sdk.capability.register', args: { name: name, handler: handler } });
      }
    },
    widget: {
      register: function (template) {
        post({ method: '__sdk.widget.register', args: { template: template } });
      }
    },
    lifecycle: {
      on: function (event, handler) {
        post({ method: '__sdk.lifecycle.on', args: { event: event, handler: handler } });
      }
    }
  };

  function __mount(c) {
    ctx = c;
    // ctx 的成员名与 Electron 版保持一致，只有 root 换成 render
    ctx.render = function (tree) { post({ method: 'render', args: tree }); };
    ctx.on = on;
    ctx.interval = setInterval;
    ctx.timeout = setTimeout;
    ctx.clearTimer = clearTimer;
    ctx.onCleanup = function (fn) { (ctx.__cleanups = ctx.__cleanups || []).push(fn); };
    // get/set        插件级键值，所有卡片共享
    // getLocal/set   本卡片私有的键值
    // cacheGet/Set   缓存，一条一个文件，超量会被宿主淘汰
    //
    // 三点要记住：
    //   1. set(k, null) 是**删除**这个键，不是存一个 null；
    //   2. 缓存随时可能消失，只放"丢了能重新算/重新抓"的东西，
    //      用户真正的数据（待办清单之类）一律用 setLocal；
    //   3. 缓存适合大块数据。键值存储是整份读写的，往里塞几百 KB
    //      会让每次存取都变贵；缓存则只碰命中的那一条。
    ctx.storage = {
      get: function (k, d) { return call('storage.get', { key: k, def: d === undefined ? null : d }); },
      set: function (k, v) { return call('storage.set', { key: k, value: v }); },
      getLocal: function (k, d) { return call('storage.getLocal', { key: k, def: d === undefined ? null : d }); },
      setLocal: function (k, v) { return call('storage.setLocal', { key: k, value: v }); },
      cacheGet: function (k) { return call('storage.cacheGet', { key: k }); },
      cacheSet: function (k, v) { return call('storage.cacheSet', { key: k, value: v }); }
    };
    // opts.headers 只有白名单里的几个头会被采纳（UA / Referer / Accept 之类），
    // 宿主那边会过滤，插件伪造不了 Cookie
    ctx.http = {
      getJSON: function (url, opts) {
        return call('http.getJSON', {
          url: url,
          headers: (opts && opts.headers) || null
        });
      },
      // 原始文本版：接口返回的不是纯 JSON 时用（JSONP 之类），插件自己解析
      getText: function (url, opts) {
        return call('http.getText', {
          url: url,
          headers: (opts && opts.headers) || null
        });
      }
    };
    // 正在播放的媒体（Windows 系统媒体控件）。封面不会以字节形式出现在这里，
    // 只有 artKey，直接塞给 {t:'image', key: artKey} 用。
    ctx.media = {
      state: function () { return call('media.state', {}); },
      play: function () { return call('media.control', { cmd: 'play' }); },
      pause: function () { return call('media.control', { cmd: 'pause' }); },
      toggle: function () { return call('media.control', { cmd: 'toggle' }); },
      next: function () { return call('media.control', { cmd: 'next' }); },
      prev: function () { return call('media.control', { cmd: 'prev' }); },
      seek: function (ms) {
        return call('media.control', { cmd: 'seek', posMs: Math.round(ms) });
      }
    };
    ctx.requestSize = function (s) { post({ method: 'requestSize', args: { size: s } }); };
    ctx.openSettings = function () { post({ method: 'openSettings' }); };
    ctx.toast = function (m) { post({ method: 'toast', args: { message: String(m) } }); };
    ctx.openExternal = function (u) { post({ method: 'openExternal', args: { url: String(u) } }); };
    ctx.sdk = sdk;

    // onLoad：比 mount 更早的时机，让插件注册扩展点
    if (impl && typeof impl.onLoad === 'function') {
      try {
        impl.onLoad({ sdk: sdk, appVersion: c.appVersion || '', pluginDir: c.pluginDir || '' });
      } catch (e) {
        // onLoad 失败不该阻止 mount
      }
    }

    if (!impl || typeof impl.mount !== 'function') {
      throw new Error('插件没有调用 lw.register({ mount })');
    }
    return impl.mount(ctx);
  }

  return {
    register: register,
    call: call,
    on: on,
    sdk: sdk,
    setTimeout: setTimeout,
    setInterval: setInterval,
    clearTimer: clearTimer,
    __mount: __mount,
    __resolve: __resolve,
    __timer: __timer,
    __event: __event,
    __settings: __settings,
    __resize: __resize,
    __theme: __theme,
    __unmount: __unmount
  };
})();

// 覆盖 flutter_js 自带的 setTimeout：那一份不可取消，插件卸载后仍会触发。
// 这里三个全局都换成 lw 内部实现，定时器句柄由 Dart 持有，卸载时统一回收。
var setTimeout = lw.setTimeout;
var setInterval = lw.setInterval;
var clearTimeout = lw.clearTimer;
var clearInterval = lw.clearTimer;
''';
