/// 插件出错时卡片上那个框的行为约定。
///
/// 插件失控是"一定会发生"的事——第三方插件写错、接口改字段、机器忙到挂载超时。
/// 真正要保证的不是"不出错"，而是**出错之后用户还有救**：看得懂发生了什么，
/// 点一下能重来，不用重启整个程序。
///
/// 这里测的是"插件加载不出来"那条路径。真正的 QuickJS 运行时在
/// flutter_test 里起不来（原生库加载失败，错误码 126），失控后自动重试那条
/// 只能实机验证。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/splash_gate.dart';
import 'package:vectra/model/card.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/plugin/plugin_card_body.dart';
import 'package:vectra/plugin/registry.dart';
import 'package:vectra/store/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SplashGate.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async => null);
  });

  tearDown(SplashGate.resetForTest);

  Future<void> pumpCard(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('vectra-card-body');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 248,
          height: 248,
          child: PluginCardBody(
            // 注册表是空的，这个 id 一定找不到
            card: WidgetCard(
                id: 'c1', pluginId: 'ghost', x: 0, y: 0, size: '2x2', z: 1),
            size: const Size(248, 248),
            registry: PluginRegistry(tmp.path),
            store: Store(tmp.path),
            state: AppState(settings: AppSettings(), cards: []),
            onRequestSize: (_) {},
            onOpenSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('插件加载不出来时，卡片上是一句人话加一个重试，而不是一串报错',
      (tester) async {
    await pumpCard(tester);

    // 标题给的是"哪个组件出问题了"，不是 JS 堆栈
    expect(find.textContaining('出错了'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('详情'), findsOneWidget);

    // 技术细节默认收着——普通用户不需要被这行字吓到
    expect(find.textContaining('找不到插件'), findsNothing);
  });

  testWidgets('点「详情」能看到真正的原因，再点能收回去', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(find.textContaining('找不到插件「ghost」'), findsOneWidget,
        reason: '写插件的人要靠这行字定位问题，展开后必须给全');
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.text('收起'));
    await tester.pump();
    expect(find.textContaining('找不到插件'), findsNothing);
  });

  testWidgets('点「重试」会重新加载，插件仍然坏着就还停在错误框', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    // 重试等于整个重来一遍：展开状态也跟着复位，不会留着上一轮的残留
    expect(find.textContaining('出错了'), findsOneWidget);
    expect(find.text('详情'), findsOneWidget);
  });

  testWidgets('错误框在最小的卡片里也放得下，展开详情也不会撑破', (tester) async {
    // 卡片可以小到 2x2 配小网格，而报错信息可以很长（QuickJS 的堆栈动辄几行）。
    // 撑破的后果不只是难看：溢出的部分会被窗口区域裁掉，「重试」按钮可能就在
    // 被裁掉的那一块里，用户点不到也就没法自救。
    final tmp = Directory.systemTemp.createTempSync('vectra-card-small');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: PluginCardBody(
              card: WidgetCard(
                  id: 'c1',
                  // 长 id 撑出一条长错误信息
                  pluginId: 'a-plugin-with-a-very-long-identifier-name-here',
                  x: 0,
                  y: 0,
                  size: '2x2',
                  z: 1),
              size: const Size(120, 120),
              registry: PluginRegistry(tmp.path),
              store: Store(tmp.path),
              state: AppState(settings: AppSettings(), cards: []),
              onRequestSize: (_) {},
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '收起状态下不该溢出');

    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '展开详情后也不该溢出');
    // 撑不破的前提下，重试按钮必须仍然在
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('坏插件也要报告就绪，否则启动幕布会一直挂着', (tester) async {
    // 一个装坏了的插件不该让整个程序卡在启动画面上
    SplashGate.start(1);
    await pumpCard(tester);
    expect(SplashGate.isDone, isTrue);
  });
}
