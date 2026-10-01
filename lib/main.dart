/// Glance · 一瞥 · Flutter + Win32 版
///
/// 单进程、单窗口：一个覆盖整个虚拟屏幕的透明置顶窗口装下所有磁贴，
/// 窗口区域被裁成"所有卡片圆角矩形的并集"，区域外的点击自然落到桌面。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dart:async' show runZonedGuarded;

import 'core/app_version.dart';
import 'core/logger.dart';
import 'core/paths.dart';
import 'core/perf_probe.dart';
import 'core/sentry.dart' as sentry;
import 'core/sentry_reporter.dart' show wireSentryReporter;
import 'core/splash_gate.dart';
import 'core/updater.dart';
import 'native/native_bridge.dart';
import 'widgets/spec.dart';
import 'store/store.dart';
import 'ui/app_root.dart';
import 'ui/panel_app.dart';

Future<void> main(List<String> args) async {
  // 【临时诊断】性能探针在 _bootstrap 里挂：它要用 SchedulerBinding，
  // 而 binding 必须在 ensureInitialized 之后才存在——放这里调会直接抛
  // "Binding has not yet been initialized"，而这一行又在 guarded Zone 之外，
  // 异常会把整个 main 打断（表现为程序起不来、日志也不生成）。
  // 整个启动流程都跑在同一个 guarded Zone 里：ensureInitialized 和后面的
  // runWidget 必须同 Zone，否则 Debug 模式会抛 "Zone mismatch" 断言。
  // runZonedGuarded 补的是"异步 Future 没被 await 而抛的异常"——那条缝
  // FlutterError（Sentry 装的 onError 钩子）抓不到。
  runZonedGuarded(
    () => _bootstrap(args),
    (error, stack) {
      Log.e('app', '未捕获异常: $error', stack);
      sentry.reportExceptionToSentry(error, stack);
    },
  );
}

/// main 的实际启动流程。由 main() 在 guarded Zone 里调起。
Future<void> _bootstrap(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 日志系统就绪后再干别的，后面每一行才能进文件
  Log.init(engine: 'main', dir: AppPaths.logsDir);
  PerfProbe.start();  // 【临时诊断】每 3 秒 dump 帧耗时与构建次数
  // --verbose：把 debug 级日志也打出来（贴到文件里），排查用
  if (args.contains('--verbose')) {
    Log.setLevel(LogLevel.debug);
  }
  // --wait-restart：重启流程的接力棒。旧进程拉起新进程后立刻退出，新
  // 进程在这里等一拍再走——等的是旧实例释放 Ctrl+Alt+Space 热键的
  // 注册权，抢跑会注册失败。
  if (args.contains('--wait-restart')) {
    Log.i('app', '重启接力：等待旧进程退出');
    await Future.delayed(const Duration(seconds: 2));
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

  // 启动各阶段分别计时。"启动慢"是最难复现的一类反馈，有了这几个数字
  // 就能直接指出是读配置慢、扫插件慢，还是后面编译插件慢。
  final boot = Stopwatch()..start();
  final store = Store(dir);
  final state = await store.load();
  final loadMs = boot.elapsedMilliseconds;

  Log.i('app', '启动耗时 读配置 ${loadMs}ms / 内置组件 ${kBuiltinSpecs.length} 个');

  if (state.cards.isEmpty) {
    state.cards.addAll(defaultLayout());
    await store.saveNow(state);
  }

  // --test-sentry：主动抛一条错误，验证 Sentry 能收到。
  if (args.contains('--test-sentry')) {
    Log.e('app', '这是一条测试错误（--test-sentry），用来验证 Sentry 上报');
  }

  // --no-sentry：本地开发时不想把数据灌进 Sentry 就加这个参数
  if (args.contains('--no-sentry')) {
    sentry.disableSentry();
  }

  // 启动后延迟静默检查应用更新：
  // 失败无声——连不上更新服务器是常态，不该给刚开机的用户弹任何东西。
  Future<void>.delayed(const Duration(seconds: 30), () {
    runUpdateCheck(
      // 更新比较需要四段数值，显示串是个性化的非数字格式
      currentVersion: appVersionNumeric,
      sources: buildUpdateSources(
          updateSource: state.settings.updateSource,
          marketBaseUrl: state.settings.marketBaseUrl),
    ).then((u) {
      if (u != null && state.settings.autoDownloadUpdate) {
        downloadUpdate(dir: AppPaths.updateDir).catchError((_) => '');
      }
    });
  });

  // 把 logger 的 Log.e 接到 sentry：init 之后、app 跑之前
  wireSentryReporter();

  // 启动幕布的进度以"卡片张数"计，得在播种默认布局之后才拍这个快照
  SplashGate.start(state.cards.length);

  // Sentry 先初始化（要 await 完毕），再跑 app。
  // 不能用 appRunner 模式：runWidget 不返回（跑消息循环），会导致
  // SentryFlutter.init 的 await 永远不完成、SDK 初始化收尾跑不完。
  try {
    await sentry.initSentry();
  } catch (e) {
    // Sentry 自己起不来不该连累整个程序——记下来，后面照样跑
    Log.e('app', 'Sentry 初始化失败（错误上报不可用）: $e');
  }

  // --test-sentry 的异常在 init 之后发，确保 SDK 已经就绪
  if (args.contains('--test-sentry')) {
    try {
      throw StateError('sentry connectivity test from Glance $appVersion');
    } catch (e, st) {
      await sentry.reportExceptionToSentry(e, st);
    }
    Log.i('app', '--test-sentry 已发出，检查 Sentry 面板');
  }

  // runWidget 而不是 runApp：这个进程要开两个窗口——覆盖整个虚拟屏幕的磁贴层,
  // 和任务栏里那个独立的设置窗口。两个窗口共用**同一个引擎、同一个 isolate**，
  // 控制面板因此还能直接改 AppState 里的对象（缘由见 panel_window.h 顶部）。
  // runApp 只认一个隐式视图，多视图必须走 runWidget + ViewCollection。
  runWidget(_MultiViewRoot(
    state: state,
    store: store,
    openPanel: args.contains('--panel'),
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
    required this.openPanel,
  });

  final AppState state;
  final Store store;

  /// --panel：启动即弹出设置窗口，供不合成键鼠的验证使用
  final bool openPanel;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _createWindows());
  }

  Future<void> _createWindows() async {
    // 设置窗口先建：它是常用入口，早一点就绪早一点能弹出来。
    // 只建好视图挂着，不显示，不占屏幕。
    final panel = await _createView(NativeWindow.panel, '设置窗口');
    if (mounted && panel != null) setState(() => _panelView = panel);
    if (panel != null && widget.openPanel) NativeWindow.panel.show();
  }

  /// 让 native 建一个次级窗口 + 视图，等它出现在 PlatformDispatcher 里。
  ///
  /// 建不出来只影响这一个窗口：磁贴照常跑，别的窗口也照常建。
  Future<ui.FlutterView?> _createView(NativeWindow window, String label) async {
    final engineId = ui.PlatformDispatcher.instance.engineId;
    if (engineId == null) {
      Log.e(window.key, '拿不到 engineId，$label 起不来');
      return null;
    }
    final viewId = await window.createView(engineId);
    if (viewId < 0) {
      Log.e(window.key, 'native 建视图失败（$label）');
      return null;
    }
    // 视图注册进 PlatformDispatcher 是异步的，等它出现
    for (var i = 0; i < 40; i++) {
      for (final v in ui.PlatformDispatcher.instance.views) {
        if (v.viewId == viewId) {
          Log.i(window.key, '$label 视图就绪 viewId=$viewId');
          return v;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    Log.e(window.key, '等了 2 秒，viewId=$viewId 仍未出现在 views 里（$label）');
    return null;
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
          ),
        ),
      if (_panelView != null)
        View(
          key: ValueKey('view:${_panelView!.viewId}'),
          view: _panelView!,
          // 窗口隐藏时挂起整棵内容树：面板里组件库页挂着 5 个真实运行的
          // 实时组件预览（每秒轮询），窗口看不见时它们没有理由活着。
          // View 本体保留（native 窗口不能没视图），只是不渲染内容。
          child: ValueListenableBuilder<bool>(
            valueListenable: NativeWindow.visibilityOf(NativeWindow.panel),
            builder: (context, visible, _) => visible
                ? PanelApp(
                    appKey: _appKey,
                    state: widget.state,
                    store: widget.store,
                  )
                : const SizedBox.shrink(),
          ),
        ),
    ]);
  }
}

class VectraApp extends StatelessWidget {
  const VectraApp({
    super.key,
    required this.appKey,
    required this.state,
    required this.store,
  });

  final AppState state;
  final Store store;
  final GlobalKey<AppRootState> appKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 整条链路都必须透明：DWM 的逐像素 alpha 才有意义
      color: Colors.transparent,
      theme: ThemeData(
          brightness: Brightness.dark, useMaterial3: true, fontFamily: 'TsukushiBMaru'),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: AppRoot(
            key: appKey,
            state: state,
            store: store,
                  ),
      ),
    );
  }
}
