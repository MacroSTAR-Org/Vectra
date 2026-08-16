// 控制面板的回归测试。
//
// 这里只有一条，但它挡的是一个能把整个界面卡死的问题：面板里改设置会通知
// 外层，而外层的 onChanged 会让所有插件卡片的 QuickJS 运行时全部销毁重建、
// 还要重新截屏算壁纸模糊。Slider 的 onChanged 是拖动期间每帧都触发的，
// 不去抖就是每秒几十次全量重建。
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
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

  testWidgets('关于页给出日志目录和打开按钮（报问题时第一步就是找日志）',
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
        initialTab: 5, // 关于页
        onClose: () {},
        onChanged: () {},
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('日志'), findsOneWidget, reason: '关于页要显示日志目录在哪');

    final btn = find.widgetWithText(Button, '打开日志目录');
    expect(btn, findsOneWidget);

    await tester.tap(btn);
    await tester.pump();

    expect(calls.where((c) => c.method == 'openLogDir'), isNotEmpty,
        reason: '按钮要真的让 native 打开目录，不能只是个摆设');

    await tester.pump(const Duration(milliseconds: 400));
  });
}
