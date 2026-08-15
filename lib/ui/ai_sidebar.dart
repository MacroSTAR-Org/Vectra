/// AI 侧边栏：贴在屏幕右侧的对话面板。
///
/// 它不是磁贴——磁贴是常驻桌面层的，而侧边栏是按快捷键唤出的临时界面，
/// 需要浮到所有窗口之上并抢键盘焦点，所以做成宿主级 UI，和控制面板同层。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../ai/chat_client.dart';
import '../ai/file_parser.dart';
import '../ai/tools.dart';
import '../model/ai_settings.dart';
import 'wallpaper.dart';

/// native 把拖进来的文件路径投到这里，侧边栏监听后自己解析成附件。
///
/// 为什么走这么一个全局 notifier 而不是把路径一层层传下来：投放事件是从
/// C++ 直接来的，它到达的时刻和 widget 树的重建时机没有关系——上面那层
/// （_SidebarHost）拿到之后再作为参数传下来，就得额外维护"已经消费过了吗"
/// 的状态。和已有的 Wallpaper.image 是同一种用法。
class SidebarDrop {
  /// 一批待处理的文件路径。消费方处理完必须置回空列表。
  static final ValueNotifier<List<String>> files =
      ValueNotifier(const <String>[]);

  static void push(List<String> paths) {
    if (paths.isEmpty) return;
    files.value = paths;
  }
}

/// 侧边栏自己的深浅色调色板。
///
/// 和设置面板的 _PanelColors 同一套思路：深色用深底白字，浅色用浅底近黑字。
/// 侧边栏是独立引擎，外层（sidebar_main.dart）按"主题偏好 + 系统深浅色"
/// 算出 light 后传进来，这里只负责取色。
class _SidebarColors {
  const _SidebarColors(this.light);

  final bool light;

  /// 染色层底色
  Color get bg => light ? Color(0xFFF3F3F6) : Color(0xFF17171B);

  /// 主文字
  Color get ink => light ? Color(0xFF16181C) : Color(0xFFFFFFFF);
  Color get ink70 => light ? Color(0xB316181C) : Color(0xB3FFFFFF);
  Color get ink54 => light ? Color(0x8A16181C) : Color(0x8AFFFFFF);
  Color get ink38 => light ? Color(0x6116181C) : Color(0x61FFFFFF);
  Color get ink30 => light ? Color(0x4D16181C) : Color(0x4DFFFFFF);
  Color get ink24 => light ? Color(0x3D16181C) : Color(0x3DFFFFFF);

  /// 主题蓝：深色亮蓝、浅色深蓝
  Color get accent => light ? Color(0xFF1565C0) : Color(0xFF7CC7FF);
  Color get accentBg => light ? Color(0x331565C0) : Color(0x337CC7FF);

  /// 左侧描边 / 分隔线 / 输入框底
  Color get border => light ? Color(0x24000000) : Color(0x24FFFFFF);
  Color get divider => light ? Color(0x14000000) : Color(0x14FFFFFF);
  Color get inputFill => light ? Color(0x14000000) : Color(0x14FFFFFF);

  /// 气泡底：用户 = 蓝、助手 = 底色上的浅浮雕
  Color get bubbleUser => light ? Color(0x331565C0) : Color(0x337CC7FF);
  Color get bubbleAssistant => light ? Color(0x14000000) : Color(0x14FFFFFF);

  /// 错误 / 警告：浅色下文字要加深才可读
  Color get errorText => light ? Color(0xFFB3261E) : Color(0xFFFFB4B4);
  Color get warnTitle => light ? Color(0xFF8A3B1E) : Color(0xFFFFC7B0);

  /// 附件小芯片底
  Color get chipBg => light ? Color(0x1F000000) : Color(0x1FFFFFFF);

  /// 确认卡片里的命令文字
  Color get cmdInk => light ? Color(0xB316181C) : Color(0xB3FFFFFF);
}

class AiSidebar extends StatefulWidget {
  const AiSidebar({
    super.key,
    required this.settings,
    required this.light,
    required this.messages,
    required this.onClose,
    required this.onOpenSettings,
    required this.onChanged,
    required this.animate,
    required this.rect,
    this.pinned = false,
    this.onPinnedChanged,
  });

  /// 钉住：不因失去焦点而自动收起。从资源管理器往里拖文件必须先点资源管理器，
  /// 那一下就会让侧边栏失活，不钉住的话窗口在文件到达之前就没了。
  final bool pinned;
  final ValueChanged<bool>? onPinnedChanged;

  final AiSettings settings;

  /// 生效明暗（外层按主题偏好 + 系统深浅色算好传入）
  final bool light;

  /// 会话历史由外层持有，关掉侧边栏不丢
  final List<ChatMessage> messages;
  final VoidCallback onClose;
  final VoidCallback onOpenSettings;

  /// 历史变化后通知外层落盘
  final VoidCallback onChanged;
  final bool animate;

  /// 侧边栏在窗口内的逻辑坐标与尺寸。由外层按工作区算好传进来，
  /// 这样它就停在任务栏之上，而不是压到任务栏上面去。
  final Rect rect;

  @override
  State<AiSidebar> createState() => _AiSidebarState();
}

class _AiSidebarState extends State<AiSidebar> {
  final _client = ChatClient();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  bool _sending = false;

  _SidebarColors get _c => _SidebarColors(widget.light);

  /// 等待用户确认的危险工具调用
  _PendingApproval? _pending;

  /// 已附加、还没发出去的文件
  final List<ParsedFile> _attachments = [];

  @override
  void initState() {
    super.initState();
    // 唤出来就能直接打字，不用再点一下输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputFocus.requestFocus();
      _scrollToEnd();
    });
    SidebarDrop.files.addListener(_takeDropped);
    // 挂上监听之前可能已经投过一批（右下角投放点会先让 native 显示窗口，
    // 再把路径推过来，两件事的先后不由这边控制）。先消费一次当前值。
    _takeDropped();
  }

  @override
  void dispose() {
    SidebarDrop.files.removeListener(_takeDropped);
    _client.abort();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 消费 native 投过来的文件路径：解析成文字挂成附件。
  Future<void> _takeDropped() async {
    final paths = SidebarDrop.files.value;
    if (paths.isEmpty) return;
    // 先清空再解析，避免解析过程中又来一批时把这批重复处理一遍
    SidebarDrop.files.value = const <String>[];
    await _attachPaths(paths);
  }

  Future<void> _attachPaths(List<String> paths) async {
    for (final path in paths) {
      try {
        final parsed = await FileParser.parse(path);
        if (!mounted) return;
        setState(() => _attachments.add(parsed));
      } catch (e) {
        if (!mounted) return;
        setState(() => widget.messages.add(ChatMessage(
            role: 'assistant',
            content: '读不了 ${p.basename(path)}：$e',
            error: true)));
      }
    }
    if (mounted) {
      _inputFocus.requestFocus();
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: Duration(milliseconds: widget.animate ? 200 : 0),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    if (!widget.settings.configured) {
      setState(() {
        widget.messages.add(ChatMessage(
            role: 'assistant',
            content: '还没配置 API Key 或 Base URL，点右上角齿轮去填。',
            error: true));
      });
      return;
    }

    _input.clear();

    // 附件解析成的文字直接拼进这条用户消息
    final buf = StringBuffer();
    for (final f in _attachments) {
      buf.writeln(f.forPrompt());
    }
    buf.write(text);
    final names = _attachments.map((f) => '📎 ${f.name}').join('\n');
    final shownText = _attachments.isEmpty ? text : '$names\n$text';

    final userMsg = ChatMessage(role: 'user', content: buf.toString());
    // 界面上只显示文件名，别把整篇文件内容糊在气泡里
    userMsg.displayOverride = shownText;

    setState(() {
      widget.messages.add(userMsg);
      _attachments.clear();
      _sending = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    await _runAgentLoop();
  }

  /// Agent 主循环：模型可能连续要求调用多轮工具，每轮把结果回灌再问一次。
  /// 设上限，防止模型在工具之间来回打转把额度烧光。
  Future<void> _runAgentLoop() async {
    const maxRounds = 8;
    try {
      for (var round = 0; round < maxRounds; round++) {
        final reply = ChatMessage(role: 'assistant', content: '');
        setState(() => widget.messages.add(reply));

        List<Map<String, Object?>>? calls;
        await _client.send(
          cfg: widget.settings,
          history: widget.messages.sublist(0, widget.messages.length - 1),
          tools: widget.settings.agent ? Tools.schemas() : null,
          onToolCalls: (c) => calls = c,
          onDelta: (d) {
            if (!mounted) return;
            setState(() => reply.content += d);
            _scrollToEnd();
          },
        );

        if (calls == null || calls!.isEmpty) {
          if (reply.content.isEmpty) {
            reply.content = '（模型没有返回内容）';
            reply.error = true;
          }
          break;
        }

        reply.toolCalls = calls;
        if (reply.content.isEmpty) reply.content = '';

        // 逐个执行；危险的先等用户点允许
        for (final call in calls!) {
          final fn = (call['function'] as Map?)?.cast<String, Object?>();
          final name = '${fn?['name']}';
          final argRaw = '${fn?['arguments'] ?? '{}'}';
          Map<String, Object?> args = {};
          try {
            args = (jsonDecode(argRaw.isEmpty ? '{}' : argRaw) as Map)
                .cast<String, Object?>();
          } catch (_) {}

          final tool = Tools.byName(name);
          String result;
          if (tool == null) {
            result = '没有这个工具：$name';
          } else if (tool.risk == ToolRisk.danger) {
            final ok = await _askApproval(tool, args);
            result = ok
                ? await _safeRun(tool, args)
                : '用户拒绝了这次操作。请不要重试，换个思路或直接告诉用户。';
          } else {
            result = await _safeRun(tool, args);
          }

          setState(() {
            widget.messages.add(ChatMessage(
              role: 'tool',
              content: result,
              toolCallId: '${call['id']}',
              toolName: name,
            ));
          });
          _scrollToEnd();
        }
      }
    } catch (e) {
      setState(() {
        widget.messages.add(
            ChatMessage(role: 'assistant', content: '$e', error: true));
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        widget.onChanged();
        _scrollToEnd();
      }
    }
  }

  Future<String> _safeRun(ToolDef tool, Map<String, Object?> args) async {
    try {
      return await tool.run(args);
    } catch (e) {
      // 工具出错要把错误交回模型，让它自己决定重试还是换路子
      return '工具执行失败：$e';
    }
  }

  /// 弹确认卡片，等用户点。返回是否允许。
  Future<bool> _askApproval(ToolDef tool, Map<String, Object?> args) async {
    final completer = Completer<bool>();
    setState(() => _pending = _PendingApproval(tool, args, completer));
    _scrollToEnd();
    final ok = await completer.future;
    if (mounted) setState(() => _pending = null);
    return ok;
  }

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.pickFiles(allowMultiple: true);
      if (res == null) return;
      await _attachPaths(
          [for (final f in res.files) if (f.path != null) f.path!]);
    } catch (e) {
      stderr.writeln('[ai] 选文件失败: $e');
    }
  }

  void _stop() {
    _client.abort();
    setState(() => _sending = false);
  }

  void _clear() {
    setState(widget.messages.clear);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.settings;
    final r = widget.rect;
    // 只圆左边两个角：右侧紧贴屏幕边缘，圆角会在边上露出缺口
    final shape = BorderRadius.only(
      topLeft: Radius.circular(cfg.radius),
      bottomLeft: Radius.circular(cfg.radius),
    );

    // 这里刻意不返回 Positioned：Positioned 只能作为 Stack 的**直接**子节点，
    // 中间隔着 AnimatedSwitcher 和 Focus 就失效了，布局会整个错乱
    // （实测表现为侧边栏内容全部消失，只剩一块半透明板）。定位由外层负责。
    return SizedBox(
      width: r.width,
      height: r.height,
      child: ClipRRect(
        borderRadius: shape,
        child: Stack(
          children: [
            // 毛玻璃：和磁贴同一张预模糊图，按本控件的屏幕位置反向偏移，
            // 于是背景和桌面严丝合缝地对上
            if (cfg.glass)
              Positioned.fill(
                child: ValueListenableBuilder<ui.Image?>(
                  valueListenable: Wallpaper.image,
                  builder: (context, img, _) {
                    if (img == null) return const SizedBox.shrink();
                    final s = 1 / Wallpaper.scale;
                    return OverflowBox(
                      alignment: Alignment.topLeft,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform.translate(
                        offset: Offset(-r.left, -r.top),
                        child: RawImage(
                          image: img,
                          width: img.width * s,
                          height: img.height * s,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    );
                  },
                ),
              ),
            // 染色层：浓度单独可调，聊天要长时间读字，通常比磁贴更实
            Positioned.fill(
              child: ColoredBox(
                color: _c.bg.withValues(
                    alpha: cfg.glass ? cfg.tint.clamp(0.0, 1.0) : 1.0),
              ),
            ),
            // 左侧描边，让它和桌面分开
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: shape,
                    border: Border.all(color: _c.border, width: 1),
                  ),
                ),
              ),
            ),
            Column(
              children: [
                _header(),
                Expanded(child: _list()),
                _composer(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 头部的小图标按钮。IconButton 默认最小 48x48，四个排下来在 380 宽的
  /// 侧边栏里会把标题挤没，所以统一收成 30x30。
  Widget _headerButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String tooltip,
    Color? color,
    double size = 17,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: size),
      color: color ?? _c.ink38,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _c.divider)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 15, color: _c.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 助手',
                    style: TextStyle(fontSize: 13, color: _c.ink)),
                Text(widget.settings.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: _c.ink30)),
              ],
            ),
          ),
          _headerButton(
            onPressed: () => widget.onPinnedChanged?.call(!widget.pinned),
            icon: widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
            size: 15,
            color: widget.pinned ? _c.accent : _c.ink38,
            tooltip: widget.pinned
                ? '已钉住：点外面不会收起，可以从资源管理器拖文件进来'
                : '钉住，点外面不自动收起',
          ),
          _headerButton(
            onPressed: widget.messages.isEmpty ? null : _clear,
            icon: Icons.delete_sweep_outlined,
            tooltip: '清空对话',
          ),
          _headerButton(
            onPressed: widget.onOpenSettings,
            icon: Icons.settings_outlined,
            tooltip: 'AI 设置',
          ),
          _headerButton(
            onPressed: widget.onClose,
            icon: Icons.close,
            tooltip: '关闭（Esc）',
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (widget.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 26, color: _c.accentBg),
              const SizedBox(height: 10),
              Text(
                widget.settings.configured
                    ? '问点什么吧\n${widget.settings.hotkeyLabel()} 可以随时唤出或收起'
                    : '还没配置\n点右上角齿轮填 API Key 与 Base URL',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11, color: _c.ink24, height: 1.6),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: widget.messages.length + (_pending != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= widget.messages.length) return _approvalCard(_pending!);
        return _bubble(widget.messages[i]);
      },
    );
  }

  /// 工具调用/结果用紧凑的一行显示，不占聊天气泡的视觉重量
  Widget _toolLine(ChatMessage m) {
    final ok = !m.content.startsWith('工具执行失败') &&
        !m.content.startsWith('用户拒绝');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(ok ? Icons.build_circle_outlined : Icons.error_outline,
            size: 13,
            color: ok ? const Color(0xFF7CE38B) : const Color(0xFFFF9E7D)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${m.toolName ?? "工具"} · ${m.content.replaceAll("\n", " ")}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: _c.ink38),
          ),
        ),
      ]),
    );
  }

  /// 危险操作的确认卡片。把要执行的东西原样摆出来再问，
  /// 而不是只说"要执行一个操作吗"。
  Widget _approvalCard(_PendingApproval p) {
    final detail = p.tool.name == 'run_powershell'
        ? '${p.args['script']}'
        : const JsonEncoder.withIndent('  ').convert(p.args);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x22FF9E7D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x55FF9E7D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded,
                size: 15, color: Color(0xFFFF9E7D)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(p.tool.summarize?.call(p.args) ?? p.tool.name,
                  style: TextStyle(
                      fontSize: 12,
                      color: _c.warnTitle,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: const Color(0x33000000),
                borderRadius: BorderRadius.circular(6)),
            child: SelectableText(detail,
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: _c.cmdInk,
                    fontFamily: 'Consolas')),
          ),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(
              onPressed: () => p.completer.complete(true),
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  backgroundColor: const Color(0xFFFF9E7D),
                  foregroundColor: const Color(0xFF20140F)),
              child: const Text('允许', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => p.completer.complete(false),
              style: TextButton.styleFrom(minimumSize: const Size(0, 30)),
              child: Text('拒绝',
                  style: TextStyle(fontSize: 12, color: _c.ink54)),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    if (m.role == 'tool') return _toolLine(m);
    // 有工具调用但没有正文的助手消息不必占一个空气泡
    if (m.role == 'assistant' &&
        m.content.trim().isEmpty &&
        (m.toolCalls?.isNotEmpty ?? false)) {
      return const SizedBox.shrink();
    }
    final isUser = m.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: widget.settings.sidebarWidth * 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: m.error
                ? const Color(0x33FF6B6B)
                : (isUser ? _c.bubbleUser : _c.bubbleAssistant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            m.displayOverride ?? (m.content.isEmpty ? '…' : m.content),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: m.error ? _c.errorText : _c.ink,
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _c.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in _attachments)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: _c.chipBg,
                          borderRadius: BorderRadius.circular(6)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.description_outlined,
                            size: 12, color: _c.ink54),
                        const SizedBox(width: 5),
                        Text(f.name,
                            style: TextStyle(
                                fontSize: 10.5, color: _c.ink70)),
                        const SizedBox(width: 5),
                        GestureDetector(
                          onTap: () => setState(() => _attachments.remove(f)),
                          child: Icon(Icons.close,
                              size: 12, color: _c.ink38),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
          Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: _pickFiles,
            icon: const Icon(Icons.attach_file, size: 18),
            color: _c.ink38,
            tooltip: '添加文件',
          ),
          Expanded(
            child: Shortcuts(
              // 回车发送、Shift+回车换行
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
              },
              child: Actions(
                actions: {
                  _SendIntent: CallbackAction<_SendIntent>(
                      onInvoke: (_) => _send()),
                },
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  maxLines: 5,
                  minLines: 1,
                  style: TextStyle(fontSize: 12.5, color: _c.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '说点什么…（Enter 发送，Shift+Enter 换行）',
                    hintStyle: TextStyle(
                        fontSize: 11, color: _c.ink24),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    filled: true,
                    fillColor: _c.inputFill,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sending
              ? IconButton(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  color: const Color(0xFFFF9E7D),
                  tooltip: '停止',
                )
              : IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward),
                  color: _c.accent,
                  tooltip: '发送',
                ),
        ],
      ),
        ],
      ),
    );
  }
}

/// 一次待确认的危险操作
class _PendingApproval {
  _PendingApproval(this.tool, this.args, this.completer);
  final ToolDef tool;
  final Map<String, Object?> args;
  final Completer<bool> completer;
}

class _SendIntent extends Intent {
  const _SendIntent();
}
