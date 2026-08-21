/// PluginSdk 核心行为的契约测试。
///
/// 定义了插件 SDK 的三个扩展点：
///   - 节点注册：插件可以给 ctx.render() 加新的节点类型
///   - 能力注册：插件可以给 ctx 加新的 API 对象
///   - 生命周期：插件可以钩入程序的各个阶段
///
/// 这些测试在 Phase 1 只定义契约，Phase 3-4 实现后才能通过。
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:vectra/plugin/registry.dart';
import 'package:vectra/plugin/sdk.dart';

void main() {
  late Directory tmpDir;
  late PluginRegistry reg;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('sdk_test_');
    reg = PluginRegistry(tmpDir.path);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  PluginSdk sdk(String id) => PluginSdk(pluginId: id, registry: reg);

  group('PluginSdk.registerNode', () {
    test('注册新节点类型后在 registry 里能查到', () {
      final s = sdk('chart-plugin');

      s.registerNode('chart', {'type': 'chart_handler'});

      expect(reg.registeredNodes, contains('chart'));
      expect(reg.registeredNodes['chart']!.pluginId, 'chart-plugin');
    });

    test('同名节点类型被拒绝，后者不覆盖前者', () {
      sdk('plugin-a').registerNode('chart', {'type': 'a'});
      sdk('plugin-b').registerNode('chart', {'type': 'b'});

      expect(reg.registeredNodes['chart']!.pluginId, 'plugin-a');
    });

    test('不同类型互不影响', () {
      sdk('a').registerNode('chart', {'type': 'a'});
      sdk('b').registerNode('map', {'type': 'b'});

      expect(reg.registeredNodes, contains('chart'));
      expect(reg.registeredNodes, contains('map'));
    });
  });

  group('PluginSdk.registerCapability', () {
    test('注册能力后在 registry 里能查到', () {
      final s = sdk('ws-bridge');

      s.registerCapability('websocket', {
        'connect': {'type': 'handler'},
      });

      expect(reg.registeredCapabilities, contains('websocket'));
      expect(reg.registeredCapabilities['websocket']!.pluginId, 'ws-bridge');
    });

    test('能力方法表可以是部分的', () {
      sdk('ws-bridge').registerCapability('websocket', {
        'connect': {'type': 'handler'},
        // 只注册 connect，不注册 send/close
      });

      final cap = reg.registeredCapabilities['websocket']!;
      expect(cap.methods, contains('connect'));
      expect(cap.methods.length, 1);
    });

    test('同名能力被拒绝', () {
      sdk('a').registerCapability('websocket', {'connect': {}});
      sdk('b').registerCapability('websocket', {'send': {}});

      expect(reg.registeredCapabilities['websocket']!.pluginId, 'a');
    });
  });

  group('PluginSdk.onLifecycle', () {
    test('注册后在 registry 里能查到', () {
      final s = sdk('plugin-a');

      s.onLifecycle('appReady', {'type': 'handler'});

      expect(reg.lifecycleListeners, contains('appReady'));
      expect(reg.lifecycleListeners['appReady']!.single.pluginId, 'plugin-a');
    });

    test('同一事件可以注册多个监听器', () {
      sdk('a').onLifecycle('appReady', {'type': 'h1'});
      sdk('b').onLifecycle('appReady', {'type': 'h2'});

      expect(reg.lifecycleListeners['appReady']!.length, 2);
    });
  });

  group('PluginSdk.dispose', () {
    test('清理该插件注册的所有节点', () {
      final s = sdk('my-plugin');
      s.registerNode('chart', {'type': 'h'});
      s.registerNode('map', {'type': 'h'});

      s.dispose();

      expect(reg.registeredNodes, isNot(contains('chart')));
      expect(reg.registeredNodes, isNot(contains('map')));
    });

    test('清理该插件注册的所有能力', () {
      final s = sdk('my-plugin');
      s.registerCapability('websocket', {'connect': {}});

      s.dispose();

      expect(reg.registeredCapabilities, isNot(contains('websocket')));
    });

    test('清理该插件注册的所有生命周期监听', () {
      final s = sdk('my-plugin');
      s.onLifecycle('appReady', {'type': 'h'});
      s.onLifecycle('cardAdded', {'type': 'h'});

      s.dispose();

      expect(reg.lifecycleListeners['appReady'], isEmpty);
      expect(reg.lifecycleListeners['cardAdded'], isEmpty);
    });

    test('不影响其他插件的注册', () {
      sdk('a').registerNode('chart', {'type': 'a'});
      final b = sdk('b');
      b.registerNode('map', {'type': 'b'});

      b.dispose();

      expect(reg.registeredNodes, contains('chart'));
      expect(reg.registeredNodes, isNot(contains('map')));
    });
  });
}
