/// host.dart SDK 路由和自定义能力路由的测试。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/model/card.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/plugin/host.dart';
import 'package:vectra/plugin/registry.dart';
import 'package:vectra/plugin/sdk.dart';
import 'package:vectra/store/store.dart';

void main() {
  late Directory tmpDir;
  late PluginRegistry registry;
  late PluginSdk sdk;
  late PluginHost host;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('host_test_');
    registry = PluginRegistry(tmpDir.path);
    sdk = PluginSdk(pluginId: 'test-plugin', registry: registry);
    final store = Store(tmpDir.path);
    await store.load();
    final state = AppState(settings: AppSettings(), cards: []);
    final card = WidgetCard(
        id: 'test-card', pluginId: 'test-plugin', x: 0, y: 0, size: '2x2', z: 0);
    host = PluginHost(
      store: store,
      state: state,
      card: card,
      pluginId: 'test-plugin',
      onRequestSize: (_) {},
      onOpenSettings: () {},
      registry: registry,
      sdk: sdk,
    );
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('SDK 节点注册', () {
    test('__sdk.node.register 注册后在 registry 里能查到', () async {
      final result = await host.call('__sdk.node.register', {
        'type': 'chart',
        'render': {'type': 'fn'},
      });
      expect(result, true);
      expect(registry.registeredNodes, contains('chart'));
    });

    test('__sdk.node.register 同名类型被拒绝', () async {
      sdk.registerNode('chart', {'type': 'a'});
      final result = await host.call('__sdk.node.register', {
        'type': 'chart',
        'render': {'type': 'b'},
      });
      expect(result, true); // 不报错，但不覆盖
      expect(registry.registeredNodes['chart']!.pluginId, 'test-plugin');
    });
  });

  group('SDK 能力注册', () {
    test('__sdk.capability.register 注册后在 registry 里能查到', () async {
      final result = await host.call('__sdk.capability.register', {
        'name': 'websocket',
        'handler': {'connect': {}, 'send': {}},
      });
      expect(result, true);
      expect(registry.registeredCapabilities, contains('websocket'));
      expect(registry.registeredCapabilities['websocket']!.methods.length, 2);
    });

    test('__sdk.capability.register 支持部分方法表', () async {
      await host.call('__sdk.capability.register', {
        'name': 'websocket',
        'handler': {'connect': {}},
      });
      expect(registry.registeredCapabilities['websocket']!.methods.length, 1);
    });
  });

  group('SDK 生命周期', () {
    test('__sdk.lifecycle.on 注册后在 registry 里能查到', () async {
      final result = await host.call('__sdk.lifecycle.on', {
        'event': 'appReady',
        'handler': {'type': 'fn'},
      });
      expect(result, true);
      expect(registry.lifecycleListeners, contains('appReady'));
    });
  });

  group('SDK widget 注册', () {
    test('__sdk.widget.register 注册后在 registry 里能查到', () async {
      final result = await host.call('__sdk.widget.register', {
        'template': {
          'id': 'stock',
          'name': '股票行情',
        },
      });
      expect(result, true);
      expect(registry.registeredWidgets, hasLength(1));
      expect(registry.registeredWidgets.first.id, 'stock');
    });
  });

  group('未知方法', () {
    test('未知的内置方法返回错误', () async {
      final result = await host.call('nonexistent.method', {});
      expect(result, isA<Map>());
      expect((result as Map)['ok'], false);
    });

    test('未知的 SDK 方法返回错误', () async {
      final result = await host.call('__sdk.unknown.method', {});
      expect(result, isA<Map>());
      expect((result as Map)['ok'], false);
    });
  });

  group('自定义能力路由', () {
    test('未注册的能力返回 method not found', () async {
      // 注册一个只有 connect 方法的能力
      await host.call('__sdk.capability.register', {
        'name': 'websocket',
        'handler': {'connect': {}},
      });

      // 调用未注册的 close 方法
      final result = await host.call('websocket.close', {});
      expect(result, isA<Map>());
      final r = result as Map;
      expect(r['ok'], false);
      expect(r['error'], contains('not found'));
    });
  });
}
