/// 把一张卡片和它的插件运行时绑在一起：挂载、渲染、出错恢复、卸载。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/grid.dart';
import '../core/app_version.dart';
import '../core/logger.dart';
import '../core/splash_gate.dart';
import '../model/card.dart';
import '../store/store.dart';
import '../ui/wallpaper.dart';
import 'host.dart';
import 'node.dart';
import 'registry.dart';
import 'runtime.dart';
import 'sdk.dart';

/// 出错后自动重试之前等多久。
///
/// 插件失控大多是代码问题，重试也救不回来；但有一类是**当时机器忙**——启动瞬间
/// 几个插件一起编译，某个插件的首次挂载就可能撞上 800ms 的执行预算被判失控。
/// 这类隔几秒重来一次就好了，用户根本不该看见。
const Duration kAutoRetryDelay = Duration(seconds: 3);

class PluginCardBody extends StatefulWidget {
  const PluginCardBody({
    super.key,
    required this.card,
    required this.size,
    required this.registry,
    required this.store,
    required this.state,
    required this.onRequestSize,
    required this.onOpenSettings,
  });

  final WidgetCard card;
  final Size size;
  final PluginRegistry registry;
  final Store store;
  final AppState state;
  final void Function(String size) onRequestSize;
  final void Function() onOpenSettings;

  @override
  State<PluginCardBody> createState() => _PluginCardBodyState();
}

class _PluginCardBodyState extends State<PluginCardBody> {
  PluginRuntime? _runtime;
  String? _loadError;

  /// 自动重试的额度只有一次。用完之后再出错就把决定权交给用户——
  /// 一直自动重下去的话，一个必然失败的插件会没完没了地重建运行时。
  bool _autoRetryUsed = false;

  /// 正在等自动重试：这期间显示"正在重试"，而不是先闪一下错误框再消失
  bool _retrying = false;

  /// 错误详情是否展开
  bool _showDetail = false;

  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _boot();
    // 壁纸一变，"莫奈取色"算出来的强调色也跟着变——插件只在 mount 时
    // 拿过一次初始值，后续得靠这个监听主动推，不然要等下次因为别的原因
    // 重新挂载（改尺寸/改设置）才会用上新颜色。
    Wallpaper.dominantColor.addListener(_pushTheme);
  }

  @override
  void dispose() {
    Wallpaper.dominantColor.removeListener(_pushTheme);
    _retryTimer?.cancel();
    _detach(_runtime);
    _runtime?.dispose();
    super.dispose();
  }

  /// 摘掉出错监听。必须赶在 dispose 之前——运行时的 dispose 会把
  /// error 这个 ValueNotifier 一起销毁，之后再动它就是对已释放对象操作。
  void _detach(PluginRuntime? rt) => rt?.error.removeListener(_onRuntimeError);

  void _pushTheme() => _runtime?.notifyTheme(_themeAccentHex());

  /// 只有用户开了"从壁纸取色"或"文字颜色也用取色"其中一个开关，才把
  /// 算出来的强调色递给插件——两个开关都关着时插件拿到 null，自己退回
  /// 写死的颜色，不会在用户没选这套风格时突然被强行换色。
  String? _themeAccentHex() {
    final s = widget.state.settings;
    if (!s.autoColorFromWallpaper && !s.autoForegroundFromWallpaper) return null;
    final c = Wallpaper.dominantColor.value;
    if (c == null) return null;

    // Material 的 tonalSpot 方案算出来的 primary 饱和度本来就压得低，
    // 直接把这个颜色当"文字色"画在卡片上时，经常又暗又灰，跟卡片背景
    // 本身也偏暗撞在一起，糊成一片看不出变化——用户实测反馈"时钟数字
    // 看着还是白的"就是这个原因。
    //
    // 不是重新套用户已经要求撤回的 vibrant 方案（那是换一整套 Material
    // 取色算法），而是照搬 card_view.dart 里 _micaBase 已经在用的"明度
    // 推向两极"手法：只保留这个颜色的色相，明度按卡片背景明暗推到能读
    // 得出来的那一档，饱和度顶一个下限，保证插件拿到的这个颜色不管画
    // 在深底还是浅底上，都一眼看得出"这是跟着壁纸变的颜色"。
    final hsl = HSLColor.fromColor(c);
    final dark = Wallpaper.brightness.value < 0.5;
    final sat = hsl.saturation.clamp(0.55, 1.0);
    final lightness = dark ? 0.72 : 0.38;
    final vivid = HSLColor.fromAHSL(1, hsl.hue, sat, lightness).toColor();
    final hex = vivid.toARGB32().toRadixString(16).padLeft(8, '0').substring(2);
    return '#$hex';
  }

  Future<void> _boot() async {
    final loaded = widget.registry[widget.card.pluginId];
    if (loaded == null) {
      setState(() => _loadError = '找不到插件「${widget.card.pluginId}」');
      // 加载不出来也算"到最终形态了"，得让启动幕布知道，
      // 否则一个坏插件就能把幕布一直挂在那儿
      SplashGate.reportReady(widget.card.id);
      return;
    }

    final host = PluginHost(
      store: widget.store,
      state: widget.state,
      card: widget.card,
      pluginId: loaded.manifest.id,
      onRequestSize: widget.onRequestSize,
      onOpenSettings: widget.onOpenSettings,
      registry: widget.registry,
      sdk: PluginSdk(pluginId: loaded.manifest.id, registry: widget.registry),
    );

    final rt = PluginRuntime(
      manifest: loaded.manifest,
      source: loaded.source,
      instanceId: widget.card.id,
      host: host.call,
      sdk: host.sdk,
      appVersion: appVersion,
      pluginDir: widget.registry.userDir,
    );

    // 卡片没配过的设置项用 manifest 里的默认值补齐
    final settings = <String, Object?>{
      ...loaded.manifest.defaultSettings(),
      ...widget.card.settings,
    };

    final grid = parseSize(widget.card.size) ?? const GridSize(2, 2);
    await rt.mount(
      settings: settings,
      w: widget.size.width,
      h: widget.size.height,
      cols: grid.cols,
      rows: grid.rows,
      themeAccent: _themeAccentHex(),
    );

    if (!mounted) {
      rt.dispose();
      return;
    }
    setState(() {
      _runtime = rt;
      _retrying = false;
      _loadError = null;
    });
    // 插件已经编译并跑出第一棵 UI 树，这张卡到此就算渲染好了。
    // 插件自己的网络请求不在等待范围内（见 SplashGate 的说明）。
    SplashGate.reportReady(widget.card.id);

    // 挂载当场就失败时 error 已经有值了，而 addListener 不会补发历史值，
    // 所以这里要自己查一次，否则"一挂载就崩"的插件永远等不到自动重试。
    if (rt.failure != null) {
      _scheduleAutoRetry();
    } else {
      rt.error.addListener(_onRuntimeError);
    }
  }

  void _onRuntimeError() {
    if (_runtime?.failure != null) _scheduleAutoRetry();
  }

  void _scheduleAutoRetry() {
    if (_autoRetryUsed || !mounted) return;
    _autoRetryUsed = true;
    setState(() => _retrying = true);
    _retryTimer?.cancel();
    _retryTimer = Timer(kAutoRetryDelay, () {
      if (!mounted) return;
      Log.i('plugin', '${widget.card.pluginId} 出错，自动重试一次');
      _reload();
    });
  }

  /// 重新来过：丢掉旧运行时，从头挂载一遍。
  ///
  /// 不是"接着跑"而是"重开一个"——失控的运行时里全局状态已经不可信了，
  /// 唯一干净的做法是整个换掉。
  Future<void> _reload() async {
    _retryTimer?.cancel();
    final old = _runtime;
    _detach(old);
    setState(() {
      _runtime = null;
      _loadError = null;
      _showDetail = false;
    });
    old?.dispose();
    await _boot();
  }

  void _manualRetry() {
    Log.i('plugin', '${widget.card.pluginId} 用户手动重试');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_retrying) return _retryingBox();
    if (_loadError != null) return _errorBox(_loadError!);

    final rt = _runtime;
    if (rt == null) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<String?>(
      valueListenable: rt.error,
      builder: (context, err, _) {
        if (err != null) return _errorBox(err);
        return ValueListenableBuilder<Map<String, Object?>?>(
          valueListenable: rt.tree,
          builder: (context, tree, _) => PluginView(
            tree: tree,
            onEvent: rt.dispatchEvent,
            animate: widget.state.settings.animations,
            registry: widget.registry,
          ),
        );
      },
    );
  }

  /// 卡片上显示的名字优先用 manifest 里的中文名，插件都加载不出来时退回 id
  String get _displayName =>
      widget.registry[widget.card.pluginId]?.manifest.name ??
      widget.card.pluginId;

  /// 前景色跟着卡片走。写死白色的话，浅色壁纸配浅色云母时整个错误框都看不见
  /// ——而这恰恰是最需要被看见的时候。
  Color get _fg =>
      DefaultTextStyle.of(context).style.color ?? Colors.white;

  Widget _retryingBox() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_displayName 出错了',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: _fg.withValues(alpha: 0.75),
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('正在重试…',
              style:
                  TextStyle(color: _fg.withValues(alpha: 0.45), fontSize: 11)),
        ],
      );

  /// 插件挂了只影响它自己那张卡片。
  ///
  /// 默认只给一句人话加一个「重试」——JS 堆栈对普通用户没有任何意义，
  /// 但对写插件的人是全部线索，所以留一个「详情」折叠着。
  Widget _errorBox(String message) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 13, color: _fg.withValues(alpha: 0.6)),
              const SizedBox(width: 4),
              Flexible(
                child: Text('$_displayName 出错了',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _fg.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _miniButton('重试', _manualRetry),
              const SizedBox(width: 6),
              _miniButton(_showDetail ? '收起' : '详情',
                  () => setState(() => _showDetail = !_showDetail)),
            ],
          ),
          if (_showDetail) ...[
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                child: Text(message,
                    style: TextStyle(
                        color: _fg.withValues(alpha: 0.5),
                        fontSize: 10,
                        height: 1.35)),
              ),
            ),
          ],
        ],
      );

  /// 卡片可能只有 2x2 那么大，按钮得小。用 GestureDetector 而不是现成的
  /// Button：Material 的按钮自带最小 48px 命中区，两个并排就把小卡片撑爆了。
  Widget _miniButton(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _fg.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style:
                  TextStyle(color: _fg.withValues(alpha: 0.8), fontSize: 11)),
        ),
      );
}
