/// Vectra（MacroSTAR Studio）· Flutter + Win32 版
///
/// 单进程、单窗口：一个覆盖整个虚拟屏幕的透明置顶窗口装下所有磁贴，
/// 窗口区域被裁成"所有卡片圆角矩形的并集"，区域外的点击自然落到桌面。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'core/app_version.dart';
import 'core/logger.dart';
import 'core/paths.dart';
import 'core/splash_gate.dart';
import 'model/card.dart';
import 'native/native_bridge.dart';
import 'plugin/registry.dart';
import 'sidebar_main.dart' as sidebar;
import 'store/store.dart';
import 'ui/app_root.dart';
import 'ui/panel_app.dart';

/// AI 侧边栏那个引擎的入口。
///
/// 必须定义在**根库**（也就是含 main() 的这个文件）里：引擎按名字找入口时
/// 只在根库里查，定义在别处会报 "Could not resolve main entrypoint function"
/// —— 实测踩过。
@pragma('vm:entry-point')
void sidebarMain() => sidebar.sidebarMain();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 日志系统就绪后再干别的，后面每一行才能进文件
  Log.init(engine: 'main', dir: AppPaths.logsDir);
  // --verbose：把 debug 级日志也打出来（贴到文件里），排查用
  if (args.contains('--verbose')) {
    Log.setLevel(LogLevel.debug);
  }
  Log.i('app', '启动参数: ${args.join(" ")}');

  // 版本号缓存一份，插件请求的 User-Agent 要用（同步取，不能 await）
  await initAppVersion();
  Log.i('app', '版本: $appVersion');

  // 用户数据一律放在 exe 同目录的 userdata\ 下（便携优先，见 AppPaths）。
  // 目录不可写就明确报错——静默失败会让用户改完设置莫名其妙丢掉。
  final pathError = await AppPaths.ensureWritable();
  if (pathError != null) {
    Log.e('app', pathError);
  }
  // 旧版数据在 %APPDATA%\LiquidWidgets，首次启动搬过来（不删旧的）
  if (await AppPaths.migrateFromLegacy()) {
    Log.i('app', '已从旧位置搬迁用户数据 -> ${AppPaths.root}');
  }

  final dir = AppPaths.root;
  Log.i('app', '用户数据目录: $dir');
  final store = Store(dir);
  final state = await store.load();

  final registry = PluginRegistry(AppPaths.pluginsDir);
  await registry.scan();
  if (registry.errors.isNotEmpty) {
    registry.errors.forEach((k, v) => Log.e('plugin', '加载失败 $k: $v'));
  }
  Log.i('plugin', '已加载 ${registry.list().length} 个: '
      '${registry.list().map((m) => m.id).join(", ")}');

  if (state.cards.isEmpty) {
    state.cards.addAll(_defaultLayout());
    await store.saveNow(state);
  }

  // 启动幕布的进度以"卡片张数"计，得在播种默认布局之后才拍这个快照
  SplashGate.start(state.cards.length);

  // runWidget 而不是 runApp：这个进程要开两个窗口——覆盖整个虚拟屏幕的磁贴层，
  // 和任务栏里那个独立的设置窗口。两个窗口共用**同一个引擎、同一个 isolate**，
  // 控制面板因此还能直接改 AppState 里的对象（缘由见 panel_window.h 顶部）。
  // runApp 只认一个隐式视图，多视图必须走 runWidget + ViewCollection。
  runWidget(_MultiViewRoot(
    state: state,
    store: store,
    registry: registry,
    openPanel: args.contains('--panel'),
    openAi: args.contains('--ai'),
  ));
}

/// 两个视图的根：隐式视图画桌面磁贴，第二个视图画设置窗口。
///
/// 第二个视图没法在 main() 里就建好——native 要先拿到 Dart 报上来的
/// PlatformDispatcher.engineId 才能找到引擎，而那得等 Dart 跑起来。
/// 所以先只挂隐式视图，拿到 viewId 之后再把第二个加进来。
class _MultiViewRoot extends StatefulWidget {
  const _MultiViewRoot({
    required this.state,
    required this.store,
    required this.registry,
    required this.openPanel,
    required this.openAi,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;

  /// --panel：启动即弹出设置窗口，供不合成键鼠的验证使用
  final bool openPanel;

  /// --ai：启动即展开 AI 侧边栏
  final bool openAi;

  @override
  State<_MultiViewRoot> createState() => _MultiViewRootState();
}

class _MultiViewRootState extends State<_MultiViewRoot> {
  ui.FlutterView? _panelView;

  /// 设置窗口那个视图要直接调 AppRoot 的方法（添加卡片要读桌面视图的
  /// 尺寸来找空位）。同一个 isolate，所以这是真正的对象引用。
  final GlobalKey<AppRootState> _appKey = GlobalKey<AppRootState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _createPanelView());
  }

  Future<void> _createPanelView() async {
    final engineId = ui.PlatformDispatcher.instance.engineId;
    if (engineId == null) {
      Log.e('panel', '拿不到 engineId，设置窗口起不来');
      return;
    }
    final viewId = await NativeBridge.createPanelView(engineId);
    if (viewId < 0) {
      Log.e('panel', 'native 建视图失败');
      return;
    }
    // 视图注册进 PlatformDispatcher 是异步的，等它出现
    for (var i = 0; i < 40; i++) {
      for (final v in ui.PlatformDispatcher.instance.views) {
        if (v.viewId == viewId) {
          Log.i('panel', '设置窗口视图就绪 viewId=$viewId');
          if (mounted) setState(() => _panelView = v);
          if (widget.openPanel) NativeBridge.showPanelWindow();
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    Log.e('panel', '等了 2 秒，viewId=$viewId 仍未出现在 views 里');
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ui.PlatformDispatcher.instance.implicitView;
    return ViewCollection(views: [
      if (desktop != null)
        View(
          // key 必须稳定：视图列表会从 1 个变成 2 个，没有 key 时桌面这个
          // View 的 element 有可能被重建，连带语义树的根节点换号，
          // 而 Flutter 的无障碍桥假设根节点永远不会被重新挂载。
          key: ValueKey('view:${desktop.viewId}'),
          view: desktop,
          child: VectraApp(
            appKey: _appKey,
            state: widget.state,
            store: widget.store,
            registry: widget.registry,
            openAi: widget.openAi,
          ),
        ),
      if (_panelView != null)
        View(
          key: ValueKey('view:${_panelView!.viewId}'),
          view: _panelView!,
          child: PanelApp(
            appKey: _appKey,
            state: widget.state,
            store: widget.store,
            registry: widget.registry,
          ),
        ),
    ]);
  }
}

/// 首次运行的默认布局
List<WidgetCard> _defaultLayout() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    WidgetCard(id: 'clock-$now', pluginId: 'clock', x: 48, y: 48, size: '2x2', z: 1),
    WidgetCard(id: 'calendar-$now', pluginId: 'calendar', x: 296, y: 48, size: '3x3', z: 2),
    WidgetCard(id: 'todo-$now', pluginId: 'todo', x: 48, y: 296, size: '2x3', z: 3),
    WidgetCard(id: 'weather-$now', pluginId: 'weather', x: 668, y: 48, size: '3x2', z: 4),
  ];
}

class VectraApp extends StatelessWidget {
  const VectraApp({
    super.key,
    required this.appKey,
    required this.state,
    required this.store,
    required this.registry,
    this.openAi = false,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;
  final GlobalKey<AppRootState> appKey;

  /// --ai：启动即展开侧边栏，用于不合成键鼠的验证
  final bool openAi;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 整条链路都必须透明：DWM 的逐像素 alpha 才有意义
      color: Colors.transparent,
      theme: ThemeData(
          brightness: Brightness.dark, useMaterial3: true, fontFamily: 'HarmonyOS Sans SC'),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: AppRoot(
            key: appKey,
            state: state,
            store: store,
            registry: registry,
            openAi: openAi,
          ),
      ),
    );
  }
}
