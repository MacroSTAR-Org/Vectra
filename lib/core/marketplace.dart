/// 插件市场的数据层：拉目录、比版本、下载、装、卸。
///
/// 这里**只有数据和文件**，没有任何界面。分开的理由很实际：市场的风险全在
/// 这一层——从网上下一个 zip 解到用户的插件目录里，路径写错一个字符就能覆盖
/// 到目录外面去。界面能靠肉眼验收，这些不能，所以它们必须能单独测。
///
/// 安全上的三条底线（每条都有对应的测试）：
///   1. **不信任 zip 里的路径**。条目名带 `..` 或绝对路径一律拒绝整个包，
///      不是跳过那一条——一个包里混着这种东西，本身就说明它不该被信任。
///   2. **不信任服务器给的身份**。解出来的 manifest 里 id 必须和请求的一致，
///      否则装 A 插件可能覆盖掉 B 插件的目录。
///   3. **装到一半失败不能留残骸**。先解到临时目录，全部校验通过才替换正式
///      目录；中途任何一步失败，原来那份插件原封不动。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../plugin/manifest.dart';
import 'app_version.dart';
import 'logger.dart';

/// 市场服务器地址。
///
/// 单独拎出来是为了以后能在设置里改（指向自建的测试服务器），
/// 现在先当常量用。
const String kMarketBaseUrl = 'https://market.vectra.macrostar.dev';

/// 市场里的一个插件条目。
///
/// 字段比 manifest 多几个"只有市场才知道"的：下载地址、更新时间、README。
/// [readme] 只有详情接口才会给，列表接口不带（catalog 要小，几十上百条呢）。
class MarketPlugin {
  const MarketPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.downloadUrl,
    this.description = '',
    this.author = '',
    this.icon = '▢',
    this.sizes = const ['2x2'],
    this.sha256,
    this.readme,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String version;
  final String downloadUrl;
  final String description;
  final String author;
  final String icon;
  final List<String> sizes;

  /// 服务器给的校验和。目前只是**记下来**，没有拿它做校验——校验和需要
  /// 一个 SHA-256 实现（crypto 包不在依赖里），而当前防的是"下载残缺"，
  /// 那个由 install() 里的"解压 + manifest 校验"挡着就够了。
  /// 将来要做强校验时，字段已经在这儿了。
  final String? sha256;

  /// 详情接口才有的完整说明（Markdown）
  final String? readme;

  final String? updatedAt;

  /// 解析一条记录；缺必填字段或类型不对返回 null。
  ///
  /// 返回 null 而不是抛异常：一条记录坏掉不该让整个市场打不开，
  /// 由调用方跳过它（见 [parseCatalog]）。
  static MarketPlugin? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, Object?>();

    String? str(String key) {
      final v = m[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final id = str('id');
    final name = str('name');
    final version = str('version');
    final url = str('downloadUrl');
    if (id == null || name == null || version == null || url == null) {
      return null;
    }
    // id 的规矩和本地插件完全一致：它最终会变成磁盘上的目录名
    if (!isSafePluginId(id)) return null;

    final sizes = <String>[
      for (final s in (m['sizes'] as List? ?? const []))
        if (s is String && s.trim().isNotEmpty) s.trim()
    ];

    return MarketPlugin(
      id: id,
      name: name,
      version: version,
      downloadUrl: url,
      description: str('description') ?? '',
      author: str('author') ?? '',
      icon: str('icon') ?? '▢',
      sizes: sizes.isEmpty ? const ['2x2'] : sizes,
      sha256: str('sha256'),
      readme: str('readme'),
      updatedAt: str('updatedAt'),
    );
  }
}

/// 目录响应 -> 插件列表。坏记录直接跳过，能显示几条是几条。
List<MarketPlugin> parseCatalog(Object? json) {
  final root = json is Map ? json.cast<String, Object?>() : const {};
  final list = root['plugins'];
  if (list is! List) return const [];
  final out = <MarketPlugin>[];
  var skipped = 0;
  for (final item in list) {
    final one = MarketPlugin.tryParse(item);
    if (one == null) {
      skipped++;
      continue;
    }
    out.add(one);
  }
  if (skipped > 0) {
    Log.w('market', '目录里有 $skipped 条记录不合法，已跳过');
  }
  return out;
}

/// 插件 id 是否能安全地当目录名用。
///
/// 规则照抄 manifest 那边：只允许小写字母、数字、`-`、`_`。这一条挡的是
/// `../../windows/system32` 这类东西——id 直接参与拼路径。
bool isSafePluginId(String id) =>
    RegExp(r'^[a-z0-9][a-z0-9\-_]{0,63}$').hasMatch(id);

/// 一个市场插件相对本地的状态
enum InstallState {
  /// 本地没有
  notInstalled,

  /// 本地有，且版本号一致
  installed,

  /// 本地有，但版本号和市场的对不上
  updatable,
}

/// 拿市场条目和本地已装的清单比一比。
///
/// 版本比较用字符串相等而不是语义化版本：插件的 version 是插件作者随手写的
/// 字符串，"2.0" 和 "2.0.0" 谁大谁小没有可靠答案。只要不一样就提示可更新，
/// 由用户决定装不装——本地比市场新（自己改过）也照样提示，这是对的，
/// 因为那种情况下"装回市场版"确实是用户可能想做的事。
InstallState installStateOf(MarketPlugin market, PluginManifest? local) {
  if (local == null) return InstallState.notInstalled;
  return local.version == market.version
      ? InstallState.installed
      : InstallState.updatable;
}

/// 下载/安装过程里的可预期错误。带一句能直接显示给用户的话。
class MarketException implements Exception {
  MarketException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 和市场服务器打交道的那一半。
///
/// [client] 可注入，测试用 MockClient 顶上，不碰真网络。
class MarketClient {
  MarketClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? kMarketBaseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {'User-Agent': appUserAgent};

  /// 拉插件目录
  Future<List<MarketPlugin>> catalog() async {
    final body = await _getJson('$baseUrl/api/v1/catalog');
    return parseCatalog(body);
  }

  /// 拉某个插件的详情（含 README）
  Future<MarketPlugin> detail(String id) async {
    if (!isSafePluginId(id)) throw MarketException('插件标识不合法');
    final body = await _getJson('$baseUrl/api/v1/plugins/$id');
    final one = MarketPlugin.tryParse(body);
    if (one == null) throw MarketException('服务器返回的插件信息不完整');
    return one;
  }

  Future<Object?> _getJson(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw MarketException('市场地址不合法');
    }
    final sw = Stopwatch()..start();
    try {
      final res = await _client.get(uri, headers: _headers).timeout(_timeout);
      sw.stop();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        Log.w('market',
            '请求返回 ${res.statusCode} ${uri.path}（${sw.elapsedMilliseconds}ms）');
        throw MarketException('服务器返回 HTTP ${res.statusCode}');
      }
      Log.i('market',
          '请求成功 ${uri.path} ${res.bodyBytes.length}B（${sw.elapsedMilliseconds}ms）');
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on MarketException {
      rethrow;
    } catch (e) {
      sw.stop();
      Log.w('market', '请求失败 ${uri.path}（${sw.elapsedMilliseconds}ms）: $e');
      throw MarketException('连不上市场服务器');
    }
  }

  /// 下载插件包。[onProgress] 回报"已收到/总字节"，总字节未知时给 0。
  ///
  /// 用流式请求而不是 http.get：进度条要的是过程，get 只有结果。
  Future<Uint8List> download(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw MarketException('下载地址不合法');
    }
    final sw = Stopwatch()..start();
    try {
      final req = http.Request('GET', uri)..headers.addAll(_headers);
      final res = await _client.send(req).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        Log.w('market', '下载返回 ${res.statusCode} ${uri.path}');
        throw MarketException('下载失败：HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final bytes = <int>[];
      await for (final chunk in res.stream) {
        bytes.addAll(chunk);
        onProgress?.call(bytes.length, total);
      }
      sw.stop();
      Log.i('market',
          '下载完成 ${uri.path} ${bytes.length}B（${sw.elapsedMilliseconds}ms）');
      return Uint8List.fromList(bytes);
    } on MarketException {
      rethrow;
    } catch (e) {
      sw.stop();
      Log.w('market', '下载失败 ${uri.path}（${sw.elapsedMilliseconds}ms）: $e');
      throw MarketException('下载失败，请重试');
    }
  }
}

/// 把插件包落到磁盘上的那一半。
///
/// [pluginsDir] 就是 AppPaths.pluginsDir，测试里换成临时目录。
class PluginInstaller {
  PluginInstaller(this.pluginsDir);

  final String pluginsDir;

  /// 装一个插件包。
  ///
  /// 校验顺序是"先看清楚，再动手"：所有检查都在临时目录里做完，
  /// 确认这是一个名副其实的插件包之后，才去碰正式目录。
  ///
  /// [expectId] 必填：装的是哪个插件由**我们**说了算，不能让包自己声称。
  /// [expectVersion] 给了就校验，对不上说明服务器目录和包不同步。
  Future<void> install(
    Uint8List zipBytes, {
    required String expectId,
    String? expectVersion,
  }) async {
    if (!isSafePluginId(expectId)) {
      throw MarketException('插件标识不合法');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw MarketException('插件包损坏，解压失败');
    }
    if (archive.isEmpty) throw MarketException('插件包是空的');

    // ---- 1. 逐条查路径。带 .. 或绝对路径的包整个拒绝 ----
    final files = <String, List<int>>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('/') ||
          name.contains('..') ||
          p.isAbsolute(name) ||
          RegExp(r'^[a-zA-Z]:').hasMatch(name)) {
        throw MarketException('插件包里有非法路径，已拒绝安装');
      }
      files[name] = entry.content;
    }
    if (files.isEmpty) throw MarketException('插件包里没有文件');

    // ---- 2. manifest 必须在包的根目录 ----
    //
    // 有些打包工具会多套一层目录（zip 里是 hello/manifest.json），
    // 这里也认：只要全部文件都在同一个顶层目录下，就把那层剥掉。
    final normalized = _stripSingleRoot(files);
    final manifestRaw = normalized['manifest.json'];
    if (manifestRaw == null) {
      throw MarketException('插件包里没有 manifest.json');
    }

    final PluginManifest manifest;
    try {
      manifest = PluginManifest.parse(
          (jsonDecode(utf8.decode(manifestRaw)) as Map).cast<String, Object?>(),
          source: 'user');
    } catch (e) {
      throw MarketException('manifest.json 不合法：$e');
    }

    // ---- 3. 身份要对得上 ----
    if (manifest.id != expectId) {
      throw MarketException('插件包里的 id 是「${manifest.id}」，与预期不符');
    }
    if (expectVersion != null && manifest.version != expectVersion) {
      throw MarketException(
          '插件包版本是 ${manifest.version}，与市场登记的 $expectVersion 不符');
    }
    // 入口文件得真的在包里，否则装完是个跑不起来的空壳
    if (!normalized.containsKey(manifest.entry.replaceAll('\\', '/'))) {
      throw MarketException('插件包里找不到入口文件 ${manifest.entry}');
    }

    // ---- 4. 先写临时目录，再整体替换 ----
    final target = Directory(p.join(pluginsDir, expectId));
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final staging = Directory(p.join(pluginsDir, '.staging-$expectId-$stamp'));
    final backup = Directory(p.join(pluginsDir, '.old-$expectId-$stamp'));

    try {
      await staging.create(recursive: true);
      for (final e in normalized.entries) {
        final dest = File(p.join(staging.path, e.key));
        // 再兜一道：拼完的绝对路径必须还在 staging 里面
        if (!p.isWithin(staging.path, dest.path)) {
          throw MarketException('插件包里有非法路径，已拒绝安装');
        }
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(e.value);
      }

      // 旧版本先挪走而不是直接删：替换过程中出岔子还能放回去
      final hadOld = await target.exists();
      if (hadOld) await target.rename(backup.path);
      try {
        await staging.rename(target.path);
      } catch (e) {
        if (hadOld) await backup.rename(target.path); // 放回去
        rethrow;
      }
      if (hadOld) await backup.delete(recursive: true);

      Log.i('market', '已安装 $expectId ${manifest.version}');
    } catch (e) {
      // 失败要保证"什么都没发生"：清掉临时目录，原来那份还在
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      try {
        if (await backup.exists() && !await target.exists()) {
          await backup.rename(target.path);
        } else if (await backup.exists()) {
          await backup.delete(recursive: true);
        }
      } catch (_) {}
      if (e is MarketException) rethrow;
      Log.w('market', '安装 $expectId 失败: $e');
      throw MarketException('写入插件目录失败');
    }
  }

  /// 卸载：删掉插件目录。内置插件在 assets 里，删不掉也不该删。
  Future<void> uninstall(String id) async {
    if (!isSafePluginId(id)) throw MarketException('插件标识不合法');
    final dir = Directory(p.join(pluginsDir, id));
    // 再确认一次真的在插件目录底下，别让 id 里的花样把别处删了
    if (!p.isWithin(pluginsDir, dir.path)) {
      throw MarketException('插件标识不合法');
    }
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
      Log.i('market', '已卸载 $id');
    } catch (e) {
      Log.w('market', '卸载 $id 失败: $e');
      throw MarketException('删除插件目录失败，可能有文件正被占用');
    }
  }

  /// 全部文件都在同一个顶层目录下时，把那层剥掉。
  ///
  /// zip 打包时习惯连目录一起打（`hello/manifest.json`），而我们要的是
  /// 目录里的内容。只有"确实只有一个顶层目录"时才剥，避免误伤。
  static Map<String, List<int>> _stripSingleRoot(Map<String, List<int>> files) {
    if (files.containsKey('manifest.json')) return files;
    final roots = <String>{};
    for (final name in files.keys) {
      final i = name.indexOf('/');
      if (i <= 0) return files; // 根目录下有散文件，不是"单一顶层目录"
      roots.add(name.substring(0, i));
    }
    if (roots.length != 1) return files;
    final prefix = '${roots.first}/';
    return {
      for (final e in files.entries) e.key.substring(prefix.length): e.value,
    };
  }
}
