/// 指针命中判定（纯逻辑，可单测）
///
/// Electron 版里这个模块最终变成了死代码——那一版每个组件一个窗口，窗口尺寸
/// 收缩到与组件本体一致之后，由操作系统自己做命中判定就够了。
///
/// 到了 Flutter 单窗口架构，它重新变成核心：整个应用只有一个覆盖全屏的窗口，
/// 必须由 WM_NCHITTEST 回答"这一点该归我，还是该穿透到桌面"。答案就是本文件。
library;

/// 点是否落在圆角矩形内
bool insideRoundedRect(double px, double py, HitRect rect, {double radius = 26}) {
  final lx = px - rect.x;
  final ly = py - rect.y;
  if (lx < 0 || ly < 0 || lx > rect.w || ly > rect.h) return false;
  final r = [radius, rect.w / 2, rect.h / 2].reduce((a, b) => a < b ? a : b);
  final dx = [r - lx, 0.0, lx - (rect.w - r)].reduce((a, b) => a > b ? a : b);
  final dy = [r - ly, 0.0, ly - (rect.h - r)].reduce((a, b) => a > b ? a : b);
  return dx * dx + dy * dy <= r * r + 1;
}

/// 找出指针下方最上层的组件，返回其 id；没有命中返回 null。
String? topmostAt(double px, double py, List<HitRect> items, {double radius = 26}) {
  String? hit;
  var bestZ = double.negativeInfinity;
  for (final it in items) {
    if (!insideRoundedRect(px, py, it, radius: radius)) continue;
    final z = it.z.isFinite ? it.z : 0.0;
    // >= 而非 >：同 z 时后来者优先，与 JS 版一致
    if (z >= bestZ) {
      bestZ = z;
      hit = it.id;
    }
  }
  return hit;
}

class HitRect {
  final String id;
  final double x;
  final double y;
  final double w;
  final double h;
  final double z;

  /// 自定义圆角半径。为 null 时用调用方给的统一值。
  /// AI 侧边栏和磁贴的圆角是分开配置的，所以需要按矩形区分。
  final double? radius;

  const HitRect({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.z = 0,
    this.radius,
  });
}
