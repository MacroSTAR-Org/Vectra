/// 插件市场窗口。
///
/// 和设置窗口一样是"同一个引擎上的第二个视图"（见 windows/runner/view_window.h），
/// 所以这里拿到的 registry / store 就是磁贴那边正在用的那几个对象——装完插件
/// 直接 scan() 一下，桌面立刻就能用，不需要重启，也不需要跨进程通知。
///
/// 目前是骨架：窗口、标题栏、缩放都通了，内容区等数据层接上来（见
/// core/marketplace.dart）。
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent;
import 'package:flutter/material.dart' as m;

import '../core/theme.dart';
import '../native/native_bridge.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'panel_app.dart' show panelThemeRevision;
import 'window_chrome.dart';

class MarketApp extends StatelessWidget {
  const MarketApp({
    super.key,
    required this.state,
    required this.store,
    required this.registry,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([systemBrightness, panelThemeRevision]),
      builder: (context, _) {
        final light = effectiveBrightness(state.settings) == Brightness.light;
        return FluentApp(
          debugShowCheckedModeBanner: false,
          title: 'Vectra 插件市场',
          theme: FluentThemeData(
            brightness: light ? Brightness.light : Brightness.dark,
            fontFamily: 'HarmonyOS Sans SC',
          ),
          home: _MarketWindow(
            light: light,
            registry: registry,
          ),
        );
      },
    );
  }
}

/// 窗口本体：自绘标题栏 + 内容区 + 四周的缩放手柄。
class _MarketWindow extends StatelessWidget {
  const _MarketWindow({required this.light, required this.registry});

  final bool light;
  final PluginRegistry registry;

  Color get _bg => light ? const Color(0xFFF3F3F3) : const Color(0xFF1F1F23);
  Color get _ink => light ? const Color(0xFF16181C) : const Color(0xFFF2F3F5);
  Color get _ink50 =>
      light ? const Color(0x8016181C) : const Color(0x80F2F3F5);

  @override
  Widget build(BuildContext context) {
    return m.Material(
      color: _bg,
      child: Stack(
        children: [
          Column(
            children: [
              _titleBar(),
              Expanded(child: _body()),
            ],
          ),
          // 缩放手柄必须铺在最上层，否则会被内容挡住点不到
          ...resizeHandles(NativeWindow.market),
        ],
      ),
    );
  }

  Widget _titleBar() {
    return SizedBox(
      height: 44,
      child: Row(children: [
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (PointerDownEvent e) =>
                beginWindowDrag(NativeWindow.market, e),
            child: Row(children: [
              const SizedBox(width: 16),
              m.Image.asset('assets/logo.png',
                  width: 16, height: 16, filterQuality: m.FilterQuality.medium),
              const SizedBox(width: 8),
              Text('插件市场',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
            ]),
          ),
        ),
        WindowButton(
          icon: m.Icons.minimize_rounded,
          tooltip: '最小化',
          light: light,
          onTap: () => NativeWindow.market.minimize(),
        ),
        WindowButton(
          icon: m.Icons.crop_square_rounded,
          tooltip: '最大化 / 还原',
          light: light,
          onTap: () => NativeWindow.market.toggleMaximize(),
        ),
        WindowButton(
          icon: m.Icons.close_rounded,
          tooltip: '关闭',
          light: light,
          danger: true,
          onTap: () => NativeWindow.market.hide(),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }

  /// 内容区。列表页和详情页在下一步接上来。
  Widget _body() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          m.Icon(m.Icons.storefront_outlined, size: 40, color: _ink50),
          const SizedBox(height: 12),
          Text('插件市场', style: TextStyle(fontSize: 15, color: _ink)),
          const SizedBox(height: 6),
          Text('窗口已就绪，内容正在接入',
              style: TextStyle(fontSize: 12, color: _ink50)),
          const SizedBox(height: 20),
          Text('本地已装 ${registry.list().length} 个插件',
              style: TextStyle(fontSize: 11, color: _ink50)),
        ],
      ),
    );
  }
}
