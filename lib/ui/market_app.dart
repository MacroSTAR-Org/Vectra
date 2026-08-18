/// 插件市场窗口。
///
/// 和设置窗口一样是"同一个引擎上的第二个视图"（见 windows/runner/view_window.h），
/// 所以这里拿到的 registry / store 就是磁贴那边正在用的那几个对象——装完插件
/// 直接让 AppRoot 重扫一遍，桌面立刻就能用，不需要重启，也不需要跨进程通知。
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent;
import 'package:flutter/material.dart' as m;

import '../core/logger.dart';
import '../core/marketplace.dart';
import '../core/paths.dart';
import '../core/theme.dart';
import '../native/native_bridge.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'app_root.dart';
import 'panel_app.dart' show panelThemeRevision;
import 'window_chrome.dart';

class MarketApp extends StatelessWidget {
  const MarketApp({
    super.key,
    required this.state,
    required this.store,
    required this.registry,
    required this.appKey,
  });

  final AppState state;
  final Store store;
  final PluginRegistry registry;

  /// 装完插件要让桌面重新扫描，那是 AppRoot 的活
  final GlobalKey<AppRootState> appKey;

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
            state: state,
            registry: registry,
            appKey: appKey,
          ),
        );
      },
    );
  }
}

class _MarketWindow extends StatefulWidget {
  const _MarketWindow({
    required this.light,
    required this.state,
    required this.registry,
    required this.appKey,
  });

  final bool light;
  final AppState state;
  final PluginRegistry registry;
  final GlobalKey<AppRootState> appKey;

  @override
  State<_MarketWindow> createState() => _MarketWindowState();
}

class _MarketWindowState extends State<_MarketWindow> {
  late MarketClient _client;
  late PluginInstaller _installer;

  List<MarketPlugin>? _plugins;
  String? _error;
  bool _loading = false;
  String _query = '';

  /// 正在装的插件：id -> 0~1 的进度。装完就移除。
  final Map<String, double> _installing = {};

  /// 刚装好的插件，卡片上给一句"已安装"的即时反馈
  final Set<String> _justDone = {};

  @override
  void initState() {
    super.initState();
    _client = makeMarketClient(widget.state.settings.marketBaseUrl);
    _installer = PluginInstaller(AppPaths.pluginsDir);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _client.catalog();
      if (!mounted) return;
      setState(() {
        _plugins = list;
        _loading = false;
      });
      // --market-install=<id>：自动点一次「安装」，用于自动验证（见该变量的说明）
      final auto = marketAutoInstallId;
      if (auto != null) {
        marketAutoInstallId = null;
        final hit = list.where((p) => p.id == auto).toList();
        if (hit.isEmpty) {
          Log.w('market', '--market-install 指定的 $auto 不在目录里');
        } else {
          Log.i('market', '--market-install：自动安装 $auto');
          await _install(hit.first);
        }
      }
    } on MarketException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      Log.w('market', '打开市场失败: $e');
      setState(() {
        _error = '打开市场失败';
        _loading = false;
      });
    }
  }

  /// 装一个插件：下载 -> 校验解压 -> 让桌面重扫
  Future<void> _install(MarketPlugin p) async {
    if (_installing.containsKey(p.id)) return;
    setState(() => _installing[p.id] = 0);
    try {
      final bytes = await _client.download(p.downloadUrl,
          onProgress: (received, total) {
        if (!mounted) return;
        // 服务器不给 Content-Length 时 total 是 0，进度只能是不确定态
        setState(() => _installing[p.id] = total > 0 ? received / total : -1);
      });
      await _installer.install(bytes,
          expectId: p.id, expectVersion: p.version);
      // 插件目录变了，让桌面重新扫描：新插件立刻能在组件库里添加，
      // 更新的插件也会在这一步重新挂载
      await widget.appKey.currentState?.rescanPlugins();
      if (!mounted) return;
      setState(() {
        _installing.remove(p.id);
        _justDone.add(p.id);
      });
    } on MarketException catch (e) {
      if (!mounted) return;
      setState(() => _installing.remove(p.id));
      _toast('${p.name}：${e.message}');
    } catch (e) {
      if (!mounted) return;
      Log.w('market', '安装 ${p.id} 失败: $e');
      setState(() => _installing.remove(p.id));
      _toast('${p.name}：安装失败');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: Text(message),
        severity: InfoBarSeverity.warning,
        onClose: close,
      );
    });
  }

  List<MarketPlugin> get _filtered {
    final all = _plugins ?? const <MarketPlugin>[];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final p in all)
        if (p.name.toLowerCase().contains(q) ||
            p.id.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q) ||
            p.author.toLowerCase().contains(q))
          p
    ];
  }

  Color get _bg =>
      widget.light ? const Color(0xFFF3F3F3) : const Color(0xFF1F1F23);
  Color get _card =>
      widget.light ? const Color(0xFFFFFFFF) : const Color(0xFF2A2A30);
  Color get _border =>
      widget.light ? const Color(0x14000000) : const Color(0x1FFFFFFF);
  Color get _ink =>
      widget.light ? const Color(0xFF16181C) : const Color(0xFFF2F3F5);
  Color get _ink60 =>
      widget.light ? const Color(0x9916181C) : const Color(0x99F2F3F5);
  Color get _ink40 =>
      widget.light ? const Color(0x6616181C) : const Color(0x66F2F3F5);

  @override
  Widget build(BuildContext context) {
    return m.Material(
      color: _bg,
      child: Stack(
        children: [
          Column(
            children: [
              _titleBar(),
              _searchRow(),
              Expanded(child: _content()),
            ],
          ),
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
              if (marketMockEnabled) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x33FF9A3C),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('假数据',
                      style: TextStyle(fontSize: 10, color: _ink60)),
                ),
              ],
            ]),
          ),
        ),
        WindowButton(
          icon: m.Icons.minimize_rounded,
          tooltip: '最小化',
          light: widget.light,
          onTap: () => NativeWindow.market.minimize(),
        ),
        WindowButton(
          icon: m.Icons.crop_square_rounded,
          tooltip: '最大化 / 还原',
          light: widget.light,
          onTap: () => NativeWindow.market.toggleMaximize(),
        ),
        WindowButton(
          icon: m.Icons.close_rounded,
          tooltip: '关闭',
          light: widget.light,
          danger: true,
          onTap: () => NativeWindow.market.hide(),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Row(children: [
        Expanded(
          child: TextBox(
            placeholder: '搜索插件',
            prefix: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: m.Icon(m.Icons.search_rounded, size: 15, color: _ink40),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: '刷新',
          child: IconButton(
            icon: m.Icon(m.Icons.refresh_rounded, size: 17, color: _ink60),
            onPressed: _loading ? null : _load,
          ),
        ),
      ]),
    );
  }

  Widget _content() {
    if (_loading && _plugins == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ProgressRing(),
          const SizedBox(height: 14),
          Text('正在连接市场…', style: TextStyle(fontSize: 12, color: _ink60)),
        ]),
      );
    }

    if (_error != null && _plugins == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          m.Icon(m.Icons.cloud_off_rounded, size: 34, color: _ink40),
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 13, color: _ink)),
          const SizedBox(height: 6),
          Text('地址：${_client.baseUrl}',
              style: TextStyle(fontSize: 11, color: _ink40)),
          const SizedBox(height: 14),
          Button(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }

    final list = _filtered;
    if (list.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? '市场里还没有插件' : '没有匹配「$_query」的插件',
          style: TextStyle(fontSize: 12, color: _ink60),
        ),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      // 卡片最窄 300：再窄描述就只剩半行，读不出这插件是干嘛的
      final cols = (c.maxWidth / 320).floor().clamp(1, 4);
      return GridView.count(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        crossAxisCount: cols,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 2.5,
        children: [for (final p in list) _pluginCard(p)],
      );
    });
  }

  Widget _pluginCard(MarketPlugin p) {
    final local = widget.registry[p.id]?.manifest;
    final state = installStateOf(p, local);
    final progress = _installing[p.id];
    final busy = progress != null;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 下载进度条压在卡片顶部，和 Microsoft Store 一样
          SizedBox(
            height: 3,
            child: busy
                ? ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(10)),
                    child: ProgressBar(
                      value: progress >= 0 ? progress * 100 : null,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: widget.light
                          ? const Color(0x0D000000)
                          : const Color(0x14FFFFFF),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(p.icon, style: const TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: _ink)),
                          ),
                          const SizedBox(width: 6),
                          Text('v${p.version}',
                              style:
                                  TextStyle(fontSize: 10.5, color: _ink40)),
                        ]),
                        const SizedBox(height: 3),
                        Text(p.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5, height: 1.35, color: _ink60)),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(
                            child: Text(
                                p.author.isEmpty ? ' ' : p.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    TextStyle(fontSize: 10.5, color: _ink40)),
                          ),
                          _actionButton(p, state, progress),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
      MarketPlugin p, InstallState state, double? progress) {
    if (progress != null) {
      return Text(
        progress >= 0 ? '${(progress * 100).round()}%' : '下载中…',
        style: TextStyle(fontSize: 11, color: _ink60),
      );
    }
    switch (state) {
      case InstallState.installed:
        return Text(_justDone.contains(p.id) ? '已安装 ✓' : '已安装',
            style: TextStyle(fontSize: 11, color: _ink40));
      case InstallState.updatable:
        return Button(
          onPressed: () => _install(p),
          child: const Text('更新', style: TextStyle(fontSize: 11)),
        );
      case InstallState.notInstalled:
        return FilledButton(
          onPressed: () => _install(p),
          child: const Text('安装', style: TextStyle(fontSize: 11)),
        );
    }
  }
}
