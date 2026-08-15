/// 吸附辅助线。
///
/// 注意一个约束：辅助线画在卡片**之外**的空白处，而窗口区域被裁成了卡片矩形的
/// 并集 —— 直接画会被裁掉，什么都看不见。
///
/// 解决办法：拖拽期间整个窗口区域都放开（见 NativeBridge.setDragging），
/// 辅助线自然可见，不需要为它单独准备区域矩形。
library;

import 'package:flutter/material.dart';

import '../core/snap.dart';


/// 辅助线的粗细（逻辑像素）
const double kGuideThickness = 2;

class GuidesLayer extends StatelessWidget {
  const GuidesLayer({super.key, required this.guides});

  final List<Guide> guides;

  @override
  Widget build(BuildContext context) {
    if (guides.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Stack(
        children: [
          for (final g in guides)
            if (g.type == 'v')
              Positioned(
                left: g.pos - kGuideThickness / 2,
                top: g.start,
                width: kGuideThickness,
                height: g.end - g.start,
                child: const ColoredBox(color: Color(0xE696E6FF)),
              )
            else
              Positioned(
                left: g.start,
                top: g.pos - kGuideThickness / 2,
                width: g.end - g.start,
                height: kGuideThickness,
                child: const ColoredBox(color: Color(0xE696E6FF)),
              ),
        ],
      ),
    );
  }
}
