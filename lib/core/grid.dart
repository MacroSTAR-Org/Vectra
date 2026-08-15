/// 网格尺寸系统 —— 组件尺寸不是无级拖拽，而是像手机小组件一样只能取
/// "列×行" 的离散规格（2x2 / 4x2 / 3x3 …）。
///
/// 像素换算：w = cols*cell + (cols-1)*gap，行同理。
/// cell / gap 是全局设置，改一次所有组件等比缩放。
///
/// 本文件从 Electron 版 src/shared/grid.mjs 1:1 移植，行为必须完全一致，
/// 对应单测同样照搬（test/grid_test.dart）。
library;

const int kDefaultCell = 112;
const int kDefaultGap = 12;
const int kMaxUnits = 8;

final RegExp _sizeRe = RegExp(r'^(\d+)x(\d+)$', caseSensitive: false);

/// 列×行
class GridSize {
  final int cols;
  final int rows;
  const GridSize(this.cols, this.rows);

  @override
  String toString() => '${cols}x$rows';

  @override
  bool operator ==(Object other) =>
      other is GridSize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);
}

/// 像素尺寸
class PxSize {
  final double w;
  final double h;
  const PxSize(this.w, this.h);

  @override
  String toString() => 'PxSize(${w.toStringAsFixed(1)}, ${h.toStringAsFixed(1)})';

  @override
  bool operator ==(Object other) => other is PxSize && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(w, h);
}

/// 列行的小数格数（拖拽时用来判断目标规格）
class UnitSize {
  final double cols;
  final double rows;
  const UnitSize(this.cols, this.rows);
}

/// "3x2" -> GridSize(3, 2)，非法返回 null
GridSize? parseSize(Object? str) {
  final m = _sizeRe.firstMatch((str?.toString() ?? '').trim());
  if (m == null) return null;
  final cols = int.parse(m.group(1)!);
  final rows = int.parse(m.group(2)!);
  if (!(cols >= 1 && cols <= kMaxUnits && rows >= 1 && rows <= kMaxUnits)) {
    return null;
  }
  return GridSize(cols, rows);
}

String formatSize(int cols, int rows) => '${cols}x$rows';

/// 规格 -> 像素
PxSize sizeToPx(Object? size, [int cell = kDefaultCell, int gap = kDefaultGap]) {
  final s = size is GridSize ? size : parseSize(size);
  if (s == null) return PxSize(cell.toDouble(), cell.toDouble());
  return PxSize(
    (s.cols * cell + (s.cols - 1) * gap).toDouble(),
    (s.rows * cell + (s.rows - 1) * gap).toDouble(),
  );
}

/// 像素 -> 最接近的（可能是小数的）格数
UnitSize pxToUnits(PxSize px, [int cell = kDefaultCell, int gap = kDefaultGap]) {
  final unit = cell + gap;
  return UnitSize((px.w + gap) / unit, (px.h + gap) / unit);
}

/// 在插件声明的可选规格里，挑出与目标像素最接近的一个。
/// [allowed] 形如 ["2x2","4x2"]；为空时回退 "2x2"。
String nearestSize(
  PxSize px,
  List<String>? allowed, [
  int cell = kDefaultCell,
  int gap = kDefaultGap,
]) {
  final list = normalizeSizes(allowed);
  if (list.isEmpty) return '2x2';
  final target = pxToUnits(px, cell, gap);

  // list 已按面积升序。用严格小于比较 => 距离并列时保留更小的规格，
  // 这样拖拽到两个规格正中间时组件不会突然变大、溢出屏幕。
  var best = list[0];
  var bestCost = double.infinity;
  for (final s in list) {
    final p = parseSize(s)!;
    // 列和行分开算欧氏距离，避免"宽扁"被"高瘦"抢走
    final dc = p.cols - target.cols;
    final dr = p.rows - target.rows;
    final cost = dc * dc + dr * dr;
    if (cost < bestCost) {
      bestCost = cost;
      best = s;
    }
  }
  return best;
}

/// 过滤掉非法项，并按面积排序（小 -> 大），保证 UI 里顺序稳定
List<String> normalizeSizes(List<String>? allowed) {
  final seen = <String>{};
  final out = <String>[];
  for (final item in allowed ?? const <String>[]) {
    final p = parseSize(item);
    if (p == null) continue;
    final key = formatSize(p.cols, p.rows);
    if (seen.contains(key)) continue;
    seen.add(key);
    out.add(key);
  }
  out.sort((a, b) {
    final pa = parseSize(a)!;
    final pb = parseSize(b)!;
    final byArea = (pa.cols * pa.rows) - (pb.cols * pb.rows);
    return byArea != 0 ? byArea : pa.cols - pb.cols;
  });
  return out;
}

/// 保证 size 落在 allowed 内；不在则取最接近的
String coerceSize(
  Object? size,
  List<String>? allowed, [
  int cell = kDefaultCell,
  int gap = kDefaultGap,
]) {
  final list = normalizeSizes(allowed);
  if (list.isEmpty) return '2x2';
  final p = parseSize(size);
  if (p != null && list.contains(formatSize(p.cols, p.rows))) {
    return formatSize(p.cols, p.rows);
  }
  if (p != null) return nearestSize(sizeToPx(p, cell, gap), list, cell, gap);
  return list[0];
}

/// 兼容旧布局：把存下来的像素尺寸迁移成规格
String migratePxToSize(
  double w,
  double h,
  List<String>? allowed, [
  int cell = kDefaultCell,
  int gap = kDefaultGap,
]) {
  if (!w.isFinite || !h.isFinite) {
    final list = normalizeSizes(allowed);
    return list.isNotEmpty ? list[0] : '2x2';
  }
  return nearestSize(PxSize(w, h), allowed, cell, gap);
}
