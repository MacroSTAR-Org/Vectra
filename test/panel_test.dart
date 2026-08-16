// 控制面板的回归测试。
//
// 这里只有一条，但它挡的是一个能把整个界面卡死的问题：面板里改设置会通知
// 外层，而外层的 onChanged 会让所有插件卡片的 QuickJS 运行时全部销毁重建、
// 还要重新截屏算壁纸模糊。Slider 的 onChanged 是拖动期间每帧都触发的，
// 不去抖就是每秒几十次全量重建。
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/plugin/registry.dart';
import 'package:vectra/store/store.dart';
import 'package:vectra/ui/panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 面板里的材质开关会调 native
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async => null);
  });

  testWidgets('连续改设置只通知外层一次（拖滑块曾经每帧重建所有插件运行时）',
      (tester) async {
    var notified = 0;
    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel').path);

    await tester.pumpWidget(FluentApp(
      home: ControlPanel(
        state: state,
        store: store,
        registry: PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
        initialTab: 2, // 外观页
        onClose: () {},
        onChanged: () => notified++,
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    final slider = find.byType(Slider).first;
    expect(slider, findsOneWidget, reason: '外观页上应该有滑块');

    // 模拟一次拖动：连续 20 帧值都在变
    final center = tester.getCenter(slider);
    final g = await tester.startGesture(center);
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();

    // 去抖窗口还没到：一次都不该通知
    expect(notified, 0,
        reason: '拖动过程中就通知外层的话，每帧都会重建所有插件的 QuickJS 运行时');

    await tester.pump(const Duration(milliseconds: 400));
    expect(notified, 1, reason: '停手之后应该正好补一次');

    await tester.pump(const Duration(milliseconds: 600));
    expect(notified, 1, reason: '不该重复补');

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('面板关掉时会把欠着的那次通知补上', (tester) async {
    var notified = 0;
    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel2').path);

    Widget build(bool show) => FluentApp(
          home: show
              ? ControlPanel(
                  state: state,
                  store: store,
                  registry: PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
                  initialTab: 2,
                  onClose: () {},
                  onChanged: () => notified++,
                  onAdd: (_) {},
                  onRemove: (_) {},
                )
              : const SizedBox.shrink(),
        );

    await tester.pumpWidget(build(true));
    await tester.pumpAndSettle();

    final sw = find.byType(ToggleSwitch).first;
    await tester.tap(sw);
    await tester.pump();
    expect(notified, 0, reason: '还在去抖窗口里');

    // 去抖没到就把面板关了，改动不能丢
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(notified, 1, reason: '关闭时要补上最后一次，否则改了等于没改');

    // Store 自己有 300ms 落盘去抖，不放掉的话测试会因"仍有未完成的 Timer"失败
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('「其他」页给出日志目录和打开按钮（报问题时第一步就是找日志）',
      (tester) async {
    // 按钮点下去会调 native 的 openLogDir，这里记下有没有真的发出去
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vectra/native'),
            (call) async {
      calls.add(call);
      return null;
    });

    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel3').path);

    await tester.pumpWidget(FluentApp(
      home: ControlPanel(
        state: state,
        store: store,
        registry:
            PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
        initialTab: 4, // 「其他」页：日志和启动、备份一样属于运维项
        onClose: () {},
        onChanged: () {},
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('日志'), findsOneWidget, reason: '「其他」页要有日志分组');

    final btn = find.widgetWithText(Button, '打开日志目录');
    expect(btn, findsOneWidget);

    await tester.tap(btn);
    await tester.pump();

    expect(calls.where((c) => c.method == 'openLogDir'), isNotEmpty,
        reason: '按钮要真的让 native 打开目录，不能只是个摆设');

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('「其他」页在最窄面板下不撑破布局', (tester) async {
    // 「关于」页当年在这里栽过：按钮和说明挤在一行，窄了就溢出。
    // 日志这组搬过来时按钮独占一行、路径用可换行的框，这条守住不再犯。
    //
    // 宽度取 720 —— panel_window.cpp 里 kMinWidth 就是这个值，
    // WM_GETMINMAXINFO 拦着，用户再怎么拖也窄不过它。按更小的尺寸测等于
    // 给一个不存在的场景加约束，只会逼出没必要的布局妥协。
    tester.view.physicalSize = const Size(720, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async => null);

    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel4').path);

    await tester.pumpWidget(FluentApp(
      home: ControlPanel(
        state: state,
        store: store,
        registry:
            PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
        initialTab: 4,
        onClose: () {},
        onChanged: () {},
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '窄面板下「其他」页不能有 RenderFlex 溢出');

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('导航栏收起按钮按下去要真的收起（而且记得住）', (tester) async {
    // NavigationView 的收起按钮只把新模式报出来，自己不留状态。
    // displayMode 以前写死 expanded，按钮按下去下一帧又被按回展开 ——
    // 表现就是"点了没反应"。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async => null);

    // 按真实窗口来：900x640 是 panel_window.cpp 里的 kWidth/kHeight，
    // embedded:false 是 panel_app.dart 里实际用的模式
    tester.view.physicalSize = const Size(900, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel5').path);

    await tester.pumpWidget(FluentApp(
      home: ControlPanel(
        state: state,
        store: store,
        registry:
            PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
        initialTab: 0,
        embedded: false,
        onClose: () {},
        onChanged: () {},
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    NavigationPane paneNow() =>
        tester.widget<NavigationView>(find.byType(NavigationView)).pane!;

    expect(paneNow().displayMode, PaneDisplayMode.expanded,
        reason: '默认是展开的');

    final view = tester.widget<NavigationView>(find.byType(NavigationView));
    expect(view.onDisplayModeChanged, isNotNull,
        reason: '不接这个回调的话，收起按钮报出来的新模式没人接，等于白按');
    // 直接走 NavigationView 对外的回调，等价于用户点那个按钮
    view.onDisplayModeChanged!(PaneDisplayMode.compact);
    await tester.pump();

    expect(paneNow().displayMode, PaneDisplayMode.compact,
        reason: '收起之后必须留在收起状态，不能被写死的常量按回展开');

    // 收起动画途中，fluent_ui 自己那个 Row 会瞬时溢出 4px
    // （pane_items.dart:305，外面就套着 ClipRect，显然是预料之中的过渡产物）。
    // 这里放掉动画、把这个已知的瞬时异常取走，但紧接着要证明**稳态是干净的**
    // ——否则就不是过渡产物，而是真的布局塌了。
    await tester.pumpAndSettle();
    tester.takeException();

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull,
        reason: '收起稳定之后不该再有溢出，否则是真的布局问题而不是过渡');

    view.onDisplayModeChanged!(PaneDisplayMode.expanded);
    await tester.pumpAndSettle();
    tester.takeException(); // 展开动画同理
    expect(paneNow().displayMode, PaneDisplayMode.expanded,
        reason: '再点一次要能展开回来');

    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '展开稳态同样要干净');

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('窗口四周有缩放手柄，按下时把正确的命中码发给 native',
      (tester) async {
    // 这窗口没有系统缩放边框（无边框 + Flutter 子窗口吃掉鼠标消息，
    // WM_NCHITTEST 用不了），缩放全靠这圈手柄喊 native。
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vectra/native'),
            (call) async {
      calls.add(call);
      return null;
    });

    tester.view.physicalSize = const Size(900, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState(settings: AppSettings(), cards: []);
    final store = Store(Directory.systemTemp.createTempSync('lw-panel6').path);

    await tester.pumpWidget(FluentApp(
      home: ControlPanel(
        state: state,
        store: store,
        registry:
            PluginRegistry(Directory.systemTemp.createTempSync('lw-reg').path),
        initialTab: 0,
        // 真实设置窗口就是这个模式（见 panel_app.dart）；
        // 默认的 embedded=true 是旧的内嵌对话框，那条路径没有独立窗口，
        // 自然也没有缩放手柄
        embedded: false,
        onClose: () {},
        onChanged: () {},
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> pressAt(Offset p) async {
      final g = await tester.startGesture(p, kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton);
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    int? lastEdge() {
      final r = calls.where((c) => c.method == 'panelResize');
      return r.isEmpty ? null : r.last.arguments as int;
    }

    // 命中码取自 winuser.h：左 10 右 11 上 12 左上 13 右上 14
    // 下 15 左下 16 右下 17
    await pressAt(const Offset(2, 320));
    expect(lastEdge(), 10, reason: '左边缘 HTLEFT');

    await pressAt(const Offset(898, 320));
    expect(lastEdge(), 11, reason: '右边缘 HTRIGHT');

    await pressAt(const Offset(450, 2));
    expect(lastEdge(), 12, reason: '上边缘 HTTOP');

    await pressAt(const Offset(450, 638));
    expect(lastEdge(), 15, reason: '下边缘 HTBOTTOM');

    // 四个角必须压在边之上，否则拐角只能单向缩放
    await pressAt(const Offset(3, 3));
    expect(lastEdge(), 13, reason: '左上角 HTTOPLEFT');

    await pressAt(const Offset(897, 3));
    expect(lastEdge(), 14, reason: '右上角 HTTOPRIGHT');

    await pressAt(const Offset(3, 637));
    expect(lastEdge(), 16, reason: '左下角 HTBOTTOMLEFT');

    await pressAt(const Offset(897, 637));
    expect(lastEdge(), 17, reason: '右下角 HTBOTTOMRIGHT');

    await tester.pump(const Duration(milliseconds: 400));
  });

  // ---------------- 设置改动的日志描述 ----------------
  //
  // 配置类问题（"我明明关了它怎么还在"）最难查，因为改动本身不留痕迹。
  // 这几条盯着那份痕迹：不是"有没有打日志"，而是"能不能看出改了什么"。
  group('设置改动描述', () {
    test('只报真正变了的项，并带上新旧值', () {
      final before = AppSettings().toJson();
      final after = AppSettings().toJson();
      after['locked'] = true;
      after['gridCell'] = 140;

      final diff = describeSettingsDiff(before, after);

      expect(diff.length, 2, reason: '没变的项不该出现，否则一次改动刷几十行');
      expect(diff, contains('locked: false -> true'));
      expect(diff.any((s) => s.startsWith('gridCell: ')), isTrue);
      expect(diff.firstWhere((s) => s.startsWith('gridCell: ')),
          contains('-> 140'));
    });

    test('什么都没改就不出声', () {
      final same = AppSettings().toJson();
      expect(describeSettingsDiff(same, Map.of(same)), isEmpty);
    });

    test('新增的设置项也能被认出来', () {
      // 插件市场以后会带进来新键，不该因为旧快照里没有就漏掉
      final diff = describeSettingsDiff(const {}, const {'newKey': 3});
      expect(diff, contains('newKey: null -> 3'));
    });
  });

  // ---------------- 插件 number 设置项的精度 ----------------
  //
  // 插件清单里的 number 字段允许带小数（step: 0.1 之类），
  // 而滑块回调过去一律 .round()，把小数全抹平了。
  group('number 设置项按 step 取值', () {
    test('step 是小数时，小数必须存得住', () {
      // 这是修复前彻底坏掉的场景：0~1 之间、步长 0.1
      expect(snapNumber(0.3, 0, 0.1), 0.3, reason: '修复前 .round() 会存成 0');
      expect(snapNumber(0.5, 0, 0.1), 0.5, reason: '修复前会存成 1');
      expect(snapNumber(0.6, 0, 0.1), 0.6, reason: '修复前会进位成 1');
      expect(snapNumber(0.85, 0, 0.05), 0.85);
    });

    test('对齐到 step，不留浮点噪声', () {
      // 直接存滑块原值会写进 0.30000000000000004 这种东西
      final v = snapNumber(0.30000000000000004, 0, 0.1);
      expect(v, 0.3);
      expect(v.toString(), '0.3', reason: 'config.json 里不该出现浮点噪声');
    });

    test('step 是整数时结果仍是 int，不写成 5.0', () {
      final v = snapNumber(5.4, 0, 1);
      expect(v, 5);
      expect(v, isA<int>(), reason: '整数设置项被写成 5.0 会让插件的相等比较出意外');
    });

    test('min 不是 0 时按 min 起算', () {
      expect(snapNumber(1.25, 1, 0.5), 1.5);
      expect(snapNumber(1.1, 1, 0.5), 1.0);
    });

    test('显示位数跟着 step 走', () {
      expect(formatNumber(0.3, 0.1), '0.3');
      expect(formatNumber(5.0, 1), '5', reason: '整数步长不该显示成 5.0');
      expect(formatNumber(0.85, 0.05), '0.85');
    });

    test('step 非法时不炸，原样返回', () {
      expect(snapNumber(0.7, 0, 0), 0.7);
      expect(snapNumber(0.7, 0, -1), 0.7);
    });
  });
}
