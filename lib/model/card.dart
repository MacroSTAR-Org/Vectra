/// 一张桌面磁贴的持久化模型。
///
/// 坐标用**窗口内逻辑像素**：窗口覆盖整个虚拟屏幕，所以窗口内坐标就是屏幕坐标
/// 减去虚拟屏幕原点再除以 devicePixelRatio。Electron 版存的是屏幕物理坐标，
/// 迁移时要做这层换算（见 store 的 migrate）。
library;

import '../core/grid.dart';

class WidgetCard {
  WidgetCard({
    required this.id,
    required this.pluginId,
    required this.x,
    required this.y,
    required this.size,
    required this.z,
    Map<String, Object?>? settings,
  }) : settings = settings ?? <String, Object?>{};

  final String id;
  final String pluginId;
  double x;
  double y;

  /// 离散规格，形如 "3x2"
  String size;

  /// 层叠顺序，越大越靠上
  int z;

  /// 该实例的插件设置
  final Map<String, Object?> settings;

  PxSize pxSize(int cell, int gap) => sizeToPx(size, cell, gap);

  Map<String, Object?> toJson() => {
        'id': id,
        'pluginId': pluginId,
        'x': x,
        'y': y,
        'size': size,
        'z': z,
        'settings': settings,
      };

  static WidgetCard fromJson(Map<String, Object?> j) => WidgetCard(
        id: j['id'] as String,
        pluginId: j['pluginId'] as String,
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        size: j['size'] as String? ?? '2x2',
        z: (j['z'] as num?)?.toInt() ?? 0,
        settings: (j['settings'] as Map?)?.cast<String, Object?>(),
      );
}
