// 启动幕布的进度闸门。
//
// 这块逻辑决定"什么时候算加载完"，而幕布落下之前磁贴窗口是藏着的 ——
// 判错了的后果不是难看，是程序看起来没启动。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/splash_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vectra/native');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SplashGate.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => SplashGate.resetForTest());

  List<MethodCall> progressCalls() =>
      calls.where((c) => c.method == 'splashProgress').toList();
  bool finished() => calls.any((c) => c.method == 'splashFinish');
  ({int ready, int total}) lastProgress() {
    final a = progressCalls().last.arguments as Map;
    return (ready: a['ready'] as int, total: a['total'] as int);
  }

  test('启动时先报一次 0/总数，让进度条从空的开始', () async {
    SplashGate.start(3);
    await Future<void>.delayed(Duration.zero);

    expect(progressCalls(), isNotEmpty);
    expect(lastProgress(), (ready: 0, total: 3));
    expect(finished(), isFalse, reason: '一张都没就绪就收幕布，等于没遮');
  });

  test('每张卡片就绪推一格，最后一张到齐才收幕布', () async {
    SplashGate.start(3);
    SplashGate.reportReady('a');
    await Future<void>.delayed(Duration.zero);
    expect(lastProgress(), (ready: 1, total: 3));
    expect(finished(), isFalse);

    SplashGate.reportReady('b');
    await Future<void>.delayed(Duration.zero);
    expect(lastProgress(), (ready: 2, total: 3));
    expect(finished(), isFalse, reason: '还差一张就收，桌面会露出半成品');

    SplashGate.reportReady('c');
    await Future<void>.delayed(Duration.zero);
    expect(lastProgress(), (ready: 3, total: 3));
    expect(finished(), isTrue);
  });

  test('同一张卡片报两次只算一次', () async {
    // 卡片会因为全局设置变化整体重建，_boot 会再跑一遍。
    // 按次数计的话，一张卡重建两次就能把进度顶满，幕布提前落下。
    SplashGate.start(3);
    SplashGate.reportReady('a');
    SplashGate.reportReady('a');
    SplashGate.reportReady('a');
    await Future<void>.delayed(Duration.zero);

    expect(lastProgress(), (ready: 1, total: 3));
    expect(finished(), isFalse);
  });

  test('加载失败的卡片也算就绪，不能让一个坏插件把幕布挂死', () async {
    // PluginCardBody 找不到插件时会显示错误框 —— 那已经是它的最终形态了
    SplashGate.start(2);
    SplashGate.reportReady('good');
    SplashGate.reportReady('broken-plugin');
    await Future<void>.delayed(Duration.zero);

    expect(finished(), isTrue);
  });

  test('一张卡片都没有时直接收幕布', () async {
    SplashGate.start(0);
    await Future<void>.delayed(Duration.zero);
    expect(finished(), isTrue, reason: '没什么可等的，幕布不该空挂着');
  });

  test('收完之后再报进度不会重复通知', () async {
    SplashGate.start(1);
    SplashGate.reportReady('a');
    await Future<void>.delayed(Duration.zero);
    final finishCount = calls.where((c) => c.method == 'splashFinish').length;

    // 用户在面板里新加的卡片也会走 _boot，但那跟这次启动无关了
    SplashGate.reportReady('later');
    await Future<void>.delayed(Duration.zero);

    expect(calls.where((c) => c.method == 'splashFinish').length, finishCount);
    expect(SplashGate.isDone, isTrue);
  });

  test('卡片迟迟不就绪时，兜底超时会把幕布收掉', () async {
    SplashGate.fallbackDelay = const Duration(milliseconds: 30);
    SplashGate.start(5);
    SplashGate.reportReady('only-one');
    await Future<void>.delayed(Duration.zero);
    expect(finished(), isFalse, reason: '才 1/5，这时候不该收');

    // 剩下四张永远不来（插件死循环被执行预算杀掉之类）
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(finished(), isTrue,
        reason: '不兜底的话幕布会一直挂着，磁贴窗口也就一直不显示');
  });

  test('正常收尾后兜底定时器要撤掉，不能过几秒又来一次', () async {
    SplashGate.fallbackDelay = const Duration(milliseconds: 30);
    SplashGate.start(1);
    SplashGate.reportReady('a');
    await Future<void>.delayed(Duration.zero);
    final count = calls.where((c) => c.method == 'splashFinish').length;
    expect(count, 1);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls.where((c) => c.method == 'splashFinish').length, count,
        reason: '定时器没撤的话会重复通知 native');
  });
}
