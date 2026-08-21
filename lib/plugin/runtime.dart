/// 单张卡片的插件运行时：一个独立的 QuickJS 实例。
///
/// 为什么一卡一实例：隔离。Electron 版靠"一个组件一个进程"做隔离，这一版是
/// 单进程，能给的最强隔离就是独立的 JS 运行时——一个插件把自己的全局搞坏，
/// 不会波及别的卡片。一个 QuickJS 运行时约 200KB，几张卡片完全可接受。
///
/// 单进程带来的真实风险是死循环：插件写个 while(true) 就把整个 UI 卡住。
/// QuickJS 的中断回调可以掐掉，但 flutter_js 0.8.7 没有暴露该接口，
/// 所以这里退而求其次：所有 evaluate 都记时长，超阈值就把该插件标记为失控
/// 并停止再向它派发任何事件（见 _guard）。这挡不住第一次死循环，
/// 但能阻止它被定时器反复触发。这一点必须如实说明，不是完整方案。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

import '../core/logger.dart';
import 'manifest.dart';
import 'prelude.dart';
import 'sdk.dart';

typedef HostCall = Future<Object?> Function(String method, Map<String, Object?> args);

class PluginRuntime {
  PluginRuntime({
    required this.manifest,
    required this.source,
    required this.instanceId,
    required this.host,
    this.sdk,
    this.appVersion = '',
    this.pluginDir = '',
  });

  final PluginManifest manifest;
  final String source;
  final String instanceId;

  /// 宿主能力（storage / http / 面板等）由外部注入，运行时本身不碰 IO
  final HostCall host;

  /// 本插件的 SDK 对象（可选，由 PluginCardBody 注入）
  PluginSdk? sdk;

  /// 应用版本号（传给插件的 onLoad / ctx.appVersion）
  String appVersion = '';

  /// 插件目录路径（传给插件的 onLoad / ctx.pluginDir）
  String pluginDir = '';

  JavascriptRuntime? _rt;
  final Map<String, Timer> _timers = {};
  bool _dead = false;

  /// 已经被销毁（卡片没了）。
  ///
  /// 和 _dead 是两回事：_dead 是"插件失控了"，这个是"这张卡片不在了"。
  /// 分开的原因是善后方式不同——失控要把原因显示给用户，销毁则要求彻底闭嘴：
  /// 界面已经没了，再往 tree/error 里写就是往已 dispose 的 ValueNotifier 上写。
  bool _disposed = false;

  String? _error;

  /// 插件最近一次 render 出来的 UI 树
  final ValueNotifier<Map<String, Object?>?> tree = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// 单次 evaluate 的时间上限；超了就认为插件失控
  static const Duration kBudget = Duration(milliseconds: 800);

  Future<void> mount({
    required Map<String, Object?> settings,
    required double w,
    required double h,
    required int cols,
    required int rows,
    String? themeAccent,
  }) async {
    // 挂载耗时是启动慢的头号嫌疑：插件多起来之后，这里的累计时间直接决定
    // 启动幕布挂多久。逐个记下来，慢的那个一眼就能挑出来。
    final sw = Stopwatch()..start();
    try {
      final rt = getJavascriptRuntime(xhr: false);
      _rt = rt;

      rt.onMessage('lw', (dynamic args) {
        // flutter_js 会把 JSON.stringify 的内容解好交过来
        final map = args is String
            ? jsonDecode(args) as Map<String, Object?>
            : (args as Map).cast<String, Object?>();
        _handleCall(map);
      });

      // 时区偏移必须在 prelude 之前注入：prelude 里的 Date 修正要用它
      final tz = DateTime.now().timeZoneOffset.inMilliseconds;
      _guard(() => rt.evaluate('var __LW_TZ_MS = $tz;'));
      _guard(() => rt.evaluate(kPrelude));
      _guard(() => rt.evaluate(source, sourceUrl: '${manifest.id}/index.js'));

      final ctx = jsonEncode({
        'id': manifest.id,
        'instanceId': instanceId,
        'manifest': manifest.toJson(),
        'settings': settings,
        'size': {'w': w, 'h': h},
        'grid': {'cols': cols, 'rows': rows},
        'theme': {'accent': themeAccent},
        'appVersion': appVersion,
        'pluginDir': pluginDir,
      });
      _guard(() => rt.evaluate('lw.__mount($ctx);'));
      _pump();
      sw.stop();
      Log.d('plugin',
          '${manifest.id} 挂载完成 $instanceId（${sw.elapsedMilliseconds}ms）');
    } catch (e) {
      sw.stop();
      _fail('插件挂载失败：$e');
    }
  }

  /// 所有进入 JS 的调用都过这里：记录耗时、捕获异常、失控后不再派发
  ///
  /// 销毁之后一律不进：卡片重建时（改设置、装插件后重扫）旧运行时会被 dispose，
  /// 而那一刻插件可能还有 HTTP 请求在飞。请求回来时若照旧往下走，_rt 已经是
  /// null，解引用就抛"Null check operator used on a null value"——日志里会
  /// 冒出一条"插件抛出异常"，看着像插件的错，其实是我们自己在拆掉的房子里开灯。
  JsEvalResult? _guard(JsEvalResult Function() body) {
    if (_dead || _disposed || _rt == null) return null;
    final sw = Stopwatch()..start();
    try {
      final r = body();
      if (r.isError) {
        _fail('插件报错：${r.stringResult}');
        return r;
      }
      return r;
    } catch (e) {
      _fail('插件抛出异常：$e');
      return null;
    } finally {
      sw.stop();
      if (sw.elapsed > kBudget) {
        _fail('插件执行超时（${sw.elapsedMilliseconds}ms），已停止调度');
      }
    }
  }

  void _pump() {
    // QuickJS 的 Promise 靠宿主推动微任务队列，不 pump 的话 await 永远不返回
    final rt = _rt;
    if (rt == null || _dead) return;
    var guardCount = 0;
    while (rt.executePendingJob() > 0 && guardCount++ < 1000) {}
  }

  Future<void> _handleCall(Map<String, Object?> msg) async {
    if (_dead || _disposed) return;
    final method = msg['method'] as String? ?? '';
    final args = (msg['args'] as Map?)?.cast<String, Object?>() ?? const {};
    final cb = msg['cb'] as String?;

    // render 是最高频的一条，单独短路
    if (method == 'render') {
      final t = msg['args'];
      tree.value = t is Map ? t.cast<String, Object?>() : null;
      return;
    }

    if (method == 'timer.set') {
      _setTimer(args);
      return;
    }
    if (method == 'timer.clear') {
      _timers.remove(args['id'])?.cancel();
      return;
    }

    Object? result;
    try {
      result = await host(method, args);
    } catch (e) {
      result = {'ok': false, 'error': '$e'};
    }
    // host 调用是异步的，等它回来时这张卡片可能已经没了（改设置、装插件后重扫
    // 都会重建卡片）。再往下走就是对着已销毁的运行时说话。
    if (_disposed || _dead) return;
    if (cb != null) {
      _guard(() => _rt!.evaluate('lw.__resolve(${jsonEncode(cb)}, ${jsonEncode(result)});'));
      _pump();
    }
  }

  void _setTimer(Map<String, Object?> args) {
    final id = args['id'] as String?;
    if (id == null) return;
    final ms = (args['ms'] as num?)?.toInt() ?? 0;
    final repeat = args['repeat'] == true;
    _timers.remove(id)?.cancel();
    void fire() {
      if (_dead) return;
      _guard(() => _rt!.evaluate('lw.__timer(${jsonEncode(id)});'));
      _pump();
    }

    _timers[id] = repeat
        ? Timer.periodic(Duration(milliseconds: ms), (_) => fire())
        : Timer(Duration(milliseconds: ms), () {
            _timers.remove(id);
            fire();
          });
  }

  /// 声明式 UI 里的事件回到 JS
  void dispatchEvent(String handlerId, Map<String, Object?> payload) {
    _guard(() => _rt!.evaluate(
        'lw.__event(${jsonEncode(handlerId)}, ${jsonEncode(payload)});'));
    _pump();
  }

  void notifySettings(Map<String, Object?> settings) {
    _guard(() => _rt!.evaluate('lw.__settings(${jsonEncode(settings)});'));
    _pump();
  }

  void notifyResize(double w, double h, int cols, int rows) {
    _guard(() => _rt!.evaluate('lw.__resize($w, $h, $cols, $rows);'));
    _pump();
  }

  /// "莫奈取色"实时变化时推给插件，跟 notifyResize 是同一套思路——
  /// mount 时给过一次初始值，这里是壁纸换了之后的后续更新。
  /// accent 为 null 表示用户关掉了取色开关，插件应该退回自己写死的颜色。
  void notifyTheme(String? accent) {
    _guard(() => _rt!.evaluate('lw.__theme(${jsonEncode(accent)});'));
    _pump();
  }

  void _fail(String message) {
    // 已经销毁的运行时不该再报错：界面早没了，tree/error 也已经 dispose，
    // 这时候写进去既没人看得到，还会往已释放的对象上写。
    if (_disposed) return;
    // 插件一旦失控就再也不调度了，界面上只剩一个错误框。不记下来的话，
    // 用户报"组件不动了"时无从查起 —— 是崩了、超时了、还是清单写错了。
    if (!_dead) Log.e('plugin', '${manifest.id}($instanceId) $message');
    _dead = true;
    _error = message;
    error.value = message;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  String? get failure => _error;

  void dispose() {
    if (_disposed) return;
    // 先置位再拆：拆的过程中如果有异步回调回来，上面那几处判断能拦住它
    _disposed = true;
    if (!_dead && _rt != null) {
      try {
        _rt!.evaluate('lw.__unmount();');
      } catch (_) {}
    }
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _rt?.dispose();
    _rt = null;
    sdk?.dispose();
    tree.dispose();
    error.dispose();
  }
}
