/// 组件库里的插件实时预览。
///
/// 用一个独立的 PluginRuntime + 隔离宿主把插件真实跑起来：时钟会走、天气会拉数、
/// 歌词会读媒体状态——预览是真的，不是静态图。宿主挂在临时目录的 Store 上，
/// 不碰真实 pluginData；离开组件库页时随 widget 销毁，定时器一起回收。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/grid.dart';
import '../model/card.dart';
import '../model/settings.dart';
import '../plugin/host.dart';
import '../plugin/manifest.dart';
import '../plugin/node.dart';
import '../plugin/runtime.dart';
import '../store/store.dart';

class PluginPreview extends StatefulWidget {
  const PluginPreview({
    super.key,
    required this.manifest,
    required this.source,
  });

  final PluginManifest manifest;

  /// 插件入口 JS（registry 里已把 scripts 拼好的那段）
  final String source;

  @override
  State<PluginPreview> createState() => _PluginPreviewState();
}

class _PluginPreviewState extends State<PluginPreview> {
  PluginRuntime? _rt;
  PxSize _px = const PxSize(200, 200);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _rt?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final grid = parseSize(widget.manifest.defaultSize) ?? const GridSize(2, 2);
    final px = sizeToPx(grid);
    if (!mounted) return;

    // 隔离宿主：临时目录的 Store + 一张假卡片。预览的 storage 读写落在
    // 临时目录里，不会进真实 pluginData；http / 媒体状态是真能力（要的就是真预览）。
    final store =
        Store(p.join(Directory.systemTemp.path, 'vectra-preview', widget.manifest.id));
    await store.load();
    final state = AppState(settings: AppSettings(), cards: []);
    final card = WidgetCard(
        id: 'preview',
        pluginId: widget.manifest.id,
        x: 0,
        y: 0,
        size: widget.manifest.defaultSize,
        z: 0);
    final host = PluginHost(
      store: store,
      state: state,
      card: card,
      pluginId: widget.manifest.id,
      onRequestSize: (_) {},
      onOpenSettings: () {},
    );

    final rt = PluginRuntime(
      manifest: widget.manifest,
      source: widget.source,
      instanceId: 'preview:${widget.manifest.id}',
      host: host.call,
    );
    await rt.mount(
      settings: widget.manifest.defaultSettings(),
      w: px.w,
      h: px.h,
      cols: grid.cols,
      rows: grid.rows,
    );
    if (!mounted) {
      rt.dispose();
      return;
    }
    setState(() {
      _rt = rt;
      _px = px;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rt = _rt;
    // 固定成插件的默认尺寸，外层 FittedBox 负责等比缩小
    return SizedBox(
      width: _px.w,
      height: _px.h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: const Color(0x0A000000),
          child: rt == null
              ? const Center(
                  child: Icon(Icons.hourglass_empty_rounded,
                      size: 20, color: Colors.white24))
              : ValueListenableBuilder<String?>(
                  valueListenable: rt.error,
                  builder: (context, err, _) {
                    if (err != null) {
                      return const Center(
                          child: Text('预览失败',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.white38)));
                    }
                    return ValueListenableBuilder<Map<String, Object?>?>(
                      valueListenable: rt.tree,
                      builder: (context, tree, _) => PluginView(
                        tree: tree,
                        onEvent: (_, _) {},  // 预览不响应交互
                        animate: false,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
