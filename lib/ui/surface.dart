/// 桌面层：所有磁贴都画在这一个全屏透明窗口里。
///
/// 与 Electron 版最大的结构差异：那边一个磁贴一个窗口，拖拽要跨进程同步，
/// 于是有心跳、看门狗、指针捕获丢失的一堆补丁。这里全在同一个窗口内，
/// 指针事件不会跨窗口丢失，那套补丁整体不需要。
///
/// 但保留两条兜底，它们防的是真实存在的情况：
///   - 指针键位为 0 却没收到 up（在别的窗口上松手）-> 立即结束拖拽
///   - pointerCancel（被系统抢走，例如触摸手势升级）-> 立即结束拖拽
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryButton, kSecondaryButton;
import 'package:flutter/material.dart';

import '../core/grid.dart';
import '../core/hit.dart';
import '../core/logger.dart';
import '../core/snap.dart' as snap;
import '../model/card.dart';
import '../model/settings.dart';
import '../native/native_bridge.dart';
import '../plugin/node.dart' show PluginPointer;
import '../store/store.dart';
import 'card_view.dart';
import 'guides.dart';

/// 触摸长按进入编辑模式的时长
const Duration kLongPress = Duration(milliseconds: 500);

/// 长按期间允许的最大位移，超过就判定为滑动，交给插件
const double kLongPressSlop = 10;

/// 编辑模式无操作后自动退出
const Duration kEditIdle = Duration(seconds: 8);

class DesktopSurface extends StatefulWidget {
  const DesktopSurface({
    super.key,
    required this.state,
    required this.store,
    required this.buildPluginBody,
    this.onCardSecondaryTap,
    this.onCardAnchor,
  });

  final AppState state;
  final Store store;

  /// 插件内容由外部注入（QuickJS 运行时）
  final Widget Function(WidgetCard card, Size size) buildPluginBody;

  /// 右键卡片：打开控制面板并定位到这张卡片
  final void Function(WidgetCard card)? onCardSecondaryTap;

  /// 卡片落位之后记一次"它现在在哪块屏的哪个位置"。
  ///
  /// 由外层实现：显示器矩形和窗口矩形都在 app_root 那边缓存着，
  /// 这里再问一遍 native 只是重复。落点不记的话，下次接屏/拔屏时这张卡
  /// 会按**上一个**落点被钉回去。
  final void Function(WidgetCard card)? onCardAnchor;

  // 这里原先有个 extraHit：当年 AI 侧边栏和磁贴共用一个窗口时，
  // 用它把侧边栏矩形并进窗口区域。侧边栏拆成独立窗口之后就没人再传了，
  // 一直是死代码，已删除。

  @override
  State<DesktopSurface> createState() => DesktopSurfaceState();
}

class DesktopSurfaceState extends State<DesktopSurface> {
  AppSettings get _settings => widget.state.settings;
  List<WidgetCard> get _cards => widget.state.cards;

  // 拖拽会话
  int? _dragPointer;
  WidgetCard? _dragCard;
  Offset _grabOffset = Offset.zero;
  bool _moved = false;
  List<snap.Guide> _guides = const [];

  // 触摸编辑模式
  String? _editingId;
  Offset? _touchStart;

  // 用可取消的 Timer 而不是 Future.delayed：后者撤不掉，widget 销毁后仍会触发，
  // 既是资源泄漏，也会让 widget 测试因"仍有未完成的 Timer"整体失败。
  Timer? _longPressTimer;
  Timer? _editIdleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clampIntoScreen();
      _pushRegion();
    });
  }

  /// 把跑到屏幕外的卡片拉回来。
  ///
  /// 卡片整个落到可视区之外就再也够不着了：看不见，也就点不到、拖不动。
  /// 换分辨率、调大网格单元、插拔显示器都可能造成这种情况。
  void _clampIntoScreen() {
    final bounds = MediaQuery.of(context).size;
    var changed = false;
    for (final c in _cards) {
      final size = _px(c);
      final nx = snap.clamp(c.x, 0, math.max(0.0, bounds.width - size.w));
      final ny = snap.clamp(c.y, 0, math.max(0.0, bounds.height - size.h));
      if (nx != c.x || ny != c.y) {
        c.x = nx;
        c.y = ny;
        changed = true;
      }
    }
    if (changed) {
      Log.i('surface', '有卡片超出可视区，已拉回');
      widget.store.save(widget.state);
      setState(() {});
    }
  }

  @override
  @override
  void dispose() {
    _longPressTimer?.cancel();
    _editIdleTimer?.cancel();
    super.dispose();
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  double get _dpr => MediaQuery.of(context).devicePixelRatio;

  PxSize _px(WidgetCard c) => c.pxSize(_settings.gridCell, _settings.gridGap);

  /// 把卡片矩形推给 native。对外公开，供外层在需要时确定性地重推一次。
  void pushRegion() => _pushRegion();

  /// 上一次推给 native 的几何签名，用来判断"这一帧卡片的形状到底变没变"。
  String? _lastRegionSig;

  /// 会影响窗口区域的所有量：每张卡片的位置和尺寸，加上圆角与缩放。
  /// 这些里面任何一个变了，native 那边的裁剪就过期了。
  String _regionSig() {
    final b = StringBuffer()
      ..write(_settings.cardRadius)
      ..write('@')
      ..write(_dpr);
    for (final c in _cards) {
      final s = _px(c);
      b
        ..write('|')
        ..write(c.id)
        ..write(',')
        ..write(c.x)
        ..write(',')
        ..write(c.y)
        ..write(',')
        ..write(s.w)
        ..write(',')
        ..write(s.h);
    }
    return b.toString();
  }

  /// 每帧落定后自检一次：卡片几何变了就把新区域推给 native。
  ///
  /// 做成"自动对账"而不是让每个调用方各自记得推，是因为漏推的代价既隐蔽又严重：
  /// 窗口被 SetWindowRgn 硬裁成卡片矩形的并集，区域之外既不绘制也不接收输入。
  /// 区域一旦过期，新加的卡片画了也会被裁掉——看不见，也点不到；而桌面上一张
  /// 卡片都没有的时候，连"拖一下别的卡片顺带把区域刷新掉"这条退路都没有，
  /// 只能重启。
  ///
  /// 这不是假想的风险：加卡、删卡、插件请求改尺寸、面板里改网格/圆角，
  /// 四条路径全都漏推过（见本次提交）。与其在每条路径末尾各加一行、
  /// 且指望以后每个新路径都记得加，不如让 surface 自己盯着几何对账。
  void _syncRegion() {
    if (!mounted) return;
    // 拖拽期间 native 那边是整窗放开的（见 _onPointerMove 与 _endDrag 的注释），
    // 这时推区域等于把卡片重新裁回去，会拖到一半"卡"住。松手时 _endDrag 补推。
    if (_dragCard != null) return;
    if (_regionSig() == _lastRegionSig) return;
    _pushRegion();
  }

  void _pushRegion() {
    final cards = <HitRect>[
      for (final c in _cards)
        HitRect(
          id: c.id,
          x: c.x,
          y: c.y,
          w: _px(c).w,
          h: _px(c).h,
          z: c.z.toDouble(),
        ),
    ];
    // 显式推送也要记账，否则自动对账会以为区域还是旧的，白推一次
    _lastRegionSig = _regionSig();
    NativeBridge.setRegion(
      cards: cards,
      // 辅助线只在拖拽时出现，而拖拽期间区域整窗放开，无需为它加矩形
      extra: const [],
      radius: _settings.cardRadius,
      devicePixelRatio: _dpr,
    );
  }

  /// 命中：返回指针下最上层的卡片
  WidgetCard? _cardAt(Offset p) {
    final rects = [
      for (final c in _cards)
        HitRect(
            id: c.id,
            x: c.x,
            y: c.y,
            w: _px(c).w,
            h: _px(c).h,
            z: c.z.toDouble()),
    ];
    final id = topmostAt(p.dx, p.dy, rects, radius: _settings.cardRadius);
    if (id == null) return null;
    return _cards.firstWhere((c) => c.id == id);
  }

  void _raise(WidgetCard card) {
    final maxZ = _cards.fold<int>(0, (m, c) => c.z > m ? c.z : m);
    if (card.z != maxZ) card.z = maxZ + 1;
  }

  // ---------------- 指针 ----------------

  void _onPointerDown(PointerDownEvent e) {
    // 插件里的滑条之类控件已经接管了这次指针，就不要再拖卡片。
    // 指针事件是从最内层往外派发的，所以这里读到的一定是插件刚置的位。
    // 少了这一条，拖进度条会把整张卡片一起拖走。
    if (PluginPointer.isGrabbed(e.pointer)) return;

    final card = _cardAt(e.localPosition);
    if (card == null) return;

    final isTouch = e.kind == PointerDeviceKind.touch ||
        e.kind == PointerDeviceKind.stylus;

    // 右键卡片 = 打开这张卡片的设置
    if (!isTouch && (e.buttons & kSecondaryButton) != 0) {
      widget.onCardSecondaryTap?.call(card);
      return;
    }

    // 只有左键能拖。漏掉这条判断的后果是实打实的：右键菜单、中键等任何按键
    // 都会启动一次拖拽，卡片被悄悄挪走。（实测右键点在卡片上就把布局搞乱了）
    if (!isTouch && (e.buttons & kPrimaryButton) == 0) return;

    setState(() => _raise(card));

    if (_settings.locked) return;

    if (isTouch) {
      // 手机桌面的语义：轻点交给插件，长按才进编辑模式，编辑模式下直接拖
      if (_editingId == card.id) {
        _beginDrag(e, card);
        return;
      }
      _touchStart = e.position;
      _cancelLongPress();
      _longPressTimer = Timer(kLongPress, () {
        _longPressTimer = null;
        if (!mounted) return;
        setState(() => _editingId = card.id);
        _scheduleEditIdle();
      });
      return;
    }

    _beginDrag(e, card);
  }

  void _beginDrag(PointerEvent e, WidgetCard card) {
    // 拖拽期间不再改窗口区域：每帧 SetWindowRgn 会与绘制打架，拖出残影
    NativeBridge.setDragging(true);
    _dragPointer = e.pointer;
    _dragCard = card;
    _grabOffset = e.localPosition - Offset(card.x, card.y);
    _moved = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    // 长按未触发时，移动超过阈值就当作滑动，取消长按
    if (_longPressTimer != null && _touchStart != null) {
      if ((e.position - _touchStart!).distance > kLongPressSlop) {
        _cancelLongPress();
      }
    }

    if (_dragPointer != e.pointer || _dragCard == null) return;

    // 已经松手却没收到 up（在别的窗口上松开）——立刻收尾，否则卡片粘在指针上
    if (e.buttons == 0 && e.kind == PointerDeviceKind.mouse) {
      _endDrag();
      return;
    }

    final card = _dragCard!;
    final size = _px(card);
    final target = e.localPosition - _grabOffset;

    final others = <snap.Rect>[
      for (final c in _cards)
        if (c.id != card.id) snap.Rect(c.x, c.y, _px(c).w, _px(c).h),
    ];

    final bounds = MediaQuery.of(context).size;
    late final snap.SnapResult r;
    if (_settings.snapEnabled) {
      r = snap.resolve(
        snap.Rect(target.dx, target.dy, size.w, size.h),
        others,
        threshold: _settings.snapThreshold,
        gutter: _settings.gridGap.toDouble(),
        bounds: (w: bounds.width, h: bounds.height),
      );
    } else {
      r = snap.SnapResult(
        x: snap.clamp(target.dx, 0, bounds.width - size.w),
        y: snap.clamp(target.dy, 0, bounds.height - size.h),
        guides: const [],
        snappedX: false,
        snappedY: false,
      );
    }

    setState(() {
      card.x = r.x;
      card.y = r.y;
      _guides = r.guides;
      _moved = true;
    });
    // 这里刻意不调 _pushRegion()：区域已整窗放开，拖拽结束时再恢复
  }

  void _onPointerUp(PointerEvent e) {
    _cancelLongPress();
    if (_dragPointer == e.pointer) _endDrag();
  }

  void _endDrag() {
    final moved = _moved;
    final card = _dragCard;
    _dragPointer = null;
    _dragCard = null;
    _moved = false;
    setState(() => _guides = const []);
    // 先关拖拽模式，再推区域，否则 native 会因为仍在拖拽而跳过这次裁剪
    NativeBridge.setDragging(false).then((_) => _pushRegion());
    if (moved && card != null) {
      // 先认家再存盘：存下去的必须是"落点 + 落点所在的屏"这一对，
      // 只存坐标的话，下次布局一变就没法把它放回用户放的地方
      widget.onCardAnchor?.call(card);
    }
    if (moved) widget.store.save(widget.state);
    // 只记落点，不记过程：拖动中每帧都记的话，一次拖拽就能刷几百行，
    // 真正有用的信息反而被冲掉了。
    if (moved && card != null) {
      Log.i('surface',
          '拖动 ${card.pluginId}(${card.id}) 落到 ${card.x.round()},${card.y.round()}');
    }
    if (_editingId != null) _scheduleEditIdle();
  }

  void _scheduleEditIdle() {
    _editIdleTimer?.cancel();
    _editIdleTimer = Timer(kEditIdle, () {
      _editIdleTimer = null;
      if (!mounted) return;
      setState(() => _editingId = null);
    });
  }

  /// 拖拽中的卡片不能有位置动画：动画会让它落后于指针。
  /// 其它卡片、以及松手之后，都用缓动过渡。
  Duration _animDuration(WidgetCard card) {
    if (!_settings.animations) return Duration.zero;
    if (_dragCard?.id == card.id) return Duration.zero;
    return const Duration(milliseconds: 260);
  }

  @override
  Widget build(BuildContext context) {
    // 卡片几何可能刚被外层改过（加卡/删卡/改尺寸/面板里改网格），
    // 等这一帧落定之后跟 native 对一次账。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRegion());
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      // Stack 里全是 Positioned 子节点时，自身会塌缩成约束允许的最小尺寸，
      // 外层 Listener 也就没有命中面积，指针事件永远进不来。必须撑满。
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final card in _sortedByZ())
            AnimatedPositioned(
              // key 必须按卡片身份给。子节点是按 z 排序的，按下任意一张卡片都会
              // 改变 z、从而改变列表顺序；没有 key 时 Flutter 按下标复用 element，
              // 同一个 AnimatedPositioned 会被换给另一张卡片，于是它从旧卡片的
              // 位置动画到新卡片的位置 —— 表现为按下去的瞬间"抽一下"。
              key: ValueKey(card.id),
              // 正在拖的那张必须零时长：动画会让它落后于指针，手感立刻就散了。
              // 其余情况（吸附回正、改尺寸、被拉回可视区、面板里改网格）走缓动。
              duration: _animDuration(card),
              curve: Curves.easeOutCubic,
              left: card.x,
              top: card.y,
              // RepaintBoundary：拖一张卡片时其余卡片的图层可以直接复用，
              // 不必跟着整屏重绘。没有它，2560x1440 下每帧都要重画所有卡片，
              // 掉帧就表现为拖影。
              child: RepaintBoundary(
                child: AnimatedSize(
                  duration: _settings.animations
                      ? const Duration(milliseconds: 280)
                      : Duration.zero,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: CardView(
                    card: card,
                    settings: _settings,
                    width: _px(card).w,
                    height: _px(card).h,
                    editing: _editingId == card.id,
                    child: widget.buildPluginBody(
                        card, Size(_px(card).w, _px(card).h)),
                  ),
                ),
              ),
            ),
          GuidesLayer(guides: _guides),
        ],
      ),
    );
  }

  List<WidgetCard> _sortedByZ() {
    final list = [..._cards];
    list.sort((a, b) => a.z.compareTo(b.z));
    return list;
  }
}
