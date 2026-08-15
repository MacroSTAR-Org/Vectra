/// AI 侧边栏的收起态：屏幕右下角那个小方块。
///
/// 它不是一个独立窗口，就是侧边栏那个窗口缩小以后的样子。这样做的原因：
///   - 投放点必须常驻置顶。放在磁贴窗口上不行，磁贴常驻 Z 序最底，
///     右下角一旦被别的窗口盖住就完全够不到（实测被 Chrome 盖住）。
///   - 又不想为它单开第三个 Flutter 引擎。侧边栏窗口本来就是置顶的，
///     收起时缩成小方块正好当投放点，一个引擎办两件事。
///
/// 于是"拖文件到投放点"和"拖文件到展开的侧边栏"在 native 那边是同一条路：
/// 同一个窗口、同一个 IDropTarget。
library;

import 'package:flutter/material.dart';

import '../model/ai_settings.dart';

/// 投放点边长（逻辑像素）。sidebar_window.cpp 里有一份同样的常量，
/// 两边必须一致，否则窗口区域裁在一处、图画在另一处。
const double kDropDockSize = 56;

/// 距侧边栏窗口右边 / 下边的内缩。窗口本身已经离工作区底边 10，
/// 所以下边只再缩 4，才和右边的 14 一起落在工作区角上。
const double kDropDockRightInset = 14;
const double kDropDockBottomInset = 4;

const double kDropDockRadius = 18;

class DropDock extends StatefulWidget {
  const DropDock({
    super.key,
    required this.settings,
    required this.light,
    required this.dropHover,
    required this.onTap,
  });

  final AiSettings settings;

  /// 生效明暗（外层算好传入），决定小方块的底色与图标颜色
  final bool light;

  /// 是否正被拖着的文件悬停（native 从 IDropTarget.DragOver 推过来）
  final bool dropHover;
  final VoidCallback onTap;

  @override
  State<DropDock> createState() => _DropDockState();
}

class _DropDockState extends State<DropDock> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // 平时压得很淡，鼠标靠近或者拖着文件过来才亮起来。
    // 它是常驻置顶的，太显眼会一直碍眼。
    final active = _hover || widget.dropHover;
    final shape = BorderRadius.circular(kDropDockRadius);
    const d = Duration(milliseconds: 200);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          opacity: active ? 1.0 : 0.35,
          duration: d,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: d,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: shape,
              color: widget.dropHover
                  ? (widget.light
                      ? const Color(0x591565C0)
                      : const Color(0xFF7CC7FF).withValues(alpha: 0.35))
                  : (widget.light
                      ? const Color(0xFFF3F3F6)
                      : const Color(0xFF17171B))
                      .withValues(
                          alpha: widget.settings.glass
                              ? widget.settings.tint.clamp(0.35, 1.0)
                              : 1.0),
              border: Border.all(
                color: widget.dropHover
                    ? (widget.light
                        ? const Color(0xFF1565C0)
                        : const Color(0xFF7CC7FF))
                    : (widget.light
                        ? const Color(0x33000000)
                        : const Color(0x33FFFFFF)),
                width: widget.dropHover ? 1.6 : 1,
              ),
            ),
            child: Center(
              // 拖到跟前时图标弹一下：easeOutBack 会轻微过冲再回落，
              // 比线性放大更容易被余光注意到
              child: AnimatedScale(
                scale: widget.dropHover ? 1.25 : 1,
                duration: d,
                curve: Curves.easeOutBack,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: Icon(
                    widget.dropHover
                        ? Icons.file_download_outlined
                        : Icons.auto_awesome,
                    key: ValueKey(widget.dropHover),
                    size: 20,
                    color: widget.dropHover
                        ? Colors.white
                        : (widget.light
                            ? const Color(0xCC16181C)
                            : const Color(0xCCFFFFFF)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
