/// AI 侧边栏的独立入口。
///
/// 跑在第二个 Flutter 引擎里（runner 的 SidebarWindow 用
/// DartProject::set_dart_entrypoint("sidebarMain") 启动它）。
///
/// 为什么要独立成一个引擎：磁贴必须常驻 Z 序最底，侧边栏必须浮在所有程序
/// 之上，一个窗口做不到两件事。共用一个窗口时，侧边栏一置顶磁贴就跟着飘到
/// QQ、浏览器上面去了。
///
/// 两个引擎不共享 isolate，状态靠磁盘交接：
///   state.json    主引擎写，这边只读（AI 配置在控制面板里改）
///   ai-chat.json  这边独占（聊天记录），避免两边同时写同一个文件互相覆盖
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'ai/chat_client.dart';
import 'core/logger.dart';
import 'core/paths.dart';
import 'model/ai_settings.dart';
import 'ui/ai_sidebar.dart';
import 'ui/drop_dock.dart';
import 'ui/wallpaper.dart';

const MethodChannel _channel = MethodChannel('vectra/sidebar');

/// 和主引擎同一个 userdata\ 目录。两个引擎不共享 isolate，但共享这份路径
/// 计算逻辑——以前两边各自硬编码 %APPDATA%，改一处漏一处。
String get _dir => AppPaths.root;

@pragma('vm:entry-point')
void sidebarMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // 侧边栏是独立引擎，日志要和主引擎错开文件名，否则两边并发追加同一个文件
  // 会互相插队。目录仍是同一个 userdata\logs\，排查时一起拷走。
  Log.init(engine: 'sidebar', dir: AppPaths.logsDir);
  Log.i('sidebar', '侧边栏引擎启动');
  runApp(const _SidebarApp());
}

class _SidebarApp extends StatelessWidget {
  const _SidebarApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(fontFamily: 'HarmonyOS Sans SC'),
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: _SidebarHost(),
      ),
    );
  }
}

class _SidebarHost extends StatefulWidget {
  const _SidebarHost();

  @override
  State<_SidebarHost> createState() => _SidebarHostState();
}

class _SidebarHostState extends State<_SidebarHost> {
  AiSettings _settings = AiSettings();
  final List<ChatMessage> _chat = [];
  bool _loaded = false;

  /// 主题偏好（auto/light/dark，来自 state.json 的 settings.theme）。
  /// 侧边栏是独立引擎，systemBrightness 那套在主引擎里，这边自己算。
  String _themePref = 'auto';

  /// 系统当前是否浅色（通过 sidebar 通道问 native）
  bool _systemLight = false;

  /// 生效明暗：light 偏好强制浅色、dark 强制深色、auto 跟随系统
  bool get _light =>
      _themePref == 'light' ? true : (_themePref == 'dark' ? false : _systemLight);

  /// 进出动画：native 只管窗口显隐，滑入滑出在这边做
  bool _open = false;

  /// 窗口当前是"整条侧边栏"还是"右下角投放点"。
  ///
  /// 窗口尺寸自始至终不变（收起是靠 native 裁窗口区域，不是缩窗口——缩窗口
  /// 会把 Flutter 的渲染表面搞坏，见 sidebar_window.cpp 里 DockRect 上面那段
  /// 实测记录），所以没法再靠视口尺寸判断，必须由 native 的 shown 通知驱动。
  ///
  /// 它和 _open 是两回事：退场动画播放期间 _open 已经是 false（正在淡出），
  /// 但窗口还是展开的，这时候仍然要画侧边栏而不是投放点。
  bool _expanded = false;

  /// 钉住：点外面不自动收起。native 那边的 WM_ACTIVATE 会跳过关闭流程。
  bool _pinned = false;

  /// 有文件正被拖到本窗口上方（native 从 IDropTarget.DragOver 推过来）
  bool _dropHover = false;

  Size? _lastLoggedSize;

  @override
  void initState() {
    super.initState();
    // native 在每次显示/隐藏时通知过来。显示时重读一次配置，
    // 这样在控制面板里改完 Key/模型，下次唤出就生效，不用重启。
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'reload') {
        // 控制面板改完 AI 配置会走这条：立刻生效，不用等下次唤出
        Log.i('sidebar', '重新读配置');
        await _reload();
        await _applyDock();
      }
      if (call.method == 'themeChanged') {
        // 系统深浅色切换（native 的 WM_SETTINGCHANGE 推过来）
        await _readSystemTheme();
        if (mounted) setState(() {});
      }
      if (call.method == 'shown') {
        final on = call.arguments == true;
        Log.i('sidebar', 'shown=$on');
        if (on) {
          // 先切成展开态再去读配置抓背景：这两步是异步的，中间那几十毫秒
          // 如果还画着投放点，窗口区域已经放开、画的却还是小方块，
          // 屏幕上就是一块空白。
          if (mounted) setState(() => _expanded = true);
          await _reload();
          await _loadBackdrop();
          // 必须先让"收起"那一帧真的画出去，AnimatedSlide 才有起点可以动。
          //
          // 不等这一帧的话，如果配置和背景都命中了缓存、几毫秒就返回，
          // _open 会在同一帧里被置真——AnimatedSlide 一出生就是终态，
          // 表现就是"有时候没有进场动画"。等一帧就把这个竞态消掉了。
          await WidgetsBinding.instance.endOfFrame;
          if (mounted) setState(() => _open = true);
        } else {
          if (mounted) {
            setState(() {
              _open = false;
              _expanded = false;
            });
          }
        }
      }
      if (call.method == 'log') {
        // native（sidebar_window.cpp）转发过来的日志，统一进这边的文件
        Log.native('${call.arguments}');
      }
      if (call.method == 'requestClose') {
        Log.i('sidebar', 'requestClose');
        await _animateOut();
      }
      if (call.method == 'dropHover') {
        final on = call.arguments == true;
        if (mounted && on != _dropHover) setState(() => _dropHover = on);
      }
      if (call.method == 'filesDropped') {
        // 两个来源：直接拖到侧边栏上，或者拖到桌面右下角的投放点
        final paths = [
          for (final v in (call.arguments as List? ?? const [])) '$v'
        ];
        Log.i('sidebar', '拖入 ${paths.length} 个文件');
        SidebarDrop.push(paths);
      }
      return null;
    });
    _boot();
  }

  Future<void> _boot() async {
    await _reload();
    // 窗口在 native 那边是 SW_HIDE 起步的。配置说要投放点，就让它缩到
    // 右下角显示出来——这一步只能等配置读完，所以放在这儿而不是 main.cpp。
    await _applyDock();
    // 主动问一次当前状态：native 可能在处理器注册之前就 Show()/钉住过了
    bool visible = false;
    try {
      visible = await _channel.invokeMethod<bool>('isVisible') ?? false;
      final pinned = await _channel.invokeMethod<bool>('isPinned') ?? false;
      if (mounted && pinned != _pinned) setState(() => _pinned = pinned);
    } catch (_) {}
    Log.i('sidebar', '启动时可见=$visible');
    if (visible) {
      if (mounted) setState(() => _expanded = true);
      await _loadBackdrop();
      if (mounted) setState(() => _open = true);
    }
  }

  Future<void> _applyDock() async {
    try {
      await _channel.invokeMethod('setDock', _settings.dock);
      Log.i('sidebar', '投放点=${_settings.dock}');
    } catch (e) {
      Log.w('sidebar', 'setDock 失败: $e');
    }
  }

  Future<void> _reload() async {
    final s = await _readSettings();
    final chat = await _readChat();
    await _readSystemTheme();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _chat
        ..clear()
        ..addAll(chat);
      _loaded = true;
    });
  }

  /// 从 native 读系统深浅色。侧边栏引擎没有主引擎那套 NativeBridge，
  /// 走自己的 sidebar 通道。
  Future<void> _readSystemTheme() async {
    try {
      _systemLight = await _channel.invokeMethod<bool>('getSystemTheme') ?? false;
    } catch (_) {}
  }

  /// 侧边栏背后是什么程序就糊什么。native 在窗口显示**之前**抓好了那块屏幕，
  /// 这里取回来模糊一次即可——不是磁贴那种"糊桌面壁纸"。
  Future<void> _loadBackdrop() async {
    if (!_settings.glass) return;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('captureBehind');
      if (m == null) return;
      final w = m['w'] as int;
      final h = m['h'] as int;
      final bytes = m['pixels'] as Uint8List;
      if (bytes.length != w * h * 4) return;

      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          bytes, w, h, ui.PixelFormat.bgra8888, done.complete);
      final src = await done.future;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(
        src,
        ui.Offset.zero,
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(
              sigmaX: _settings.blurSigma * 0.5,
              sigmaY: _settings.blurSigma * 0.5,
              tileMode: ui.TileMode.clamp),
      );
      final pic = recorder.endRecording();
      final blurred = await pic.toImage(w, h);
      pic.dispose();
      src.dispose();

      Wallpaper.image.value?.dispose();
      Wallpaper.image.value = blurred;
    } catch (e) {
      Log.w('sidebar', '背景抓取失败: $e');
    }
  }

  /// 钉住状态必须同步给 native：真正决定"失活要不要收起"的是 C++ 那边的
  /// WM_ACTIVATE，Dart 自己记着没用。
  void _setPinned(bool on) {
    setState(() => _pinned = on);
    _channel.invokeMethod('setPinned', on);
    Log.i('sidebar', '钉住=$on');
  }

  /// 点齿轮：让磁贴那个引擎把控制面板打开到 AI 页，自己再收起。
  ///
  /// 之前这里直接绑的 _animateOut——齿轮只是把侧边栏关掉，从来没打开过设置。
  Future<void> _openSettings() async {
    try {
      await _channel.invokeMethod('openPanel');
    } catch (e) {
      Log.w('sidebar', '打开面板失败: $e');
    }
    await _animateOut();
  }

  /// 先播退场动画，播完再让 native 隐藏窗口。
  /// 直接隐藏的话动画根本来不及被看见。
  Future<void> _animateOut() async {
    if (!_open) {
      _channel.invokeMethod('hide');
      return;
    }
    if (mounted) setState(() => _open = false);
    await Future<void>.delayed(const Duration(milliseconds: 220));
    _channel.invokeMethod('hide');
  }

  Future<AiSettings> _readSettings() async {
    try {
<<<<<<< HEAD
      // 配置文件是 config.json（schema 3 之后）。
      // **不要**读 state.json：那只是迁移用的旧文件，迁移完之后就再也不更新了，
      // 读它会和面板完全脱节——面板改了写 config.json，侧边栏重载还读 state.json，
      // 拿到的是迁移那一刻的快照，所有改动全部失效。
      final f = File(p.join(_dir, 'config.json'));
      if (!await f.exists()) return AiSettings();
      final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      // 主题偏好在 AppSettings 里（settings.theme），AI 配置在 ai 键。
=======
      // schema 3 之后主引擎把配置从单个 state.json 拆成了 config.json +
      // plugindata/（见 store.dart _configFile）。侧边栏一直没跟上，还在
      // 读 state.json——控制面板改完 Key/模型，侧边栏实际用的还是旧文件
      // 里那份，两边就脱节了（实测：config.json 里是新 key，state.json
      // 里是 8 月 14 日的老 key，AI 请求用的恰恰是后者）。
      //
      // 这里改成跟主引擎一致：优先 config.json，state.json 只在老版本
      // 还没迁移时兜底。顺序不能反过来——config.json 存在时旧文件永远
      // 是死数据，读它就是在读垃圾。
      final f = File(p.join(_dir, 'config.json'));
      Map<String, Object?> raw;
      if (await f.exists()) {
        raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      } else {
        final legacy = File(p.join(_dir, 'state.json'));
        if (!await legacy.exists()) return AiSettings();
        raw = jsonDecode(await legacy.readAsString()) as Map<String, Object?>;
      }
      // 主题偏好在 AppSettings 里（settings.theme），AI 配置在 settings.ai。
>>>>>>> 773c1c70fdd20f70186fa720ccb0c34d98067517
      // 侧边栏要做深浅色，两个都得读。
      final appSettings =
          (raw['settings'] as Map?)?.cast<String, Object?>() ?? const {};
      _themePref = appSettings['theme'] as String? ?? 'auto';
      return AiSettings.fromJson(
          (raw['ai'] as Map?)?.cast<String, Object?>() ?? const {});
    } catch (_) {
      return AiSettings();
    }
  }

  /// 会话历史由侧边栏引擎独占。命名和 config.json 对齐，不再叫 ai-chat.json。
  File get _chatFile => File(p.join(_dir, 'chat.json'));

  Future<List<ChatMessage>> _readChat() async {
    try {
      // 依次回退到两代旧位置，别让历史凭空消失：
      //   chat.json（现在） <- ai-chat.json（上一版） <- state.json 里的 chat 键（更早）
      if (!await _chatFile.exists()) {
        final legacy = await _readLegacyChat();
        if (legacy.isNotEmpty) return legacy;
        return [];
      }
      final raw = jsonDecode(await _chatFile.readAsString()) as List;
      return [
        for (final m in raw)
          if (m is Map) ChatMessage.fromJson(m.cast<String, Object?>())
      ];
    } catch (_) {
      return [];
    }
  }

  /// 两代旧位置的会话迁移，只在 chat.json 还不存在时读一次。
  Future<List<ChatMessage>> _readLegacyChat() async {
    // 上一版：同目录下的 ai-chat.json
    try {
      final old = File(p.join(_dir, 'ai-chat.json'));
      if (await old.exists()) {
        final raw = jsonDecode(await old.readAsString()) as List;
        final msgs = [
          for (final m in raw)
            if (m is Map) ChatMessage.fromJson(m.cast<String, Object?>())
        ];
        if (msgs.isNotEmpty) return msgs;
      }
    } catch (_) {}
    // 更早：混在 state.json 的 chat 键里
    try {
      final f = File(p.join(_dir, 'state.json'));
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      return [
        for (final m in (raw['chat'] as List? ?? const []))
          if (m is Map) ChatMessage.fromJson(m.cast<String, Object?>())
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveChat() async {
    try {
      await Directory(_dir).create(recursive: true);
      // 只留最近 40 条，历史无限增长会让文件越来越大
      final keep = _chat.length > 40 ? _chat.sublist(_chat.length - 40) : _chat;
      await _chatFile
          .writeAsString(jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (e) {
      Log.w('sidebar', '聊天记录保存失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    final size = mq.size;
    // 只在尺寸变化时打一行：build 每帧都跑，全打会把日志淹了。
    //
    // 这条日志留着不是凑数：上一版"收起就缩窗口"的表面损坏，就是靠它把
    // "框架布局算错了"和"渲染表面跟窗口对不上"两种可能区分开的——框架这边
    // 打出的是 380x892 dpr=1.5（完全正确），屏幕上却只画了 242 物理像素。
    if (size != _lastLoggedSize) {
      _lastLoggedSize = size;
      Log.d('sidebar', '视口 ${size.width}x${size.height} '
          'dpr=${mq.devicePixelRatio}');
    }

    // 深浅色下让光标/选区等系统默认色跟随（MaterialApp 建在 _SidebarApp 里，
    // 那里拿不到 _light，只能在宿主这里用 Theme 包一层）
    final themed = Theme(
      data: Theme.of(context).copyWith(
        brightness: _light ? Brightness.light : Brightness.dark,
      ),
      child: _buildContent(size),
    );
    return themed;
  }

  Widget _buildContent(Size size) {
    // 收起态：窗口还是整条侧边栏那么大，只是被 native 裁成了右下角一个
    // 小方块，所以这里要把投放点画在同一个位置上——两边的常量必须对齐，
    // 错开就是"画在这儿、能点的却在那儿"。
    if (!_expanded) {
      return Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(
              right: kDropDockRightInset, bottom: kDropDockBottomInset),
          child: SizedBox(
            width: kDropDockSize,
            height: kDropDockSize,
            child: DropDock(
              settings: _settings,
              light: _light,
              dropHover: _dropHover,
              onTap: () => _channel.invokeMethod('show'),
            ),
          ),
        ),
      );
    }

    // 非线性进出：滑入用 easeOutCubic（快进慢停），滑出用 easeInCubic
    return AnimatedSlide(
      offset: _open ? Offset.zero : const Offset(1, 0),
      duration: const Duration(milliseconds: 260),
      curve: _open ? Curves.easeOutCubic : Curves.easeInCubic,
      child: AnimatedOpacity(
        opacity: _open ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: AiSidebar(
          // 独立窗口里，侧边栏就是整个客户区
          rect: Offset.zero & size,
          settings: _settings,
          light: _light,
          messages: _chat,
          animate: true,
          pinned: _pinned,
          onPinnedChanged: _setPinned,
          onClose: _animateOut,
          onOpenSettings: _openSettings,
          onChanged: _saveChat,
        ),
      ),
    );
  }
}
