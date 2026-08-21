/// 设置窗口里的那棵 widget 树。
///
/// 它跑在**第二个视图**上，但和桌面磁贴共用同一个引擎、同一个 isolate，
/// 所以这里拿到的 state / store / registry 就是磁贴那边同一批对象——
/// 控制面板改设置仍然是就地改，不需要任何跨进程同步。
///
/// 添加/删除卡片、改完设置后的重建，都要落到 AppRoot 上执行：找空位要读
/// **桌面那个视图**的尺寸，注册快捷键要读改完的 state.ai。所以这里直接持有
/// AppRoot 的 State（同一个 isolate，是真正的对象引用，不是消息）。
///
/// 界面用 fluent_ui 的 Windows 11 风格（小组件磁贴那边不用它，保持原样）。
library;

import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'app_root.dart';
import 'panel.dart';

/// 设置窗口该显示哪一页 / 定位到哪张卡片。
/// 托盘、右键卡片、AI 侧边栏齿轮都往这里写，设置窗口监听。
final ValueNotifier<int?> panelTabRequest = ValueNotifier(null);
final ValueNotifier<String?> panelCardRequest = ValueNotifier(null);

/// 面板主题重建信号。
///
/// 控制面板里改了"主题"（auto/light/dark）时 bump 一下，让这棵 FluentApp
/// 树重建——否则 FluentApp 的 FluentThemeData 只在 PanelApp 第一次 build
/// 时算一次，scaffoldBackgroundColor / accentColor / 各种 fluent 控件的
/// 主题色就卡在旧亮度里不动。
///
/// 系统深浅色的翻转由 AnimatedBuilder 直接监听 systemBrightness，
/// 这个 notifier 只负责"用户手动改了 settings.theme"的那一条路径。
final ValueNotifier<int> panelThemeRevision = ValueNotifier(0);

class PanelApp extends StatelessWidget {
  const PanelApp({
    super.key,
    required this.state,
    required this.store,
    required this.registry,
    required this.appKey,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;
  final GlobalKey<AppRootState> appKey;

  @override
  Widget build(BuildContext context) {
    // 双重监听重建 FluentApp：
    //   1. systemBrightness 翻转（系统深浅色切换 / 显式 light+dark 不影响）
    //   2. panelThemeRevision 被 bump（用户手动改了 settings.theme）
    // AnimatedBuilder 内部 setState，外层 PanelApp 不会重建。
    return AnimatedBuilder(
      animation: Listenable.merge([systemBrightness, panelThemeRevision]),
      builder: (context, _) {
        final light = effectiveBrightness(state.settings) == Brightness.light;
        return FluentApp(
          debugShowCheckedModeBanner: false,
          title: 'Vectra 设置',
          color: light ? const Color(0xFFF3F3F6) : const Color(0xFF171B1B),
          // FluentApp 默认就会带上 FluentLocalizations + Material/Cupertino/Widgets
          // 三套 Global delegates 和它的 supportedLocales（含 zh_CN），不用自己再传
          locale: const Locale('zh', 'CN'),
          theme: FluentThemeData(
            brightness: light ? Brightness.light : Brightness.dark,
            fontFamily: 'TsukushiBMaru',
            // 主色沿用磁贴那套天蓝：浅色下加深一档，保证对比度
            accentColor: AccentColor.swatch({
              'normal':
                  light ? const Color(0xFF1565C0) : const Color(0xFF7CC7FF),
            }),
            scaffoldBackgroundColor:
                light ? const Color(0xFFF3F3F6) : const Color(0xFF171B1B),
          ),
          home: ScaffoldPage(
            padding: EdgeInsets.zero,
            content: ValueListenableBuilder<int?>(
              valueListenable: panelTabRequest,
              builder: (context, tab, _) => ValueListenableBuilder<String?>(
                valueListenable: panelCardRequest,
                builder: (context, cardId, _) => ControlPanel(
                  // 换页/换定位卡片时重建，其余时候不动
                  key: ValueKey('panel:$tab:$cardId'),
                  state: state,
                  store: store,
                  registry: registry,
                  focusCardId: cardId,
                  initialTab: tab,
                  // 独立窗口里不要遮罩、不要固定尺寸、不要自绘关闭按钮
                  embedded: false,
                  onHotkeyChanged: () => appKey.currentState?.applyHotkey(),
                  onClose: () => appKey.currentState?.hidePanelWindow(),
                  onChanged: () => appKey.currentState?.onPanelChanged(),
                  onAdd: (plugin) => appKey.currentState?.addCard(plugin),
                  // 每块屏都放过这种组件了就不让再加。判断要用磁贴那边的显示器
                  // 信息，所以问 appKey 而不是在面板里自己算。
                  canAdd: (pluginId) =>
                      appKey.currentState?.canAddPlugin(pluginId) ?? true,
                  onRemove: (card) => appKey.currentState?.removeCard(card),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
