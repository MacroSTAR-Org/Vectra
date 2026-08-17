/// 无边框窗口自绘的那圈"边框件"：缩放手柄和窗口按钮。
///
/// 设置窗口和插件市场都是同一种无边框窗口（见 windows/runner/view_window.h），
/// 缩放的做法也完全一样，所以这套东西放在这里共用。标题栏本身不在这里——
/// 那部分各窗口差别很大（设置窗口是图标+标题，市场还要塞搜索框），共用反而绑手。
library;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../native/native_bridge.dart';

/// Win32 的窗口命中码，缩放时原样传给 native。
///
/// 数值来自 winuser.h，不能改：native 侧直接把它塞进
/// WM_NCLBUTTONDOWN 的 wParam 交给系统。
class WindowEdge {
  static const int left = 10; // HTLEFT
  static const int right = 11; // HTRIGHT
  static const int top = 12; // HTTOP
  static const int topLeft = 13; // HTTOPLEFT
  static const int topRight = 14; // HTTOPRIGHT
  static const int bottom = 15; // HTBOTTOM
  static const int bottomLeft = 16; // HTBOTTOMLEFT
  static const int bottomRight = 17; // HTBOTTOMRIGHT
}

/// 窗口四周的缩放手柄，铺在最外层的 Stack 里。
///
/// 这类窗口是无边框的，没有系统缩放边缘可用（缘由见 view_window.cpp 里
/// ResizeFrom 的注释），只能自己在边上铺一圈透明区域，按下时喊 native
/// 交给系统去拖。
///
/// 边宽 6px、角落 12x12：太窄了不好抓，太宽会盖住边上的控件。角落必须
/// 压在边之后（Stack 里靠后者在上），否则拐角处只能单向缩放。
List<Widget> resizeHandles(NativeWindow window) {
  const t = 6.0; // 边的厚度
  const c = 12.0; // 角的边长

  Widget h({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required int edge,
    required MouseCursor cursor,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: Listener(
          // behavior 必须是 opaque：手柄是透明的，不这样按不到
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (e.kind != PointerDeviceKind.mouse) return;
            if ((e.buttons & kPrimaryButton) == 0) return;
            Log.d(window.key, '缩放手柄按下 edge=$edge');
            window.resizeFrom(edge);
          },
        ),
      ),
    );
  }

  return [
    // 四条边
    h(left: c, right: c, top: 0, height: t,
        edge: WindowEdge.top, cursor: SystemMouseCursors.resizeUpDown),
    h(left: c, right: c, bottom: 0, height: t,
        edge: WindowEdge.bottom, cursor: SystemMouseCursors.resizeUpDown),
    h(top: c, bottom: c, left: 0, width: t,
        edge: WindowEdge.left, cursor: SystemMouseCursors.resizeLeftRight),
    h(top: c, bottom: c, right: 0, width: t,
        edge: WindowEdge.right, cursor: SystemMouseCursors.resizeLeftRight),
    // 四个角压在边上面
    h(left: 0, top: 0, width: c, height: c,
        edge: WindowEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight),
    h(right: 0, top: 0, width: c, height: c,
        edge: WindowEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft),
    h(left: 0, bottom: 0, width: c, height: c,
        edge: WindowEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft),
    h(right: 0, bottom: 0, width: c, height: c,
        edge: WindowEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight),
  ];
}

/// 标题栏空白处按下就拖窗口。只认鼠标左键——触屏拖标题栏会和滚动打架。
void beginWindowDrag(NativeWindow window, PointerDownEvent e) {
  if (e.kind == PointerDeviceKind.mouse && (e.buttons & kPrimaryButton) != 0) {
    window.dragMove();
  }
}

/// 右上角那三个窗口按钮（最小化 / 最大化 / 关闭）。
///
/// 样式是从设置窗口原样搬过来的：两个窗口的按钮必须长得一样，各画各的迟早
/// 会走形。悬停底色跟着深浅色翻转，关闭键悬停时偏红。
class WindowButton extends StatefulWidget {
  const WindowButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.light,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// 深浅色决定图标和悬停底色
  final bool light;

  /// 关闭按钮：悬停用红色强调
  final bool danger;

  @override
  State<WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _hover
                  ? (widget.danger
                      ? const Color(0x33FF6B6B)
                      : widget.light
                          ? const Color(0x1F000000)
                          : const Color(0x1FFFFFFF))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: widget.danger
                  ? (widget.light ? const Color(0xFFB3261E) : Colors.white)
                  : widget.light
                      ? const Color(0x9916181C)
                      : const Color(0x99FFFFFF),
            ),
          ),
        ),
      ),
    );
  }
}
