/// 把一张卡片和它的插件运行时绑在一起：挂载、渲染、卸载。
library;

import 'package:flutter/material.dart';

import '../core/grid.dart';
import '../model/card.dart';
import '../store/store.dart';
import 'host.dart';
import 'node.dart';
import 'registry.dart';
import 'runtime.dart';

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

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _runtime?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final loaded = widget.registry[widget.card.pluginId];
    if (loaded == null) {
      setState(() => _loadError = '找不到插件「${widget.card.pluginId}」');
      return;
    }

    final host = PluginHost(
      store: widget.store,
      state: widget.state,
      card: widget.card,
      pluginId: loaded.manifest.id,
      onRequestSize: widget.onRequestSize,
      onOpenSettings: widget.onOpenSettings,
    );

    final rt = PluginRuntime(
      manifest: loaded.manifest,
      source: loaded.source,
      instanceId: widget.card.id,
      host: host.call,
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
    );

    if (!mounted) {
      rt.dispose();
      return;
    }
    setState(() => _runtime = rt);
  }

  @override
  Widget build(BuildContext context) {
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
          ),
        );
      },
    );
  }

  /// 插件挂了只影响它自己那张卡片，把原因显示出来而不是留一片空白
  Widget _errorBox(String message) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.card.pluginId,
              style: const TextStyle(color: Color(0xFFFF9A9A), fontSize: 12)),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: Text(message,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 10, height: 1.35)),
            ),
          ),
        ],
      );
}
