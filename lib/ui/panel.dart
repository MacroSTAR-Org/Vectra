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

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/logger.dart';
import '../core/paths.dart';
import '../core/theme.dart';
import '../model/ai_settings.dart';
import '../model/card.dart';
import '../model/settings.dart';
import '../native/native_bridge.dart';
import '../plugin/manifest.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'panel_app.dart' show panelThemeRevision;
import 'window_chrome.dart';
import 'panel_preview.dart';
import 'wallpaper.dart';

/// 全局统一的主色与材质，跟磁贴/侧边栏同一套语言
/// （主题蓝放 _PanelColors.accent 里按深浅色翻转）
const double _kRadius = 14;

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

  /// 卡片底/边框：深色是白 5%/12%，浅色换成黑 5%/12%
  Color get card => light ? Color(0x0D000000) : Color(0x0DFFFFFF);
  Color get cardBorder =>
      light ? Color(0x1F000000) : Color(0x1FFFFFFF);

  /// 未选中 chip / 分隔线的底（白 8% ↔ 黑 8%）
  Color get chipBg =>
      light ? Color(0x14000000) : Color(0x14FFFFFF);

  /// 图标圆底（白 6% ↔ 黑 6%）
  Color get iconTile =>
      light ? Color(0x0F000000) : Color(0x0FFFFFFF);

  /// 预览区底色（本来就是近黑，浅色下加深到看得见边框里的内容）
  Color get previewBg =>
      light ? Color(0x12000000) : Color(0x08000000);

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
}

class ControlPanel extends StatefulWidget {
  const ControlPanel({
    super.key,
    required this.state,
    required this.store,
    required this.registry,
    required this.onClose,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
    this.canAdd,
    this.focusCardId,
    this.initialTab,
    this.onHotkeyChanged,
    this.embedded = true,
  });

  /// true = 画在磁贴那个全屏窗口里（旧行为：遮罩 + 居中的固定尺寸盒子）
  /// false = 独立窗口，窗口边框由系统负责，这里只管铺满客户区
  final bool embedded;

  final AppState state;
  final Store store;
  final PluginRegistry registry;
  final VoidCallback onClose;

  /// 任何改动后通知外层重建并推送新的命中区
  final VoidCallback onChanged;
  final void Function(PluginManifest plugin) onAdd;
  final void Function(WidgetCard card) onRemove;

  /// 这种组件还能不能再加（每块屏最多一个）。
  /// 需要显示器信息，只有磁贴那边算得了，所以由外面传进来；
  /// 不传时一律放行（内嵌形态和测试里用）。
  final bool Function(String pluginId)? canAdd;

  /// 从卡片右键进来时，直接定位到该卡片的设置
  final String? focusCardId;

  /// 指定打开时停在哪一页（AI 侧边栏的齿轮会指到 AI 页）
  final int? initialTab;

  /// 快捷键改了要重新向系统注册
  final VoidCallback? onHotkeyChanged;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  late int _tab = widget.initialTab ?? (widget.focusCardId != null ? 1 : 0);

  /// 导航栏是展开还是收成图标条。
  ///
  /// 必须自己存着：NavigationView 的收起按钮只通过 onDisplayModeChanged
  /// 把新模式**报出来**，它自己不留状态。之前这里给的是写死的
  /// PaneDisplayMode.expanded，按钮按下去内部虽然变了，可下一次重建又被
  /// 这个常量按回展开——表现就是"点了没反应"。
  PaneDisplayMode _paneMode = PaneDisplayMode.expanded;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // WinUI 3 标准布局：无边框自绘标题栏（最顶）+ NavigationView（左侧导航
    // 窗格 + 右侧内容）。NavigationView 的 body 按选中项构建（keyed 切换），
    // 不会像 TabView/IndexedStack 那样同时建多页，安全的。
    final body = Column(
      children: [
        // 无边框窗口的自绘标题栏；内嵌模式没有独立窗口，不需要
        if (!widget.embedded) _titleBar(),
        Expanded(child: _navigation()),
      ],
    );

    // 独立窗口：铺满客户区，底色由 panel_app 负责。
    // 四周叠一圈缩放手柄——这窗口没有系统缩放边框（见 panel_window.cpp）。
    if (!widget.embedded) {
      // fit 用 expand：Stack 的子节点全是 Positioned 时，它自己会塌缩到约束
      // 允许的最小尺寸，手柄就跟着缩没了（surface.dart 里踩过同样的坑）
      return Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: body),
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

  // ---------------- 左侧导航（NavigationView） ----------------

  Widget _navigation() {
    return NavigationView(
      // 收起按钮只负责把新模式报出来，记不记得住得靠调用方。
      // 这个回调挂在 NavigationView 上，不是 NavigationPane 上。
      onDisplayModeChanged: (m) {
        if (m != _paneMode) setState(() => _paneMode = m);
      },
      pane: NavigationPane(
        selected: _tab,
        onChanged: (i) => setState(() => _tab = i),
        displayMode: _paneMode,
        size: const NavigationPaneSize(openWidth: 220),
        // 品牌行不放了：标题栏已有「Vectra 设置」，导航栏顶部再放一遍重复
        items: [
          PaneItem(
            icon: Icon(Icons.widgets_outlined, size: 18),
            title: Text('组件库'),
            body: _pageFrame('组件库', _library()),
          ),
          PaneItem(
            icon: Icon(Icons.grid_view_outlined, size: 18),
            title: Text('已放置 ${widget.state.cards.length}'),
            body: _pageFrame('已放置', _placed()),
          ),
          PaneItem(
            icon: Icon(Icons.palette_outlined, size: 18),
            title: Text('外观'),
            body: _pageFrame('外观', _appearance()),
          ),
          PaneItem(
            icon: Icon(Icons.smart_toy_outlined, size: 18),
            title: Text('AI'),
            body: _pageFrame('AI', _aiSettings()),
          ),
          // 放在 AI 之后：AI 仍是索引 3，托盘的 openPanel(tab: 3) 不受影响
          PaneItem(
            icon: Icon(Icons.tune_outlined, size: 18),
            title: Text('其他'),
            body: _pageFrame('其他', _other()),
          ),
        ],
        // 底部固定项：关于页固定在标签栏下方，不随 items 区滚动
        footerItems: [
          if (widget.embedded)
            PaneItemAction(
              icon: Icon(Icons.close, size: 18),
              title: Text('关闭'),
              onTap: widget.onClose,
            ),
          PaneItem(
            icon: Icon(Icons.info_outline, size: 18),
            title: Text('关于'),
            body: _pageFrame('关于', _about()),
          ),
        ],
      ),
    );
  }

  /// 内容页的标准骨架：大标题 + 可滚动内容
  Widget _pageFrame(String title, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 10),
          child: Text(title,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: _c.ink)),
        ),
        Expanded(child: content),
      ],
    );
  }

  // ---------------- 标题栏（无边框窗口专用） ----------------

  Widget _titleBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _c.chipBg)),
      ),
      child: Row(children: [
        Expanded(
          // 整条标题栏（按钮区域除外）都能拖窗口：按下即让 native 接管鼠标
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onTitleDrag,
            child: Row(children: [
              const SizedBox(width: 16),
              Image.asset('assets/logo.png',
                  width: 16, height: 16,
                  filterQuality: FilterQuality.medium),
              const SizedBox(width: 8),
              Text('Vectra 设置',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _c.ink)),
            ]),
          ),
        ),
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
        const SizedBox(width: 4),
      ]),
    );
  }

  void _onTitleDrag(PointerDownEvent e) =>
      beginWindowDrag(NativeWindow.panel, e);

  // ---------------- 组件库 ----------------

  Widget _library() {
    final plugins = widget.registry.list();
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
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.25,
                children: [for (final p in plugins) _pluginCard(p)],
              ),
          ],
        ),
        if (widget.registry.errors.isNotEmpty)
          _group(
            title: '加载失败的插件',
            icon: Icons.error_outline,
            children: [
              for (final e in widget.registry.errors.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${e.key}\n  ${e.value}',
                      style: TextStyle(
                          color: _c.ink38, fontSize: 11, height: 1.4)),
                ),
            ],
          ),
        _group(
          title: '获取更多组件',
          icon: Icons.storefront_outlined,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  '在插件市场浏览、安装社区做的组件。',
                  style: TextStyle(color: _c.ink60, fontSize: 12),
                ),
              ),
              FilledButton(
                onPressed: () => NativeWindow.market.show(),
                child: const Text('打开插件市场'),
              ),
            ]),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '第三方插件放到：${widget.registry.userDir}\n'
            '每个插件一个目录，目录名必须与 manifest.json 里的 id 相同。',
            style: TextStyle(color: _c.ink30, fontSize: 11, height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _pluginCard(PluginManifest p) {
    final placed = widget.state.cards.where((c) => c.pluginId == p.id).length;
    // 两道限制：插件自己声明的 singleton，以及"每块屏最多一个"的全局规则
    final singleBlocked = p.singleton && placed > 0;
    final screenFull = !(widget.canAdd?.call(p.id) ?? true);
    final blocked = singleBlocked || screenFull;
    final loaded = widget.registry[p.id];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 真实实时预览：插件真的在跑
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: _c.previewBg,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: FittedBox(
                fit: BoxFit.contain,
                child: loaded == null
                    ? const SizedBox.shrink()
                    : PluginPreview(
                        key: ValueKey('preview:${p.id}'),
                        manifest: loaded.manifest,
                        source: loaded.source,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.icon, style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _c.ink)),
                    ),
                    const SizedBox(width: 6),
                    Text('v${p.version}',
                        style: TextStyle(fontSize: 10, color: _c.ink30)),
                    if (p.source == 'user') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                            color: _c.badgeBg,
                            borderRadius: BorderRadius.circular(4)),
                        child: Text('第三方',
                            style: TextStyle(
                                fontSize: 9, color: _c.accentSoft)),
                      ),
                    ],
                  ]),
                  if (p.description.isNotEmpty)
                    Text(p.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5, color: _c.ink38, height: 1.3)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            if (placed > 0)
              Text('已放置 $placed',
                  style: TextStyle(fontSize: 11, color: _c.ink30)),
            const Spacer(),
            FilledButton(
              style: ButtonStyle(
                backgroundColor:
                    WidgetStateProperty.all(_c.cardBorder),
                padding: WidgetStateProperty.all(
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5)),
              ),
              onPressed: blocked
                  ? null
                  : () {
                      widget.onAdd(p);
                      // 导航项标题上有已放置数量，添加后要刷新
                      if (mounted) setState(() {});
                    },
              child: Text(
                  singleBlocked ? '仅一个' : (screenFull ? '每屏一个' : '添加'),
                  style: TextStyle(fontSize: 12)),
            ),
          ]),
        ],
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
    final plugin = widget.registry[card.pluginId]?.manifest;
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
                child: Text(plugin?.icon ?? '▢',
                    style: TextStyle(fontSize: 18)),
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

  Widget _sizePicker(WidgetCard card, PluginManifest plugin) {
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
  Widget _settingField(WidgetCard card, Map<String, Object?> f) {
    final key = f['key'] as String;
    final label = f['label'] as String? ?? key;
    final desc = f['desc'] as String?;
    final plugin = widget.registry[card.pluginId]?.manifest;
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
            Text(
              '点击预设色块切换；点"自定义"打开取色器，支持色轮/滑块/Hex 输入。',
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
          child: Text(
            '磁贴常驻在所有窗口之下，只有露出桌面时才看得见。\n'
            '用户数据：${widget.store.dir}\n'
            '（就在程序目录里，整个文件夹拷走即完整迁移）',
            style: TextStyle(fontSize: 11, color: _c.ink30, height: 1.5),
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

  // ---------------- AI ----------------

  Widget _aiSettings() {
    final ai = widget.state.ai;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      children: [
        _group(
          title: '接口',
          icon: Icons.link_outlined,
          children: [
            _aiField('Base URL', ai.baseUrl,
                placeholder: 'https://api.openai.com/v1',
                desc: '按 OpenAI 兼容格式请求 {BaseURL}/chat/completions。'
                    'DeepSeek、Kimi、本地 Ollama、One API 都可以填。',
                onSubmit: (v) {
              ai.baseUrl = v.trim();
              _commit();
            }),
            _aiField('API Key', ai.apiKey,
                obscure: true,
                desc: '明文存在 state.json 里，请勿把该文件分享出去。',
                onSubmit: (v) {
              ai.apiKey = v.trim();
              _commit();
            }),
            _aiField('模型', ai.model, placeholder: 'gpt-4o-mini', onSubmit: (v) {
              ai.model = v.trim();
              _commit();
            }),
            _slider('温度（越高越发散）', ai.temperature, 0, 2, 0.1, (v) {
              ai.temperature = v;
              _commit();
            }, decimals: 1),
            _slider('携带历史条数', ai.maxHistory.toDouble(), 2, 60, 2, (v) {
              ai.maxHistory = v.round();
              _commit();
            }),
          ],
        ),
        _group(
          title: '对话',
          icon: Icons.chat_outlined,
          children: [
            Text('系统提示词',
                style: TextStyle(fontSize: 12, color: _c.ink70)),
            const SizedBox(height: 6),
            _LwTextBox(
              initial: ai.systemPrompt,
              maxLines: 5,
              minLines: 3,
              onChanged: (v) {
                ai.systemPrompt = v;
                _commit();
              },
            ),
            const SizedBox(height: 4),
            Text('改动自动保存',
                style: TextStyle(fontSize: 10, color: _c.ink24)),
          ],
        ),
        _group(
          title: '外观',
          icon: Icons.palette_outlined,
          children: [
            _slider('侧边栏宽度', ai.sidebarWidth, 280, 640, 10, (v) {
              ai.sidebarWidth = v;
              _commit();
            }, suffix: 'px'),
            _slider('侧边栏圆角', ai.radius, 0, 48, 2, (v) {
              ai.radius = v;
              _commit();
            }, suffix: 'px'),
            _switch('侧边栏用毛玻璃（与磁贴同一材质）', ai.glass, (v) {
              ai.glass = v;
              _commit();
            }),
            if (ai.glass)
              _slider('侧边栏不透明度', ai.tint, 0, 1, 0.05, (v) {
                ai.tint = v;
                _commit();
              }, percent: true),
            const SizedBox(height: 4),
            Text('侧边栏的材质与磁贴共用同一张预模糊图，但透明度和圆角单独调。'
                '它会停在任务栏上方，不会压住任务栏。',
                style: TextStyle(fontSize: 10, color: _c.ink24)),
          ],
        ),
        _group(
          title: '行为',
          icon: Icons.tune_outlined,
          children: [
            _switch('Agent 能力（让 AI 操作电脑与读文件）', ai.agent, (v) {
              ai.agent = v;
              _commit();
            }),
            Text('开启后 AI 可以读文件、查系统信息、调音量、开设置页等。'
                '执行脚本、删文件、关机重启这类会先弹卡片让你确认。',
                style: TextStyle(fontSize: 10, color: _c.ink24)),
            const SizedBox(height: 8),
            _switch('右下角投放点（收起后缩成小方块）', ai.dock, (v) {
              ai.dock = v;
              _commit();
            }),
            Text('把文件拖到屏幕右下角那个小方块上，侧边栏就会展开并把文件挂成附件。'
                '它是常驻置顶的——磁贴常驻在最底层，右下角一被别的窗口盖住就够不到，'
                '所以投放点只能长在侧边栏这个置顶窗口上。代价是那 56x56 会挡住下面一小块的点击。',
                style: TextStyle(fontSize: 10, color: _c.ink24, height: 1.5)),
          ],
        ),
        _group(
          title: '快捷键',
          icon: Icons.keyboard_outlined,
          children: [
            _hotkeyRow(ai),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: hotkeyStatus,
              builder: (context, msg, _) {
                final bad = msg.startsWith('注册失败');
                return Row(children: [
                  Icon(bad ? Icons.error_outline : Icons.check_circle_outline,
                      size: 13,
                      color:
                          bad ? Color(0xFFFF9E7D) : Color(0xFF7CE38B)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(msg,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: bad
                                ? Color(0xFFFF9E7D)
                                : Color(0xFF7CE38B))),
                  ),
                ]);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _aiField(String label, String value,
      {String? placeholder,
      String? desc,
      bool obscure = false,
      required ValueChanged<String> onSubmit}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: _c.ink70)),
          if (desc != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(desc,
                  style: TextStyle(fontSize: 10, color: _c.ink24)),
            ),
          const SizedBox(height: 6),
          _LwTextBox(
            initial: value,
            placeholder: placeholder,
            obscure: obscure,
            // 和旧实现一致：每敲一下都提交（外层有 260ms 去抖）
            onChanged: onSubmit,
          ),
        ],
      ),
    );
  }

  /// 快捷键选择：修饰键多选 + 主键下拉。不做"按下录制"，
  /// 因为录制时按键会被面板自己吃掉，反而容易设出用不了的组合。
  Widget _hotkeyRow(dynamic ai) {
    Widget mod(String label, int bit) {
      final on = (ai.hotkeyMods & bit) != 0;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () {
            ai.hotkeyMods ^= bit;
            _commit();
            widget.onHotkeyChanged?.call();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: on ? _c.accentBg : _c.chipBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11, color: on ? _c.accentSoft : _c.ink54)),
          ),
        ),
      );
    }

    const keys = <(int, String)>[
      (0x20, 'Space'), (0x41, 'A'), (0x44, 'D'), (0x51, 'Q'),
      (0x57, 'W'), (0x70, 'F1'), (0x71, 'F2'), (0x7A, 'F11'), (0x7B, 'F12'),
    ];
    // Wrap 自适应：内容区变窄时自动换行，不溢出
    return Wrap(
      spacing: 6,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        mod('Ctrl', 2),
        mod('Alt', 1),
        mod('Shift', 4),
        mod('Win', 8),
        ComboBox<int>(
          value: keys.any((k) => k.$1 == ai.hotkeyVk) ? ai.hotkeyVk : null,
          items: [
            for (final k in keys)
              ComboBoxItem(value: k.$1, child: Text(k.$2))
          ],
          onChanged: (v) {
            if (v == null) return;
            ai.hotkeyVk = v;
            _commit();
            widget.onHotkeyChanged?.call();
          },
        ),
        Text('当前：${ai.hotkeyLabel()}',
            style: TextStyle(fontSize: 11, color: _c.ink38)),
      ],
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

  // ---------------- 关于 ----------------

  // ---------------- 「其他」页：开机自启 + 布局备份 ----------------

  Widget _other() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        _group(title: '启动', icon: Icons.power_settings_new_outlined, children: [
          if (_autoStart == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('读取中…',
                  style: TextStyle(fontSize: 12, color: _c.ink38)),
            )
          else
            _switch('开机时自动启动 Vectra', _autoStart!, _toggleAutoStart),
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
            '备份包含卡片布局、外观设置和 AI 配置，不含插件缓存，只有几 KB。\n'
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
      final name = 'vectra-backup-${stamp.year}${two(stamp.month)}'
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
      widget.state.disabledPlugins = incoming.disabledPlugins;
      widget.state.ai = incoming.ai;

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
      // 让磁贴、面板外壳、侧边栏都按新配置重建
      _maybeBumpThemeRevision();
      widget.onChanged();
      widget.onHotkeyChanged?.call();
      NativeBridge.reloadSidebar();
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
          '和全部外观、AI 设置都会被覆盖，且无法撤销。',
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
          child: Text('Vectra',
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
          _aboutRow('作者', 'MacroSTAR Studio © 2026'),
          _aboutRow('数据', widget.store.dir, monospace: true),
        ]),
        _group(title: '项目', icon: Icons.link_outlined, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              const SizedBox(width: 2),
              Icon(Icons.link, size: 14, color: _c.accentIcon),
              const SizedBox(width: 10),
              HyperlinkButton(
                onPressed: () => launchUrl(
                    Uri.parse('https://github.com/MacroSTAR-Org/Vectra')),
                child: Text('github.com/MacroSTAR-Org/Vectra',
                    style: TextStyle(fontSize: 12, color: _c.accent)),
              ),
            ]),
          ),
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
      child: Text(
        path,
        style: TextStyle(
          fontSize: 11,
          color: _c.ink70,
          height: 1.4,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
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

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ToggleSwitch(
        checked: value,
        onChanged: onChanged,
        content: Text(label,
            style: TextStyle(fontSize: 12, color: _c.ink70)),
      ),
    );
  }

  /// 分组卡片：圆角 + 半透明底 + 小节标题
  Widget _group({
    required String title,
    IconData? icon,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: _c.card,
        borderRadius: BorderRadius.circular(_kRadius),
        border: Border.all(color: _c.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: _c.accentIcon),
              const SizedBox(width: 6),
            ],
            Text(title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _c.accentSoft)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// fluent 的 TextBox 需要外部持有 controller，包一层自己管理生命周期。
class _LwTextBox extends StatefulWidget {
  const _LwTextBox({
    required this.initial,
    this.placeholder,
    this.maxLines = 1,
    this.minLines,
    this.obscure = false,
    this.onChanged,
    this.onSubmitted,
  });

  final String initial;
  final String? placeholder;
  final int maxLines;
  final int? minLines;
  final bool obscure;
  final ValueChanged<String>? onChanged;
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
    if (widget.obscure) {
      return PasswordBox(
        controller: _controller,
        placeholder: widget.placeholder,
        onChanged: widget.onChanged,
      );
    }
    return TextBox(
      controller: _controller,
      placeholder: widget.placeholder,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      onChanged: widget.onChanged,
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
