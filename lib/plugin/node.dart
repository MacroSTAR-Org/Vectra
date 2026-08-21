/// 声明式 UI 协议：插件不碰 DOM，也碰不到 Flutter，只返回一棵 JSON 描述的树。
///
/// 这是 Flutter 版与 Electron 版最根本的差异。那边插件直接拿 HTMLElement 往里
/// 塞 DOM；Dart 是 AOT 编译的，release 版没法加载第三方 Dart 代码，所以插件
/// 只能"描述"界面，由宿主翻译成 Flutter widget。
///
/// 节点类型故意保持小：够画完 4 个官方插件即可。多加一种类型就多一份要长期
/// 兼容的协议表面。
///
/// 动画有两档，都由插件显式声明：
///   - 根节点 `key`：整卡内容切换时交叉淡入（日历翻月把 key 设成 "2026-8"；
///     歌词切歌把 key 设成歌名|歌手）
///   - `flip` 节点：3D X 轴翻转（从下往上），带淡入淡出
///   - 节点 `animKey`：**已禁用**（真实渲染下换行动画闪白，见 _child 注释），
///     字段保留在协议里兼容旧插件，宿主不再产生动画
library;

import 'package:flutter/material.dart';

import 'images.dart';
import 'registry.dart';

/// 事件回调：插件在树里声明 {"t":"tap","id":"h1"}，点中时回调 h1
typedef PluginEvent = void Function(String handlerId, Map<String, Object?> payload);

/// 插件内部控件正在接管这次指针操作，桌面层不要把它当成"拖动卡片"。
///
/// 背景：DesktopSurface 在整个桌面上挂了一个 Listener，指针在卡片上按下就开始
/// 拖卡片。这对点击没问题（没移动就不算拖），但对滑条是致命的——拖进度条会
/// 把整张卡片一起拖走。
///
/// Flutter 的指针事件是**从最内层往外层**依次派发的，所以滑条在自己的
/// onPointerDown 里置位，外层 Listener 随后就能读到。
class PluginPointer {
  PluginPointer._();

  /// 正在被插件控件抓住的指针 id；null 表示没有
  static int? grabbedPointer;

  static bool isGrabbed(int pointer) => grabbedPointer == pointer;
}

class PluginView extends StatefulWidget {
  const PluginView({
    super.key,
    required this.tree,
    required this.onEvent,
    this.animate = true,
    this.registry,
  });

  /// 插件返回的 UI 树；null 表示还没渲染出内容
  final Map<String, Object?>? tree;
  final PluginEvent onEvent;

  /// 是否允许内容切换动画（全局设置里可以关）
  final bool animate;

  /// 插件注册表（用于查找自定义节点类型）。null 时只用内置节点。
  final PluginRegistry? registry;

  @override
  State<PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends State<PluginView> {
  /// 当前卡片的默认前景色
  Color _fg = Colors.white;

  /// 输入框控制器按节点 id 复用，否则每次重建都会丢失光标与内容
  final Map<String, TextEditingController> _controllers = {};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    if (tree == null) {
      return const SizedBox.shrink();
    }
    // 默认前景色取自外层 DefaultTextStyle（CardView 会按卡片底色明暗设定），
    // 插件显式写的颜色仍然优先。
    return DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 13, decoration: TextDecoration.none),
      child: Builder(builder: (ctx) {
        _fg = DefaultTextStyle.of(ctx).style.color ?? Colors.white;
        final content = _build(tree);

        // 内容切换动画必须由插件显式声明：根节点带 key 时才做交叉淡入。
        // 不能对每次 render 都动画——时钟每秒重绘一次，那样会一直在闪。
        // 日历翻月时把 key 设成 "2026-8"，就只在真正换月时过渡。
        final key = _str(tree['key']);
        if (!widget.animate || key == null) return content;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: ValueKey(key), child: content),
        );
      }),
    );
  }

  // ------------------------------------------------------------------
  // 取值助手：插件是 JS 写的，数字可能是 int 也可能是 double，统统按 num 读
  // ------------------------------------------------------------------

  double? _num(Object? v) => v is num ? v.toDouble() : null;
  String? _str(Object? v) => v is String ? v : null;

  List<Map<String, Object?>> _children(Object? v) {
    if (v is! List) return const [];
    return [
      for (final c in v)
        if (c is Map) c.cast<String, Object?>()
    ];
  }

  Widget _build(Map<String, Object?> n) {
    switch (_str(n['t'])) {
      case 'col':
        return _flexBox(n, Axis.vertical);
      case 'row':
        return _flexBox(n, Axis.horizontal);
      case 'text':
        return _text(n);
      case 'box':
        return _box(n);
      case 'flex':
        return Expanded(
          flex: (_num(n['f']) ?? 1).round(),
          child: _child(n),
        );
      case 'spacer':
        return const Spacer();
      case 'gap':
        final s = _num(n['v']) ?? 8;
        return SizedBox(width: s, height: s);
      case 'grid':
        return _grid(n);
      case 'tap':
        return _tap(n);
      case 'input':
        return _input(n);
      case 'divider':
        return Container(
          height: 1,
          color: _color(n['color']) ?? const Color(0x1AFFFFFF),
          margin: const EdgeInsets.symmetric(vertical: 4),
        );
      case 'progress':
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (_num(n['v']) ?? 0).clamp(0, 1),
            minHeight: _num(n['h']) ?? 4,
            backgroundColor: const Color(0x22FFFFFF),
            valueColor: AlwaysStoppedAnimation(
                _color(n['color']) ?? const Color(0xFF7CC7FF)),
          ),
        );
      case 'scroll':
        return SingleChildScrollView(child: _child(n));
      case 'stack':
        return Stack(children: [for (final c in _children(n['children'])) _build(c)]);
      case 'icon':
        return Icon(
          _icon(_str(n['v'])),
          size: _num(n['size']) ?? 16,
          color: _color(n['color']) ?? _fg.withValues(alpha: 0.75),
        );
      case 'image':
        return _image(n);
      case 'slider':
        return _slider(n);
      case 'flip':
        return _flip(n);
      default:
        // 查插件注册的自定义节点类型
        final nodeType = _str(n['t']);
        if (widget.registry != null && nodeType != null) {
          final handler = widget.registry!.registeredNodes[nodeType];
          if (handler != null) {
            // v1: 自定义节点目前只显示一个占位符。
            // 后续接入 QuickJS 调用链后，会调用 handler.render(props) 获取真实 widget。
            return Container(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.extension_outlined,
                      size: 14, color: _fg.withValues(alpha: 0.5)),
                  const SizedBox(width: 4),
                  Text(nodeType,
                      style: TextStyle(
                          fontSize: 11, color: _fg.withValues(alpha: 0.5))),
                ],
              ),
            );
          }
        }
        // 未知节点不该让整张卡片崩掉
        return const SizedBox.shrink();
    }
  }

  Widget _child(Map<String, Object?> n) {
    final c = n['child'];
    // animKey 字段保留在协议里（兼容旧插件），但**不再产生动画**：
    // 真实渲染下换行动画（_SlideSwap，见 git 历史 18ca340/dc2a61b）会闪白
    // 约 200ms——用户多轮实测所有过渡形式（滑动/淡入淡出）都闪，而
    // 无动画版本不闪。换行改回原地替换（内容直接平移到新位置）。
    // 要恢复动画前，必须先在真实渲染环境定位闪白机制（flutter_test 的
    // toImage 对 TransformLayer 有固有伪影，测试里无法复现真实渲染）。
    return c is Map ? _build(c.cast<String, Object?>()) : const SizedBox.shrink();
  }

  /// 3D Y 轴翻转：children[0] 前脸，children[1] 后脸。
  /// flipKey 变化时触发 180° 翻转，中间点切换显示面。
  Widget _flip(Map<String, Object?> n) {
    final kids = _children(n['children']);
    final front = kids.isNotEmpty ? _build(kids.first) : const SizedBox.shrink();
    final back = kids.length > 1 ? _build(kids[1]) : const SizedBox.shrink();
    final flipKey = _str(n['flipKey']);
    if (!widget.animate || flipKey == null) return front;
    return _FlipSwap(
      flipKey: flipKey,
      front: front,
      back: back,
    );
  }

  Widget _flexBox(Map<String, Object?> n, Axis axis) {
    final gap = _num(n['gap']) ?? 0;
    final kids = _children(n['children']);
    final widgets = <Widget>[];
    for (var i = 0; i < kids.length; i++) {
      if (i > 0 && gap > 0) {
        widgets.add(SizedBox(
            width: axis == Axis.horizontal ? gap : 0,
            height: axis == Axis.vertical ? gap : 0));
      }
      widgets.add(_build(kids[i]));
    }
    final cross = _crossAlign(_str(n['cross']));
    final mainName = _str(n['main']);
    final main = _mainAlign(mainName);
    // main 只要不是默认的 start，就必须让容器撑满主轴，否则 between / around /
    // center / end 全是空操作——容器缩到内容大小，压根没有多余空间可分配。
    // 实测：歌词卡片里"当前时间 | 总时长"那一行用了 between，却挤在一起显示成
    // "0:033:43"。
    //
    // 代价：撑满要求父节点在主轴上有确定尺寸。放进 scroll 这种无界容器里会报错，
    // 但那本来就是写错了——无限高的容器里谈"垂直居中"没有意义。
    final size = mainName == null || mainName == 'start'
        ? MainAxisSize.min
        : MainAxisSize.max;
    return axis == Axis.vertical
        ? Column(
            crossAxisAlignment: cross,
            mainAxisAlignment: main,
            mainAxisSize: size,
            children: widgets)
        : Row(
            crossAxisAlignment: cross,
            mainAxisAlignment: main,
            mainAxisSize: size,
            children: widgets);
  }

  CrossAxisAlignment _crossAlign(String? v) => switch (v) {
        'center' => CrossAxisAlignment.center,
        'end' => CrossAxisAlignment.end,
        'stretch' => CrossAxisAlignment.stretch,
        _ => CrossAxisAlignment.start,
      };

  MainAxisAlignment _mainAlign(String? v) => switch (v) {
        'center' => MainAxisAlignment.center,
        'end' => MainAxisAlignment.end,
        'between' => MainAxisAlignment.spaceBetween,
        'around' => MainAxisAlignment.spaceAround,
        _ => MainAxisAlignment.start,
      };

  Widget _text(Map<String, Object?> n) {
    final w = _num(n['weight'])?.round();
    return Text(
      _str(n['v']) ?? '',
      maxLines: _num(n['maxLines'])?.round(),
      overflow: n['maxLines'] != null ? TextOverflow.ellipsis : null,
      textAlign: switch (_str(n['align'])) {
        'center' => TextAlign.center,
        'end' => TextAlign.end,
        _ => TextAlign.start,
      },
      style: TextStyle(
        fontSize: _num(n['size']) ?? 13,
        height: _num(n['lh']),
        fontWeight: w == null ? null : _weight(w),
        color: (_color(n['color']) ?? _fg)
            .withValues(alpha: _num(n['opacity']) ?? 1.0),
        fontFeatures: n['mono'] == true
            ? const [FontFeature.tabularFigures()]
            : null,
        decoration: n['strike'] == true
            ? TextDecoration.lineThrough
            : TextDecoration.none,
      ),
    );
  }

  FontWeight _weight(int w) {
    const map = {
      100: FontWeight.w100, 200: FontWeight.w200, 300: FontWeight.w300,
      400: FontWeight.w400, 500: FontWeight.w500, 600: FontWeight.w600,
      700: FontWeight.w700, 800: FontWeight.w800, 900: FontWeight.w900,
    };
    return map[(w ~/ 100) * 100] ?? FontWeight.w400;
  }

  EdgeInsets _pad(Object? v) {
    if (v is num) return EdgeInsets.all(v.toDouble());
    if (v is List && v.length == 2) {
      return EdgeInsets.symmetric(
          vertical: (v[0] as num).toDouble(), horizontal: (v[1] as num).toDouble());
    }
    if (v is List && v.length == 4) {
      return EdgeInsets.fromLTRB(
        (v[3] as num).toDouble(), (v[0] as num).toDouble(),
        (v[1] as num).toDouble(), (v[2] as num).toDouble(),
      );
    }
    return EdgeInsets.zero;
  }

  Widget _box(Map<String, Object?> n) {
    Widget w = Container(
      width: _num(n['w']),
      height: _num(n['h']),
      padding: _pad(n['pad']),
      alignment: n['center'] == true ? Alignment.center : null,
      // clip:true 给固定宽高的盒子裁掉超出部分。插件按估算的文字尺寸给
      // 每一行分配固定高度时，字体真实行高和插件估的数字对不上是常态
      // （不同语言/字重的行高差异本来就没法在 JS 里精确算出来）——与其让
      // 估算误差累加成一整块内容顶穿卡片底边（RenderFlex 的溢出警告只在
      // debug 下画出来，release 下用户看到的是内容被无声裁掉，同样难看），
      // 不如让每个盒子自己兜底裁一刀，误差只会体现成"这一行文字被裁了
      // 一两像素"，而不是"歌词区整体溢出卡片"。
      clipBehavior: n['clip'] == true ? Clip.hardEdge : Clip.none,
      decoration: BoxDecoration(
        color: _color(n['bg']),
        borderRadius: BorderRadius.circular(_num(n['radius']) ?? 0),
        border: n['border'] == null
            ? null
            : Border.all(color: _color(n['border']) ?? Colors.white24, width: 1),
      ),
      child: n['child'] == null ? null : _child(n),
    );
    // 渐变遮罩：顶部和底部淡出，让滚出视口的内容自然消失。
    // fade 是遮罩渐变的相对高度比例（0~0.5），默认 0.15。
    if (n['gradientMask'] == true) {
      final fade = _num(n['fade']) ?? 0.15;
      w = ShaderMask(
        shaderCallback: (rect) {
          final f = fade.clamp(0.01, 0.45);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, f, 1.0 - f, 1.0],
          ).createShader(rect);
        },
        blendMode: BlendMode.dstIn,
        child: w,
      );
    }
    return w;
  }

  /// 固定列数的网格。用 Column+Row 而不是 GridView：日历要的是确定的行列，
  /// 而且卡片里不需要滚动虚拟化。
  Widget _grid(Map<String, Object?> n) {
    final cols = (_num(n['cols']) ?? 7).round().clamp(1, 12);
    final gap = _num(n['gap']) ?? 4;
    // fill：让各行均分可用高度。放在 flex 里却不开这个的话，网格会缩在顶部，
    // 卡片放大后中间留一大块空白。
    final fill = n['fill'] == true;
    final kids = _children(n['children']);
    final rows = <Widget>[];
    for (var i = 0; i < kids.length; i += cols) {
      final slice = kids.sublist(i, (i + cols).clamp(0, kids.length));
      final cells = <Widget>[];
      for (var j = 0; j < cols; j++) {
        if (j > 0 && gap > 0) cells.add(SizedBox(width: gap));
        cells.add(Expanded(
          child: j < slice.length ? _build(slice[j]) : const SizedBox.shrink(),
        ));
      }
      if (rows.isNotEmpty && gap > 0) rows.add(SizedBox(height: gap));
      rows.add(fill ? Expanded(child: Row(children: cells)) : Row(children: cells));
    }
    return Column(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      children: rows,
    );
  }

  Widget _tap(Map<String, Object?> n) {
    final id = _str(n['id']);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: id == null ? null : () => widget.onEvent(id, const {}),
      child: _child(n),
    );
  }

  Widget _input(Map<String, Object?> n) {
    final id = _str(n['id']) ?? 'input';
    final value = _str(n['value']) ?? '';
    final ctrl = _controllers.putIfAbsent(id, () => TextEditingController(text: value));
    // 插件主动改了值（例如提交后清空）才覆盖，避免打字时被回写打断
    if (ctrl.text != value && !(n['live'] == true)) {
      ctrl.value = TextEditingValue(
          text: value, selection: TextSelection.collapsed(offset: value.length));
    }
    final submit = _str(n['submit']);
    // 输入框的颜色全部从 _fg 派生（_fg 是卡片前景色，深浅色自动翻转）：
    // 提示文字、填充底色、光标都跟着明暗走，否则浅色卡上硬编码的白色
    // 提示和底纹会看不见（todo 添加框踩过）。
    return TextField(
      controller: ctrl,
      style: TextStyle(fontSize: _num(n['size']) ?? 13, color: _fg),
      cursorColor: _fg.withValues(alpha: 0.8),
      cursorHeight: (_num(n['size']) ?? 13) + 2,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        hintText: _str(n['placeholder']),
        hintStyle: TextStyle(color: _fg.withValues(alpha: 0.35), fontSize: 12),
        filled: true,
        fillColor: _fg.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onSubmitted: submit == null
          ? null
          : (text) {
              widget.onEvent(submit, {'value': text});
              ctrl.clear();
            },
    );
  }

  /// 图片节点：{t:'image', key, w, h, radius, fit}
  ///
  /// 插件只给 key，不给字节。字节由宿主取、解码、缓存（见 PluginImages 的
  /// 注释：一张封面十几万字节，塞进 UI 树等于每次 render 都序列化一遍）。
  /// key 查不到就画一个占位方块——封面是异步解码的，第一帧必然还没有。
  Widget _image(Map<String, Object?> n) {
    final key = _str(n['key']);
    final w = _num(n['w']);
    final h = _num(n['h']);
    final radius = _num(n['radius']) ?? 0;

    // 监听缓存版本号：图片解码完成时这一帧早就画过了，不重建就永远是占位图
    return ValueListenableBuilder<int>(
      valueListenable: PluginImages.revision,
      builder: (context, _, child) {
        final current = key == null ? null : PluginImages.get(key);
        final Widget child;
        if (current == null) {
          child = Container(
            width: w,
            height: h,
            color: const Color(0x14FFFFFF),
            alignment: Alignment.center,
            child: Icon(Icons.music_note_rounded,
                size: (w ?? 32) * 0.32, color: _fg.withValues(alpha: 0.25)),
          );
        } else {
          child = RawImage(
            image: current,
            width: w,
            height: h,
            fit: switch (_str(n['fit'])) {
              'contain' => BoxFit.contain,
              'fill' => BoxFit.fill,
              _ => BoxFit.cover,
            },
            filterQuality: FilterQuality.medium,
          );
        }
        if (radius <= 0) return child;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: child,
        );
      },
    );
  }

  /// 可拖动的滑条：{t:'slider', id, v, h, color, bg, enabled}
  ///
  /// 与 progress 的区别就是能拖。做成独立节点而不是给 progress 加属性，
  /// 是因为它要维护"拖拽中"的本地状态，和只读的进度条不是一回事。
  Widget _slider(Map<String, Object?> n) {
    final id = _str(n['id']);
    final enabled = n['enabled'] != false && id != null;
    return _PluginSlider(
      value: (_num(n['v']) ?? 0).clamp(0.0, 1.0),
      height: _num(n['h']) ?? 4,
      color: _color(n['color']) ?? const Color(0xFF7CC7FF),
      background: _color(n['bg']) ?? const Color(0x22FFFFFF),
      enabled: enabled,
      onChanged: enabled ? (v) => widget.onEvent(id, {'value': v}) : null,
    );
  }

  IconData _icon(String? name) => switch (name) {
        'check' => Icons.check,
        'check_circle' => Icons.check_circle_outline,
        'circle' => Icons.circle_outlined,
        'close' => Icons.close,
        'add' => Icons.add,
        'refresh' => Icons.refresh,
        'left' => Icons.chevron_left,
        'right' => Icons.chevron_right,
        'up' => Icons.arrow_drop_up,
        'down' => Icons.arrow_drop_down,
        // 天气图标：换成真正的气象语义图标，别再用 grain/flash_on 这种
        // 名字对不上的通用符号硬凑（grain 本意是"颗粒"，flash_on 是"闪光
        // 灯开关"，跟雨/雷完全不是一回事，凑合用一眼就能看出没认真做）。
        'sun' => Icons.wb_sunny_outlined,
        'moon' => Icons.nights_stay_outlined,
        'cloud' => Icons.cloud_outlined,
        'cloud_sun' => Icons.wb_cloudy_outlined,
        'rain' => Icons.water_drop_outlined,
        'snow' => Icons.ac_unit,
        'sleet' => Icons.cloudy_snowing,
        'fog' => Icons.foggy,
        'storm' => Icons.thunderstorm_outlined,
        'thermostat' => Icons.thermostat_outlined,
        'air' => Icons.air,
        'settings' => Icons.settings,
        // 媒体控制
        'play' => Icons.play_arrow_rounded,
        'pause' => Icons.pause_rounded,
        'prev' => Icons.skip_previous_rounded,
        'next' => Icons.skip_next_rounded,
        'music' => Icons.music_note_rounded,
        _ => Icons.square_outlined,
      };

  /// 支持 #RGB / #RRGGBB / #RRGGBBAA
  Color? _color(Object? v) {
    if (v is num) return Color(v.toInt());
    if (v is! String || v.isEmpty) return null;
    var s = v.startsWith('#') ? v.substring(1) : v;
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length == 6) {
      // 补上不透明的 alpha，此时已经是 AARRGGBB，不能再往下走
      s = 'FF$s';
    } else if (s.length == 8) {
      // 输入是 RRGGBBAA，Flutter 要 AARRGGBB
      s = s.substring(6) + s.substring(0, 6);
    }
    // 上面两个分支必须互斥。写成两个独立的 if 会让 6 位色补完 alpha 后
    // 又被当成 RRGGBBAA 旋转一次：#29B6F6 会变成 #F6FF29B6，蓝色渲染成粉色。
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : Color(n);
  }
}

/// 滑条本体。
///
/// 拖拽期间用本地值跟手，松手才把结果回调给插件——插件那边是异步的
/// （seek 要经过通道到 native 再到播放器），等它回来再更新的话，
/// 手指在拖、条却一顿一顿地追，手感立刻就散了。
class _PluginSlider extends StatefulWidget {
  const _PluginSlider({
    required this.value,
    required this.height,
    required this.color,
    required this.background,
    required this.enabled,
    required this.onChanged,
  });

  final double value;
  final double height;
  final Color color;
  final Color background;
  final bool enabled;
  final ValueChanged<double>? onChanged;

  @override
  State<_PluginSlider> createState() => _PluginSliderState();
}

class _PluginSliderState extends State<_PluginSlider> {
  /// 拖拽中的本地值；null 表示没在拖，显示插件给的值
  double? _dragging;

  /// 命中判定要比视觉高，否则 4px 高的条根本按不中
  static const double _hitHeight = 20;

  void _update(double dx, double width) {
    if (width <= 0) return;
    setState(() => _dragging = (dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final v = _dragging ?? widget.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Listener(
          // 按下的瞬间就要声明"这次指针归我"，外层桌面层随后才读得到。
          // 放到 onPointerMove 里就晚了——那时卡片拖拽已经开始了。
          onPointerDown: widget.enabled
              ? (e) {
                  PluginPointer.grabbedPointer = e.pointer;
                  _update(e.localPosition.dx, width);
                }
              : null,
          onPointerMove: widget.enabled
              ? (e) {
                  if (!PluginPointer.isGrabbed(e.pointer)) return;
                  _update(e.localPosition.dx, width);
                }
              : null,
          onPointerUp: widget.enabled
              ? (e) {
                  if (!PluginPointer.isGrabbed(e.pointer)) return;
                  PluginPointer.grabbedPointer = null;
                  final done = _dragging;
                  setState(() => _dragging = null);
                  if (done != null) widget.onChanged?.call(done);
                }
              : null,
          onPointerCancel: widget.enabled
              ? (e) {
                  if (!PluginPointer.isGrabbed(e.pointer)) return;
                  PluginPointer.grabbedPointer = null;
                  setState(() => _dragging = null);
                }
              : null,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: _hitHeight,
            width: double.infinity,
            child: Center(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: widget.height,
                    decoration: BoxDecoration(
                      color: widget.background,
                      borderRadius: BorderRadius.circular(widget.height / 2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: v,
                    child: Container(
                      height: widget.height,
                      decoration: BoxDecoration(
                        color: widget.enabled
                            ? widget.color
                            : widget.color.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(widget.height / 2),
                      ),
                    ),
                  ),
                  // 拖拽中才显示滑块，平时保持截图里那种干净的细条
                  if (_dragging != null)
                    Align(
                      alignment: Alignment(v * 2 - 1, 0),
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: widget.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 3D X 轴翻转切换（从下往上翻）：前脸 ↔ 后脸。
///
/// 控制器值 0 = 前脸静止，1 = 后脸静止。
/// 翻到后脸：forward(0→1)；翻回前脸：reverse(1→0)。
/// value < 0.5 显示前脸，>= 0.5 显示后脸，两面各自做 rotateX + 淡入淡出。
class _FlipSwap extends StatefulWidget {
  const _FlipSwap({
    required this.flipKey,
    required this.front,
    required this.back,
  });

  final String flipKey;
  final Widget front;
  final Widget back;

  @override
  State<_FlipSwap> createState() => _FlipSwapState();
}

class _FlipSwapState extends State<_FlipSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 600),
    vsync: this,
  );

  String? _prevKey;

  static const _pi = 3.141592653589793;

  @override
  void initState() {
    super.initState();
    _prevKey = widget.flipKey;
  }

  @override
  void didUpdateWidget(_FlipSwap old) {
    super.didUpdateWidget(old);
    if (widget.flipKey != _prevKey) {
      _prevKey = widget.flipKey;
      // value=0 在前脸 → forward 到 1（翻到后脸）
      // value=1 在后脸 → reverse 到 0（翻回前脸）
      if (_ctrl.value < 0.5) {
        _ctrl.forward(from: 0.0);
      } else {
        _ctrl.reverse(from: 1.0);
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_ctrl.value);
        // t=0 → 前脸静止（0°），t=1 → 后脸静止（0°）
        // 前脸：0→π 旋转（翻倒），后脸：-π→0 旋转（翻正）
        final frontAngle = t * _pi;
        final backAngle = t * _pi - _pi;
        // opacity 跟着角度走：接近侧视（π/2）时最透明
        final frontOpacity = (1.0 - t).clamp(0.0, 1.0);
        final backOpacity = t.clamp(0.0, 1.0);
        return Stack(
          children: [
            // 前脸：t<0.5 时可见，t>=0.5 时隐藏
            if (t < 0.5)
              Transform(
                alignment: Alignment.bottomCenter,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateX(frontAngle),
                child: Opacity(opacity: frontOpacity, child: widget.front),
              ),
            // 后脸：t>=0.5 时可见，t<0.5 时隐藏
            if (t >= 0.5)
              Transform(
                alignment: Alignment.bottomCenter,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateX(backAngle),
                child: Opacity(opacity: backOpacity, child: widget.back),
              ),
          ],
        );
      },
    );
  }
}

/// 上浮切换动画（_SlideSwap）已在 dc2a61b 之后被移除：真实渲染下换行动画
/// 会闪白约 200ms（所有过渡形式：滑动 / 淡入淡出都闪，无动画版本不闪）。
/// 需要恢复动画时从 git 历史（18ca340 引入、dc2a61b 纯滑动）取回实现，
/// 但必须先定位真实渲染的闪白机制——flutter_test 的 toImage 对
/// TransformLayer 有固有伪影（最小化 SlideTransition 对照实验同样全空白），
/// 测试环境无法复现/验证真实渲染。换行现在走原地替换。

