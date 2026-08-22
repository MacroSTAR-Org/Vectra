/// manifest.dart 新增字段（api_version / dependencies / headless）的解析测试。
///
/// 这些字段是插件 SDK 的基础：api_version 做兼容性检查，dependencies
/// 声明对其他插件注册能力的依赖，headless 标识是否支持无 UI 后台运行。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/plugin/manifest.dart';

void main() {
  Map<String, Object?> base({
    String id = 'test-plugin',
    String name = '测试插件',
    String version = '1.0.0',
    String entry = 'index.js',
  }) => {
        'id': id,
        'name': name,
        'version': version,
        'entry': entry,
      };

  group('api_version', () {
    test('缺失时默认 "1.0"', () {
      final m = PluginManifest.parse(base(), source: 'user');
      expect(m.apiVersion, '1.0');
    });

    test('正常解析', () {
      final m = PluginManifest.parse({
        ...base(),
        'api_version': '2.0',
      }, source: 'user');
      expect(m.apiVersion, '2.0');
    });

    test('空白字符串被 trim', () {
      final m = PluginManifest.parse({
        ...base(),
        'api_version': '  1.5  ',
      }, source: 'user');
      expect(m.apiVersion, '1.5');
    });
  });

  group('dependencies', () {
    test('缺失时默认空列表', () {
      final m = PluginManifest.parse(base(), source: 'user');
      expect(m.dependencies, isEmpty);
    });

    test('正常解析多个依赖', () {
      final m = PluginManifest.parse({
        ...base(),
        'dependencies': ['ws-bridge:websocket', 'sync:cloud'],
      }, source: 'user');
      expect(m.dependencies, ['ws-bridge:websocket', 'sync:cloud']);
    });

    test('空字符串被过滤', () {
      final m = PluginManifest.parse({
        ...base(),
        'dependencies': ['ws-bridge:websocket', '', '  ', 'sync:cloud'],
      }, source: 'user');
      expect(m.dependencies, ['ws-bridge:websocket', 'sync:cloud']);
    });

    test('非字符串被过滤', () {
      final m = PluginManifest.parse({
        ...base(),
        'dependencies': ['ws-bridge:websocket', 123, null, true],
      }, source: 'user');
      expect(m.dependencies, ['ws-bridge:websocket']);
    });

    test('空列表', () {
      final m = PluginManifest.parse({
        ...base(),
        'dependencies': [],
      }, source: 'user');
      expect(m.dependencies, isEmpty);
    });
  });

  group('headless', () {
    test('缺失时默认 false', () {
      final m = PluginManifest.parse(base(), source: 'user');
      expect(m.headless, false);
    });

    test('显式 true', () {
      final m = PluginManifest.parse({
        ...base(),
        'headless': true,
      }, source: 'user');
      expect(m.headless, true);
    });

    test('显式 false', () {
      final m = PluginManifest.parse({
        ...base(),
        'headless': false,
      }, source: 'user');
      expect(m.headless, false);
    });

    test('非布尔值被忽略', () {
      final m = PluginManifest.parse({
        ...base(),
        'headless': 'yes',
      }, source: 'user');
      expect(m.headless, false);
    });
  });

  group('toJson 往返', () {
    test('新字段在 toJson 里保留', () {
      final m = PluginManifest.parse({
        ...base(),
        'api_version': '2.0',
        'dependencies': ['ws-bridge:websocket'],
        'headless': true,
      }, source: 'user');
      final json = m.toJson();
      expect(json['api_version'], '2.0');
      expect(json['dependencies'], ['ws-bridge:websocket']);
      expect(json['headless'], true);
    });

    test('从 toJson 重新解析结果一致', () {
      final m1 = PluginManifest.parse({
        ...base(),
        'api_version': '2.0',
        'dependencies': ['ws-bridge:websocket'],
        'headless': true,
      }, source: 'user');
      // toJson 不含 entry（设计意图），补上再解析
      final m2 = PluginManifest.parse({
        ...m1.toJson(),
        'entry': m1.entry,
      }, source: 'user');
      expect(m2.apiVersion, m1.apiVersion);
      expect(m2.dependencies, m1.dependencies);
      expect(m2.headless, m1.headless);
    });
  });

  group('现有字段不受影响', () {
    test('所有必填字段仍然必填', () {
      expect(
        () => PluginManifest.parse({'id': 'x'}, source: 'user'),
        throwsFormatException,
      );
    });

    test('sizes/defaultSize/settings/scripts 正常工作', () {
      final m = PluginManifest.parse({
        ...base(),
        'sizes': ['2x2', '3x3'],
        'defaultSize': '3x3',
        'settings': [{'key': 'city', 'type': 'text', 'label': '城市'}],
        'scripts': ['lib.js'],
      }, source: 'user');
      expect(m.sizes, ['2x2', '3x3']);
      expect(m.defaultSize, '3x3');
      expect(m.settings, hasLength(1));
      expect(m.scripts, ['lib.js']);
    });
  });
}
