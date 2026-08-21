/// 宿主能力：插件通过 lw.call(method, args) 请求，最终落到这里。
///
/// 有意让这一层很薄且集中：插件能做的每一件"运行时之外的事"都在这个 switch
/// 里，一眼能数清楚。想收权限时也只有这一处要改。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/app_version.dart';
import '../core/logger.dart';
import '../model/card.dart';
import '../native/native_bridge.dart';
import '../store/store.dart';
import 'images.dart';
import 'registry.dart';
import 'sdk.dart';

class PluginHost {
  PluginHost({
    required this.store,
    required this.state,
    required this.card,
    required this.pluginId,
    required this.onRequestSize,
    required this.onOpenSettings,
    required this.registry,
    required this.sdk,
  });

  final Store store;
  final AppState state;
  final WidgetCard card;
  final String pluginId;
  final void Function(String size) onRequestSize;
  final void Function() onOpenSettings;
  final PluginRegistry registry;
  final PluginSdk sdk;

  /// 实例私有键：同一插件的不同卡片各存各的
  String _localKey(String key) => '@inst:${card.id}:$key';

  Future<Object?> call(String method, Map<String, Object?> args) async {
    switch (method) {
      case 'storage.get':
        return store.nsGet(pluginId, args['key'] as String? ?? '', args['def']);

      case 'storage.set':
        store.nsSet(pluginId, args['key'] as String? ?? '', args['value']);
        return true;

      case 'storage.getLocal':
        return store.nsGet(pluginId, _localKey(args['key'] as String? ?? ''), args['def']);

      case 'storage.setLocal':
        store.nsSet(pluginId, _localKey(args['key'] as String? ?? ''), args['value']);
        return true;

      // 缓存：一条一个文件，可被淘汰。适合歌词、网络响应这种"丢了能重建"的
      // 大块数据；别拿它存用户真正的东西。
      case 'storage.cacheGet':
        return store.cacheGet(pluginId, args['key'] as String? ?? '');

      case 'storage.cacheSet':
        await store.cacheSet(
            pluginId, args['key'] as String? ?? '', args['value']);
        return true;

      case 'http.getJSON':
        return _getJson(
          args['url'] as String? ?? '',
          (args['headers'] as Map?)?.cast<String, Object?>(),
        );

      // 原始文本版：接口返回的不是纯 JSON 时用（比如中国天气网的城市
      // 搜索 toy1 是 JSONP 包装 `([{...}])`，getJSON 的 jsonDecode 必然
      // 炸）。插件拿到文本自己剥包装再解析。
      case 'http.getText':
        return _getText(
          args['url'] as String? ?? '',
          (args['headers'] as Map?)?.cast<String, Object?>(),
        );

      case 'media.state':
        return _mediaState();

      case 'media.control':
        return NativeBridge.smtcControl(
          args['cmd'] as String? ?? '',
          posMs: (args['posMs'] as num?)?.round() ?? 0,
        );

      case 'requestSize':
        final s = args['size'] as String?;
        if (s != null) onRequestSize(s);
        return true;

      case 'openSettings':
        onOpenSettings();
        return true;

      case 'toast':
        // 目前只落日志。真正的 toast UI 等面板做好再接。
        Log.i('plugin', '$pluginId: ${args['message']}');
        return true;

      case 'openExternal':
        return _openExternal(args['url'] as String? ?? '');

      case 'pickFile':
        return _pickFile(args);

      default:
        // ---- SDK 注册消息 ----
        if (method.startsWith('__sdk.')) {
          return _handleSdk(method, args);
        }

        // ---- 自定义能力路由 ----
        final dotIdx = method.lastIndexOf('.');
        if (dotIdx > 0) {
          final capName = method.substring(0, dotIdx);
          final methodName = method.substring(dotIdx + 1);
          final capHandler = registry.registeredCapabilities[capName];
          if (capHandler != null) {
            if (capHandler.methods.containsKey(methodName)) {
              // v1: 方法是 JS 函数引用，需要通过提供者的运行时调用
              // 目前先返回提示，后续接入 QuickJS 跨运行时调用
              return {'ok': false, 'error': 'JS-side capability routing not yet implemented'};
            }
            return {'ok': false, 'error': 'method "$methodName" not found in capability "$capName"'};
          }
        }

        return {'ok': false, 'error': '未知的宿主方法：$method'};
    }
  }

  /// 正在播放的媒体状态（SMTC）。
  ///
  /// 顺手把封面解码进宿主的图片缓存：插件只会拿到 artKey 这个字符串，
  /// 永远碰不到字节。理由见 PluginImages 的注释。
  Future<Map<String, Object?>> _mediaState() async {
    try {
      final s = await NativeBridge.smtcState();
      if (s == null) return {'ok': false, 'error': '取不到媒体状态'};

      final artId = (s['artId'] as num?)?.toInt() ?? 0;
      final available = s['available'] == true;
      String? artKey;
      if (available && artId > 0) {
        final key = 'smtc:$artId';
        if (PluginImages.has(key)) {
          artKey = key;
        } else {
          final bytes = await NativeBridge.smtcArt(artId);
          if (bytes != null && await PluginImages.decodeAndPut(key, bytes)) {
            artKey = key;
          }
        }
      }
      return {'ok': true, 'data': {...s, 'artKey': artKey}};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// 网络请求由宿主代发：插件拿不到原始 socket，也就没有 CORS 之类的问题。
  /// 永远返回 {ok, data} / {ok, error}，不抛异常——插件里没有统一的错误边界。
  ///
  /// [extraHeaders] 是插件自己要加的请求头。有些接口（例如网易云那套非官方
  /// 接口）会按 Referer/UA 限流；实测目前不带也能通，但它随时可能收紧。
  /// 只允许覆盖白名单内的头，免得插件伪造 Cookie 之类的东西。
  Future<Map<String, Object?>> _getJson(
      String url, Map<String, Object?>? extraHeaders) async {
    final res = await _fetch(url, extraHeaders);
    if (res == null) return {'ok': false, 'error': '只允许 http/https'};
    if (res['ok'] != true) return res;
    try {
      return {'ok': true, 'data': jsonDecode(res['text'] as String)};
    } catch (e) {
      Log.w('plugin', '插件 JSON 解析失败: $e');
      return {'ok': false, 'error': '响应不是合法 JSON'};
    }
  }

  Future<Map<String, Object?>> _getText(
      String url, Map<String, Object?>? extraHeaders) async {
    final res = await _fetch(url, extraHeaders);
    if (res == null) return {'ok': false, 'error': '只允许 http/https'};
    if (res['ok'] != true) return res;
    return {'ok': true, 'data': res['text'] as String};
  }

  /// 共用请求骨架：URL 校验、头白名单、日志留痕、超时。返回的 map 里
  /// ok=false 时带 error；ok=true 时带 text（原始文本）。
  Future<Map<String, Object?>?> _fetch(
      String url, Map<String, Object?>? extraHeaders) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return {'ok': false, 'error': '只允许 http/https'};
    }
    const allowed = {'user-agent', 'referer', 'accept', 'accept-language'};
    final headers = <String, String>{'User-Agent': appUserAgent};
    if (extraHeaders != null) {
      for (final e in extraHeaders.entries) {
        if (allowed.contains(e.key.toLowerCase())) {
          headers[e.key] = '${e.value}';
        }
      }
    }
    // 插件请求外部接口是最常出问题的一环：接口挂了、限流了、字段改了、
    // 网络不通……而这些在界面上一律表现为"组件不显示数据"。所以整条链路
    // 都要留痕：发起、结果、耗时。URL 只记 host+path，query 里可能有密钥
    // （日志系统还有一道统一脱敏兜底，这里先自己收着）。
    final target = '${uri.host}${uri.path}';
    Log.d('plugin', '$pluginId 请求 $target');
    final sw = Stopwatch()..start();
    try {
      final res =
          await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
      sw.stop();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        Log.w('plugin',
            '$pluginId 请求返回 ${res.statusCode} $target（${sw.elapsedMilliseconds}ms）');
        return {'ok': false, 'error': 'HTTP ${res.statusCode}'};
      }
      Log.i('plugin',
          '$pluginId 请求成功 $target ${res.bodyBytes.length}B（${sw.elapsedMilliseconds}ms）');
      return {
        'ok': true,
        'text': utf8.decode(res.bodyBytes),
      };
    } catch (e) {
      sw.stop();
      // 异常文本里常常带着完整请求 URL，而 URL 的 query 可能含密钥
      // （插件自己拼的接口地址不受我们控制）。回给插件的错误只保留主机名，
      // 真正的诊断信息进日志——日志那边还有一道统一脱敏兜底。
      Log.w('plugin',
          '$pluginId 请求失败 $target（${sw.elapsedMilliseconds}ms）: $e');
      return {'ok': false, 'error': '请求失败：${uri.host}'};
    }
  }

  /// 系统文件选择对话框。
  Future<Map<String, Object?>> _pickFile(Map<String, Object?> args) async {
    final title = args['title'] as String? ?? '选择文件';
    final ext = (args['ext'] as List?)?.cast<String>() ?? const [];
    try {
      final path = await NativeBridge.pickFile(title: title, ext: ext);
      if (path == null || path.isEmpty) {
        return {'ok': false, 'cancelled': true};
      }
      return {'ok': true, 'path': path};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// 处理 SDK 注册消息。
  Future<Object?> _handleSdk(String method, Map<String, Object?> args) async {
    switch (method) {
      case '__sdk.node.register':
        final type = args['type'] as String?;
        final render = args['render'];
        if (type != null && render != null) {
          sdk.registerNode(type, render);
        }
        return true;

      case '__sdk.capability.register':
        final name = args['name'] as String?;
        final handler = args['handler'];
        if (name != null && handler is Map) {
          sdk.registerCapability(name, handler.cast<String, Object?>());
        }
        return true;

      case '__sdk.widget.register':
        final template = (args['template'] as Map?)?.cast<String, Object?>();
        if (template != null) {
          sdk.registerWidget(template);
        }
        return true;

      case '__sdk.lifecycle.on':
        final event = args['event'] as String?;
        final handler = args['handler'];
        if (event != null && handler != null) {
          sdk.onLifecycle(event, handler);
        }
        return true;

      default:
        return {'ok': false, 'error': 'unknown SDK method: $method'};
    }
  }

  Future<Map<String, Object?>> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return {'ok': false, 'error': '只允许 http/https'};
    }
    try {
      await launchUrl(uri);
      // 插件把用户支出到浏览器是件"看得见的大事"，出问题时要能对上时间点
      Log.i('plugin', '$pluginId 打开外部链接 ${uri.host}${uri.path}');
      return {'ok': true};
    } catch (e) {
      Log.w('plugin', '$pluginId 打开外部链接失败 ${uri.host}: $e');
      return {'ok': false, 'error': '$e'};
    }
  }
}
