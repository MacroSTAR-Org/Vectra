/// 与 runner 里那段 C++ 的唯一通道。
///
/// C++ 侧只做两件事：按传下来的矩形设置窗口区域、在命中查询时查一下。
/// 所有业务判断都留在 Dart，native 不参与决策。
library;

import 'package:flutter/services.dart';

import '../core/hit.dart';
import '../core/logger.dart';
import '../core/monitor.dart';
import '../core/snap.dart' as snap;

class NativeBridge {
  static const MethodChannel _channel = MethodChannel('vectra/native');

  /// 设置窗口区域。
  ///
  /// [cards] 既进区域也进命中判定（圆角矩形）。
  /// [extra] 只进区域、不进命中判定 —— 拖拽辅助线属于这类：需要被画出来，
  ///         但点上去应该穿透到桌面，而不是被我们接住。
  /// 返回值现在恒为 false（早年用来回传 panel_mode 做诊断，面板搬走后作废）
  static Future<bool> setRegion({
    required List<HitRect> cards,
    required List<snap.Rect> extra,
    required double radius,
    required double devicePixelRatio,
  }) {
    final d = devicePixelRatio;
    return _channel.invokeMethod<bool>('setRegion', {
      'cards': [
        for (final r in cards)
          {
            'x': r.x * d,
            'y': r.y * d,
            'w': r.w * d,
            'h': r.h * d,
            // 每个矩形可以带自己的半径；不带就用统一值
            'radius': (r.radius ?? radius) * d
          }
      ],
      'extra': [
        for (final r in extra)
          {'x': r.x * d, 'y': r.y * d, 'w': r.w * d, 'h': r.h * d, 'radius': 0.0}
      ],
    }).then((v) => v ?? false);
  }

  /// Windows 11 系统背景材质。返回是否设置成功（旧系统会失败，需回退不透明）。
  /// 0=自动 1=无 2=云母 3=亚克力
  static Future<bool> setBackdrop(int type) async =>
      await _channel.invokeMethod<bool>('setBackdrop', type) ?? false;

  /// 抓取桌面（壁纸层）实际像素，BGRA 顺序。返回 null 表示抓取失败，
  /// 调用方应回退到读壁纸文件。
  static Future<Uint8List?> captureDesktop(int w, int h) =>
      _channel.invokeMethod<Uint8List>('captureDesktop', {'w': w, 'h': h});

  /// 拖拽模式：拖动期间暂停区域裁剪，避免每帧 SetWindowRgn 造成的残影。
  static Future<void> setDragging(bool on) =>
      _channel.invokeMethod<void>('setDragging', on);

  /// 注册全局快捷键。mods 是 Win32 修饰位（ALT=1 CTRL=2 SHIFT=4 WIN=8），
  /// vk 是虚拟键码。返回是否注册成功（被别的程序占用会失败）。
  static Future<bool> registerHotkey(int mods, int vk) async =>
      await _channel.invokeMethod<bool>(
          'registerHotkey', {'mods': mods, 'vk': vk}) ??
      false;

  // 这里原先有个 onHotkey：全局快捷键早已改成 C++ 里直接切换侧边栏窗口，
  // Dart 根本收不到那条消息，是死代码，已删除。

  /// native 请求打开控制面板，参数是要定位到的标签页（目前只有 'ai'）。
  ///
  /// 用途：AI 侧边栏跑在另一个 Flutter 引擎里，点它的齿轮时没法直接调到这边，
  /// 两个引擎不共享 isolate。只能由侧边栏喊 native、native 再喊这边。
  static void onOpenPanel(void Function(String tab) handler) {
    _ensureHandler();
    _onOpenPanel = handler;
  }

  /// 显示器插拔后 native 通知这边（磁贴窗口已重摆到新虚拟屏），
  /// 用来迁移卡片、刷新壁纸。
  static void onDisplayChanged(VoidCallback handler) {
    _ensureHandler();
    _onDisplayChanged = handler;
  }

  /// 系统深浅色切换（native 的 WM_SETTINGCHANGE 推过来）。
  static void onThemeChanged(VoidCallback handler) {
    _ensureHandler();
    _onThemeChanged = handler;
  }

  /// 当前系统是否浅色（读注册表 AppsUseLightTheme）。
  static Future<bool> getSystemTheme() async =>
      await _channel.invokeMethod<bool>('getSystemTheme') ?? false;

  static void Function(String tab)? _onOpenPanel;
  static VoidCallback? _onDisplayChanged;
  static VoidCallback? _onThemeChanged;
  static bool _handlerInstalled = false;

  /// 通道只有一个 method call handler，多个回调登记到这里统一分发，
  /// 免得后登记的覆盖掉先登记的。
  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openPanel':
          _onOpenPanel?.call('${call.arguments ?? ''}');
        case 'displayChanged':
          _onDisplayChanged?.call();
        case 'themeChanged':
          _onThemeChanged?.call();
        case 'log':
          // C++ 侧的日志。native 自己不落盘（发布版没有控制台，printf 全丢），
          // 统一转到 Dart 这边进同一个日志文件。
          Log.native('${call.arguments ?? ''}');
      }
      return null;
    });
  }

  /// 在资源管理器里打开日志目录（面板"关于"页那个按钮）。
  ///
  /// 不能复用插件的 openExternal：那条只放行 http/https，本地目录会被挡掉。
  static Future<void> openLogDir(String dir) =>
      _channel.invokeMethod<void>('openLogDir', dir);

  /// 当前所有显示器的物理矩形 + 设备名。多显示器适配用。
  static Future<List<MonitorRect>> getMonitors() async {
    final list =
        await _channel.invokeListMethod<Map<dynamic, dynamic>>('getMonitors');
    return [
      for (final m in list ?? const [])
        (
          id: '${m['id'] ?? ''}',
          x: (m['x'] as num?)?.toInt() ?? 0,
          y: (m['y'] as num?)?.toInt() ?? 0,
          w: (m['w'] as num?)?.toInt() ?? 0,
          h: (m['h'] as num?)?.toInt() ?? 0,
        )
    ];
  }

  /// 系统媒体控件（SMTC）的当前快照。
  ///
  /// 取的是"按音量键弹出的那个正在播放浮层"背后的数据，任何支持 SMTC 的
  /// 播放器都算数（实测 Spotify 会给全标题/歌手/专辑/封面/进度，且允许 seek）。
  /// 第一次调用时 native 才起轮询线程，没人用就不占资源。
  static Future<Map<String, Object?>?> smtcState() =>
      _channel.invokeMapMethod<String, Object?>('smtcState');

  /// 取封面原始字节（JPEG/PNG）。[artId] 与快照里的对不上会返回 null——
  /// 版本号就是为了让封面每首歌只搬一次，而不是每次轮询都搬十几万字节。
  static Future<Uint8List?> smtcArt(int artId) =>
      _channel.invokeMethod<Uint8List>('smtcArt', {'id': artId});

  /// 播放控制。cmd: play / pause / toggle / next / prev / seek
  /// 返回值只表示命令已排队，不代表播放器真的照做了（有的播放器不支持 seek）。
  static Future<bool> smtcControl(String cmd, {int posMs = 0}) async =>
      await _channel
          .invokeMethod<bool>('smtcControl', {'cmd': cmd, 'posMs': posMs}) ??
      false;

  /// 在**同一个引擎**上再开一个视图，用作任务栏里的设置窗口。
  ///
  /// 要把 Dart 侧的 engineId 报给 native：C++ 拿不到
  /// flutter::FlutterEngine 内部那个 FlutterDesktopEngineRef（私有成员）。
  /// 返回视图 id，-1 表示失败。
  static Future<int> createPanelView(int engineId) async =>
      await _channel.invokeMethod<int>('createPanelView', {'engineId': engineId}) ??
      -1;

  static Future<void> showPanelWindow() =>
      _channel.invokeMethod<void>('showPanelWindow');

  static Future<void> hidePanelWindow() =>
      _channel.invokeMethod<void>('hidePanelWindow');

  /// 无边框设置窗口的标题栏操作：拖动 / 最小化 / 最大化切换。
  static Future<void> panelDragMove() =>
      _channel.invokeMethod<void>('panelDragMove');

  static Future<void> panelMinimize() =>
      _channel.invokeMethod<void>('panelMinimize');

  static Future<void> panelToggleMaximize() =>
      _channel.invokeMethod<void>('panelToggleMaximize');

  /// 从窗口某条边/某个角开始缩放。
  ///
  /// 传的是 Win32 的命中码（HTLEFT=10 那一套，见 PanelEdge）。窗口没有系统
  /// 缩放边框，也没法靠 WM_NCHITTEST——Flutter 子窗口把鼠标消息全吃了，
  /// 所以由 Flutter 侧的边缘手柄按下时喊一声，native 再交给系统去拖。
  static Future<void> panelResize(int edge) =>
      _channel.invokeMethod<void>('panelResize', edge);

  /// 启动幕布的加载进度。ready/total 是"已就绪的卡片数 / 总卡片数"。
  static Future<void> splashProgress(int ready, int total) =>
      _channel.invokeMethod<void>(
          'splashProgress', {'ready': ready, 'total': total});

  /// 全部就绪，让启动幕布收尾淡出。
  static Future<void> splashFinish() =>
      _channel.invokeMethod<void>('splashFinish');

  /// 通知侧边栏那个引擎重新读一遍配置。
  /// 两个引擎不共享 isolate，AI 配置由本引擎写进 config.json，
  /// 不喊一声的话侧边栏要等到下次唤出才知道变了。
  static Future<void> reloadSidebar() =>
      _channel.invokeMethod<void>('reloadSidebar');

  /// 是否已登记开机自启（HKCU 的 Run 键，不需要管理员权限）。
  /// 便携版被搬走后 native 会顺手把登记的路径修正到当前 exe。
  static Future<bool> isAutoStart() async =>
      await _channel.invokeMethod<bool>('isAutoStart') ?? false;

  /// 开关开机自启，返回写完之后的实际状态。
  static Future<bool> setAutoStart(bool on) async =>
      await _channel.invokeMethod<bool>('setAutoStart', on) ?? false;

  /// 主显示器工作区（物理像素，已排除任务栏）。取不到时返回 null。
  static Future<({int x, int y, int w, int h})?> getWorkArea() async {
    final m = await _channel.invokeMapMethod<String, int>('getWorkArea');
    if (m == null) return null;
    return (x: m['x'] ?? 0, y: m['y'] ?? 0, w: m['w'] ?? 0, h: m['h'] ?? 0);
  }

  /// 窗口在虚拟屏幕中的物理像素范围。
  static Future<({int x, int y, int w, int h})> getWindowRect() async {
    final m = await _channel.invokeMapMethod<String, int>('getWindowRect');
    return (x: m?['x'] ?? 0, y: m?['y'] ?? 0, w: m?['w'] ?? 0, h: m?['h'] ?? 0);
  }
}
