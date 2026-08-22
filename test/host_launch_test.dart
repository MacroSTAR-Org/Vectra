/// host.launch（启动本地程序）的路径校验与返回值测试。
///
/// launcher 卡片的核心动作就是它：白名单放不放行、native 通道收没收到、
/// 失败时插件拿到的是不是 {ok:false} 而不是异常，都在这几个用例里。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/model/card.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/plugin/host.dart';
import 'package:vectra/plugin/registry.dart';
import 'package:vectra/plugin/sdk.dart';
import 'package:vectra/store/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late PluginHost host;
  late List<MethodCall> calls;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('host_launch_test_');
    final registry = PluginRegistry(tmpDir.path);
    final sdk = PluginSdk(pluginId: 'test-plugin', registry: registry);
    final store = Store(tmpDir.path);
    await store.load();
    host = PluginHost(
      store: store,
      state: AppState(settings: AppSettings(), cards: []),
      card: WidgetCard(
          id: 'test-card', pluginId: 'test-plugin', x: 0, y: 0, size: '2x2', z: 0),
      pluginId: 'test-plugin',
      onRequestSize: (_) {},
      onOpenSettings: () {},
      registry: registry,
      sdk: sdk,
    );
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async {
      calls.add(call);
      if (call.method == 'launchApp') return true;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vectra/native'), null);
    tmpDir.deleteSync(recursive: true);
  });

  /// 遍历渲染树收集所有 tap 节点
  List<MethodCall> launchCalls() =>
      calls.where((c) => c.method == 'launchApp').toList();

  group('launch 放行', () {
    test('exe 绝对路径转发给 native 并返回 ok', () async {
      final r = await host.call('launch', {'path': r'C:\Windows\notepad.exe'});
      expect(r, {'ok': true});
      expect(launchCalls(), hasLength(1));
      expect(launchCalls().first.arguments, r'C:\Windows\notepad.exe');
    });

    test('lnk / bat / cmd / msc 都在白名单里', () async {
      for (final p in [
        r'C:\Users\a\Desktop\浏览器.lnk',
        r'D:\tools\run.bat',
        r'D:\tools\setup.cmd',
        r'C:\Windows\system32\services.msc',
      ]) {
        final r = await host.call('launch', {'path': p});
        expect(r, {'ok': true}, reason: p);
      }
      expect(launchCalls(), hasLength(4));
    });

    test('扩展名大小写不敏感', () async {
      final r = await host.call('launch', {'path': r'C:\Windows\NOTEPAD.EXE'});
      expect(r, {'ok': true});
    });

    test('UNC 路径算绝对路径', () async {
      final r = await host
          .call('launch', {'path': r'\\server\share\tool.exe'});
      expect(r, {'ok': true});
    });
  });

  group('launch 拦截', () {
    test('白名单外的扩展名不进 native', () async {
      final r = await host.call('launch', {'path': r'C:\temp\notes.txt'});
      expect((r as Map)['ok'], false);
      expect(launchCalls(), isEmpty);
    });

    test('没有扩展名拒绝', () async {
      final r = await host.call('launch', {'path': r'C:\Windows\System32'});
      expect((r as Map)['ok'], false);
      expect(launchCalls(), isEmpty);
    });

    test('相对路径拒绝', () async {
      final r = await host.call('launch', {'path': 'notepad.exe'});
      expect((r as Map)['ok'], false);
      expect(launchCalls(), isEmpty);
    });

    test('http 地址拒绝（那是 openExternal 的事）', () async {
      final r = await host.call('launch', {'path': 'https://example.com/a.exe'});
      expect((r as Map)['ok'], false);
      expect(launchCalls(), isEmpty);
    });

    test('空路径拒绝', () async {
      final r = await host.call('launch', {});
      expect((r as Map)['ok'], false);
      expect(launchCalls(), isEmpty);
    });
  });

  group('launch 失败回传', () {
    test('native 返回失败时插件拿到 {ok:false}', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('vectra/native'), (call) async {
        calls.add(call);
        if (call.method == 'launchApp') return false;
        return null;
      });
      final r = await host.call('launch', {'path': r'C:\x\nope.exe'});
      expect((r as Map)['ok'], false);
      expect(r.containsKey('error'), isTrue);
    });
  });
}
