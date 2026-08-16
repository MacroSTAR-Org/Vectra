/// 多显示器的坐标换算。
///
/// 这里只有纯函数，没有任何 IO —— 多显示器的问题几乎没法靠手点复现
/// （得真去插拔屏、改排列、改缩放），所以规则必须能单独测。
///
/// 三套坐标要分清楚：
///   - **显示器矩形**：虚拟屏物理像素，原点是虚拟屏左上角，可能为负
///     （副屏摆在主屏左边/上面时）。native 的 EnumDisplayMonitors 给的就是这个。
///   - **窗口坐标**：磁贴窗口覆盖整个虚拟屏，卡片的 x/y 是相对窗口左上角的
///     **逻辑**像素（除过 devicePixelRatio）。
///   - **屏内相对位置**：卡片中心落在某块屏里的百分比 0~1。卡片"记住自己在
///     哪块屏的哪个位置"靠的就是它。
///
/// 为什么要有"屏内相对位置"这一层：卡片存的是窗口坐标，而窗口原点就是**虚拟屏
/// 原点**——它会动。在主屏左边接一块 1920 宽的屏，虚拟屏原点从 0 变成 -1920，
/// 于是所有存下来的窗口坐标一夜之间都指向了左边 1920 像素的地方，桌面上看到的
/// 就是"卡片整体错位"。显示器矩形本身不会因此改变（主屏还在 0,0），所以把卡片
/// 锚在**屏**上而不是锚在窗口原点上，才是稳的。
library;

/// 一块显示器：设备名 + 虚拟屏物理像素矩形。
typedef MonitorRect = ({String id, int x, int y, int w, int h});

/// 包含点 (x, y) 的那块屏；点不在任何屏上（比如落在屏与屏之间的空隙）返回 null。
MonitorRect? monitorAt(List<MonitorRect> monitors, double x, double y) {
  for (final m in monitors) {
    if (x >= m.x && x < m.x + m.w && y >= m.y && y < m.y + m.h) return m;
  }
  return null;
}

/// 按设备名找屏。id 为 null（老数据没记过家）或那块屏已经被拔掉时返回 null。
MonitorRect? monitorById(List<MonitorRect> monitors, String? id) {
  if (id == null) return null;
  for (final m in monitors) {
    if (m.id == id) return m;
  }
  return null;
}

/// 离点 (cx, cy) 最近的屏，按屏中心的距离算。用于"卡片原来那块屏被拔了，
/// 往哪搬"。显示器列表为空时返回 null。
MonitorRect? nearestMonitor(
    List<MonitorRect> monitors, double cx, double cy) {
  MonitorRect? best;
  var bestD = double.infinity;
  for (final m in monitors) {
    final mcx = m.x + m.w / 2.0;
    final mcy = m.y + m.h / 2.0;
    final d = (mcx - cx) * (mcx - cx) + (mcy - cy) * (mcy - cy);
    if (d < bestD) {
      bestD = d;
      best = m;
    }
  }
  return best;
}

/// 卡片中心在虚拟屏里的物理坐标。
///
/// [windowOrigin] 是磁贴窗口在虚拟屏里的原点（物理像素），[topLeft] 是卡片
/// 在窗口内的逻辑坐标，[cardSize] 是卡片逻辑尺寸。
double physicalCenter(
        double windowOrigin, double topLeft, double cardSize, double dpr) =>
    windowOrigin + (topLeft + cardSize / 2) * dpr;

/// 由"家"（屏 + 屏内相对位置）反算卡片左上角应该在的窗口逻辑坐标。
///
/// 与 [physicalCenter] 互为逆运算：屏没动过时算回来的就是原值。
double anchoredTopLeft({
  required double monitorOrigin,
  required double monitorSize,
  required double rel,
  required double windowOrigin,
  required double dpr,
  required double cardSize,
}) =>
    (monitorOrigin + rel * monitorSize - windowOrigin) / dpr - cardSize / 2;

/// 卡片中心所在的屏，以及它在那块屏里的相对位置——也就是要存进卡片的那份"家"。
/// 中心不在任何屏上时返回 null（这种卡片交给夹回可视区那步处理）。
({String id, double relX, double relY})? homeOf(
    List<MonitorRect> monitors, double physCX, double physCY) {
  final m = monitorAt(monitors, physCX, physCY);
  if (m == null) return null;
  return (
    id: m.id,
    relX: (physCX - m.x) / m.w,
    relY: (physCY - m.y) / m.h,
  );
}

/// 判定"卡片当前位置和它记录的家还对不对得上"的容差（逻辑像素）。
///
/// 不能用 == 比：相对位置是除出来的小数，再乘回去有浮点误差（约 1e-10 像素）。
/// 用 == 的话每次启动都会判定成"要重摆"，于是每次启动都存一次盘、日志里天天
/// 有一行"卡片已重摆"——真出问题时反而看不出来。
const double kAnchorEpsilon = 0.5;
