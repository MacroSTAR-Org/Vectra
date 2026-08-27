/// 控制面板：组件库 / 已放置 / 外观 / AI / 其他。
///
/// 纯 fluent_ui 原生实现，复刻 WinUI3 / Windows 11 Fluent Design 风格。
/// 全部使用 fluent_ui 控件，零 Material 依赖，零硬编码颜色。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/logger.dart';
import '../core/paths.dart';
import '../model/card.dart';
import '../model/settings.dart';
import '../native/native_bridge.dart';
import '../plugin/manifest.dart';
import '../plugin/registry.dart';
import '../store/store.dart';
import 'panel_app.dart' show panelThemeRevision;

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
    this.onInstallUpdate,
    this.embedded = true,
  });

  final bool embedded;
  final AppState state;
  final Store store;
  final PluginRegistry registry;
  final VoidCallback onClose;
  final VoidCallback onChanged;
  final void Function(PluginManifest plugin) onAdd;
  final void Function(WidgetCard card) onRemove;
  final bool Function(String pluginId)? canAdd;
  final String? focusCardId;
  final int? initialTab;
  final VoidCallback? onHotkeyChanged;
  final Future<bool> Function(String installerPath)? onInstallUpdate;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  late int _tab = widget.initialTab ?? (widget.focusCardId != null ? 1 : 0);

  PackageInfo? _pkgInfo;
  Color? _pickedColor;
  bool? _autoStart;
  String? _backupHint;
  bool _backupFailed = false;
  AppSettings get _s => widget.state.settings;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _pkgInfo = i);
    });
    NativeBridge.isAutoStart().then((on) {
      if (mounted) setState(() => _autoStart = on);
    });
  }

  @override
  void didUpdateWidget(covariant ControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // focusCardId / initialTab 变化时跳转
    if (widget.focusCardId != oldWidget.focusCardId) {
      setState(() => _tab = 1); // 已放置
    }
    if (widget.initialTab != oldWidget.initialTab && widget.initialTab != null) {
      setState(() => _tab = widget.initialTab!);
    }
  }

  void _commit() {
    widget.store.save(widget.state);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    // 独立窗口模式：铺满客户区
    if (!widget.embedded) {
      return NavigationView(
        pane: NavigationPane(
          selected: _tab,
          onChanged: (i) => setState(() => _tab = i),
          displayMode: PaneDisplayMode.expanded,
          size: const NavigationPaneSize(openWidth: 220),
          items: [
            PaneItem(
              icon: const Icon(FluentIcons.library),
              title: const Text('组件库'),
              body: _pageFrame('组件库', _library()),
            ),
            PaneItem(
              icon: const Icon(FluentIcons.view),
              title: Text('已放置 ${widget.state.cards.length}'),
              body: _pageFrame('已放置', _placed()),
            ),
            PaneItem(
              icon: const Icon(FluentIcons.color),
              title: const Text('外观'),
              body: _pageFrame('外观', _appearance()),
            ),
            PaneItem(
              icon: const Icon(FluentIcons.chat),
              title: const Text('AI'),
              body: _pageFrame('AI', _aiSettings()),
            ),
            PaneItem(
              icon: const Icon(FluentIcons.settings),
              title: const Text('其他'),
              body: _pageFrame('其他', _other()),
            ),
          ],
          footerItems: [
            PaneItem(
              icon: const Icon(FluentIcons.info),
              title: const Text('关于'),
              body: _pageFrame('关于', _about()),
            ),
          ],
        ),
        transitionBuilder: null,
      );
    }

    // 内嵌模式
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: Container(color: Colors.black.withValues(alpha: 0.6)),
          ),
        ),
        Center(
          child: Container(
            width: 720,
            height: 560,
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: NavigationView(
              pane: NavigationPane(
                selected: _tab,
                onChanged: (i) => setState(() => _tab = i),
                displayMode: PaneDisplayMode.compact,
                items: [
                  PaneItem(icon: const Icon(FluentIcons.library), title: const Text('组件库'), body: _pageFrame('组件库', _library())),
                  PaneItem(icon: const Icon(FluentIcons.view), title: Text('已放置 ${widget.state.cards.length}'), body: _pageFrame('已放置', _placed())),
                  PaneItem(icon: const Icon(FluentIcons.color), title: const Text('外观'), body: _pageFrame('外观', _appearance())),
                  PaneItem(icon: const Icon(FluentIcons.chat), title: const Text('AI'), body: _pageFrame('AI', _aiSettings())),
                  PaneItem(icon: const Icon(FluentIcons.settings), title: const Text('其他'), body: _pageFrame('其他', _other())),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pageFrame(String title, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text(title,
              style: FluentTheme.of(context).typography.title),
        ),
        Expanded(child: content),
      ],
    );
  }

  // ─── 通用卡片 ───────────────────────────────────────────────

  Widget _card({
    required String title,
    IconData? icon,
    Widget? trailing,
    required List<Widget> children,
  }) {
    final theme = FluentTheme.of(context);
    return Card(
      borderRadius: BorderRadius.circular(8),
      backgroundColor: theme.resources.cardBackgroundFillColorDefault,
      borderColor: theme.resources.cardStrokeColorDefault,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: theme.accentColor),
                  const SizedBox(width: 8),
                ],
                Text(title, style: theme.typography.bodyStrong),
              ]),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged, {String? description}) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.typography.body),
                if (description != null)
                  Text(description, style: _caption),
              ],
            ),
          ),
          ToggleSwitch(
            checked: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max, int divisions, ValueChanged<double> onChanged, {String suffix = ''}) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 176,
            child: Text(label, style: theme.typography.body),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '${value.round()}$suffix',
              style: theme.typography.caption,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  // ─── 组件库 ───────────────────────────────────────────────

  Widget _library() {
    final plugins = widget.registry.list();
    if (plugins.isEmpty) {
      return Center(
        child: Text('没有已安装的插件', style: _caption),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      itemCount: plugins.length,
      itemBuilder: (context, index) {
        final p = plugins[index];
        final added = widget.state.cards.where((c) => c.pluginId == p.id).length;
        final canAdd = widget.canAdd?.call(p.id) ?? true;
        return Card(
          borderRadius: BorderRadius.circular(8),
          backgroundColor: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
          borderColor: FluentTheme.of(context).resources.cardStrokeColorDefault,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
              children: [
                Icon(FluentIcons.page, size: 24, color: FluentTheme.of(context).accentColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: FluentTheme.of(context).typography.bodyStrong),
                      Text('${p.description}  ·  已放置 $added', style: _caption),
                    ],
                  ),
                ),
                Button(
                  onPressed: canAdd ? () => widget.onAdd(p) : null,
                  child: Text(canAdd ? '添加' : '已满'),
                ),
              ],
          ),
        );
      },
    );
  }

  // ─── 已放置 ───────────────────────────────────────────────

  Widget _placed() {
    final cards = widget.state.cards;
    if (cards.isEmpty) {
      return Center(
        child: Text('还没有放置任何卡片', style: _caption),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      itemCount: cards.length,
      itemBuilder: (context, index) {
        final c = cards[index];
        final plugin = widget.registry[c.pluginId];
        return Card(
          borderRadius: BorderRadius.circular(8),
          backgroundColor: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
          borderColor: FluentTheme.of(context).resources.cardStrokeColorDefault,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
              children: [
                Icon(FluentIcons.page, size: 24, color: FluentTheme.of(context).accentColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plugin?.manifest.name ?? c.pluginId, style: FluentTheme.of(context).typography.bodyStrong),
                      Text('尺寸 ${c.size}  ·  ${c.monitorId ?? "默认屏幕"}', style: _caption),
                    ],
                  ),
                ),
                Button(
                  child: const Text('移除'),
                  onPressed: () => widget.onRemove(c),
                ),
              ],
          ),
        );
      },
    );
  }

  // ─── 外观 ───────────────────────────────────────────────

  Widget _appearance() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        // 布局与吸附
        _card(
          title: '布局与吸附',
          icon: FluentIcons.grid_view_medium,
          children: [
            _sliderRow('网格单元大小', _s.gridCell.toDouble(), 72, 180, 27, (v) {
              _s.gridCell = v.round();
              _commit();
            }, suffix: 'px'),
            _sliderRow('网格间距', _s.gridGap.toDouble(), 0, 32, 16, (v) {
              _s.gridGap = v.round();
              _commit();
            }, suffix: 'px'),
            _sliderRow('吸附阈值', _s.snapThreshold, 2, 40, 38, (v) {
              _s.snapThreshold = v;
              _commit();
            }, suffix: 'px'),
            _toggleRow('磁吸对齐', _s.snapEnabled, (v) {
              _s.snapEnabled = v;
              _commit();
            }),
            _toggleRow('锁定布局', _s.locked, (v) {
              _s.locked = v;
              _commit();
            }),
            _toggleRow('动画效果', _s.animations, (v) {
              _s.animations = v;
              _commit();
            }),
          ],
        ),

        // 卡片材质
        _card(
          title: '卡片材质',
          icon: FluentIcons.blur,
          children: [
            // 材质选择
            RadioGroup<String>(
              groupValue: _s.material,
              onChanged: (v) {
                if (v != null) {
                  _s.material = v;
                  _commit();
                }
              },
              child: Column(
                children: [
                  _radioRow('不透明 (Opaque)', 'opaque'),
                  _radioRow('毛玻璃 (Acrylic)', 'acrylic'),
                  _radioRow('云母 (Mica)', 'mica'),
                ],
              ),
            ),
            _sliderRow('圆角', _s.cardRadius, 0, 40, 40, (v) {
              _s.cardRadius = v;
              _commit();
            }, suffix: 'px'),

            if (_s.material != 'opaque') ...[
              _sliderRow('透明度', 1 - _s.glassTint, 0, 1, 20, (v) {
                _s.glassTint = 1 - v;
                _commit();
              }),
              _sliderRow('模糊强度', _s.glassBlur, 0, 40, 40, (v) {
                _s.glassBlur = v;
                _commit();
              }, suffix: 'px'),
              if (_s.material != 'mica')
                _liveRefreshRadio()
              else
                Text('云母只跟壁纸走，不需要刷新。', style: _caption),
            ],
          ],
        ),

        // 卡片底色
        _card(
          title: '卡片底色',
          icon: FluentIcons.color,
          children: [
            _toggleRow('从壁纸取色 (莫奈取色)', _s.autoColorFromWallpaper, (v) {
              _s.autoColorFromWallpaper = v;
              _commit();
            }),
            _toggleRow('文字颜色也用取色', _s.autoForegroundFromWallpaper, (v) {
              _s.autoForegroundFromWallpaper = v;
              _commit();
            }),
            // 颜色选择
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
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
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Color(c),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _s.cardColor == c
                                ? FluentTheme.of(context).accentColor
                                : FluentTheme.of(context).resources.cardStrokeColorDefault,
                            width: _s.cardColor == c ? 2 : 1,
                          ),
                        ),
                        child: _s.cardColor == c
                            ? const Icon(FluentIcons.check_mark, size: 14, color: Colors.white)
                            : null,
                      ),
                    ),
                  // 自定义颜色按钮
                  GestureDetector(
                    onTap: _openColorPicker,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: FluentTheme.of(context).resources.cardStrokeColorDefault),
                      ),
                      child: Icon(FluentIcons.color, size: 14, color: FluentTheme.of(context).accentColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // 主题
        _card(
          title: '主题',
          icon: FluentIcons.brightness,
          children: [
            RadioGroup<String>(
              groupValue: _s.theme,
              onChanged: (v) {
                if (v != null) {
                  _s.theme = v;
                  _commit();
                  // 通知 panel_app 重建 FluentApp
                  panelThemeRevision.value++;
                }
              },
              child: Column(
                children: [
                  _radioRow('跟随系统', 'auto'),
                  _radioRow('浅色', 'light'),
                  _radioRow('深色', 'dark'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _radioRow(String label, String value) {
    return RadioButton<String>(
      value: value,
      content: Text(label, style: FluentTheme.of(context).typography.body),
    );
  }

  Widget _liveRefreshRadio() {
    const options = [
      (0, '静态'),
      (1000, '1 秒'),
      (200, '5 fps'),
      (66, '15 fps'),
      (33, '30 fps'),
      (16, '60 fps'),
    ];
    return RadioGroup<int>(
      groupValue: _s.liveRefreshMs,
      onChanged: (v) {
        if (v != null) {
          _s.liveRefreshMs = v;
          _commit();
        }
      },
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final o in options)
            RadioButton<int>(
              value: o.$1,
              content: Text(o.$2, style: FluentTheme.of(context).typography.body),
            ),
        ],
      ),
    );
  }

  Future<void> _openColorPicker() async {
    final result = await showDialog<Color>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('选择颜色'),
        content: SizedBox(
          height: 300,
          child: ColorPicker(
            color: Color(_s.cardColor),
            onChanged: (color) {
              _pickedColor = color;
            },
          ),
        ),
        actions: [
          Button(
            child: const Text('取消'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          FilledButton(
            child: const Text('确定'),
            onPressed: () {
              if (_pickedColor != null) {
                _s.cardColor = _pickedColor!.toARGB32();
                _commit();
              }
              Navigator.of(context).pop(_pickedColor);
            },
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() {});
    }
  }

  // ─── AI 设置 ───────────────────────────────────────────────

  Widget _aiSettings() {
    final ai = widget.state.ai;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _card(
          title: '接口',
          icon: FluentIcons.globe,
          children: [
            _textBoxRow('Base URL', ai.baseUrl, (v) { ai.baseUrl = v.trim(); _commit(); },
                placeholder: 'https://api.openai.com/v1'),
            _textBoxRow('API Key', ai.apiKey, (v) { ai.apiKey = v.trim(); _commit(); },
                obscure: true),
            _textBoxRow('模型', ai.model, (v) { ai.model = v.trim(); _commit(); },
                placeholder: 'gpt-4o-mini'),
            _sliderRow('温度', ai.temperature, 0, 2, 20, (v) {
              ai.temperature = double.parse(v.toStringAsFixed(1));
              _commit();
            }),
            _sliderRow('历史条数', ai.maxHistory.toDouble(), 2, 60, 29, (v) {
              ai.maxHistory = v.round();
              _commit();
            }),
          ],
        ),

        _card(
          title: '对话',
          icon: FluentIcons.chat,
          children: [
            Text('系统提示词', style: FluentTheme.of(context).typography.body),
            const SizedBox(height: 8),
            TextBox(
              maxLines: 5,
              minLines: 3,
              controller: TextEditingController(text: ai.systemPrompt),
              onChanged: (v) {
                ai.systemPrompt = v;
                _commit();
              },
            ),
            Text('改动自动保存', style: _caption),
          ],
        ),

        _card(
          title: '外观',
          icon: FluentIcons.color,
          children: [
            _sliderRow('侧边栏宽度', ai.sidebarWidth, 280, 640, 36, (v) {
              ai.sidebarWidth = v;
              _commit();
            }, suffix: 'px'),
            _sliderRow('侧边栏圆角', ai.radius, 0, 48, 24, (v) {
              ai.radius = v;
              _commit();
            }, suffix: 'px'),
            _toggleRow('毛玻璃效果', ai.glass, (v) {
              ai.glass = v;
              _commit();
            }),
            if (ai.glass)
              _sliderRow('不透明度', ai.tint, 0, 1, 20, (v) {
                ai.tint = v;
                _commit();
              }),
          ],
        ),

        _card(
          title: '行为',
          icon: FluentIcons.settings,
          children: [
            _toggleRow('Agent 能力', ai.agent, (v) {
              ai.agent = v;
              _commit();
            }, description: '让 AI 操作电脑与读文件'),
            _toggleRow('右下角投放点', ai.dock, (v) {
              ai.dock = v;
              _commit();
            }, description: '拖文件到屏幕右下角小方块'),
          ],
        ),

        _card(
          title: '快捷键',
          icon: FluentIcons.keyboard_classic,
          children: [
            Row(
              children: [
                for (final mod in const [
                  ('Ctrl', 2),
                  ('Alt', 1),
                  ('Shift', 4),
                  ('Win', 8),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                      checked: ai.hotkeyMods & mod.$2 != 0,
                      onChanged: (v) {
                        ai.hotkeyMods = v == true
                            ? ai.hotkeyMods | mod.$2
                            : ai.hotkeyMods & ~mod.$2;
                        _commit();
                        widget.onHotkeyChanged?.call();
                      },
                      content: Text(mod.$1, style: FluentTheme.of(context).typography.body),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ComboBox<int>(
              value: ai.hotkeyVk,
              items: const [
                ComboBoxItem(value: 32, child: Text('Space')),
                ComboBoxItem(value: 65, child: Text('A')),
                ComboBoxItem(value: 68, child: Text('D')),
                ComboBoxItem(value: 81, child: Text('Q')),
                ComboBoxItem(value: 87, child: Text('W')),
                ComboBoxItem(value: 112, child: Text('F1')),
                ComboBoxItem(value: 113, child: Text('F2')),
                ComboBoxItem(value: 122, child: Text('F11')),
                ComboBoxItem(value: 123, child: Text('F12')),
              ],
              onChanged: (v) {
                if (v != null) {
                  ai.hotkeyVk = v;
                  _commit();
                  widget.onHotkeyChanged?.call();
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  // ─── 其他 ───────────────────────────────────────────────

  Widget _other() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _card(
          title: '软件更新',
          icon: FluentIcons.download,
          children: [
            _toggleRow('自动下载更新', _s.autoDownloadUpdate, (v) {
              _s.autoDownloadUpdate = v;
              _commit();
            }),
            const SizedBox(height: 4),
            Text('更新源', style: FluentTheme.of(context).typography.body),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _s.updateSource,
              onChanged: (v) {
                if (v != null) {
                  _s.updateSource = v;
                  _commit();
                }
              },
              child: Column(
                children: [
                  _radioRow('自动', 'auto'),
                  _radioRow('Unisphere', 'unisphere'),
                  _radioRow('GitHub', 'github'),
                ],
              ),
            ),
            Text('自动 = 先问 Unisphere，连不上再试 GitHub Releases。',
                style: _caption),
          ],
        ),

        _card(
          title: '启动',
          icon: FluentIcons.power_button,
          children: [
            if (_autoStart == null)
              const ProgressRing()
            else
              _toggleRow('开机时自动启动 Vectra', _autoStart!, (v) => _toggleAutoStart(v)),
            Text('登记在当前用户的启动项里，不需要管理员权限。',
                style: _caption),
          ],
        ),

        _card(
          title: '日志',
          icon: FluentIcons.page,
          children: [
            Text(AppPaths.logsDir, style: _caption),
            const SizedBox(height: 8),
            Button(
              child: const Text('打开日志目录'),
              onPressed: () => NativeBridge.openLogDir(AppPaths.logsDir),
            ),
          ],
        ),

        _card(
          title: '备份',
          icon: FluentIcons.download,
          children: [
            Row(
              children: [
                Button(
                  child: const Text('导出备份'),
                  onPressed: _exportBackup,
                ),
                const SizedBox(width: 8),
                Button(
                  child: const Text('导入备份'),
                  onPressed: _importBackup,
                ),
              ],
            ),
            if (_backupHint != null) ...[
              const SizedBox(height: 8),
              InfoBar(
                severity: _backupFailed ? InfoBarSeverity.error : InfoBarSeverity.success,
                title: Text(_backupHint!),
              ),
            ],
          ],
        ),

        _card(
          title: '关于',
          icon: FluentIcons.info,
          children: [
            _infoRow('版本', _pkgInfo == null ? '获取中…' : 'v${_pkgInfo!.version}.${_pkgInfo!.buildNumber}'),
            _infoRow('作者', 'MacroSTAR Studio © 2026'),
            _infoRow('数据', widget.store.dir),
            const SizedBox(height: 8),
            HyperlinkButton(
              onPressed: () => launchUrl(Uri.parse('https://github.com/MacroSTAR-Org/Vectra')),
              child: const Text('GitHub 仓库'),
            ),
          ],
        ),
      ],
    );
  }

  // ─── 关于 ───────────────────────────────────────────────

  Widget _about() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _card(
          title: '关于',
          icon: FluentIcons.info,
          children: [
            _infoRow('版本', _pkgInfo == null ? '获取中…' : 'v${_pkgInfo!.version}.${_pkgInfo!.buildNumber}'),
            _infoRow('作者', 'MacroSTAR Studio © 2026'),
            _infoRow('数据', widget.store.dir),
            const SizedBox(height: 8),
            HyperlinkButton(
              onPressed: () => launchUrl(Uri.parse('https://github.com/MacroSTAR-Org/Vectra')),
              child: const Text('GitHub 仓库'),
            ),
          ],
        ),
      ],
    );
  }

  /// WinUI3 caption：80% 透明度，辅助说明用
  TextStyle? get _caption =>
      FluentTheme.of(context).typography.caption?.copyWith(
          color: FluentTheme.of(context)
              .typography
              .caption
              ?.color
              ?.withValues(alpha: 0.8));

  // ─── 通用 helper ───────────────────────────────────────────────

  Widget _textBoxRow(String label, String value, ValueChanged<String> onChanged,
      {String? placeholder, bool obscure = false}) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 176,
            child: Text(label, style: theme.typography.body),
          ),
          Expanded(
            child: obscure
                ? PasswordBox(
                    placeholder: placeholder,
                    onChanged: onChanged,
                  )
                : TextBox(
                    placeholder: placeholder,
                    onChanged: onChanged,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 176,
            child: Text(label, style: theme.typography.body),
          ),
          Expanded(
            child: Text(value, style: _caption),
          ),
        ],
      ),
    );
  }

  // ─── 业务逻辑（保持不变） ───────────────────────────────────────

  Future<void> _toggleAutoStart(bool on) async {
    setState(() => _autoStart = on);
    Log.i('panel', '开机自启 -> $on');
    try {
      final actual = await NativeBridge.setAutoStart(on);
      if (actual != on) {
        if (mounted) setState(() => _autoStart = actual);
      }
    } catch (e) {
      Log.e('panel', '开机自启写入失败: $e');
      if (mounted) setState(() => _autoStart = !on);
    }
  }

  Future<void> _exportBackup() async {
    final path = await FilePicker.saveFile(
      dialogTitle: '导出备份',
      fileName: 'vectra-backup.json',
    );
    if (path == null) return;
    try {
      final json = widget.store.encodeConfig(widget.state);
      await File(path).writeAsString(json);
      if (mounted) {
        setState(() {
          _backupHint = '已导出到 $path';
          _backupFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backupHint = '导出失败: $e';
          _backupFailed = true;
        });
      }
    }
  }

  Future<void> _importBackup() async {
    final result = await FilePicker.pickFiles(
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    try {
      final json = await File(result.files.first.path!).readAsString();
      widget.store.decodeConfig(json);
      _commit();
      if (mounted) {
        setState(() {
          _backupHint = '导入成功';
          _backupFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backupHint = '导入失败: $e';
          _backupFailed = true;
        });
      }
    }
  }
}
