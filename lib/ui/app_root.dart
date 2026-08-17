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
import '../core/logger.dart';
import '../core/monitor.dart';
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
  List<MonitorRect> _lastMonitors = const [];

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

  /// 启动时先认一遍屏，再立刻对一次账。
  ///
  /// 光记不对账是不够的：卡片存的是窗口坐标，而窗口原点就是虚拟屏原点，
  /// 关掉程序、在主屏左边接一块屏、再打开——原点从 0 变成了 -1920，所有卡片
  /// 于是整体偏到左边那块屏上去。这种"上次退出到这次启动之间布局变了"的情况
  /// 收不到任何 WM_DISPLAYCHANGE，只能启动时自己对一次。
  Future<void> _initMonitors() async {
    try {
      final monitors = await NativeBridge.getMonitors();
      final winRect = await NativeBridge.getWindowRect();
      if (monitors.isNotEmpty) _lastMonitors = monitors;
      _lastWindowRect = winRect;
      Log.i('app',
          '显示器 ${monitors.length} 块'
          '${monitors.map((m) => " ${m.id} ${m.w}x${m.h}@${m.x},${m.y}").join()}');
    } catch (e) {
      Log.w('app', '显示器初始化失败: $e');
    }
    await _syncCardsWithDisplays();
  }

  /// 记下这张卡现在在哪块屏的哪个位置。
  ///
  /// 放好位置的每条路径都要调一次（加卡、拖拽落点、改尺寸），否则下次布局一变，
  /// 卡片会按**旧**的家被钉回去，看起来就是"自己跑了"。
  void anchorCard(WidgetCard c) {
    final wr = _lastWindowRect;
    if (!mounted || _lastMonitors.isEmpty || wr == null) return;
    final s = widget.state.settings;
    final size = c.pxSize(s.gridCell, s.gridGap);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final home = homeOf(
      _lastMonitors,
      physicalCenter(wr.x.toDouble(), c.x, size.w, dpr),
      physicalCenter(wr.y.toDouble(), c.y, size.h, dpr),
    );
    if (home == null) return;
    c.anchorTo(monitorId: home.id, relX: home.relX, relY: home.relY);
  }

  /// 面板里改过东西（尺寸、网格）之后，把所有卡片的家刷新一遍。
  void _anchorAll() {
    for (final c in widget.state.cards) {
      anchorCard(c);
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

  /// 把卡片和当前的显示器布局对一次账。启动时和显示器插拔时都走这里。
  ///
  /// 三种情况，按顺序判：
  ///   1. 卡片记得自己的家，那块屏还在 → 按屏内相对位置钉回去。
  ///      **这条是多显示器错位的正解**：窗口原点（虚拟屏原点）会因为接上/拔掉
  ///      左边或上面的屏而移动，缩放比例变了也会让同一个逻辑坐标落到别处；
  ///      而屏本身的矩形不会因此改变，所以锚在屏上算出来的位置才是稳的。
  ///      位置和家对得上就什么都不做——不然浮点误差会让每次启动都存一次盘。
  ///   2. 家没了（那块屏被拔了）→ 迁到最近的屏，保持相对位置，再认新家。
  ///   3. 压根没记过家（老配置）→ 按当前位置认领一块屏，位置不动。
  /// 最后无论如何都夹回可视区，保证卡片不会丢在屏幕外。
  Future<void> _syncCardsWithDisplays() async {
    try {
      final monitors = await NativeBridge.getMonitors();
      final winRect = await NativeBridge.getWindowRect();
      if (!mounted || monitors.isEmpty) return;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final vx = winRect.x.toDouble(), vy = winRect.y.toDouble();
      final bounds = MediaQuery.of(context).size;

      var moved = 0, claimed = 0;
      for (final c in widget.state.cards) {
        final size = c.pxSize(widget.state.settings.gridCell,
            widget.state.settings.gridGap);
        final home = monitorById(monitors, c.monitorId);

        if (home != null) {
          // 情况 1：家还在，按相对位置算出该在哪，对不上就钉回去
          final wantX = anchoredTopLeft(
            monitorOrigin: home.x.toDouble(),
            monitorSize: home.w.toDouble(),
            rel: c.relX ?? 0.5,
            windowOrigin: vx,
            dpr: dpr,
            cardSize: size.w,
          );
          final wantY = anchoredTopLeft(
            monitorOrigin: home.y.toDouble(),
            monitorSize: home.h.toDouble(),
            rel: c.relY ?? 0.5,
            windowOrigin: vy,
            dpr: dpr,
            cardSize: size.h,
          );
          if ((wantX - c.x).abs() > kAnchorEpsilon ||
              (wantY - c.y).abs() > kAnchorEpsilon) {
            c.x = wantX;
            c.y = wantY;
            moved++;
          }
        } else {
          // 情况 2：家被拔了 —— 迁到最近那块屏，保持它在原屏里的相对位置
          final physCX = physicalCenter(vx, c.x, size.w, dpr);
          final physCY = physicalCenter(vy, c.y, size.h, dpr);
          final oldHome = monitorAt(_lastMonitors, physCX, physCY);
          if (oldHome != null &&
              !monitors.any((m) => m.id == oldHome.id)) {
            final target = nearestMonitor(monitors,
                oldHome.x + oldHome.w / 2.0, oldHome.y + oldHome.h / 2.0);
            if (target != null) {
              c.x = anchoredTopLeft(
                monitorOrigin: target.x.toDouble(),
                monitorSize: target.w.toDouble(),
                rel: (physCX - oldHome.x) / oldHome.w,
                windowOrigin: vx,
                dpr: dpr,
                cardSize: size.w,
              );
              c.y = anchoredTopLeft(
                monitorOrigin: target.y.toDouble(),
                monitorSize: target.h.toDouble(),
                rel: (physCY - oldHome.y) / oldHome.h,
                windowOrigin: vy,
                dpr: dpr,
                cardSize: size.h,
              );
              moved++;
            }
          }
        }

        // 夹回可视区：换分辨率、屏变少、网格变大都可能把卡片挤出去，
        // 而完全看不见的卡片也就点不到、拖不回来。
        final nx = snap.clamp(c.x, 0, math.max(0.0, bounds.width - size.w));
        final ny = snap.clamp(c.y, 0, math.max(0.0, bounds.height - size.h));
        if (nx != c.x || ny != c.y) {
          c.x = nx;
          c.y = ny;
          moved++;
        }

        // 情况 3（以及迁移之后）：认一块新家。位置本身不动。
        if (monitorById(monitors, c.monitorId) == null) {
          final h = homeOf(
            monitors,
            physicalCenter(vx, c.x, size.w, dpr),
            physicalCenter(vy, c.y, size.h, dpr),
          );
          if (h != null) {
            c.anchorTo(monitorId: h.id, relX: h.relX, relY: h.relY);
            claimed++;
          }
        }
      }

      _lastMonitors = monitors;
      _lastWindowRect = winRect;
      if (moved > 0 || claimed > 0) {
        widget.store.save(widget.state);
        if (mounted) setState(() => _revision++);
        _surfaceKey.currentState?.pushRegion();
        Log.i(
            'app',
            '按显示器布局对账：'
            '${moved > 0 ? "重摆 $moved 张" : ""}'
            '${moved > 0 && claimed > 0 ? "，" : ""}'
            '${claimed > 0 ? "认领 $claimed 张" : ""}');
      }
      _loadWallpaper();
    } catch (e) {
      Log.w('app', '显示器适配失败: $e');
    }
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
    if (ok) {
      Log.i('ai', msg);
    } else {
      Log.w('ai', msg);
    }
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
    // 托盘是用户操作里最"没有痕迹"的一类：点完就没了，事后全靠猜。
    Log.i('tray', '点击菜单项 ${item.key}');
    switch (item.key) {
      case 'panel':
        openPanel();
      case 'lock':
        widget.state.settings.locked = !widget.state.settings.locked;
        Log.i('tray', '锁定桌面 -> ${widget.state.settings.locked}');
        widget.store.save(widget.state);
        await _rebuildTrayMenu();
        setState(() {});
      case 'refreshWall':
        _loadWallpaper();
      case 'rescan':
        await widget.registry.scan();
        Log.i('plugin',
            '重新扫描插件，现有 ${widget.registry.list().length} 个'
            '${widget.registry.errors.isEmpty ? "" : "，失败 ${widget.registry.errors.length} 个"}');
        setState(() => _revision++);
      case 'quit':
        // saveNow 而不是 save：去抖的 300ms 还没到就退出会丢掉最后一次改动。
        // 插件数据是各自去抖的（待办勾选完立刻退出就会丢），一并刷盘。
        await widget.store.saveNow(widget.state);
        await widget.store.flushPluginData();
        // 日志也是攒一批再写的，不刷这一下最后几行就随进程一起没了——
        // 而"退出前发生了什么"恰恰是最需要看的那几行。
        Log.i('app', '退出');
        await Log.flushLogs();
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
    Log.i('app',
        '打开设置窗口${cardId == null ? "" : "（定位卡片 $cardId）"}');
    NativeWindow.panel.show();
  }

  void hidePanelWindow() {
    Log.i('app', '关闭设置窗口');
    NativeWindow.panel.hide();
    // 设置可能改了，让卡片按新参数重建
    setState(() => _revision++);
  }

  /// 面板里改了设置。和过去那个内嵌面板的 onChanged 是同一件事。
  void onPanelChanged() {
    _loadWallpaper();
    // 面板能改卡片尺寸和网格大小，两者都会挪动卡片中心，家要跟着刷新
    _anchorAll();
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
        Log.i('app', '${plugin.id} 每块屏都已放置，忽略本次添加');
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
    final card = WidgetCard(
      id: '${plugin.id}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      pluginId: plugin.id,
      x: spot.x,
      y: spot.y,
      size: plugin.defaultSize,
      z: maxZ + 1,
      settings: plugin.defaultSettings(),
    );
    widget.state.cards.add(card);
    // 新卡片当场认家，否则下次布局一变它就没有依据、只能被夹回可视区
    anchorCard(card);
    Log.i('app',
        '添加组件 ${plugin.id} 于 ${card.x.round()},${card.y.round()} '
        '(${card.size})，现有 ${widget.state.cards.length} 张');
    widget.store.save(widget.state);
    setState(() => _revision++);
  }

  void removeCard(WidgetCard card) {
    widget.state.cards.removeWhere((c) => c.id == card.id);
    Log.i('app',
        '移除组件 ${card.pluginId}(${card.id})，剩 ${widget.state.cards.length} 张');
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
          onCardAnchor: anchorCard,
          buildPluginBody: (card, size) => PluginCardBody(
            key: ValueKey('${card.id}:${card.size}:$_revision'),
            card: card,
            size: size,
            registry: widget.registry,
            store: widget.store,
            state: widget.state,
            onRequestSize: (s) {
              card.size = s;
              // 尺寸变了中心也就变了，家要跟着刷新：不然下次布局变化时
              // 会按旧中心把卡片钉回去，看起来像自己挪了半个身位
              anchorCard(card);
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
