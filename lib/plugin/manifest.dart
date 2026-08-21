/// 插件清单。字段与校验规则沿用 Electron 版，保证同一份 manifest.json
/// 在两边含义一致。
library;

import '../core/grid.dart';

class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.entry,
    this.description = '',
    this.author = '',
    this.icon = '▢',
    this.sizes = const ['2x2'],
    this.defaultSize = '2x2',
    this.singleton = false,
    this.settings = const [],
    this.scripts = const [],
    this.source = 'builtin',
    this.apiVersion = '1.0',
    this.dependencies = const [],
    this.headless = false,
  });

  final String id;
  final String name;
  final String version;
  final String entry;
  final String description;
  final String author;
  final String icon;
  final List<String> sizes;
  final String defaultSize;
  final bool singleton;

  /// 设置项描述，见面板渲染
  final List<Map<String, Object?>> settings;

  /// 在 entry 之前按顺序加载的附加脚本（相对插件目录）。
  /// 让插件可以把算法之类拆成独立文件，而不是全塞进一个 index.js。
  final List<String> scripts;

  /// builtin | user
  final String source;

  /// 插件要求的 SDK API 版本。不匹配时警告但不阻止加载。
  final String apiVersion;

  /// 依赖的其他插件注册的能力（"provider:capability" 格式）。
  final List<String> dependencies;

  /// 是否支持无 UI 后台运行（用于能力提供者插件）。
  final bool headless;

  static final RegExp _idRe = RegExp(r'^[a-z0-9][a-z0-9\-_]{0,63}$');

  /// 解析并校验；不合法时抛出带原因的异常，由调用方收集到"损坏插件"列表
  static PluginManifest parse(Map<String, Object?> raw, {required String source}) {
    String req(String key) {
      final v = raw[key];
      if (v is! String || v.trim().isEmpty) {
        throw FormatException('缺少必填字段 $key');
      }
      return v.trim();
    }

    final id = req('id');
    if (!_idRe.hasMatch(id)) {
      throw FormatException('id "$id" 不合法（只允许小写字母、数字、- 和 _）');
    }

    var sizes = <String>[];
    final rawSizes = raw['sizes'];
    if (rawSizes is List) {
      sizes = normalizeSizes(rawSizes.whereType<String>().toList());
    }
    if (sizes.isEmpty) sizes = ['2x2'];

    var def = (raw['defaultSize'] as String?)?.trim().toLowerCase() ?? sizes.first;
    if (!sizes.contains(def)) {
      throw FormatException('defaultSize "$def" 不在 sizes 列表里');
    }

    return PluginManifest(
      id: id,
      name: req('name'),
      version: req('version'),
      entry: req('entry'),
      description: raw['description'] as String? ?? '',
      author: raw['author'] as String? ?? '',
      icon: raw['icon'] as String? ?? '▢',
      sizes: sizes,
      defaultSize: def,
      singleton: raw['singleton'] == true,
      settings: [
        for (final s in (raw['settings'] as List? ?? const []))
          if (s is Map && s['key'] is String) s.cast<String, Object?>()
      ],
      scripts: [
        for (final s in (raw['scripts'] as List? ?? const []))
          if (s is String) s
      ],
      source: source,
      apiVersion: (raw['api_version'] as String?)?.trim() ?? '1.0',
      dependencies: [
        for (final d in (raw['dependencies'] as List? ?? const []))
          if (d is String && d.trim().isNotEmpty) d.trim()
      ],
      headless: raw['headless'] == true,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'author': author,
        'icon': icon,
        'sizes': sizes,
        'defaultSize': defaultSize,
        'singleton': singleton,
        'settings': settings,
        'source': source,
        'api_version': apiVersion,
        'dependencies': dependencies,
        'headless': headless,
      };

  /// 每个设置项的默认值
  Map<String, Object?> defaultSettings() => {
        for (final f in settings) f['key'] as String: f['default'],
      };
}
