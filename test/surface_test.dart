// 交互层的自动化测试：用模拟指针事件驱动真实的 DesktopSurface。
// 不合成系统级输入，不动真实鼠标。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/model/card.dart';
import 'package:vectra/plugin/node.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/store/store.dart';
import 'package:vectra/ui/surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vectra/native');
  final pushedRegions = <Map<Object?, Object?>>[];
  final dragFlags = <bool>[];

  setUp(() {
    pushedRegions.clear();
    dragFlags.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setRegion') {
        pushedRegions.add(call.arguments as Map<Object?, Object?>);
        return false;
      }
      if (call.method == 'setDragging') {
        dragFlags.add(call.arguments as bool);
      }
      return null;
    });
  });

  /// 造一个测试场景：anchor 固定在 (500,300)，mover 在 (100,700)，都是 2x2=236
  (AppState, Store) makeState() {
    final state = AppState(
      settings: AppSettings(),
      cards: [
        WidgetCard(id: 'anchor', pluginId: 'x', x: 500, y: 300, size: '2x2', z: 1),
        WidgetCard(id: 'mover', pluginId: 'y', x: 100, y: 700, size: '2x2', z: 2),
      ],
    );
    final store = Store(Directory.systemTemp.createTempSync('lw-test').path);
    return (state, store);
  }

  Future<void> pumpSurface(WidgetTester tester, AppState state, Store store) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: DesktopSurface(
          state: state,
          store: store,
          buildPluginBody: (card, size) => const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('拖拽跟手：抓点偏移被保留', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    // 从卡片左上角附近按下（不是中心），拖动后该点仍应对应同一位置
    final grab = Offset(mover.x + 30, mover.y + 40);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(200, 100));
    await tester.pump();

    expect(mover.x, 300, reason: '100 + 200');
    expect(mover.y, 800, reason: '700 + 100');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('拖到阈值内自动吸附到左对齐', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    // 目标 x=506，距 anchor 左边 500 只差 6px，在阈值 10 内 -> 吸到 500
    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(406, 0));
    await tester.pump();

    expect(mover.x, 500, reason: '应吸附到 anchor 的左边缘');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('超出阈值不吸附', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(420, 0)); // 目标 520，差 20px
    await tester.pump();

    expect(mover.x, 520);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('锁定布局后拖不动', (tester) async {
    final (state, store) = makeState();
    state.settings.locked = true;
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 100, reason: '锁定时坐标不应变化');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('点在卡片外不会拖动任何卡片', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    // (900,900) 不在任何卡片上
    final g = await tester.startGesture(const Offset(900, 900),
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(const Offset(1000, 950));
    await tester.pump();

    expect(mover.x, 100);
    expect(mover.y, 700);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('按下时置顶：z 变成最大', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final anchor = state.cards.firstWhere((c) => c.id == 'anchor');
    final mover = state.cards.firstWhere((c) => c.id == 'mover');
    expect(anchor.z < mover.z, isTrue);

    final g = await tester.startGesture(Offset(anchor.x + 118, anchor.y + 118),
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    expect(anchor.z > mover.z, isTrue, reason: '被按下的卡片应升到最上层');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('拖拽期间暂停区域裁剪，松手后恢复', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    expect(pushedRegions, isNotEmpty, reason: '启动就该推一次区域');
    expect((pushedRegions.last['cards'] as List).length, 2);

    final regionsBefore = pushedRegions.length;
    dragFlags.clear();

    final mover = state.cards.firstWhere((c) => c.id == 'mover');
    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();

    // 拖动若干帧
    for (var i = 1; i <= 5; i++) {
      await g.moveTo(grab + Offset(20.0 * i, 0));
      await tester.pump();
    }
    // 通道调用是异步的，断言放在几帧之后而不是紧贴按下那一刻
    expect(dragFlags.first, isTrue, reason: '按下后应通知 native 暂停裁剪');
    expect(pushedRegions.length, regionsBefore,
        reason: '拖动过程中不得再推区域——每帧 SetWindowRgn 正是拖影的来源');

    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(dragFlags.last, false, reason: '松手要关掉拖拽模式');
    expect(pushedRegions.length, greaterThan(regionsBefore),
        reason: '松手后必须重新推一次区域，否则窗口一直整窗接收点击');
  });

  testWidgets('触摸：轻点不拖动，交给插件', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab); // 默认就是 touch
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 100, reason: '未长按时触摸滑动不应拖走卡片');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('触摸：长按 500ms 进编辑模式后可拖动', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');
    final grab = Offset(mover.x + 118, mover.y + 118);

    // 第一次按住不动，等长按触发
    final g1 = await tester.startGesture(grab);
    await tester.pump(const Duration(milliseconds: 600));
    await g1.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();

    // 已进入编辑模式，这次触摸可以直接拖
    final g2 = await tester.startGesture(grab);
    await tester.pump();
    await g2.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 300, reason: '编辑模式下触摸应能直接拖动');
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump(const Duration(seconds: 9)); // 等编辑模式自动退出
  });

  testWidgets('触摸：长按期间移动超过 10px 判定为滑动，不进编辑模式', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');
    final grab = Offset(mover.x + 118, mover.y + 118);

    final g = await tester.startGesture(grab);
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveTo(grab + const Offset(30, 0)); // 超过 slop
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();

    // 再次触摸：若上一步误进了编辑模式，这里就会被拖走
    final g2 = await tester.startGesture(grab);
    await tester.pump();
    await g2.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 100, reason: '滑动不该被误判为长按');
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400)); // 放掉 store 去抖
    await tester.pump();
  });

  testWidgets('右键不启动拖拽（漏掉这条会被右键悄悄挪走布局）', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 100, reason: '右键拖动不应移动卡片');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('中键同样不启动拖拽', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    expect(mover.x, 100);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('拖拽中的卡片位置动画时长必须为 0，其余卡片走缓动', (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(200, 0));
    await tester.pump();

    final positioned = tester
        .widgetList<AnimatedPositioned>(find.byType(AnimatedPositioned))
        .toList();
    expect(positioned.length, 2);
    // 被拖的那张：左边等于它的新 x，时长必须是 0
    final dragged =
        positioned.firstWhere((p) => p.left == mover.x);
    expect(dragged.duration, Duration.zero,
        reason: '拖拽中加动画会让卡片落后于指针，手感立刻就散');
    // 另一张没被拖，应该有缓动时长
    final other = positioned.firstWhere((p) => p.left != mover.x);
    expect(other.duration.inMilliseconds, greaterThan(0));

    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('关掉动画开关后所有卡片时长都是 0', (tester) async {
    final (state, store) = makeState();
    state.settings.animations = false;
    await pumpSurface(tester, state, store);

    final positioned =
        tester.widgetList<AnimatedPositioned>(find.byType(AnimatedPositioned));
    for (final p in positioned) {
      expect(p.duration, Duration.zero);
    }
  });

  testWidgets('z 序重排后，每个动画节点仍绑定同一张卡片（按下时"抽一下"的根因）',
      (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    final anchor = state.cards.firstWhere((c) => c.id == 'anchor');
    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    Map<String, double> leftsByCard() {
      final out = <String, double>{};
      for (final p
          in tester.widgetList<AnimatedPositioned>(find.byType(AnimatedPositioned))) {
        final k = p.key;
        if (k is ValueKey<String>) out[k.value] = p.left!;
      }
      return out;
    }

    final before = leftsByCard();
    expect(before['anchor'], anchor.x);
    expect(before['mover'], mover.x);

    // 按下 anchor 会把它提到最上层，子节点顺序随之改变
    final g = await tester.startGesture(Offset(anchor.x + 118, anchor.y + 118),
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();

    final after = leftsByCard();
    // 没有 key 时，重排会让某个 AnimatedPositioned 换绑到另一张卡片，
    // 它的 left 就会变成对方的 x —— 那正是肉眼看到的抽动。
    expect(after['anchor'], anchor.x, reason: 'anchor 的动画节点不能换绑到 mover');
    expect(after['mover'], mover.x, reason: 'mover 的动画节点不能换绑到 anchor');

    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });


  testWidgets('拖插件里的滑条不能把整张卡片一起拖走', (tester) async {
    final (state, store) = makeState();
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => PluginPointer.grabbedPointer = null);

    final mover = state.cards.firstWhere((c) => c.id == 'mover');

    // 只给 mover 这张卡片塞一个滑条，anchor 保持空白作对照
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: DesktopSurface(
          state: state,
          store: store,
          buildPluginBody: (card, size) => card.id == 'mover'
              ? PluginView(
                  tree: const {
                    't': 'box',
                    'w': 200.0,
                    'child': {'t': 'slider', 'id': 'seek', 'v': 0.0}
                  },
                  onEvent: (_, _) {},
                )
              : const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();

    final startX = mover.x, startY = mover.y;
    final slider = find.byType(FractionallySizedBox);
    expect(slider, findsOneWidget, reason: '滑条得先真的画出来');

    final center = tester.getCenter(slider);
    final g = await tester.startGesture(center,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(center + const Offset(120, 60));
    await tester.pump();

    // 没有 PluginPointer 那条判断的话，桌面层会把这次拖动当成拖卡片
    expect(mover.x, startX, reason: '拖进度条时卡片不能横向移动');
    expect(mover.y, startY, reason: '拖进度条时卡片不能纵向移动');

    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('卡片上没有插件控件时，拖拽照常工作（上一条不能误伤正常拖动）',
      (tester) async {
    final (state, store) = makeState();
    await pumpSurface(tester, state, store);
    addTearDown(() => PluginPointer.grabbedPointer = null);

    final mover = state.cards.firstWhere((c) => c.id == 'mover');
    final grab = Offset(mover.x + 118, mover.y + 118);
    final g = await tester.startGesture(grab,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(grab + const Offset(-60, -80));
    await tester.pump();

    expect(mover.x, isNot(100), reason: '普通卡片仍然要能拖');

    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  // ---------------- 窗口区域与卡片几何的对账 ----------------
  //
  // 窗口被 SetWindowRgn 硬裁成卡片矩形的并集，区域外既不绘制也不接收输入。
  // 所以"区域推没推"不是性能问题，是卡片可见不可见的问题：区域过期时，
  // 新卡片画了也会被裁掉，用户看到的就是"加了组件但桌面上没反应"。
  group('区域对账', () {
    /// 取最近一次推给 native 的矩形（已乘 dpr，这里 dpr=1）。
    List<({double x, double y, double w, double h})> lastRects() {
      final cards = pushedRegions.last['cards'] as List;
      return [
        for (final c in cards.cast<Map<Object?, Object?>>())
          (
            x: c['x']! as double,
            y: c['y']! as double,
            w: c['w']! as double,
            h: c['h']! as double,
          )
      ];
    }

    bool covers(double x, double y, double w, double h) => lastRects().any(
        (r) => r.x == x && r.y == y && r.w == w && r.h == h);

    testWidgets('加卡之后立刻推区域——不必先去拖一下别的卡片', (tester) async {
      final (state, store) = makeState();
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      // 等价于 AppRoot.addCard：改模型，然后外层 setState 重建一帧
      state.cards.add(WidgetCard(
          id: 'fresh', pluginId: 'z', x: 900, y: 200, size: '2x2', z: 3));
      await pumpSurface(tester, state, store);

      expect(pushedRegions, isNotEmpty,
          reason: '加卡后一帧内必须推区域，否则新卡片被裁掉，用户只能靠拖动别的卡片"救"出来');
      expect(covers(900, 200, 236, 236), isTrue,
          reason: '新卡片的矩形必须进区域，实际推的是 ${lastRects()}');
    });

    testWidgets('桌面一张卡片都没有时，加的第一张也要能出来', (tester) async {
      // 最要命的场景：区域是空的（整窗被裁没），而桌面上没有任何卡片可拖，
      // 也就没有任何办法触发重推 —— 修复前只能重启程序。
      final state = AppState(settings: AppSettings(), cards: []);
      final store = Store(Directory.systemTemp.createTempSync('lw-test').path);
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      state.cards.add(WidgetCard(
          id: 'first', pluginId: 'z', x: 300, y: 300, size: '2x2', z: 1));
      await pumpSurface(tester, state, store);

      expect(pushedRegions, isNotEmpty, reason: '空桌面加第一张卡必须推区域');
      expect(covers(300, 300, 236, 236), isTrue,
          reason: '第一张卡片不在区域里就永远看不见，且没有任何卡片可拖来触发重推');
    });

    testWidgets('删卡之后区域里不再留着它的矩形', (tester) async {
      final (state, store) = makeState();
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      state.cards.removeWhere((c) => c.id == 'anchor'); // 原本在 (500,300)
      await pumpSurface(tester, state, store);

      expect(pushedRegions, isNotEmpty, reason: '删卡后也要重推区域');
      expect(covers(500, 300, 236, 236), isFalse,
          reason: '删掉的卡片若留在区域里，桌面上会多出一块看不见却照样吃掉鼠标点击的死角');
    });

    testWidgets('插件请求改尺寸后，区域跟着改', (tester) async {
      final (state, store) = makeState();
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      // 等价于 onRequestSize：2x2 -> 4x2
      state.cards.firstWhere((c) => c.id == 'mover').size = '4x2';
      await pumpSurface(tester, state, store);

      expect(pushedRegions, isNotEmpty, reason: '改尺寸后要重推区域');
      expect(covers(100, 700, 484, 236), isTrue,
          reason: '区域没跟上就只有原来 2x2 那块可见，变宽的部分被裁掉，实际推的是 ${lastRects()}');
    });

    testWidgets('面板里改网格尺寸后，区域跟着改', (tester) async {
      final (state, store) = makeState();
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      state.settings.gridCell = 140; // 2x2 = 140*2+12 = 292
      await pumpSurface(tester, state, store);

      expect(pushedRegions, isNotEmpty, reason: '改网格后要重推区域');
      expect(covers(500, 300, 292, 292), isTrue,
          reason: '卡片按新网格画大了，区域还是旧的，边缘会被裁掉，实际推的是 ${lastRects()}');
    });

    testWidgets('几何没变就不重复推，别每帧都去烦 native', (tester) async {
      final (state, store) = makeState();
      await pumpSurface(tester, state, store);
      pushedRegions.clear();

      // 重建好几帧，但一个几何量都没动
      for (var i = 0; i < 3; i++) {
        await pumpSurface(tester, state, store);
      }

      expect(pushedRegions, isEmpty,
          reason: '几何没变还推区域，等于每帧都 SetWindowRgn，那正是当年拖影的来源');
    });
  });
}
