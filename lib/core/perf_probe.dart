/// 性能测量：各 widget 的构建次数 + 帧耗时统计。
///
/// 构建次数用来定位"谁在每帧重建"；帧耗时（build / raster）用来判断瓶颈
/// 在 Dart 侧还是 GPU 侧——这两个数字决定优化往哪打，光看代码猜不出来。
///
/// 实测（2560x1440、5 张卡、acrylic）：build p50≈0.2ms / raster p50≈6.3ms，
/// 也就是说瓶颈全在光栅化，Dart 侧可以忽略。改版式时拿这组数字当尺子，
/// 别凭手感说"快了/慢了"。
///
/// 用 SchedulerBinding.addTimingsCallback 而不是 DevTools：release 包里
/// 也能跑，用户机器上出的问题就地量，不用挂调试器。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

import 'logger.dart';

class PerfProbe {
  static final Map<String, int> _counts = <String, int>{};
  static final Map<String, String> _samples = <String, String>{};
  static Timer? _timer;

  // ---- 帧耗时（毫秒）----
  static final List<double> _buildMs = <double>[];
  static final List<double> _rasterMs = <double>[];
  static int _jankFrames = 0;  // 超过一个 60Hz 帧预算（16.7ms）的帧数
  static bool _timingHooked = false;

  static void start() {
    if (!_timingHooked) {
      _timingHooked = true;
      // addTimingsCallback 拿到的是一批帧的耗时明细。
      // buildDuration = Dart 侧构建+布局；rasterDuration = 光栅化（GPU 提交前）
      //
      // 用 Timer.run 推迟一拍 + try/catch：测量代码自己绝不该把应用搞崩
      // （之前那次就是 binding 未就绪时访问 SchedulerBinding，启动直接断）。
      Timer.run(() {
        try {
          SchedulerBinding.instance.addTimingsCallback(_onTimings);
        } catch (_) {
          _timingHooked = false;
        }
      });
    }
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => dump());
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _buildMs.add(t.buildDuration.inMicroseconds / 1000.0);
      _rasterMs.add(t.rasterDuration.inMicroseconds / 1000.0);
      if (t.totalSpan.inMilliseconds > 17) _jankFrames++;
    }
  }

  static void hit(String tag, [String? sample]) {
    _counts[tag] = (_counts[tag] ?? 0) + 1;
    if (sample != null) _samples[tag] = sample;
  }

  static double _pct(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  static String _fmt(List<double> values) {
    if (values.isEmpty) return '无';
    final sorted = List<double>.from(values)..sort();
    final p50 = _pct(sorted, 0.5);
    final p95 = _pct(sorted, 0.95);
    final maxMs = sorted.last;
    return 'p50=${p50.toStringAsFixed(1)} p95=${p95.toStringAsFixed(1)} '
        'max=${maxMs.toStringAsFixed(1)}ms (n=${values.length})';
  }

  static void dump() {
    // 帧耗时：3 秒窗口内一个都没采到，说明这 3 秒根本没有出帧（静止桌面），
    // 这本身就是有价值的信息——常驻磁贴不该一直刷帧。
    if (_buildMs.isNotEmpty || _rasterMs.isNotEmpty) {
      Log.i(
          'perf',
          '帧耗时 build[${_fmt(_buildMs)}] raster[${_fmt(_rasterMs)}] '
          '掉帧(>17ms)=$_jankFrames');
      _buildMs.clear();
      _rasterMs.clear();
      _jankFrames = 0;
    } else {
      Log.i('perf', '帧耗时 无帧（这 3 秒没有重绘，静止是好事）');
    }

    if (_counts.isEmpty) return;
    final parts = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final buf = StringBuffer('3秒内构建次数：');
    for (final e in parts.take(8)) {
      buf.write(' ${e.key}=${e.value}');
      final s = _samples[e.key];
      if (s != null) buf.write('("$s")');
    }
    Log.i('perf', buf.toString());
    _counts.clear();
    _samples.clear();
  }

  /// 一次性快照（需要立刻拿到数字时用，比如优化前后各测一次）
  static String snapshot() =>
      'build[${_fmt(_buildMs)}] raster[${_fmt(_rasterMs)}] '
      '掉帧=$_jankFrames n=${math.max(_buildMs.length, _rasterMs.length)}';
}
