/// 应用根节点：桌面层 + 控制面板 + 托盘。
///
/// 设置面板已经搬进任务栏里那个独立窗口（见 panel_app.dart / panel_window.h），
/// 所以这个窗口现在只干一件事：画磁贴、沉在 Z 序最底、只在卡片上接收输入。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import '../core/grid.dart';
import '../core/snap.dart' as snap;
import '../core/theme.dart';
import '../model/ai_settings.dart';
import '../model/card.dart';
import '../native/native_bridge.dart';
import '../plugin/manifest.dart';
import '../plugin/plugin_card_body.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'panel_app.dart';
import 'wallpaper.dart';
import 'surface.dart';

class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    required this.state,
    required this.store,
    required this.registry,
    this.openPanel = false,
    this.openAi = false,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;

  /// 启动即打开面板（--panel），供验证与自检使用
  final bool openPanel;

  /// 启动即展开 AI 侧边栏（--ai）
  final bool openAi;

  @override
  State<AppRoot> createState() => AppRootState();
}

class AppRootState extends State<AppRoot> with TrayListener {
  /// 直接拿到桌面层，用于确定性地重推命中区
  final GlobalKey<DesktopSurfaceState> _surfaceKey = GlobalKey();

  /// 改了它就会让所有卡片重建（尺寸/圆角等全局设置变化时需要）
  int _revision = 0;

  /// 最近一次见过的显示器集合。显示器插拔时和新的比对，
  /// 用来判断"某张卡原来在的那块屏被拔了没有"。
  List<({String id, int x, int y, int w, int h})> _lastMonitors = const [];

  /// 磁贴窗口在虚拟屏里的位置。显示器矩形是虚拟屏坐标、卡片是窗口内坐标，
  /// 两者换算就靠它。和 _lastMonitors 同时更新。
  ({int x, int y, int w, int h})? _lastWindowRect;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    // AI 侧边栏在另一个引擎里，它点齿轮时只能让 native 转告这边
    NativeBridge.onOpenPanel((tab) {
      if (!mounted) return;
      openPanel(tab: tab == 'ai' ? 3 : null);
    });
    // 显示器插拔：native 已重摆窗口，这里迁移卡片、刷壁纸
    NativeBridge.onDisplayChanged(_onDisplayChanged);
    // 深浅色：读系统主题，切换时卡片文字自动翻转
    initSystemTheme();
    _initTray();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyMaterial();
      _loadWallpaper();
      applyHotkey();
      _initMonitors();
    });
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    Wallpaper.stop();
    super.dispose();
  }

  /// 毛玻璃用的是预模糊壁纸，不是系统材质 —— 系统材质按整个窗口矩形绘制，
  /// 会把整个桌面糊掉（见 wallpaper.dart 里的实测记录）。
  Future<void> _applyMaterial() async {
    // 确保系统材质是关的，避免旧配置留下的状态
    await NativeBridge.setBackdrop(1);
  }

  void _loadWallpaper() {
    final s = widget.state.settings;
    if (s.material == 'opaque') {
      Wallpaper.stop();
      return;
    }
    if (!mounted) return;
    final mica = s.material == 'mica';
    Wallpaper.startAutoRefresh(
      MediaQuery.of(context).size,
      // 云母是静态材质：真正的 Windows 云母只跟壁纸走，窗口在它上面移动时
      // 底子不变。所以这里不跟随动态壁纸刷新，也就没有那份持续开销。
      ms: mica ? 0 : s.liveRefreshMs,
      // 再糊一档，让轮廓彻底化开，接近云母那种"看不出原图"的底子
      sigma: mica ? s.glassBlur * 1.8 : s.glassBlur,
      // 去饱和是云母和亚克力观感上最大的区别
      // 0.35 太狠，壁纸被去成死灰，叠上深色后整张卡片又灰又闷。
      // 0.55 保留一点色相——云母的质感来自带壁纸色相的深色，不是纯灰。
      saturation: mica ? 0.55 : 1.0,
    );
  }

  // ---------------- 多显示器适配 ----------------

  /// 启动时记录一次显示器集合。卡片坐标是绝对的，屏在就在、拔了就被
  /// 下面的 _syncCardsWithDisplays 迁移；这里只需要记住"当前有哪些屏"。
  Future<void> _initMonitors() async {
    try {
      final monitors = await NativeBridge.getMonitors();
      final winRect = await NativeBridge.getWindowRect();
      if (monitors.isNotEmpty) _lastMonitors = monitors;
      _lastWindowRect = winRect;
    } catch (e) {
      stderr.writeln('[app] 显示器初始化失败: $e');
    }
  }

  /// 显示器插拔后：native 已把磁贴窗口重摆到新虚拟屏，这里等 Flutter 把
  /// 新尺寸画出来，再迁移卡片、刷壁纸。
  Future<void> _onDisplayChanged() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCardsWithDisplays());
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 卡片迁移：
  ///   1. 某张卡原来所在的那块屏被拔了 → 迁到离它最近的屏，保持相对位置
  ///   2. 无论如何都夹回新的可见区，保证卡不丢
  /// 屏幕没被拔的卡不动（位置不变，天然"记住"自己那块屏）。
  Future<void> _syncCardsWithDisplays() async {
    try {
      final monitors = await NativeBridge.getMonitors();
      final winRect = await NativeBridge.getWindowRect();
      if (!mounted || monitors.isEmpty) return;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final vx = winRect.x.toDouble(), vy = winRect.y.toDouble();
      final bounds = MediaQuery.of(context).size;

      var changed = false;
      for (final c in widget.state.cards) {
        final size = c.pxSize(widget.state.settings.gridCell,
            widget.state.settings.gridGap);
        final physCX = vx + (c.x + size.w / 2) * dpr;
        final physCY = vy + (c.y + size.h / 2) * dpr;

        final oldHome = _monitorAt(_lastMonitors, physCX, physCY);
        if (oldHome != null) {
          final stillThere = monitors.any((m) => m.id == oldHome.id);
          if (!stillThere) {
            final target =
                _nearestMonitor(monitors, oldHome.x + oldHome.w / 2.0,
                    oldHome.y + oldHome.h / 2.0);
            if (target != null) {
              final relX = (physCX - oldHome.x) / oldHome.w;
              final relY = (physCY - oldHome.y) / oldHome.h;
              c.x = (target.x + relX * target.w - vx) / dpr - size.w / 2;
              c.y = (target.y + relY * target.h - vy) / dpr - size.h / 2;
              changed = true;
            }
          }
        }

        final nx = snap.clamp(c.x, 0, math.max(0.0, bounds.width - size.w));
        final ny = snap.clamp(c.y, 0, math.max(0.0, bounds.height - size.h));
        if (nx != c.x || ny != c.y) {
          c.x = nx;
          c.y = ny;
          changed = true;
        }
      }

      _lastMonitors = monitors;
      _lastWindowRect = winRect;
      if (changed) {
        widget.store.save(widget.state);
        if (mounted) setState(() => _revision++);
        _surfaceKey.currentState?.pushRegion();
        stdout.writeln('[app] 显示器变化，卡片已重摆');
      }
      _loadWallpaper();
    } catch (e) {
      stderr.writeln('[app] 显示器适配失败: $e');
    }
  }

  ({String id, int x, int y, int w, int h})? _monitorAt(
      List<({String id, int x, int y, int w, int h})> mons, double x, double y) {
    for (final m in mons) {
      if (x >= m.x && x < m.x + m.w && y >= m.y && y < m.y + m.h) return m;
    }
    return null;
  }

  ({String id, int x, int y, int w, int h})? _nearestMonitor(
      List<({String id, int x, int y, int w, int h})> mons,
      double cx,
      double cy) {
    ({String id, int x, int y, int w, int h})? best;
    var bestD = double.infinity;
    for (final m in mons) {
      final mcx = m.x + m.w / 2.0, mcy = m.y + m.h / 2.0;
      final d = (mcx - cx) * (mcx - cx) + (mcy - cy) * (mcy - cy);
      if (d < bestD) {
        bestD = d;
        best = m;
      }
    }
    return best;
  }



  Future<void> applyHotkey() async {
    final ai = widget.state.ai;
    final ok = await NativeBridge.registerHotkey(ai.hotkeyMods, ai.hotkeyVk);
    // 成功也要打日志：只在失败时打的话，"没有日志"既可能是成功、
    // 也可能是这段压根没执行，事后分不清楚（实测就被这一点误导过）。
    final msg = ok
        ? '已注册：${ai.hotkeyLabel()}'
        : '注册失败：${ai.hotkeyLabel()} 已被别的程序占用，换一个组合';
    hotkeyStatus.value = msg;
    stdout.writeln('[ai] $msg');
  }






  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray.ico');
    } catch (_) {
      // 图标缺失不该让应用起不来
    }
    await trayManager.setToolTip('Vectra');
    await _rebuildTrayMenu();
  }

  Future<void> _rebuildTrayMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'panel', label: '控制面板'),
      MenuItem.separator(),
      MenuItem.checkbox(
          key: 'lock', label: '锁定布局', checked: widget.state.settings.locked),
      MenuItem(key: 'refreshWall', label: '刷新壁纸模糊'),
      MenuItem(key: 'rescan', label: '重新扫描插件'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => openPanel();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'panel':
        openPanel();
      case 'lock':
        widget.state.settings.locked = !widget.state.settings.locked;
        widget.store.save(widget.state);
        await _rebuildTrayMenu();
        setState(() {});
      case 'refreshWall':
        _loadWallpaper();
      case 'rescan':
        await widget.registry.scan();
        setState(() => _revision++);
      case 'quit':
        // saveNow 而不是 save：去抖的 300ms 还没到就退出会丢掉最后一次改动。
        // 插件数据是各自去抖的（待办勾选完立刻退出就会丢），一并刷盘。
        await widget.store.saveNow(widget.state);
        await widget.store.flushPluginData();
        await trayManager.destroy();
        exit(0);
    }
  }


  /// 打开设置窗口（任务栏里那个独立窗口），可指定停在哪页/定位到哪张卡片。
  ///
  /// 面板不再画在磁贴这个窗口里，所以这里**不需要**再把磁贴窗口顶到最前、
  /// 也不需要临时放开窗口区域——过去那套 setPanelMode 正是磁贴被顶到浏览器
  /// 上面去的根源，现在整块删掉了。
  void openPanel({String? cardId, int? tab}) {
    panelCardRequest.value = cardId;
    panelTabRequest.value = tab ?? (cardId != null ? 1 : 0);
    NativeBridge.showPanelWindow();
  }

  void hidePanelWindow() {
    NativeBridge.hidePanelWindow();
    // 设置可能改了，让卡片按新参数重建
    setState(() => _revision++);
  }

  /// 面板里改了设置。和过去那个内嵌面板的 onChanged 是同一件事。
  void onPanelChanged() {
    _loadWallpaper();
    // AI 那页的改动写在 state.json 里，侧边栏是另一个引擎，
    // 得喊一声它才会重新读——否则要等到下次唤出才生效。
    NativeBridge.reloadSidebar();
    setState(() => _revision++);
  }

  // ---------------- 卡片增删 ----------------

  /// 各显示器在磁贴窗口坐标系里的矩形（逻辑像素）。
  ///
  /// 磁贴窗口是一整块盖住整个虚拟屏的窗口，卡片的 x/y 是相对它的逻辑像素；
  /// 而 native 给的显示器矩形是虚拟屏物理像素，两者要换算一次才能比。
  /// 拿不到显示器信息时退化成"整个窗口就是一块屏"，功能照常。
  List<({String id, snap.Rect rect})> _monitorRects() {
    final size = MediaQuery.of(context).size;
    if (_lastMonitors.isEmpty || _lastWindowRect == null) {
      return [(id: '@window', rect: snap.Rect(0, 0, size.width, size.height))];
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final w = _lastWindowRect!;
    return [
      for (final m in _lastMonitors)
        (
          id: m.id,
          rect: snap.Rect((m.x - w.x) / dpr, (m.y - w.y) / dpr, m.w / dpr,
              m.h / dpr),
        )
    ];
  }

  /// 还有没有哪块屏没放这种组件。面板据此禁用「添加」按钮。
  bool canAddPlugin(String pluginId) => _freeMonitorFor(pluginId) != null;

  /// 挑第一块还没有这种组件的屏。规则本身是纯几何，放在 snap 里便于测试，
  /// 这里只负责把卡片换算成矩形。
  snap.Rect? _freeMonitorFor(String pluginId) {
    final s = widget.state.settings;
    final mons = _monitorRects();
    final occupied = [
      for (final c in widget.state.cards)
        if (c.pluginId == pluginId)
          snap.Rect(c.x, c.y, c.pxSize(s.gridCell, s.gridGap).w,
              c.pxSize(s.gridCell, s.gridGap).h)
    ];
    final i = snap.firstFreeMonitor([for (final m in mons) m.rect], occupied);
    return i == null ? null : mons[i].rect;
  }

  void addCard(PluginManifest plugin) {
    final s = widget.state.settings;
    final size = sizeToPx(plugin.defaultSize, s.gridCell, s.gridGap);

    // 一种组件每块屏最多一个：挑一块还空着的，没有就别加
    final target = _freeMonitorFor(plugin.id);
    if (target == null) {
      stdout.writeln('[app] ${plugin.id} 每块屏都已放置，忽略本次添加');
      return;
    }

    final others = [
      for (final c in widget.state.cards)
        snap.Rect(c.x, c.y, c.pxSize(s.gridCell, s.gridGap).w,
            c.pxSize(s.gridCell, s.gridGap).h)
    ];
    final spot = snap.findFreeSpot(
      snap.PxRect(size.w, size.h),
      others,
      target,
    );
    final maxZ = widget.state.cards.fold<int>(0, (m, c) => math.max(m, c.z));
    widget.state.cards.add(WidgetCard(
      id: '${plugin.id}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      pluginId: plugin.id,
      x: spot.x,
      y: spot.y,
      size: plugin.defaultSize,
      z: maxZ + 1,
      settings: plugin.defaultSettings(),
    ));
    widget.store.save(widget.state);
    setState(() => _revision++);
  }

  void removeCard(WidgetCard card) {
    widget.state.cards.removeWhere((c) => c.id == card.id);
    widget.store.save(widget.state);
    setState(() => _revision++);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        DesktopSurface(
          key: _surfaceKey,
          state: widget.state,
          store: widget.store,
          onCardSecondaryTap: (card) => openPanel(cardId: card.id),
          buildPluginBody: (card, size) => PluginCardBody(
            key: ValueKey('${card.id}:${card.size}:$_revision'),
            card: card,
            size: size,
            registry: widget.registry,
            store: widget.store,
            state: widget.state,
            onRequestSize: (s) {
              card.size = s;
              widget.store.save(widget.state);
              setState(() => _revision++);
            },
            onOpenSettings: () => openPanel(cardId: card.id),
          ),
        ),
      ],
    );
  }
}
