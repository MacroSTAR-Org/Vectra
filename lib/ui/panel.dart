/// 控制面板：组件库 / 已放置 / 外观 / 单个组件的设置。
///
/// 它活在任务栏里那个独立窗口中（见 panel_app.dart / panel_window.h），但和
/// 桌面磁贴共用同一个引擎、同一个 isolate —— 所以下面这些设置项仍然是就地改
/// AppState 里的对象，不需要任何跨进程同步。
///
/// 窗口是无边框自绘的：顶部一条自绘标题栏（拖动/最小化/最大化/关闭走 native），
/// 下面是图标化标签页。控件全部用 fluent_ui（Windows 11 风格），
/// 分组卡片统一用主色强调。
///
/// embedded=true 是旧的内嵌形态（遮罩 + 居中盒子），保留只是为了别把那条
/// 代码路径悄悄弄坏，正常运行时走不到。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../core/app_version.dart' show appVersion;
import '../core/logger.dart';
import '../core/paths.dart';
import '../core/theme.dart';
import 'card_view.dart';
import '../widgets/kit.dart' show iconDataFor;
import '../widgets/spec.dart';
import '../core/updater.dart';
import '../model/card.dart';
import '../model/settings.dart';
import '../native/native_bridge.dart';
import '../store/store.dart';
import 'panel_app.dart' show panelThemeRevision;
import 'window_chrome.dart';
import 'panel_preview.dart';
import 'wallpaper.dart';

/// 全局统一的主色与材质，跟磁贴/侧边栏同一套语言
/// （主题蓝放 _PanelColors.accent 里按深浅色翻转）
/// 面板统一圆角：Win11 设置的设置卡片是 8px，跟着走
const double _kRadius = 8;

/// 面板自身的一套颜色，按深浅色翻转。
///
/// 深色：深底 + 白字；浅色：浅底 + 近黑字。做法和卡片 _foreground 一致，
/// 生效明暗由 effectiveBrightness 决定（auto 跟随系统、显式主题强制覆盖）。
/// 面板以前只有深色一套，颜色全是写死的白色系 alpha —— 直接搬过来。
class _PanelColors {
  const _PanelColors(this.light);

  /// 生效的明暗（true = 浅色）
  final bool light;

  /// 窗口底色
  Color get bg => light ? Color(0xFFF3F3F6) : Color(0xFF171B1B);

  /// 主文字
  Color get ink => light ? Color(0xFF16181C) : Color(0xFFFFFFFF);

  Color get ink70 =>
      light ? Color(0xB316181C) : Color(0xB3FFFFFF);
  Color get ink60 =>
      light ? Color(0x9916181C) : Color(0x99FFFFFF);
  Color get ink54 =>
      light ? Color(0x8A16181C) : Color(0x8AFFFFFF);
  Color get ink38 =>
      light ? Color(0x6116181C) : Color(0x61FFFFFF);
  Color get ink30 =>
      light ? Color(0x4D16181C) : Color(0x4DFFFFFF);
  Color get ink24 =>
      light ? Color(0x3D16181C) : Color(0x3DFFFFFF);

  /// 卡片底/边框：Win11 设置风格的**实色**卡片（浅色纯白 / 深色比底色亮一档）
  Color get card => light ? Color(0xFFFFFFFF) : Color(0xFF23292B);
  Color get cardBorder =>
      light ? Color(0x14000000) : Color(0x1FFFFFFF);

  /// 侧边栏导航项的悬停 / 选中底（Win11 那种浅灰胶囊）
  Color get navHover =>
      light ? Color(0x0A000000) : Color(0x0AFFFFFF);
  Color get navSelected =>
      light ? Color(0x14181C1C) : Color(0x1FFFFFFF);

  /// 未选中 chip / 分隔线的底（白 8% ↔ 黑 8%）
  Color get chipBg =>
      light ? Color(0x14000000) : Color(0x14FFFFFF);

  /// 图标圆底（白 6% ↔ 黑 6%）
  Color get iconTile =>
      light ? Color(0x0F000000) : Color(0x0FFFFFFF);

  /// 主题蓝：深色用亮蓝、浅色用深蓝，保证同样的对比度。
  /// 主色（选中态底色/描边/文字高亮），深浅色下观感一致但深浅相反。
  Color get accent => light ? Color(0xFF1565C0) : Color(0xFF7CC7FF);
  Color get accentSoft => light ? Color(0xFF1E6FC4) : Color(0xFF9BD9FF);

  /// 选中态的底（accent 的 20%）
  Color get accentBg =>
      light ? Color(0x331565C0) : Color(0x334FC7FF);

  /// 选中态的描边（accent 的 33%）
  Color get accentBorder =>
      light ? Color(0x551565C0) : Color(0x557CC7FF);

  /// 分组小标题图标/标题用的 accent 变体
  Color get accentIcon =>
      light ? Color(0xAA1565C0) : Color(0xAA7CC7FF);

  /// 第三方徽章的底
  Color get badgeBg =>
      light ? Color(0x331565C0) : Color(0x334FC3F7);

  /// 错误文字：更新失败之类。深浅色下都保证和背景拉开。
  Color get danger => light ? Color(0xFFC62828) : Color(0xFFFF8A80);
}

class ControlPanel extends StatefulWidget {
  const ControlPanel({
    super.key,
    required this.state,
    required this.store,
    required this.onClose,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
    this.canAdd,
    this.focusCardId,
    this.initialTab,
    this.onInstallUpdate,
    this.embedded = true,
  });

  /// true = 画在磁贴那个全屏窗口里（旧行为：遮罩 + 居中的固定尺寸盒子）
  /// false = 独立窗口，窗口边框由系统负责，这里只管铺满客户区
  final bool embedded;

  final AppState state;
  final Store store;
  final VoidCallback onClose;

  /// 任何改动后通知外层重建并推送新的命中区
  final VoidCallback onChanged;
  final void Function(BuiltinSpec plugin) onAdd;
  final void Function(WidgetCard card) onRemove;

  /// 这种组件还能不能再加（每块屏最多一个）。
  /// 需要显示器信息，只有磁贴那边算得了，所以由外面传进来；
  /// 不传时一律放行（内嵌形态和测试里用）。
  final bool Function(String pluginId)? canAdd;

  /// 从卡片右键进来时，直接定位到该卡片的设置
  final String? focusCardId;

  /// 指定打开时停在哪一页（托盘/卡片右键的跳转用）
  final int? initialTab;

  /// 安装应用更新（保存退出 → 拉起静默安装器）。由磁贴侧 AppRoot 提供，
  /// 不传时（内嵌/测试）点了没反应。
  final Future<bool> Function(String installerPath)? onInstallUpdate;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  late int _tab = widget.initialTab ?? (widget.focusCardId != null ? 1 : 0);

  /// 顶部搜索框：内容与焦点
  final TextEditingController _searchCtrl = TextEditingController();

  /// 每页一个滚动控制器。中键自动滚动要推位置（见 [_onAutoScrollMove]），
  /// 必须自己持有；按 tab 缓存，换页回来还在原来的位置。
  final Map<int, ScrollController> _pageScroll = {};

  /// 中键自动滚动状态（Windows 资源管理器/浏览器里那个行为）。
  bool _autoScrolling = false;
  Offset? _autoScrollOrigin;
  double _autoScrollBase = 0;
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  /// 关于页的版本信息；异步加载，未就绪时显示"获取中…"
  PackageInfo? _pkgInfo;

  /// 自定义卡片颜色取色器的草稿值；为 null 表示目前没有打开对话框
  Color? _pickedColor;

  /// 开机自启当前状态；null 表示还在问 native
  bool? _autoStart;

  /// 「其他」页底部的一行操作结果反馈（导出到哪了 / 导入失败原因）
  String? _backupHint;
  bool _backupFailed = false;

  /// 上一次已确认的生效亮度；用户手动切换主题/翻转系统深浅色时更新。
  /// 与 panelThemeRevision 配合：只在亮度真的变了才 bump，避免 Slider 拖动
  /// 也去重建整棵 FluentApp。
  Brightness? _lastBrightness;

  AppSettings get _s => widget.state.settings;

  /// 面板配色：随生效明暗翻转（auto 跟系统，显式主题强制覆盖）
  _PanelColors get _c =>
      _PanelColors(effectiveBrightness(_s) == Brightness.light);

  @override
  void initState() {
    super.initState();
    _lastBrightness = effectiveBrightness(_s);
    // 先拍一张基线，否则第一次改动会把所有设置项都算成"变了"
    _settingsSnapshot = widget.state.settings.toJson();
    Log.i('panel', '打开设置窗口（页 $_tab）');
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _pkgInfo = info);
    });
    NativeBridge.isAutoStart().then((on) {
      if (mounted) setState(() => _autoStart = on);
    });
  }

  /// 面板里改了任何设置。
  ///
  /// 界面自己立刻更新，但通知外层的那一下必须去抖：外层的 onChanged 会让
  /// _revision 自增，从而**把所有插件卡片的 QuickJS 运行时全部销毁重建**，
  /// 还会重新截屏 + 高斯模糊算壁纸。而 Slider 的 onChanged 是拖动期间每帧
  /// 都触发的——拖一下滑块就是每秒几十次全量重建，界面直接卡死。
  ///
  /// store.save 本身已经有 300ms 去抖，所以这里只需要拦住 onChanged。
  /// 上一次记过日志的设置快照，用来算出"这次到底改了哪一项"
  Map<String, Object?> _settingsSnapshot = const {};

  /// 把设置改动记成"键: 旧值 -> 新值"。
  ///
  /// 用快照对比而不是在每个控件的回调里各写一行：设置项有几十个，靠人肉埋点
  /// 迟早漏，而且插件市场以后还会带进来新的。这里一次对比全覆盖，
  /// 以后加设置项也不用管日志。
  void _logSettingsDiff() {
    final now = widget.state.settings.toJson();
    if (_settingsSnapshot.isEmpty) {
      _settingsSnapshot = now;
      return;
    }
    final changed = describeSettingsDiff(_settingsSnapshot, now);
    if (changed.isNotEmpty) {
      Log.i('panel', '改设置 ${changed.join("；")}');
    }
    _settingsSnapshot = now;
  }

  void _commit() {
    _logSettingsDiff();
    widget.store.save(widget.state);
    setState(() {});
    // 立刻检查生效亮度：手动切换主题时希望面板外壳（背景 / fluent 控件的
    // 主题色）跟着变，不必等 260ms 去抖。
    _maybeBumpThemeRevision();
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 260), () {
      _commitTimer = null;
      // 去抖后再兜一次：系统深浅色切换不会走 setState，可能正好在这期间翻转
      _maybeBumpThemeRevision();
      if (mounted) widget.onChanged();
    });
  }

  void _maybeBumpThemeRevision() {
    final now = effectiveBrightness(_s);
    if (now != _lastBrightness) {
      _lastBrightness = now;
      panelThemeRevision.value++;
    }
  }

  Timer? _commitTimer;

  @override
  void dispose() {
    // 面板关掉时还欠着一次通知，补上——否则最后那次改动要等下次才生效
    if (_commitTimer?.isActive ?? false) {
      _commitTimer!.cancel();
      widget.onChanged();
    }
    _searchCtrl.dispose();
    _searchFocus.dispose();
    for (final c in _pageScroll.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Win11 设置布局：无边框自绘标题栏（最顶，中间有"查找设置"）+
    // 左侧栏 + 右侧内容。内容按选中项构建，不会同时建多页。
    final body = Column(
      children: [
        // 无边框窗口的自绘标题栏；内嵌模式没有独立窗口，不需要
        if (!widget.embedded) _titleBar(),
        Expanded(child: _navigation()),
      ],
    );

    // 搜索结果浮层挂在 body 上层的 Stack 里，从标题栏正下方弹出。
    // 放在 Column 外面（Positioned），弹出时不把内容往下顶。
    //
    // 最底下垫的是亚克力层（见 [_acrylicBackdrop]）：设置窗口的背景不再是
    // panel_app 给的那块实色，而是模糊桌面 + 主题 tint，Windows 设置那种质感。
    final layered = Stack(
      fit: StackFit.expand,
      children: [
        if (!widget.embedded) _acrylicBackdrop(),
        body,
        ...[
          if (!widget.embedded) _searchResultsPanel() ?? const SizedBox.shrink(),
        ],
      ],
    );

    // 独立窗口：铺满客户区，底色由 panel_app 负责。
    // 四周叠一圈缩放手柄——这窗口没有系统缩放边框（见 panel_window.cpp）。
    if (!widget.embedded) {
      // fit 用 expand：Stack 的子节点全是 Positioned 时，它自己会塌缩到约束
      // 允许的最小尺寸，手柄就跟着缩没了（surface.dart 里踩过同样的坑）
      return Stack(fit: StackFit.expand, children: [
        layered,
        ...resizeHandles(NativeWindow.panel),
        ...resizeHandles(NativeWindow.panel),
        // 描边。窗口是无边框的，浅色主题下面板底色和浅色桌面/浅色应用背景
        // 挨在一起时几乎分不出边界，一圈淡黑色才能把窗口"框"出来。
        //
        // 圆角半径要和 native 那边对齐：panel_window.cpp 的 kCornerRadiusLogical
        // 是 12，窗口本身就被裁成这个圆角，画大画小都会露馅。
        //
        // 必须 IgnorePointer：它铺满整个窗口且盖在最上层，不挡住指针的话
        // 缩放手柄和界面全都点不到了。
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0x38000000)),
                ),
              ),
            ),
          ),
        ),
      ]);
    }

    // 内嵌模式（保留是为了别把这条路径悄悄弄坏）：遮罩 + 居中盒子
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(color: Color(0x99000000)),
          ),
        ),
        Center(
          child: Container(
            width: 720,
            height: 560,
            decoration: BoxDecoration(
              color: Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _c.cardBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: body,
          ),
        ),
      ],
    );
  }

  // ---------------- Win11 设置风格的导航壳 ----------------

  /// 导航元数据（图标 + 标题）。**顺序即索引**：其他 3、关于 4——
  /// 托盘的 openPanel(tab:) 按这个下标写死，别动。
  static const List<(int, IconData, String)> _navItems = [
    (0, Icons.widgets_outlined, '组件库'),
    (1, Icons.grid_view_outlined, '已放置'),
    (2, Icons.palette_outlined, '外观'),
    (3, Icons.tune_outlined, '其他'),
  ];

  Widget _navigation() {
    // Win11 设置布局：左侧侧栏（品牌卡 + 导航列表 + 底部固定项），中间一条
    // 分隔线（兼拖拽手柄），右侧内容区只建当前选中页。
    //
    // 侧栏宽度以前写死 256，反馈里"侧边栏拖不动"就是它——那条 1px 分隔线
    // 只是个装饰 Container，没有任何指针处理，拖上去自然毫无反应。现在把
    // 分隔线换成有热区的拖拽手柄（见 [_sidebarResizer]），宽度交给 [_sideW]。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sidebar(),
        _sidebarResizer(),
        Expanded(child: _pageSwitcher()),
      ],
    );
  }

  // ---------------- 侧栏拖拽调宽 ----------------

  /// 侧栏宽度的上下限（逻辑像素）。
  ///
  /// 下限 180：再窄的话「外观」「已放置」这些两字标签加上缩进就贴边了。
  /// 上限 420：接近内容区一半，再宽就把设置项挤成细条，不如直接不拖。
  static const double _sideMin = 180;
  static const double _sideMax = 420;

  /// 手柄自身的可点宽度。视觉上仍然是 1px 发丝线，但热区给到 7px——
  /// 1px 的线用鼠标去精确瞄准是折磨，[MouseRegion] 的 cursor 会提示这里能拖。
  static const double _sideHandleHit = 7;

  /// 侧栏当前宽度。拖动期间直接改它并 setState，落手时写进设置持久化。
  late double _sideW = _s.sidebarWidth.clamp(_sideMin, _sideMax);

  /// 拖动会话的起点：按下时的指针 x 与当时的侧栏宽度。
  /// 用「起点 + 位移」而不是「指针 - 窗口左边」——后者在拖动中窗口若被
  /// 系统移动会整体漂移，手感会突然跳一下。
  double? _sideDragStartX;
  double _sideDragStartW = 0;

  void _onSideDragStart(DragStartDetails d) {
    _sideDragStartX = d.globalPosition.dx;
    _sideDragStartW = _sideW;
  }

  void _onSideDragUpdate(DragUpdateDetails d) {
    final x0 = _sideDragStartX;
    if (x0 == null) return;
    final next = (_sideDragStartW + (d.globalPosition.dx - x0))
        .clamp(_sideMin, _sideMax);
    if (next == _sideW) return;
    setState(() => _sideW = next);
  }

  void _onSideDragEnd(DragEndDetails d) {
    _sideDragStartX = null;
    // 落手才写盘：拖动过程中每帧都存一次会把磁盘刷成筛子
    _s.sidebarWidth = _sideW;
    widget.onChanged();
  }

  /// 双击手柄复位到默认宽度（和拖拽条双击还原一个习惯）
  void _resetSideWidth() {
    setState(() => _sideW = kSidebarWidthDefault);
    _s.sidebarWidth = _sideW;
    widget.onChanged();
  }

  /// 拖拽手柄：1px 发丝线 + 左右各 3px 热区，悬停/拖动时整条亮起主色。
  ///
  /// 用 [GestureDetector] 的横向拖拽而不是 [Listener] 原始指针：
  /// 横向 DragGestureRecognizer 会和内容区的纵向滚动竞争，方向判定后
  /// 只有真正横拖才被这里吃掉，垂直滚动照常穿透到下面的列表。
  Widget _sidebarResizer() {
    final hot = _sideDragStartX != null;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onSideDragStart,
        onHorizontalDragUpdate: _onSideDragUpdate,
        onHorizontalDragEnd: _onSideDragEnd,
        onDoubleTap: _resetSideWidth,
        child: SizedBox(
          width: _sideHandleHit,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              width: hot ? 2 : 1,
              color: hot ? _c.accentBorder : _c.chipBg,
            ),
          ),
        ),
      ),
    );
  }

  /// 当前页内容。按需懒构建——以前每次 setState 会把 5 个页面全构建一遍，
  /// 只挂一页也是白费力气。
  Widget _currentPage() => switch (_tab) {
        0 => _pageFrame('组件库', _library()),
        1 => _pageFrame('已放置', _placed()),
        2 => _pageFrame('外观', _appearance()),
        3 => _pageFrame('其他', _other()),
        _ => _pageFrame('关于', _about()),
      };

  /// 页面切换动画：淡入 + 轻微上移（Win11 设置换页时的那种感觉）。
  ///
  /// 进和出用**不对称**的节奏：新页 200ms 缓动入场，旧页 100ms 快速
  /// 淡出（easeInCubic 起手就猛退）。AnimatedSwitcher 默认新旧交叉淡变
  /// 且时长相同，旧页文字会几乎全程挂在新页上——"切换时字体留存过久"
  /// 就是对称交叉淡变留下的残影，缩短 reverseDuration 并加速退场解决。
  Widget _pageSwitcher() {
    // 窗口最右边 6px 铺着缩放手柄（见 window_chrome.dart 的 resizeHandles，
    // behavior: opaque），而 Flutter 默认把滚动条**紧贴 viewport 边缘**——整条
    // 被手柄盖住，只有贴边那 1~2px 能点到，反馈里"滚动条根本点不到"就是它。
    // 这里让滚动条往里收 10px 并加粗，彻底离开手柄的地盘。
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        // Win11 设置同款：平时 4px 细线（常显），hover/拖住加粗到 10px 好抓。
        //
        // 反馈说滚动条"判定不好、会突然伸出来一下"——那是 fluent 滚动条的
        // hover 态默认值在搞事：hoveringThickness 默认 16（比静止粗 6px），
        // hoveringCrossAxisMargin / hoveringMainAxisMargin 默认 0（条向外跳
        // 10px、两端还各伸长一截），expandContractAnimationDuration 默认
        // Duration.zero（跳变不带动画）。滚动条的热区是"厚度+两侧边距"共
        // 20px 宽的右缘竖条，鼠标扫过右缘（外观页一整排滑块就在边上）它就
        // 瞬间加粗外跳，看起来像"突然伸出来"。把三个 hovering* 钉成与静止
        // 同值（厚度除外）+ 给展开动画 120ms，hover 只加粗、不挪窝不变长。
        thickness: 4,
        hoveringThickness: 10,
        crossAxisMargin: 10,
        hoveringCrossAxisMargin: 10,
        mainAxisMargin: 2,
        hoveringMainAxisMargin: 2,
        radius: const Radius.circular(5),
        hoveringRadius: const Radius.circular(5),
        minThumbLength: 48,
        expandContractAnimationDuration: const Duration(milliseconds: 120),
        contractDelay: const Duration(milliseconds: 200),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        reverseDuration: const Duration(milliseconds: 100),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // 透明度线性（时长由 duration/reverseDuration 控制）；缓动曲线只给
          // 位移。旧页退场时如果透明度也走 easeOutCubic，反向播放会在接近
          // 完全不透明处滞留到最后一刻——"字体留存"就是这么来的。
          final slide = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.012),
                end: Offset.zero,
              ).animate(slide),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey('page:$_tab'),
          child: _currentPage(),
        ),
      ),
    );
  }

  /// 面板窗口的亚克力底。
  ///
  /// native 的 WCA 亚克力在这台 Win10 上渲染成整窗透明、还拖慢合成
  /// （view_window.cpp 里有实测记录），所以走磁贴卡片同一套路：拿
  /// [Wallpaper.image] 那张**预模糊的桌面截图**铺满窗口最底层，上面压一层
  /// 主题色 tint——模糊桌面 + 半透明着色，观感就是 Windows 设置那种
  /// Mica/亚克力方向。壁纸还没就绪时退回纯 tint，不会闪出一帧透明。
  ///
  /// tint 的不透明度刻意压得很高（壁纸只透出一成多一点）：透太多会跟卡片
  /// 底色抢，文字对比度也保不住。桌面壁纸一换（Wallpaper.image 是
  /// ValueNotifier），这里的背景就跟着变，和真亚克力"透出桌面"的语义一致。
  Widget _acrylicBackdrop() {
    final tint = _c.light ? const Color(0xE9F3F3F6) : const Color(0xEA171B1B);
    return Positioned.fill(
      child: ValueListenableBuilder<ui.Image?>(
        valueListenable: Wallpaper.image,
        builder: (context, img, _) {
          if (img == null) return ColoredBox(color: tint);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // cover：等比铺满、超出裁掉，别把壁纸拉变形
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: img.width.toDouble(),
                    height: img.height.toDouble(),
                    child: RawImage(image: img, fit: BoxFit.fill),
                  ),
                ),
                ColoredBox(color: tint),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sidebar() {
    return SizedBox(
      // 宽度由拖拽手柄控制（见 [_sidebarResizer]），双击手柄可复位
      width: _sideW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _brandCard(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              children: [
                for (final (index, icon, title) in _navItems)
                  _navItem(index, icon, title,
                      // 已放置的卡片数量跟在标题后面，和旧导航栏的信息一致
                      trailing: index == 1 && widget.state.cards.isNotEmpty
                          ? '${widget.state.cards.length}'
                          : null),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: _navItem(4, Icons.info_outline, '关于'),
          ),
        ],
      ),
    );
  }

  /// 侧栏顶部的品牌卡（对应 Win11 设置里的账户卡：头像 + 名称 + 说明）
  Widget _brandCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/logo.png',
                width: 38, height: 38, filterQuality: FilterQuality.medium),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Glance · 一瞥',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _c.ink)),
                const SizedBox(height: 2),
                Text('v$appVersion · 桌面磁贴',
                    style: TextStyle(fontSize: 11, color: _c.ink54)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 导航项：Win11 那种浅灰胶囊选中态（选中图标用主色，悬停浅浅一层），
  /// 左侧一条主色小指示条随选中伸缩。全部动画用 easeOutCubic 缓动，
  /// 起步快、收尾减速，跟 Win11 系统应用同一个节奏。
  Widget _navItem(int index, IconData icon, String title, {String? trailing}) {
    final selected = _tab == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HoverButton(
        onPressed: () => setState(() => _tab = index),
        builder: (context, states) {
          final Color bg;
          if (selected) {
            bg = _c.navSelected;
          } else if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)) {
            bg = _c.navHover;
          } else {
            bg = Colors.transparent;
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // Win11 的选中指示条：3px 宽的圆头小竖条，选中时长出来
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  width: 3,
                  height: selected ? 16 : 0,
                  margin: EdgeInsets.only(right: selected ? 9 : 0),
                  decoration: BoxDecoration(
                    color: _c.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(icon,
                    size: 18, color: selected ? _c.accent : _c.ink60),
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? _c.ink : _c.ink70),
                    child: Text(title),
                  ),
                ),
                if (trailing != null)
                  Text(trailing,
                      style: TextStyle(fontSize: 11, color: _c.ink38)),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------- 设置搜索 ----------------

  /// 搜索索引：关键词 -> 页面。纯静态表，加新分组时顺手补一行就行。
  /// 做成"关键词集合"而不是精确标题：中文没有前缀匹配的必要，
  /// 搜"备份"、"启动"这类词能直接命中分组才是想要的体验。
  static const List<(String, int, String)> _searchIndex = [
    ('组件 插件 添加 组件库 市场 预览 第三方', 0, '组件库'),
    ('已放置 卡片 尺寸 移除 删除 布局', 1, '已放置'),
    ('外观 网格 间距 吸附 对齐 锁定 动画 材质 毛玻璃 云母 圆角 透明度 '
        '底色 颜色 取色 莫奈 主题 深色 浅色 壁纸 刷新 模糊', 2, '外观'),
    ('更新 升级 版本 检查更新 下载 更新源 自动下载 自启 开机启动 启动 '
        '日志 备份 导出 导入 恢复', 3, '其他'),
    ('关于 版本 作者', 4, '关于'),
  ];

  List<(String, int)> get _searchResults {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final (keywords, tab, label) in _searchIndex)
        if (keywords.toLowerCase().contains(q) ||
            label.toLowerCase().contains(q))
          (label, tab),
    ];
  }

  /// 标题栏中间的搜索框（"查找设置"那个位置的的东西）
  Widget _searchBox() {
    return SizedBox(
      width: 300,
      height: 30,
      child: TextBox(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        placeholder: '查找设置',
        prefix: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Icon(Icons.search, size: 14, color: _c.ink38),
        ),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  /// 搜索结果浮层：标题栏正下方拉出一个卡片，点结果跳页。
  /// 出现时是淡入 + 轻微上提的非线性动画，不是"啪"地闪现。
  Widget? _searchResultsPanel() {
    final results = _searchResults;
    if (results.isEmpty || !_searchFocus.hasFocus) return null;
    return Positioned(
      top: 48,
      left: 0,
      right: 0,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: child,
            ),
          ),
          child: Container(
            width: 380,
            decoration: BoxDecoration(
              color: _c.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _c.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (label, tab) in results)
                  _searchResultRow(label, tab),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchResultRow(String label, int tab) {
    return HoverButton(
      onPressed: () {
        setState(() {
          _tab = tab;
          _query = '';
          _searchCtrl.clear();
          _searchFocus.unfocus();
        });
      },
      builder: (context, states) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: states.contains(WidgetState.hovered)
              ? _c.navHover
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(Icons.search, size: 13, color: _c.ink38),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12.5, color: _c.ink70))),
          Icon(Icons.chevron_right, size: 12, color: _c.ink24),
        ]),
      ),
    );
  }

  /// 内容页的标准骨架：大标题 + 可滚动内容（Win11 设置那种 28px 页题）
  Widget _pageFrame(String title, Widget content) {
    // 把这一页的 controller 塞进 PrimaryScrollController：页里的 ListView
    // 没显式给 controller，会自己吃下这一个，外面就能拿它推位置。
    return PrimaryScrollController(
      controller: _pageScroll.putIfAbsent(_tab, ScrollController.new),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 10),
            child: Text(title,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: _c.ink)),
          ),
          // 中键自动滚动的拾取层：包在页面内容外面。translucent 保证指针事件
          // 照常往下传给 ListView，正常滚动和点击都不受影响。
          Expanded(
            child: MouseRegion(
              cursor: _autoScrolling
                  ? SystemMouseCursors.grabbing
                  : MouseCursor.defer,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onAutoScrollDown,
                onPointerMove: _onAutoScrollMove,
                onPointerUp: _onAutoScrollEnd,
                onPointerCancel: _onAutoScrollEnd,
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 中键自动滚动 ----------------

  /// 中键按下：记下起点和当时的滚动位置，进入自动滚动。
  ///
  /// 反馈 Fb0007 —— 提反馈的人滚轮是坏的，页面只能靠中键拖着翻，
  /// 滚动条又点不到。所以补一个 Windows 上很常见但这里一直缺的自动滚动。
  /// 4 = Flutter 的 kMiddleButton（buttons 位掩码）。
  void _onAutoScrollDown(PointerDownEvent e) {
    if ((e.buttons & 4) == 0) return;
    final ctrl = _pageScroll[_tab];
    if (ctrl == null || !ctrl.hasClients) return;
    setState(() {
      _autoScrolling = true;
      _autoScrollOrigin = e.position;
      _autoScrollBase = ctrl.position.pixels;
    });
  }

  void _onAutoScrollMove(PointerMoveEvent e) {
    if (!_autoScrolling || _autoScrollOrigin == null) return;
    final ctrl = _pageScroll[_tab];
    if (ctrl == null || !ctrl.hasClients) return;
    final dy = e.position.dy - _autoScrollOrigin!.dy;
    // 鼠标往下拖 = 内容往上走 = 视口位置变大，和 Windows 自动滚动同向。
    // 1.8 倍是手感值：1:1 太黏，太大容易飘。
    final target = _autoScrollBase + dy * 1.8;
    ctrl.jumpTo(target.clamp(
        ctrl.position.minScrollExtent, ctrl.position.maxScrollExtent));
  }

  void _onAutoScrollEnd(PointerEvent e) {
    if (!_autoScrolling) return;
    setState(() {
      _autoScrolling = false;
      _autoScrollOrigin = null;
    });
  }

  // ---------------- 标题栏（无边框窗口专用） ----------------

  Widget _titleBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _c.chipBg)),
      ),
      child: Stack(children: [
        // 左侧品牌 + 可拖区域。搜索框是 Stack 里的独立兄弟节点，压在
        // 拖动区上方——TextBox 命中时事件到不了下面的拖动 Listener，
        // 搜索框里点按就不会把窗口拖走。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onTitleDrag,
            child: Row(children: [
              const SizedBox(width: 16),
              Image.asset('assets/logo.png',
                  width: 16, height: 16,
                  filterQuality: FilterQuality.medium),
              const SizedBox(width: 8),
              Text('Glance 设置',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _c.ink)),
            ]),
          ),
        ),
        // 标题栏正中的搜索框（对齐 Win11 设置的"查找设置"位置）
        Align(
          alignment: Alignment.center,
          child: _searchBox(),
        ),
        // 右上角窗口按钮
        Positioned(
          right: 4,
          top: 0,
          bottom: 0,
          child: Row(children: [
            WindowButton(
              icon: Icons.minimize_rounded,
              tooltip: '最小化',
              light: _c.light,
              onTap: () => NativeWindow.panel.minimize(),
            ),
            WindowButton(
              icon: Icons.crop_square_rounded,
              tooltip: '最大化 / 还原',
              light: _c.light,
              onTap: () => NativeWindow.panel.toggleMaximize(),
            ),
            WindowButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              light: _c.light,
              danger: true,
              onTap: widget.onClose,
            ),
          ]),
        ),
      ]),
    );
  }

  void _onTitleDrag(PointerDownEvent e) =>
      beginWindowDrag(NativeWindow.panel, e);

  // ---------------- 组件库 ----------------

  Widget _library() {
    final plugins = builtinCatalog();
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      children: [
        _group(
          title: '组件',
          icon: Icons.widgets_outlined,
          children: [
            if (plugins.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                    child: Text('没有可用的插件',
                        style: TextStyle(color: _c.ink30, fontSize: 12))),
              )
            else
              // 统一磁贴：概览图全部按同一块 4x4 画布渲染（见
              // panel_preview.dart 的 kPreviewGrid），预览区因此统一成 1:1——
              // 时钟、天气、日历摆在一起终于一样大，字体缩放基准也一致。
              //
              // 布局用 Wrap 而不是 GridView：列宽由容器宽度决定（3/2/1 列），
              // 磁贴高度 = 预览区（随列宽走、单列时封顶）+ 信息区定高。
              // 单列时磁贴太宽，预览区若不封顶，图会被撑得离谱。
              LayoutBuilder(
                builder: (context, box) {
                  final cols = box.maxWidth > 920
                      ? 3
                      : box.maxWidth > 520
                          ? 2
                          : 1;
                  const gap = 14.0;
                  const infoH = 104.0;
                  final tileW = (box.maxWidth - (cols - 1) * gap) / cols;
                  // 预览区边长 ≈ 列宽（方形）；只有单列超宽时封顶
                  final previewH = tileW.clamp(220.0, 420.0);
                  Widget tile(BuiltinSpec p) => SizedBox(
                        width: tileW,
                        height: previewH + infoH,
                        child: _pluginCard(p),
                      );

                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [for (final p in plugins) tile(p)],
                  );
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '组件内置在应用里，随版本一起更新。',
            style: TextStyle(color: _c.ink30, fontSize: 11, height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _pluginCard(BuiltinSpec p) {
    final placed = widget.state.cards.where((c) => c.pluginId == p.id).length;
    // singleton 随清单一并移除；内置组件允许多开，唯一限制是"每块屏最多一个"
    final screenFull = !(widget.canAdd?.call(p.id) ?? true);
    final blocked = screenFull;
    return _TileHover(
      child: Container(
        decoration: BoxDecoration(
          color: _c.card,
          borderRadius: BorderRadius.circular(_kRadius),
          border: Border.all(color: _c.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 预览井：比卡片底色深/浅一档的"展台"，概览图坐在正中——
            // 图自带底色和发丝描边（见 BuiltinPreview），和井底自然分层，
            // 轮廓清晰又不会像被硬贴上去。
            Expanded(
              child: ColoredBox(
                color: _c.light
                    ? const Color(0x08000000)
                    : const Color(0x2E000000),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: ClipRect(
                    child: SizedBox.expand(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: BuiltinPreview(
                          key: ValueKey('preview:${p.id}'),
                          spec: p,
                          light: _c.light,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 信息区定高：预览区吃掉剩余高度，任何卡片宽度下信息排布一致
            SizedBox(
              height: 104,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _c.ink)),
                        ),
                        const SizedBox(width: 6),
                        // 版本做成小胶囊徽章：元信息的"身份"一眼可辨，
                        // 也不会和标题抢视觉重量
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _c.chipBg,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('v${p.version}',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  height: 1.15,
                                  color: _c.ink54)),
                        ),
                      ],
                    ),
                    if (p.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(p.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: _c.ink38)),
                    ],
                    const Spacer(),
                    Row(children: [
                      if (placed > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _c.accentBg,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('已放置 $placed',
                              style: TextStyle(
                                  fontSize: 10,
                                  height: 1.2,
                                  color: _c.accentSoft)),
                        ),
                      const Spacer(),
                      Tooltip(
                        message: screenFull
                            ? '该组件每块屏幕最多放置一个'
                            : '添加到桌面',
                        child: FilledButton(
                          onPressed: blocked
                              ? null
                              : () {
                                  widget.onAdd(p);
                                  // 导航项标题上有已放置数量，添加后要刷新
                                  if (mounted) setState(() {});
                                },
                          child: Text(
                              screenFull ? '每屏一个' : '添加',
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 已放置 ----------------

  Widget _placed() {
    final cards = widget.state.cards;
    if (cards.isEmpty) {
      return Center(
          child: Text('还没有放置任何组件',
              style: TextStyle(color: _c.ink30, fontSize: 12)));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      children: [for (final c in cards) _cardRow(c)],
    );
  }

  Widget _cardRow(WidgetCard card) {
    final plugin = builtinSpecById(card.pluginId);
    final expanded = widget.focusCardId == card.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _c.card,
        borderRadius: BorderRadius.circular(_kRadius),
        border: Border.all(
            color: expanded ? _c.accentBorder : _c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _c.iconTile,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                // spec.icon 是 iconDataFor 的语义名，用 Icon 渲染——
                // 以前直接 Text(emoji)，'✓' 这类符号字形缺失就成方框
                child: Icon(iconDataFor(plugin?.icon),
                    size: 18, color: _c.ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(plugin?.name ?? card.pluginId,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _c.ink)),
              ),
              Tooltip(
                message: '移除',
                child: IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: _c.ink38),
                  onPressed: () {
                    widget.onRemove(card);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bgPicker(card),
          if (plugin != null) ...[
            const SizedBox(height: 8),
            _sizePicker(card, plugin),
            if (plugin.settings.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(height: 1, color: _c.chipBg),
              const SizedBox(height: 10),
              for (final f in plugin.settings) _settingField(card, f),
            ],
          ],
        ],
      ),
    );
  }

  Widget _sizePicker(WidgetCard card, BuiltinSpec plugin) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in plugin.sizes)
          GestureDetector(
            onTap: () {
              card.size = s;
              _commit();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: card.size == s
                    ? _c.accentBg
                    : _c.chipBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(s,
                  style: TextStyle(
                      fontSize: 11,
                      color: card.size == s ? _c.accentSoft : _c.ink54)),
            ),
          ),
      ],
    );
  }

  /// 设置项控件类型与 Electron 版一致：boolean / select / number / 其余按文本
  /// 每卡自定义背景图（Fluent 形态）：缩略图 + 状态行 + 图标按钮。
  /// 选图复制到 userdata/bg/，卡片的 bgImage 设置只存文件名；
  /// 可读性由 card_view 按图片实测亮度自动翻转文字色，这里只把结果说出来。
  Widget _bgPicker(WidgetCard card) {
    final current = card.settings['bgImage'] as String?;
    final file = current == null || current.isEmpty
        ? null
        : File(p.join(widget.store.dir, 'bg', current));
    final fileReady = file != null && file.existsSync();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 44,
            height: 44,
            color: _c.chipBg,
            child: fileReady
                ? Image.file(file, fit: BoxFit.cover, gaplessPlayback: true)
                : Center(
                    child: Icon(Icons.image_outlined,
                        size: 16, color: _c.ink38)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('背景图片',
                  style: TextStyle(fontSize: 13, color: _c.ink)),
              const SizedBox(height: 2),
              ValueListenableBuilder<int>(
                valueListenable: CardView.bgRevision,
                builder: (context, _, _) {
                  String status;
                  if (!fileReady) {
                    status = '未设置 · 使用主题材质（云母/毛玻璃）';
                  } else {
                    final l = CardView.bgLuminance(file.path);
                    final adapt = l == null
                        ? ''
                        : (l > 0.5 ? ' · 浅色图，文字已自动切黑' : ' · 深色图，文字已自动切白');
                    status = '$current$adapt';
                  }
                  return Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: _c.ink38));
                },
              ),
            ],
          ),
        ),
        Button(
          onPressed: () async {
            final result = await FilePicker.pickFiles(type: FileType.image);
            final path = result?.files.single.path;
            if (path == null) return;
            final dir = Directory(p.join(widget.store.dir, 'bg'));
            await dir.create(recursive: true);
            final ext = path.split('.').last.toLowerCase();
            final name = '${card.id}.$ext';
            if (current != null && current != name) {
              final old = File(p.join(dir.path, current));
              if (old.existsSync()) old.deleteSync();
            }
            await File(path).copy(p.join(dir.path, name));
            card.settings['bgImage'] = name;
            _commit();
            if (mounted) setState(() {});
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.image_outlined, size: 14),
            const SizedBox(width: 6),
            Text(current == null ? '选择图片' : '更换'),
          ]),
        ),
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Button(
              onPressed: () {
                final old = File(p.join(widget.store.dir, 'bg', current));
                if (old.existsSync()) old.deleteSync();
                card.settings.remove('bgImage');
                _commit();
                if (mounted) setState(() {});
              },
              child: const Text('清除',
                  style: TextStyle(color: Color(0xFFD13438))),
            ),
          ),
      ],
    );
  }

  Widget _settingField(WidgetCard card, Map<String, Object?> f) {
    final key = f['key'] as String;
    final label = f['label'] as String? ?? key;
    final desc = f['desc'] as String?;
    final plugin = builtinSpecById(card.pluginId);
    final current = card.settings.containsKey(key)
        ? card.settings[key]
        : (plugin?.defaultSettings()[key] ?? f['default']);

    Widget control;
    switch (f['type']) {
      case 'boolean':
        control = ToggleSwitch(
          checked: current == true,
          onChanged: (v) {
            card.settings[key] = v;
            _commit();
          },
        );
      case 'select':
        final options = (f['options'] as List? ?? const [])
            .whereType<Map>()
            .map((o) => o.cast<String, Object?>())
            .toList();
        control = ComboBox<String>(
          value: options.any((o) => '${o['value']}' == '$current')
              ? '$current'
              : null,
          items: [
            for (final o in options)
              ComboBoxItem(
                  value: '${o['value']}',
                  child: Text('${o['label'] ?? o['value']}'))
          ],
          onChanged: (v) {
            if (v == null) return;
            card.settings[key] = v;
            _commit();
          },
        );
      case 'number':
        final min = (f['min'] as num?)?.toDouble() ?? 0;
        final max = (f['max'] as num?)?.toDouble() ?? 100;
        final step = (f['step'] as num?)?.toDouble() ?? 1;
        final v = ((current as num?)?.toDouble() ?? min).clamp(min, max);
        control = SizedBox(
          width: 220,
          child: Row(children: [
            Expanded(
              child: Slider(
                value: v,
                min: min,
                max: max,
                divisions: ((max - min) / step).round().clamp(1, 1000),
                onChanged: (nv) {
                  card.settings[key] = snapNumber(nv, min, step);
                  _commit();
                },
              ),
            ),
            SizedBox(
                width: 34,
                child: Text(formatNumber(v, step),
                    style: TextStyle(fontSize: 11, color: _c.ink60))),
          ]),
        );
      default:
        control = SizedBox(
          width: 220,
          child: _LwTextBox(
            initial: '${current ?? ''}',
            placeholder: f['placeholder'] as String?,
            onSubmitted: (v) {
              card.settings[key] = v;
              _commit();
            },
          ),
        );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: _c.ink70)),
                if (desc != null)
                  Text(desc,
                      style: TextStyle(fontSize: 10, color: _c.ink30)),
              ],
            ),
          ),
          control,
        ],
      ),
    );
  }

  // ---------------- 外观 ----------------

  Widget _appearance() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      children: [
        _group(
          title: '布局与吸附',
          icon: Icons.grid_view_outlined,
          children: [
            _slider('网格单元大小', _s.gridCell.toDouble(), 72, 180, 4, (v) {
              _s.gridCell = v.round();
              _commit();
            }, suffix: 'px'),
            _slider('网格间距', _s.gridGap.toDouble(), 0, 32, 2, (v) {
              _s.gridGap = v.round();
              _commit();
            }, suffix: 'px'),
            _slider('吸附阈值', _s.snapThreshold, 2, 40, 1, (v) {
              _s.snapThreshold = v;
              _commit();
            }, suffix: 'px'),
            _switch('磁吸对齐', _s.snapEnabled, (v) {
              _s.snapEnabled = v;
              _commit();
            }),
            _switch('锁定布局（禁止拖动与改尺寸）', _s.locked, (v) {
              _s.locked = v;
              _commit();
            }),
            _switch('动画效果（拖拽缓动与插件内容切换）', _s.animations, (v) {
              _s.animations = v;
              _commit();
            }),
            // 侧栏宽度也能在这里调：鼠标拖那条分隔线是主要方式（见
            // [_sidebarResizer]），但拖到一半想精确还原/微调时，滑块或
            // 下面的"重置"更省事——两个入口改的是同一个值。
            _slider('侧栏宽度', _sideW, _sideMin, _sideMax, 4, (v) {
              setState(() => _sideW = v);
              _s.sidebarWidth = v;
              _commit();
            }, suffix: 'px'),
            Row(children: [
              Expanded(
                child: Text('也可以直接拖动侧栏右侧的分隔线，双击该分隔线可复位。',
                    style: TextStyle(fontSize: 11, color: _c.ink38)),
              ),
              HyperlinkButton(
                onPressed: () {
                  setState(() => _sideW = kSidebarWidthDefault);
                  _s.sidebarWidth = kSidebarWidthDefault;
                  _commit();
                },
                child: const Text('重置', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ],
        ),
        _group(
          title: '卡片材质',
          icon: Icons.blur_on_outlined,
          children: [
            _materialPicker(),
            _slider('圆角', _s.cardRadius, 0, 40, 1, (v) {
              _s.cardRadius = v;
              _commit();
            }, suffix: 'px'),
            if (_s.material != 'opaque') ...[
              _slider('透明度（染色越少越透）', 1 - _s.glassTint, 0, 1, 0.05, (v) {
                _s.glassTint = 1 - v;
                _commit();
              }, percent: true),
              // 透明度 100% = 染色 0 = 色板 alpha 0：此时"卡片底色"整组
              // （含莫奈取色）都不可能有可见效果。以前没有提示，用户会以为
              // 那两组的开关坏了。
              if (_s.material == 'acrylic' && _s.glassTint < 0.1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      '染色已经到 0：卡片完全透明，下面「卡片底色」那一组'
                      '（包括莫奈取色）都不会有可见效果。想看到底色，'
                      '把这个「透明度」往回调一些。',
                      style: TextStyle(
                          fontSize: 10, color: _c.accent, height: 1.5)),
                ),
              _slider('模糊强度', _s.glassBlur, 0, 40, 1, (v) {
                _s.glassBlur = v;
                _commit();
              }, suffix: 'px'),
              // 云母是静态材质，刷新率对它没有意义，别摆出来误导人
              if (_s.material != 'mica')
                _liveRefreshRow()
              else
                Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                      '云母只跟壁纸走，不跟随身后的窗口变化，所以不需要刷新，也没有那份开销。'
                      '想要跟随窗口的实时模糊请选毛玻璃。',
                      style: TextStyle(
                          fontSize: 10.5, color: _c.ink24, height: 1.5)),
                ),
              const SizedBox(height: 6),
              Row(children: [
                ValueListenableBuilder<String>(
                  valueListenable: Wallpaper.source,
                  builder: (context, src, _) => Text('来源：$src',
                      style: TextStyle(
                          fontSize: 10, color: _c.ink30)),
                ),
                if (_s.liveRefreshMs > 0) ...[
                  const SizedBox(width: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: Wallpaper.lastFrameMs,
                    builder: (context, ms, _) {
                      final target = _s.liveRefreshMs;
                      final ok = ms <= target;
                      return Text(
                          '实测 $ms ms/帧'
                          '${ok ? "" : "（达不到目标 $target ms，已自动降速）"}',
                          style: TextStyle(
                              fontSize: 10,
                              color: ok
                                  ? Color(0xFF7CE38B)
                                  : Color(0xFFFF9E7D)));
                    },
                  ),
                ],
              ]),
              const SizedBox(height: 6),
              Text('毛玻璃取的是桌面窗口的实际像素，所以动态壁纸'
                  '（Wallpaper Engine 等）也能被模糊；但要让它跟着动，'
                  '需要把下面的刷新间隔调成非「静态」。',
                  style: TextStyle(fontSize: 10, color: _c.ink30)),
            ],
          ],
        ),
        _group(
          title: '卡片底色',
          icon: Icons.color_lens_outlined,
          children: [
            // 同一件事在"用"的这一侧再说一次：用户点开关没反应时，
            // 目光就在这里，提示放在这里才救得了
            if (_s.material == 'acrylic' && _s.glassTint < 0.1)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                    '当前「透明度」是 100%（染色 0），卡片完全透明，'
                    '这一组设置（含莫奈取色）都不会显示出来——'
                    '先去上面「卡片材质」里把透明度调低一点。',
                    style: TextStyle(
                        fontSize: 10, color: _c.accent, height: 1.5)),
              ),
            _switch('从壁纸取色（莫奈取色）', _s.autoColorFromWallpaper, (v) {
              _s.autoColorFromWallpaper = v;
              _commit();
            }),
            Text(
              '开着的时候下面选的颜色不生效，改成实时从当前壁纸算一个代表色——'
              '算法跟 Android 12 的动态取色（Material You）同源，换壁纸卡片'
              '底色跟着换。关掉立刻退回你手选的颜色，设置不会丢。',
              style: TextStyle(fontSize: 10, color: _c.ink30, height: 1.5),
            ),
            // 取色结果：算法给的是一个方案（primary/secondary/tertiary/…），
            // 摆出来让用户挑，而不是我们替他定一个。
            if (_s.autoColorFromWallpaper)
              ValueListenableBuilder<List<Color>>(
                valueListenable: Wallpaper.palette,
                builder: (context, colors, _) {
                  if (colors.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text('取色结果还没出来（要先抓壁纸、模糊，再算色）',
                          style:
                              TextStyle(fontSize: 10, color: _c.ink30)),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Row(children: [
                      Text('取色结果',
                          style: TextStyle(fontSize: 10.5, color: _c.ink54)),
                      const SizedBox(width: 10),
                      for (var i = 0; i < colors.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () {
                              _s.paletteIndex = i;
                              _commit();
                            },
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: colors[i],
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _s.paletteIndex == i
                                      ? _c.accent
                                      : _c.cardBorder,
                                  width: _s.paletteIndex == i ? 2 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  );
                },
              ),
            const SizedBox(height: 4),
            _switch('文字颜色也用取色（莫奈取色）', _s.autoForegroundFromWallpaper, (v) {
              _s.autoForegroundFromWallpaper = v;
              _commit();
            }),
            Text(
              '默认文字颜色只有"深底白字/浅底黑字"两档；开着这个之后文字颜色'
              '也从壁纸算，会带一点点色相而不是纯黑白，算法保证跟卡片底色的'
              '对比度够读——跟上面那个开关各自独立，可以只开一个。',
              style: TextStyle(fontSize: 10, color: _c.ink30, height: 1.5),
            ),
            const SizedBox(height: 10),
            IgnorePointer(
              ignoring: _s.autoColorFromWallpaper,
              child: AnimatedOpacity(
                opacity: _s.autoColorFromWallpaper ? 0.35 : 1.0,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final c in const [
                      0xFF2A2A2E, 0xFF1C1C20, 0xFF23303A, 0xFF2E2436,
                      0xFF203029, 0xFF3A2A2A, 0xFFF2F2F5,
                    ])
                      GestureDetector(
                        onTap: () {
                          _s.cardColor = c;
                          _commit();
                        },
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Color(c),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _s.cardColor == c
                                  ? _c.accent
                                  : _c.cardBorder,
                              width: _s.cardColor == c ? 2 : 1,
                            ),
                          ),
                          child: _s.cardColor == c
                              ? Icon(Icons.check,
                                  size: 16,
                                  color: Color(c).computeLuminance() > 0.5
                                      ? Color(0x8A000000)
                                      : _c.ink70)
                              : null,
                        ),
                      ),
                    _customColorSwatch(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 反馈 Fb0039：莫奈开着时这一整排是禁用的（点上去没反应），
            // 但页面上什么都不说，看起来就像取色器"冻住了"。把话说清楚。
            Text(
              _s.autoColorFromWallpaper
                  ? '莫奈取色开着的时候，底色由壁纸算出来，下面这些色块和'
                      '"自定义"都不生效——想自己定底色，先关掉上面那个开关。'
                  : '点击预设色块切换；点"自定义"打开取色器，支持色轮/滑块/Hex 输入。',
              style: TextStyle(fontSize: 10, color: _c.ink30, height: 1.5),
            ),
          ],
        ),
        _group(
          title: '主题',
          icon: Icons.light_mode_outlined,
          children: [
            _themePicker(),
            Text(
                '玻璃卡片的文字颜色会跟着底子明暗自动翻转，保证可读性。'
                '自动 = 跟随系统深浅色，亮壁纸/亮主题用深字、暗壁纸用浅字。',
                style: TextStyle(fontSize: 10, color: _c.ink24, height: 1.5)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '磁贴常驻在所有窗口之下，只有露出桌面时才看得见。',
                style: TextStyle(fontSize: 11, color: _c.ink30, height: 1.5),
              ),
              const SizedBox(height: 10),
              Text('用户数据目录',
                  style: TextStyle(fontSize: 11, color: _c.ink38)),
              const SizedBox(height: 6),
              _pathLine(widget.store.dir),
              const SizedBox(height: 6),
              Text(
                '就在程序目录里，整个文件夹拷走即完整迁移。',
                style: TextStyle(fontSize: 11, color: _c.ink30, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _themePicker() {
    const options = [
      ('auto', '自动'),
      ('light', '浅色'),
      ('dark', '深色'),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        for (final m in options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                _s.theme = m.$1;
                _commit();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _s.theme == m.$1
                      ? _c.accentBg
                      : _c.chipBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _s.theme == m.$1
                        ? _c.accentBorder
                        : _c.chipBg,
                  ),
                ),
                child: Text(m.$2,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: _s.theme == m.$1 ? _c.accentSoft : _c.ink54)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _materialPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('材质', style: TextStyle(fontSize: 12, color: _c.ink70)),
          const SizedBox(height: 8),
          Row(children: [
            for (final m in const [
              ('opaque', '不透明'),
              ('acrylic', '毛玻璃'),
              ('mica', '云母'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    _s.material = m.$1;
                    _commit();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _s.material == m.$1
                          ? _c.accentBg
                          : _c.chipBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _s.material == m.$1
                            ? _c.accentBorder
                            : _c.chipBg,
                      ),
                    ),
                    child: Text(m.$2,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: _s.material == m.$1
                                ? _c.accentSoft
                                : _c.ink54)),
                  ),
                ),
              ),
          ]),
        ],
      ),
    );
  }

  /// 动态壁纸的刷新频率。静态壁纸不需要刷新，所以默认关。
  Widget _liveRefreshRow() {
    const options = [
      (0, '静态'),
      (1000, '1 秒'),
      (200, '5 fps'),
      (66, '15 fps'),
      (33, '30 fps'),
      (16, '60 fps'),
    ];
    // 内容区左侧被导航窗格占了，宽度有限：标签一行、选项 Wrap 自动换行
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('动态壁纸刷新',
              style: TextStyle(fontSize: 12, color: _c.ink70)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                GestureDetector(
                  onTap: () {
                    _s.liveRefreshMs = o.$1;
                    _commit();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _s.liveRefreshMs == o.$1
                          ? _c.accentBg
                          : _c.chipBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(o.$2,
                        style: TextStyle(
                            fontSize: 11,
                            color: _s.liveRefreshMs == o.$1
                                ? _c.accentSoft
                                : _c.ink54)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 卡片自定义底色 ----------------

  /// 自定义卡片底色按钮（紧跟 7 个预设色块）：
  ///   - 当前底色不在预设里时，高亮显示当前颜色
  ///   - 显示一个调色板小图标暗示可点击
  ///   - 点击打开 fluent_ui ColorPicker 对话框
  Widget _customColorSwatch() {
    final current = Color(_s.cardColor);
    final inPreset = const <int>[
      0xFF2A2A2E, 0xFF1C1C20, 0xFF23303A, 0xFF2E2436,
      0xFF203029, 0xFF3A2A2A, 0xFFF2F2F5,
    ].contains(_s.cardColor);
    final glyphColor =
        current.computeLuminance() > 0.5 ? Color(0xB3000000) : _c.ink70;
    return GestureDetector(
      onTap: _openColorPicker,
      child: Tooltip(
        message: inPreset ? '自定义卡片底色' : '当前是自定义色，点击调整',
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: current,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: inPreset ? _c.cardBorder : _c.accent,
              width: inPreset ? 1 : 2,
            ),
          ),
          child: Icon(Icons.colorize, size: 16, color: glyphColor),
        ),
      ),
    );
  }

  /// 弹出 fluent_ui ColorPicker 对话框。
  ///
  /// 对话框内用本地草稿 _pickedColor 暂存用户选择，点"应用"时才写回 settings。
  /// 这样避免每滑一下都触发全局去抖、磁贴闪烁。
  Future<void> _openColorPicker() async {
    setState(() => _pickedColor = Color(_s.cardColor));
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _buildColorDialog(),
    );
    // 无论取消还是应用，结束对话框就清掉草稿（apply 已经写回 _s.cardColor）
    if (mounted) setState(() => _pickedColor = null);
    if (result == true && mounted) _commit();
  }

  Widget _buildColorDialog() {
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setDialogState) {
        final draft = _pickedColor ?? Color(_s.cardColor);
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          title: Text('自定义卡片底色',
              style: TextStyle(fontSize: 16, color: _c.ink, fontWeight: FontWeight.w600)),
          content: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: ColorPicker(
              // ColorPicker 不接收 brightness，自己画在浅色面板上；
              // 用 ValueKey 强制它在面板深浅色切换时重建。
              key: ValueKey('picker:${_c.light}'),
              color: draft,
              onChanged: (c) {
                setDialogState(() => _pickedColor = c);
              },
              orientation: Axis.vertical,
              isColorPreviewVisible: true,
              isMoreButtonVisible: false,
              isColorSliderVisible: true,
              isColorChannelTextInputVisible: false,
              isHexInputVisible: true,
              isAlphaEnabled: false,
              isAlphaSliderVisible: false,
              isAlphaTextInputVisible: false,
            ),
          ),
          actions: [
            Button(
              child: Text('取消'),
              onPressed: () => Navigator.pop(context, false),
            ),
            FilledButton(
              child: Text('应用'),
              onPressed: () {
                final finalColor = _pickedColor ?? draft;
                _s.cardColor = finalColor.toARGB32();
                Navigator.pop(context, true);
              },
            ),
          ],
        );
      },
    );
  }

  // ---------------- 软件更新 ----------------

  String? get _updateCheckBusy =>
      appUpdateState.value.phase == AppUpdatePhase.checking ||
      appUpdateState.value.phase == AppUpdatePhase.downloading
          ? 'busy'
          : null;

  /// 手动触发检查；开了自动下载时顺手把新版下下来（等用户确认重启）
  Future<void> _checkUpdate() async {
    if (_updateCheckBusy != null) return;
    final s = _s;
    final u = await runUpdateCheck(
      currentVersion: appVersion,
      sources: buildUpdateSources(
          updateSource: s.updateSource, marketBaseUrl: s.marketBaseUrl),
    );
    if (u != null && s.autoDownloadUpdate) {
      unawaited(_downloadUpdate(autoInstall: false));
    }
  }

  /// 「立即更新」：下载 → 装好安装包直接进入安装（保存退出由 AppRoot 编排）
  Future<void> _downloadAndInstall() async {
    try {
      final path = await downloadUpdate(dir: AppPaths.updateDir);
      await widget.onInstallUpdate?.call(path);
    } catch (_) {
      // 状态机已标 failed 并保留更新对象，界面给出重试入口
    }
  }

  Future<void> _downloadUpdate({required bool autoInstall}) async {
    try {
      final path = await downloadUpdate(dir: AppPaths.updateDir);
      if (autoInstall) await widget.onInstallUpdate?.call(path);
    } catch (_) {}
  }

  Widget _updateBody(AppUpdateSnapshot snap) {
    const srcName = {
      'unisphere': 'Unisphere',
      'github': 'GitHub',
    };
    switch (snap.phase) {
      case AppUpdatePhase.checking:
        return Text('正在检查更新…',
            style: TextStyle(fontSize: 12, color: _c.ink70));
      case AppUpdatePhase.upToDate:
        return Row(children: [
          Icon(Icons.check_circle_outline, size: 14, color: _c.ink60),
          const SizedBox(width: 6),
          Text('已是最新版本', style: TextStyle(fontSize: 12, color: _c.ink70)),
          const SizedBox(width: 12),
          Button(onPressed: _checkUpdate, child: const Text('再查一次')),
        ]);
      case AppUpdatePhase.available:
        final u = snap.update!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('发现新版本 ${u.version}（来自 ${srcName[u.source] ?? u.source}）',
                style: TextStyle(
                    fontSize: 12, color: _c.ink70, fontWeight: FontWeight.w600)),
            if (u.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(u.notes.trim(),
                  style: TextStyle(fontSize: 10, color: _c.ink38, height: 1.5)),
            ],
            const SizedBox(height: 10),
            Button(onPressed: _downloadAndInstall, child: const Text('立即更新')),
          ],
        );
      case AppUpdatePhase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                snap.progress < 0 ? '正在下载…' : '正在下载… ${(snap.progress * 100).toInt()}%',
                style: TextStyle(fontSize: 12, color: _c.ink70)),
            const SizedBox(height: 6),
            ProgressBar(value: snap.progress < 0 ? null : snap.progress),
          ],
        );
      case AppUpdatePhase.ready:
        return Row(children: [
          Icon(Icons.download_done_outlined, size: 14, color: _c.ink60),
          const SizedBox(width: 6),
          Text('新版本 ${snap.update!.version} 已就绪',
              style: TextStyle(fontSize: 12, color: _c.ink70)),
          const SizedBox(width: 12),
          Button(
            onPressed: () => widget.onInstallUpdate?.call(snap.installerPath!),
            child: const Text('重启以更新'),
          ),
        ]);
      case AppUpdatePhase.failed:
        return Row(children: [
          Expanded(
            child: Text(snap.error ?? '更新失败',
                style: TextStyle(fontSize: 12, color: _c.danger)),
          ),
          const SizedBox(width: 12),
          Button(
            onPressed: snap.update != null
                ? () => _downloadAndInstall()
                : _checkUpdate,
            child: const Text('重试'),
          ),
        ]);
      case AppUpdatePhase.idle:
        return Button(onPressed: _checkUpdate, child: const Text('检查更新'));
    }
  }

  // ---------------- 关于 ----------------

  // ---------------- 「其他」页：开机自启 + 布局备份 ----------------

  Widget _other() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        _group(title: '软件更新', icon: Icons.system_update_outlined, children: [
          ValueListenableBuilder<AppUpdateSnapshot>(
            valueListenable: appUpdateState,
            builder: (context, snap, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本 Glance $appVersion',
                    style: TextStyle(fontSize: 11, color: _c.ink38)),
                const SizedBox(height: 10),
                _updateBody(snap),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _switch('检测到新版本时自动下载（下完等你确认重启）',
              _s.autoDownloadUpdate, (v) {
            _s.autoDownloadUpdate = v;
            _commit();
          }),
          const SizedBox(height: 4),
          Row(children: [
            Text('更新源',
                style: TextStyle(fontSize: 12, color: _c.ink70)),
            const SizedBox(width: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (v, label) in const [
                  ('auto', '自动'),
                  ('unisphere', 'Unisphere'),
                  ('github', 'GitHub'),
                ])
                  GestureDetector(
                    onTap: () {
                      _s.updateSource = v;
                      _commit();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _s.updateSource == v ? _c.accentBg : _c.chipBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 11,
                              color: _s.updateSource == v
                                  ? _c.accentSoft
                                  : _c.ink54)),
                    ),
                  ),
              ],
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            '自动 = 先问 Unisphere，连不上再试 GitHub Releases。\n'
            '更新装到程序所在目录，userdata 里的卡片和设置原样保留。',
            style: TextStyle(fontSize: 11, color: _c.ink38, height: 1.5),
          ),
        ]),
        _group(title: '启动', icon: Icons.power_settings_new_outlined, children: [
          if (_autoStart == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('读取中…',
                  style: TextStyle(fontSize: 12, color: _c.ink38)),
            )
          else
            _switch('开机时自动启动 Glance', _autoStart!, _toggleAutoStart),
          Text(
            '登记在当前用户的启动项里，不需要管理员权限。\n'
            '便携版整个文件夹搬走后，下次打开设置会自动把路径修正过来。',
            style: TextStyle(fontSize: 11, color: _c.ink38, height: 1.5),
          ),
        ]),
        _group(title: '日志', icon: Icons.description_outlined, children: [
          Text(
            '运行日志按天分文件，保留最近 7 天。\n'
            '反馈问题时把最近那几个 .log 一并发来，能省掉大量来回确认。',
            style: TextStyle(fontSize: 11, color: _c.ink38, height: 1.5),
          ),
          const SizedBox(height: 10),
          _pathLine(AppPaths.logsDir),
          const SizedBox(height: 10),
          Button(
            onPressed: () => NativeBridge.openLogDir(AppPaths.logsDir),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.folder_open_outlined, size: 14, color: _c.ink70),
              const SizedBox(width: 6),
              Text('打开日志目录', style: TextStyle(fontSize: 12)),
            ]),
          ),
        ]),
        _group(title: '布局备份', icon: Icons.backup_outlined, children: [
          Text(
            '备份包含卡片布局和外观设置，不含插件缓存，只有几 KB。\n'
            '换电脑或重装前导出一份，装好之后导入即可恢复原样。',
            style: TextStyle(fontSize: 11, color: _c.ink38, height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Button(
              onPressed: _exportBackup,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.file_upload_outlined, size: 14, color: _c.ink70),
                const SizedBox(width: 6),
                Text('导出备份', style: TextStyle(fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 10),
            Button(
              onPressed: _importBackup,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.file_download_outlined, size: 14, color: _c.ink70),
                const SizedBox(width: 6),
                Text('导入备份', style: TextStyle(fontSize: 12)),
              ]),
            ),
          ]),
          if (_backupHint != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                _backupFailed
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 14,
                color: _backupFailed ? const Color(0xFFE81123) : _c.accentIcon,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_backupHint!,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: _backupFailed
                            ? const Color(0xFFE81123)
                            : _c.ink54)),
              ),
            ]),
          ],
        ]),
      ],
    );
  }

  Future<void> _toggleAutoStart(bool on) async {
    // 先乐观改开关，写失败再弹回去——注册表写入通常是毫秒级，
    // 让开关卡住等 native 反而显得迟钝
    setState(() => _autoStart = on);
    Log.i('panel', '开机自启 -> $on');
    try {
      final actual = await NativeBridge.setAutoStart(on);
      if (actual != on) {
        Log.w('panel', '开机自启写入后回读为 $actual，与请求的 $on 不一致');
      }
      if (mounted) setState(() => _autoStart = actual);
    } catch (e) {
      Log.e('panel', '修改开机自启失败: $e');
      if (!mounted) return;
      setState(() {
        _autoStart = !on;
        _backupFailed = true;
        _backupHint = '无法修改启动项：$e';
      });
    }
  }

  Future<void> _exportBackup() async {
    try {
      final stamp = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'glance-backup-${stamp.year}${two(stamp.month)}'
          '${two(stamp.day)}-${two(stamp.hour)}${two(stamp.minute)}.json';
      final path = await FilePicker.saveFile(
        dialogTitle: '导出布局备份',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null) return; // 用户取消
      await File(path).writeAsString(widget.store.encodeConfig(widget.state));
      Log.i('panel', '导出备份 ${widget.state.cards.length} 张卡片 -> $path');
      if (!mounted) return;
      setState(() {
        _backupFailed = false;
        _backupHint = '已导出到 $path';
      });
    } catch (e) {
      Log.e('panel', '导出备份失败: $e');
      if (!mounted) return;
      setState(() {
        _backupFailed = true;
        _backupHint = '导出失败：$e';
      });
    }
  }

  Future<void> _importBackup() async {
    try {
      final res = await FilePicker.pickFiles(
        dialogTitle: '选择要导入的备份',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = res?.files.single.path;
      if (path == null) return; // 用户取消

      // 先解析再问，别让用户确认完才发现文件是坏的
      final incoming = widget.store.decodeConfig(await File(path).readAsString());
      if (!mounted) return;

      final ok = await _confirmImport(incoming.cards.length);
      if (ok != true || !mounted) return;

      // 就地替换：AppState 的引用被外层持有，不能换对象，只能换字段
      widget.state.settings = incoming.settings;
      widget.state.cards = incoming.cards;

      await widget.store.saveNow(widget.state);
      Log.i('panel',
          '导入备份 ${incoming.cards.length} 张卡片（来自 $path），布局已整体替换');
      // 导入会把设置整个换掉，快照跟着重置，否则下一次改动会报出一堆假差异
      _settingsSnapshot = widget.state.settings.toJson();
      if (!mounted) return;
      setState(() {
        _backupFailed = false;
        _backupHint = '已导入 ${incoming.cards.length} 张卡片，布局已恢复。';
      });
      // 让磁贴、面板外壳都按新配置重建
      _maybeBumpThemeRevision();
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backupFailed = true;
        _backupHint = '导入失败：$e';
      });
    }
  }

  /// 导入会覆盖当前布局，且没有撤销，问一句
  Future<bool?> _confirmImport(int cardCount) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 420),
        title: Text('导入备份？',
            style: TextStyle(
                fontSize: 16, color: _c.ink, fontWeight: FontWeight.w600)),
        content: Text(
          '备份里有 $cardCount 张卡片。导入后当前的 ${widget.state.cards.length} 张卡片'
          '和全部外观设置都会被覆盖，且无法撤销。',
          style: TextStyle(fontSize: 13, color: _c.ink70, height: 1.6),
        ),
        actions: [
          Button(
            child: Text('取消'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          FilledButton(
            child: Text('覆盖导入'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  Widget _about() {
    final info = _pkgInfo;
    // 显示成四段，和 exe 属性里看到的文件版本一致，报问题时好对齐
    final version = info == null
        ? '获取中…'
        : 'v${info.version}.${info.buildNumber}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        const SizedBox(height: 28),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset('assets/logo.png',
                width: 72, height: 72, filterQuality: FilterQuality.medium),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('Glance · 一瞥',
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w600, color: _c.ink)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text('桌面磁贴小组件',
              style: TextStyle(fontSize: 13, color: _c.ink54)),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(version,
              style: TextStyle(fontSize: 12, color: _c.ink38)),
        ),
        const SizedBox(height: 28),
        _group(title: '信息', icon: Icons.info_outline, children: [
          _aboutRow('作者', 'KiriharaReina © 2026'),
          _aboutRow('数据', widget.store.dir, monospace: true),
        ]),
      ],
    );
  }

  /// 一行只读路径。面板可以被拖得很窄，所以必须能换行——
  /// 路径动辄上百字符，塞进不换行的 Text 会直接把布局撑破。
  Widget _pathLine(String path) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _c.cardBorder.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(4),
      ),
      // 长路径以前是直接折行，混在说明文字里显得很乱（反馈里红框圈的就是
      // 那一段）。改成单行 + 中间省略：盘符和末级目录名是两头有信息量的
      // 部分，中段那串用户名/版本目录才是可以牺牲的。悬停给出完整路径。
      child: Tooltip(
        message: path,
        child: Text(
          _elideMiddle(path, 56),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontSize: 11,
            color: _c.ink70,
            height: 1.4,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// 按字符数做中间省略。路径基本是 ASCII，配合等宽数字字体，按字符估宽够用。
  /// 按 rune 切而不是按下标切：用户名带中文时 `substring` 会把字符劈成两半，
  /// 末尾留一个问号形的替换符，比超宽还难看。
  static String _elideMiddle(String s, int max) {
    final chars = s.runes.map(String.fromCharCode).toList();
    if (chars.length <= max) return s;
    final head = (max - 1) ~/ 2;
    final tail = max - 1 - head;
    return '${chars.take(head).join()}…${chars.skip(chars.length - tail).join()}';
  }

  Widget _aboutRow(String label, String value, {bool monospace = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 52,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: _c.ink54)),
        ),
        Expanded(
          child: Text(value,
              style: TextStyle(
                  fontSize: 12,
                  color: _c.ink70,
                  fontFeatures: monospace
                      ? const [FontFeature.tabularFigures()]
                      : null)),
        ),
      ]),
    );
  }

  // ---------------- 通用控件 ----------------

  Widget _slider(String label, double value, double min, double max, double step,
      ValueChanged<double> onChanged,
      {String suffix = '', bool percent = false, int decimals = 0}) {
    String shown() {
      if (percent) return '${(value * 100).round()}%';
      if (decimals > 0) return value.toStringAsFixed(decimals);
      return '${value.round()}$suffix';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
            width: 190,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: _c.ink70))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
            width: 52,
            child: Text(shown(),
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 11, color: _c.ink60))),
      ]),
    );
  }

  /// 开关行：Win11 设置那样"文字在左、开关在右"，不再把文字塞进开关里
  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(fontSize: 12.5, color: _c.ink70)),
        ),
        const SizedBox(width: 12),
        ToggleSwitch(checked: value, onChanged: onChanged),
      ]),
    );
  }

  /// Win11 设置的分组样式：**小标题在卡片外面**（组名 + 可选图标），
  /// 下面一张实色圆角卡片装着这一组的所有行。
  Widget _group({
    required String title,
    IconData? icon,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: _c.ink54),
                const SizedBox(width: 6),
              ],
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _c.ink)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            decoration: BoxDecoration(
              color: _c.card,
              borderRadius: BorderRadius.circular(_kRadius),
              border: Border.all(color: _c.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 组件库磁贴的悬停反馈：整卡上浮 2px + 落影加深。
///
/// Win11 设置卡片/商店卡片都有这一层"浮起来"的暗示，告诉用户这张卡是
/// 一个整体。悬停态放在独立 widget 里，每个磁贴自己管理自己的 hover，
/// 不用在面板 State 里维护一张 hovered-id 表。动画用 easeOutCubic +
/// 180ms，与面板其余交互动画同一节奏。
class _TileHover extends StatefulWidget {
  const _TileHover({required this.child});

  final Widget child;

  @override
  State<_TileHover> createState() => _TileHoverState();
}

class _TileHoverState extends State<_TileHover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_kRadius),
          boxShadow: [
            // 深色主题下黑影几乎不可见——那就让它不可见，不额外发明
            // 发光效果；浅色主题的落影才是这层反馈的主场
            if (_hover)
              const BoxShadow(
                  color: Color(0x2E000000),
                  blurRadius: 14,
                  offset: Offset(0, 6)),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

/// fluent 的 TextBox 需要外部持有 controller，包一层自己管理生命周期。
class _LwTextBox extends StatefulWidget {
  const _LwTextBox({
    required this.initial,
    this.placeholder,
    this.onSubmitted,
  });

  final String initial;
  final String? placeholder;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_LwTextBox> createState() => _LwTextBoxState();
}

class _LwTextBoxState extends State<_LwTextBox> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _controller,
      placeholder: widget.placeholder,
      onSubmitted: widget.onSubmitted,
    );
  }
}

// ---------------- 插件 number 设置项的取值 ----------------

/// 把滑块值对齐到插件声明的 step 上。
///
/// 这里过去写的是 `nv.round()`，等于不管 step 是多少都取整到个位——
/// 插件声明 step:0.1 时用户根本存不进小数：拖到 0.3 存成 0、拖到 0.6 存成 1。
/// 内置那几个设置项（网格像素、历史条数）本来就是整数，所以一直没暴露出来，
/// 但插件清单里的 number 字段是允许带小数的。
///
/// 对齐到 step 而不是直接存原值：滑块给的是连续值，不归一下会存进
/// 0.30000000000000004 这种浮点噪声，写进 config.json 难看，插件那边拿它
/// 比较相等也会出意外。step 为整数时结果转回 int，免得整数项被写成 "5.0"。
@visibleForTesting
num snapNumber(double raw, double min, double step) {
  if (step <= 0) return raw;
  final snapped = min + ((raw - min) / step).round() * step;
  // 浮点累加会漂，按 step 的小数位数收尾
  final decimals = decimalsOf(step);
  final fixed = double.parse(snapped.toStringAsFixed(decimals));
  return decimals == 0 ? fixed.toInt() : fixed;
}

/// step 有几位小数——取整和显示都按它来
@visibleForTesting
int decimalsOf(double step) {
  if (step == step.roundToDouble()) return 0;
  final s = step.toString();
  final dot = s.indexOf('.');
  return dot < 0 ? 0 : (s.length - dot - 1).clamp(0, 4);
}

@visibleForTesting
String formatNumber(double v, double step) {
  final d = decimalsOf(step);
  return d == 0 ? '${v.round()}' : v.toStringAsFixed(d);
}

// ---------------- 设置改动的可读描述 ----------------

/// 算出两份设置快照之间"到底改了哪几项"，每项写成「键: 旧值 -> 新值」。
///
/// 单独抽出来是因为这是纯数据变换，值得直接测：配置类问题（"我明明关了它
/// 怎么还在"）最难查，靠的就是这行日志，而它一旦退化成只说"设置变了"，
/// 就等于没写。
///
/// 用快照对比而不是在每个控件回调里各写一行：设置项有几十个，靠人肉埋点迟早
/// 会漏，插件市场以后还会带进来新的。这里一次对比全覆盖。
@visibleForTesting
List<String> describeSettingsDiff(
    Map<String, Object?> before, Map<String, Object?> after) {
  final changed = <String>[];
  after.forEach((key, value) {
    final old = before[key];
    if (old != value) changed.add('$key: $old -> $value');
  });
  return changed;
}
