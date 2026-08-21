/// 插件 SDK：给插件提供扩展宿主程序的能力。
///
/// 插件通过 [registerNode] 注册新的渲染节点类型，通过 [registerCapability]
/// 注册新的 host API，通过 [onLifecycle] 钩入程序生命周期。所有注册在
/// 插件卸载时自动清理（[dispose]）。
///
/// 设计思路借鉴 Class Widgets SDK 的模型：插件通过 rich API 深度集成到宿主，
/// 而不是只能用固定几个 API 搭积木。
library;

import '../core/logger.dart';
import 'registry.dart';

/// 插件注册的自定义节点处理器。
///
/// [render] 是插件传来的 JS 函数引用，由 prelude 通过 post() 传到宿主侧。
/// 宿主在渲染时需要通过 QuickJS 运行时调用它。
class NodeHandler {
  NodeHandler({required this.pluginId, required this.type, required this.render});

  final String pluginId;
  final String type;

  /// JS 函数引用（由 prelude 传来的序列化标识）。
  /// v1 阶段先存为 opaque Object，后续接入 QuickJS 调用链。
  final Object? render;
}

/// 插件注册的能力处理器。
///
/// [methods] 的 key 是方法名，value 是 JS 函数引用。
/// 消费方调用时，宿主根据方法名找到对应函数并转发请求。
class CapabilityHandler {
  CapabilityHandler({
    required this.pluginId,
    required this.name,
    required this.methods,
  });

  final String pluginId;
  final String name;

  /// 方法表：方法名 → JS 函数引用。可以是部分的（只注册部分方法）。
  final Map<String, Object?> methods;
}

/// 生命周期事件监听器。
class LifecycleListener {
  LifecycleListener({required this.pluginId, required this.handler});

  final String pluginId;

  /// JS 函数引用或 Dart 回调。
  final Object? handler;
}

/// Widget 模板（插件注册到组件库的卡片模板）。
class WidgetTemplate {
  WidgetTemplate({
    required this.pluginId,
    required this.id,
    required this.name,
    this.description = '',
    this.icon = '▢',
    this.sizes = const ['2x2'],
    this.defaultSize = '2x2',
    this.settings = const [],
  });

  final String pluginId;
  final String id;
  final String name;
  final String description;
  final String icon;
  final List<String> sizes;
  final String defaultSize;
  final List<Map<String, Object?>> settings;

  static WidgetTemplate? parse(Map<String, Object?> raw) {
    final id = raw['id'] as String?;
    final name = raw['name'] as String?;
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;

    final sizes = <String>[
      for (final s in (raw['sizes'] as List? ?? const []))
        if (s is String && s.trim().isNotEmpty) s.trim()
    ];
    if (sizes.isEmpty) sizes.add('2x2');

    final defaultSize = sizes.contains(raw['defaultSize'])
        ? raw['defaultSize'] as String
        : sizes.first;

    return WidgetTemplate(
      pluginId: raw['pluginId'] as String? ?? '',
      id: id,
      name: name,
      description: raw['description'] as String? ?? '',
      icon: raw['icon'] as String? ?? '▢',
      sizes: sizes,
      defaultSize: defaultSize,
      settings: [
        for (final s in (raw['settings'] as List? ?? const []))
          if (s is Map && s['key'] is String) s.cast<String, Object?>()
      ],
    );
  }
}

/// 插件 SDK 核心对象。
///
/// 每个插件实例拥有一个 [PluginSdk]，通过它注册扩展点。
/// 所有注册在 [dispose] 时自动清理。
class PluginSdk {
  PluginSdk({required this.pluginId, required this.registry});

  final String pluginId;
  final PluginRegistry registry;

  /// 注册新的渲染节点类型。
  ///
  /// 同名类型会被拒绝（后者不覆盖前者），并在日志中记录冲突。
  void registerNode(String type, Object? renderHandler) {
    if (type.isEmpty) return;
    if (registry.registeredNodes.containsKey(type)) {
      final existing = registry.registeredNodes[type]!;
      Log.w('plugin',
          '节点类型 "$type" 冲突：${existing.pluginId} 已注册，$pluginId 被拒绝');
      return;
    }
    registry.registeredNodes[type] = NodeHandler(
      pluginId: pluginId,
      type: type,
      render: renderHandler,
    );
    Log.i('plugin', '$pluginId 注册节点类型 "$type"');
  }

  /// 注册新的 host API 能力。
  ///
  /// [methods] 可以是部分的——只注册需要的方法，其余方法调用时返回
  /// "method not found"。同名能力会被拒绝。
  void registerCapability(String name, Map<String, Object?> methods) {
    if (name.isEmpty) return;
    if (registry.registeredCapabilities.containsKey(name)) {
      final existing = registry.registeredCapabilities[name]!;
      Log.w('plugin',
          '能力 "$name" 冲突：${existing.pluginId} 已注册，$pluginId 被拒绝');
      return;
    }
    registry.registeredCapabilities[name] = CapabilityHandler(
      pluginId: pluginId,
      name: name,
      methods: Map.of(methods),
    );
    Log.i('plugin', '$pluginId 注册能力 "$name"（${methods.length} 个方法）');
  }

  /// 注册 widget 模板到组件库。
  void registerWidget(Map<String, Object?> template) {
    final t = WidgetTemplate.parse({...template, 'pluginId': pluginId});
    if (t != null) {
      registry.registeredWidgets.add(t);
      Log.i('plugin', '$pluginId 注册 widget 模板 "${t.name}" (${t.id})');
    }
  }

  /// 钩入生命周期事件。
  void onLifecycle(String event, Object? handler) {
    if (event.isEmpty) return;
    registry.lifecycleListeners
        .putIfAbsent(event, () => [])
        .add(LifecycleListener(pluginId: pluginId, handler: handler));
  }

  /// 清理本插件注册的所有扩展点。插件卸载时由 runtime 调用。
  void dispose() {
    final removedNodes =
        registry.registeredNodes.keys.where((k) {
      final h = registry.registeredNodes[k];
      return h != null && h.pluginId == pluginId;
    }).toList();
    for (final k in removedNodes) {
      registry.registeredNodes.remove(k);
    }

    final removedCaps =
        registry.registeredCapabilities.keys.where((k) {
      final h = registry.registeredCapabilities[k];
      return h != null && h.pluginId == pluginId;
    }).toList();
    for (final k in removedCaps) {
      registry.registeredCapabilities.remove(k);
    }

    registry.registeredWidgets
        .removeWhere((t) => t.pluginId == pluginId);

    for (final list in registry.lifecycleListeners.values) {
      list.removeWhere((l) => l.pluginId == pluginId);
    }

    if (removedNodes.isNotEmpty || removedCaps.isNotEmpty) {
      Log.i('plugin',
          '$pluginId SDK 已清理（${removedNodes.length} 节点, ${removedCaps.length} 能力）');
    }
  }
}
