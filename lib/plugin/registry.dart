/// 插件注册表：扫描内置插件与用户插件。
///
/// 内置插件随应用打包成 Flutter asset；用户插件放在
/// `<exe>\userdata\plugins\<id>\`，运行时从磁盘读取——
/// "运行时加载第三方插件"是需求里定死的，不能退化成编译期。
///
/// 同 id 时用户插件覆盖内置，与 Electron 版一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../core/logger.dart';
import 'manifest.dart';

class LoadedPlugin {
  LoadedPlugin(this.manifest, this.source);
  final PluginManifest manifest;

  /// 插件入口的 JS 源码
  final String source;
}

class PluginRegistry {
  PluginRegistry(this.userDir);

  final String userDir;

  final Map<String, LoadedPlugin> _plugins = {};

  /// 加载失败的插件：目录 -> 原因。面板里要能看到，不能静默吞掉。
  final Map<String, String> errors = {};

  List<PluginManifest> list() =>
      _plugins.values.map((e) => e.manifest).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  LoadedPlugin? operator [](String id) => _plugins[id];

  /// 内置插件清单。Flutter 的 asset 不支持目录枚举，只能显式列出。
  static const List<String> builtinIds = [
    'clock',
    'calendar',
    'todo',
    'weather',
    'lyrics',
  ];

  Future<void> scan() async {
    _plugins.clear();
    errors.clear();
    await _scanBuiltin();
    await _scanUser();
  }

  Future<void> _scanBuiltin() async {
    for (final id in builtinIds) {
      try {
        final manifestRaw = await rootBundle.loadString('assets/plugins/$id/manifest.json');
        final manifest = PluginManifest.parse(
            jsonDecode(manifestRaw) as Map<String, Object?>,
            source: 'builtin');
        if (manifest.id != id) {
          throw FormatException('manifest.id "${manifest.id}" 与目录名 "$id" 不一致');
        }
        // scripts 先于 entry 加载，拼成一段代码交给同一个 QuickJS 运行时
        final buf = StringBuffer();
        for (final extra in manifest.scripts) {
          buf.writeln(await rootBundle.loadString('assets/plugins/$id/$extra'));
        }
        buf.writeln(await rootBundle.loadString('assets/plugins/$id/${manifest.entry}'));
        _plugins[id] = LoadedPlugin(manifest, buf.toString());
      } catch (e) {
        errors['builtin/$id'] = '$e';
        Log.e('plugin', '内置插件 $id 加载失败: $e');
      }
    }
  }

  Future<void> _scanUser() async {
    final dir = Directory(userDir);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
      return;
    }
    await for (final entry in dir.list()) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      try {
        final mf = File(p.join(entry.path, 'manifest.json'));
        if (!await mf.exists()) {
          throw const FormatException('没有 manifest.json');
        }
        final manifest = PluginManifest.parse(
            jsonDecode(await mf.readAsString()) as Map<String, Object?>,
            source: 'user');
        if (manifest.id != name) {
          throw FormatException('manifest.id "${manifest.id}" 必须与目录名 "$name" 相同');
        }
        // 路径穿越防护：entry 必须落在插件目录内
        final entryPath = p.normalize(p.join(entry.path, manifest.entry));
        if (!p.isWithin(entry.path, entryPath)) {
          throw const FormatException('entry 指向了插件目录之外');
        }
        final buf = StringBuffer();
        for (final extra in manifest.scripts) {
          final ep = p.normalize(p.join(entry.path, extra));
          if (!p.isWithin(entry.path, ep)) {
            throw FormatException('scripts 里的 $extra 指向了插件目录之外');
          }
          buf.writeln(await File(ep).readAsString());
        }
        final src = File(entryPath);
        if (!await src.exists()) {
          throw FormatException('入口文件不存在：${manifest.entry}');
        }
        buf.writeln(await src.readAsString());
        _plugins[manifest.id] = LoadedPlugin(manifest, buf.toString());
      } catch (e) {
        errors[entry.path] = '$e';
        Log.e('plugin', '用户插件 ${entry.path} 加载失败: $e');
      }
    }
  }
}
