/// 磁吸对齐引擎（纯逻辑，无 UI 依赖，便于单测）
///
/// 两类吸附：
///   1. 对齐吸附 align  —— 左/右/水平中线 与 顶/底/垂直中线 对齐
///   2. 贴合吸附 stick  —— 边贴边"咬合"，间距为 0 或设定的留白
///
/// resolve() 在 X/Y 两轴上各自独立取最近的候选，互不干扰。
///
/// 本文件从 Electron 版 src/shared/snap.mjs 1:1 移植。
library;

import 'dart:math' as math;

const double _eps = 0.01;

class Rect {
  final double x;
  final double y;
  final double w;
  final double h;
  const Rect(this.x, this.y, this.w, this.h);

  double get left => x;
  double get right => x + w;
  double get top => y;
  double get bottom => y + h;
  double get centerX => x + w / 2;
  double get centerY => y + h / 2;

  @override
  String toString() => 'Rect($x, $y, $w, $h)';
}

/// 辅助线。[type] 为 'v'（竖线）或 'h'（横线）。
class Guide {
  final String type;
  final double pos;
  double start;
  double end;
  Guide({required this.type, required this.pos, required this.start, required this.end});

  @override
  String toString() => 'Guide($type, pos=$pos, $start..$end)';
}

class SnapResult {
  final double x;
  final double y;
  final List<Guide> guides;
  final bool snappedX;
  final bool snappedY;
  const SnapResult({
    required this.x,
    required this.y,
    required this.guides,
    required this.snappedX,
    required this.snappedY,
  });
}

/// 内部：某一轴上当前最优的候选
class _Slot {
  double value;
  double absDelta;
  final List<_GuideRef> guides;
  _Slot(this.value, this.absDelta, this.guides);
}

class _GuideRef {
  final String type;
  final double pos;
  final Rect a;
  const _GuideRef(this.type, this.pos, this.a);
}

/// JS 的 Math.round 语义：向上取整半数（-0.5 -> -0，而不是 Dart 的 -1）。
/// 辅助线去重 key 用到它，多显示器负坐标下若用 Dart 的 round 会与原实现分叉。
int _jsRound(double v) => (v + 0.5).floor();

double clamp(double v, double min, double max) => v < min ? min : (v > max ? max : v);

/// [moving] 拖动中卡片的候选位置；[others] 其它卡片。
SnapResult resolve(
  Rect moving,
  List<Rect> others, {
  double threshold = 10,
  double gutter = 12,
  ({double w, double h})? bounds,
}) {
  _Slot? bestX;
  _Slot? bestY;

  void consider(String axis, double value, double delta, _GuideRef guide) {
    final abs = delta.abs();
    if (abs > threshold) return;
    final slot = axis == 'x' ? bestX : bestY;
    if (slot == null || abs < slot.absDelta - _eps) {
      final next = _Slot(value, abs, [guide]);
      if (axis == 'x') {
        bestX = next;
      } else {
        bestY = next;
      }
    } else if ((abs - slot.absDelta).abs() <= _eps) {
      // 同等贴近的多条参考线一起画出来
      slot.guides.add(guide);
    }
  }

  final mL = moving.left, mR = moving.right, mCX = moving.centerX;
  final mT = moving.top, mB = moving.bottom, mCY = moving.centerY;

  for (final o in others) {
    final oL = o.left, oR = o.right, oCX = o.centerX;
    final oT = o.top, oB = o.bottom, oCY = o.centerY;

    // ---------- X 轴 ----------
    // 对齐
    consider('x', oL, oL - mL, _GuideRef('v', oL, o));
    consider('x', oR - moving.w, oR - mR, _GuideRef('v', oR, o));
    consider('x', oCX - moving.w / 2, oCX - mCX, _GuideRef('v', oCX, o));
    consider('x', oL - moving.w, oL - mR, _GuideRef('v', oL, o));
    consider('x', oR, oR - mL, _GuideRef('v', oR, o));

    // 贴合：放到对方右侧 / 左侧。gutter 为 0 时集合退化成 {0}，只跑一轮。
    for (final gap in <double>{0, gutter}) {
      consider('x', oR + gap, (oR + gap) - mL, _GuideRef('v', oR, o));
      consider('x', oL - moving.w - gap, (oL - gap) - mR, _GuideRef('v', oL, o));
    }

    // ---------- Y 轴 ----------
    consider('y', oT, oT - mT, _GuideRef('h', oT, o));
    consider('y', oB - moving.h, oB - mB, _GuideRef('h', oB, o));
    consider('y', oCY - moving.h / 2, oCY - mCY, _GuideRef('h', oCY, o));
    consider('y', oT - moving.h, oT - mB, _GuideRef('h', oT, o));
    consider('y', oB, oB - mT, _GuideRef('h', oB, o));

    for (final gap in <double>{0, gutter}) {
      consider('y', oB + gap, (oB + gap) - mT, _GuideRef('h', oB, o));
      consider('y', oT - moving.h - gap, (oT - gap) - mB, _GuideRef('h', oT, o));
    }
  }

  var x = bestX != null ? bestX!.value : moving.x;
  var y = bestY != null ? bestY!.value : moving.y;

  // 不做屏幕边缘吸附，但必须夹在画布内，否则卡片会拖丢
  if (bounds != null) {
    x = clamp(x, 0, math.max(0, bounds.w - moving.w));
    y = clamp(y, 0, math.max(0, bounds.h - moving.h));
  }

  // 计算辅助线的绘制范围：覆盖参考卡片与当前卡片
  final finalRect = Rect(x, y, moving.w, moving.h);
  final guides = <Guide>[];

  void pushGuides(_Slot? slot, bool applied) {
    if (slot == null || !applied) return;
    for (final g in slot.guides) {
      if (g.type == 'v') {
        guides.add(Guide(
          type: 'v',
          pos: g.pos,
          start: math.min(g.a.y, finalRect.y) - 10,
          end: math.max(g.a.bottom, finalRect.bottom) + 10,
        ));
      } else {
        guides.add(Guide(
          type: 'h',
          pos: g.pos,
          start: math.min(g.a.x, finalRect.x) - 10,
          end: math.max(g.a.right, finalRect.right) + 10,
        ));
      }
    }
  }

  // 被边界夹回去之后，原来的吸附就不成立了，不该再画线
  final appliedX = bestX != null && (x - bestX!.value).abs() < 0.5;
  final appliedY = bestY != null && (y - bestY!.value).abs() < 0.5;
  pushGuides(bestX, appliedX);
  pushGuides(bestY, appliedY);

  return SnapResult(
    x: x,
    y: y,
    guides: _dedupeGuides(guides),
    snappedX: appliedX,
    snappedY: appliedY,
  );
}

List<Guide> _dedupeGuides(List<Guide> guides) {
  final seen = <String, Guide>{};
  for (final g in guides) {
    final key = '${g.type}:${_jsRound(g.pos * 10)}';
    final prev = seen[key];
    if (prev != null) {
      prev.start = math.min(prev.start, g.start);
      prev.end = math.max(prev.end, g.end);
    } else {
      seen[key] = Guide(type: g.type, pos: g.pos, start: g.start, end: g.end);
    }
  }
  return seen.values.toList();
}

/// 为新卡片找一个不与现有卡片重叠的落点。
///
/// [area] 是允许落座的区域，带原点——多显示器下传某一块屏的矩形，就能把新卡片
/// 限制在那块屏上。[margin] 是与区域边缘的留白。
///
/// 从**右上角**开始逐行往左、往下扫。桌面左上通常摆着系统图标，右上一般是空的，
/// 新卡片落在那儿更不容易挡住东西。
({double x, double y}) findFreeSpot(
  PxRect size,
  List<Rect> others,
  Rect area, {
  double margin = 40,
  math.Random? random,
}) {
  const step = 28.0;
  bool overlaps(Rect r) => others.any((o) =>
      r.x < o.right && r.right > o.x && r.y < o.bottom && r.bottom > o.y);

  final minX = area.x + margin;
  final minY = area.y + margin;
  // 区域比卡片还窄时 max 会小于 min，下面的循环自然不执行，走兜底
  final maxX = area.x + area.w - margin - size.w;
  final maxY = area.y + area.h - margin - size.h;

  for (var y = minY; y <= maxY; y += step) {
    for (var x = maxX; x >= minX; x -= step) {
      final cand = Rect(x, y, size.w, size.h);
      if (!overlaps(cand)) return (x: x, y: y);
    }
  }
  // 整块区域都排满了：随机撒在右上附近，至少别叠得完全一致
  final rnd = random ?? math.Random();
  final loX = math.min(minX, maxX), hiX = math.max(minX, maxX);
  final loY = math.min(minY, maxY), hiY = math.max(minY, maxY);
  return (
    x: clamp(hiX - rnd.nextDouble() * 160, loX, hiX),
    y: clamp(loY + rnd.nextDouble() * 160, loY, hiY),
  );
}

/// 在 [monitors] 里挑第一块「还没被占」的，返回下标；全被占了返回 null。
///
/// [occupied] 传的是同一种组件已有卡片的矩形。判定用卡片**中心点**落在哪块屏：
/// 卡片可能横跨两块屏的边界，用中心点才有唯一答案，这和显示器插拔时判断卡片
/// 归属用的是同一套口径。
int? firstFreeMonitor(List<Rect> monitors, List<Rect> occupied) {
  final taken = <int>{};
  for (final o in occupied) {
    final cx = o.x + o.w / 2, cy = o.y + o.h / 2;
    for (var i = 0; i < monitors.length; i++) {
      final m = monitors[i];
      if (cx >= m.x && cx < m.right && cy >= m.y && cy < m.bottom) {
        taken.add(i);
        break;
      }
    }
  }
  for (var i = 0; i < monitors.length; i++) {
    if (!taken.contains(i)) return i;
  }
  return null;
}

/// findFreeSpot 的尺寸入参
class PxRect {
  final double w;
  final double h;
  const PxRect(this.w, this.h);
}
