/// 启动幕布的进度闸门。
///
/// native 那边立着一块幕布（见 windows/runner/splash_window.cpp），盖住整个
/// 启动过程。这里负责回答一个问题：**什么时候算"加载好了"**。
///
/// 判据是"每张卡片都跑出了第一棵 UI 树"，也就是插件源码编译完、lw.__mount()
/// 执行完。刻意**不等插件的网络请求**：weather、lyrics 这类插件会去拉数据，
/// 单次超时就有 15 秒，等它们的话幕布会挂在那儿不动，而那些数据晚一点到并
/// 不影响卡片先把骨架显示出来。
///
/// 插件市场做起来之后卡片会更多、编译更久，这套按"张数"记的进度不用改结构，
/// total 自然就变大了。
library;

import 'dart:async';

import '../native/native_bridge.dart';
import 'logger.dart';

class SplashGate {
  SplashGate._();

  static int _total = 0;

  /// 已经报到的卡片 id。用 Set 而不是计数器：卡片会因为全局设置变化
  /// （_revision）整体重建，同一张卡的 _boot 会再跑一遍，按次数加会多报。
  static final Set<String> _reported = <String>{};

  static bool _done = false;
  static Timer? _fallback;

  /// 兜底时长。native 侧还有一道 4 秒的，这里稍短一点，正常情况下由 Dart
  /// 这边先把幕布收掉 —— 它知道得更准。
  static const Duration kFallback = Duration(seconds: 3);

  /// 实际使用的兜底时长。做成可覆盖是为了测试：这条分支只有"插件永远不就绪"
  /// 时才会走到，而它恰恰是唯一能把幕布从卡死里救出来的路径，必须测；
  /// 真等 3 秒又会把测试拖慢。生产代码不会去改它。
  static Duration fallbackDelay = kFallback;

  static bool get isDone => _done;

  /// 启动时把总卡片数拍个快照。之后再加卡片是用户在面板里操作的，
  /// 跟这次启动无关。
  static void start(int total) {
    _total = total;
    _reported.clear();
    _done = false;
    _fallback?.cancel();

    if (total <= 0) {
      // 没有卡片可等（理论上不会：main 里空布局会播种默认卡片）
      finish();
      return;
    }

    _push(0, total);
    _fallback = Timer(fallbackDelay, () {
      if (_done) return;
      Log.w('splash',
          '等待卡片就绪超时（${_reported.length}/$_total），先收幕布');
      finish();
    });
  }

  /// 某张卡片就绪。加载失败的卡片也要报 —— 它已经有最终形态（错误框）了，
  /// 再等下去只会让幕布陪着一起卡死。
  static void reportReady(String cardId) {
    if (_done) return;
    if (!_reported.add(cardId)) return;

    _push(_reported.length, _total);
    if (_reported.length >= _total) {
      Log.i('splash', '全部 $_total 张卡片就绪');
      finish();
    }
  }

  static void finish() {
    if (_done) return;
    _done = true;
    _fallback?.cancel();
    _fallback = null;
    NativeBridge.splashFinish().catchError((Object e) {
      Log.w('splash', '通知幕布收尾失败: $e');
    });
  }

  /// 进度上报。这几个调用都不 await —— 幕布画得慢一点无所谓，
  /// 但失败要留下痕迹，否则通道断了只会表现为"进度条一直不动"。
  static void _push(int ready, int total) {
    NativeBridge.splashProgress(ready, total).catchError((Object e) {
      Log.w('splash', '上报进度失败 $ready/$total: $e');
    });
  }

  /// 仅供测试：把闸门恢复成未启动的样子
  static void resetForTest() {
    _total = 0;
    _reported.clear();
    _done = false;
    _fallback?.cancel();
    _fallback = null;
    fallbackDelay = kFallback;
  }
}
