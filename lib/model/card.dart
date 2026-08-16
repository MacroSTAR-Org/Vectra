/// 一张桌面磁贴的持久化模型。
///
/// 坐标用**窗口内逻辑像素**：窗口覆盖整个虚拟屏幕，所以窗口内坐标就是屏幕坐标
/// 减去虚拟屏幕原点再除以 devicePixelRatio。Electron 版存的是屏幕物理坐标，
/// 迁移时要做这层换算（见 store 的 migrate）。
///
/// 光有窗口坐标不够，还要记"家在哪块屏"：窗口原点等于虚拟屏原点，而虚拟屏原点
/// 会随着屏的增减而移动（在主屏左边接一块屏，原点就从 0 变成负的），窗口坐标
/// 于是集体指偏。见 core/monitor.dart 顶部的说明。
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
    this.monitorId,
    this.relX,
    this.relY,
    Map<String, Object?>? settings,
  }) : settings = settings ?? <String, Object?>{};

  final String id;
  final String pluginId;
  double x;
  double y;

  /// 这张卡"家"在哪块屏（显示器设备名，形如 \\.\DISPLAY1），
  /// 以及卡片中心在那块屏里的相对位置（0~1）。
  ///
  /// 放好位置（加卡、拖拽落点、改尺寸）时记一次；启动和显示器变化时按它把卡片
  /// 钉回原来那块屏的原来那个位置。null 表示老数据还没认过家，第一次启动时
  /// 会按当时的位置补上。
  String? monitorId;
  double? relX;
  double? relY;

  /// 记下这张卡现在的家。三个值要么一起有、要么一起没有，所以只留这一个入口。
  void anchorTo({required String monitorId, required double relX, required double relY}) {
    this.monitorId = monitorId;
    this.relX = relX;
    this.relY = relY;
  }

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
        // 没认过家就不写这三个键，省得老配置里凭空多出一堆 null
        if (monitorId != null) 'monitor': monitorId,
        if (relX != null) 'relX': relX,
        if (relY != null) 'relY': relY,
        'settings': settings,
      };

  static WidgetCard fromJson(Map<String, Object?> j) => WidgetCard(
        id: j['id'] as String,
        pluginId: j['pluginId'] as String,
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        size: j['size'] as String? ?? '2x2',
        z: (j['z'] as num?)?.toInt() ?? 0,
        monitorId: j['monitor'] as String?,
        relX: (j['relX'] as num?)?.toDouble(),
        relY: (j['relY'] as num?)?.toDouble(),
        settings: (j['settings'] as Map?)?.cast<String, Object?>(),
      );
}
