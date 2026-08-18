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

/// 市场服务器地址（统曜 Unisphere 部署根）。
///
/// 指向 Unisphere 的部署域名即可：客户端调用的 `/api/v1/catalog`、
/// `/api/v1/plugins/{id}` 由 Unisphere 提供，**默认只返回 Vectra 分区**
/// （Vectra 与 Lunar X 是两个不同产品，插件不通用）。
/// 单独拎出来是为了以后能在设置里改（指向自建/测试服务器）。
const String kMarketBaseUrl = 'https://unisphere.macrostar.top';

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

/// 把服务器广播的下载地址归一化到"我们正在对话的那个源"。
///
/// 起因是实测：Unisphere 返回的 downloadUrl 是
/// `http://unisphere.macrostar.top:443/api/vectra/plugins/clock-lite/release`
/// —— http 配 443 端口，连不上（反代没把 X-Forwarded-Proto 传给应用，
/// 应用于是拿 http 拼上了 https 的端口）。服务端该修，但客户端不能因为
/// 服务器写错一个字段就装不了插件。
///
/// 规则：
///   - 相对地址 → 拼到 base 上（完整版接口给的资源路径本来就是相对的）
///   - 同主机 → 一律改用 base 的协议和端口。我们刚刚就是从这个源把目录拉下来的，
///     它一定是通的；服务器自述的协议反而不可信。
///   - 别的主机 → 原样保留。插件包放 CDN / 对象存储是合法做法，不该被改写。
Uri? resolveDownloadUrl(String baseUrl, String advertised) {
  final base = Uri.tryParse(baseUrl);
  final raw = Uri.tryParse(advertised.trim());
  if (base == null || raw == null || advertised.trim().isEmpty) return null;

  final abs = raw.hasScheme ? raw : base.resolveUri(raw);
  if (abs.scheme != 'http' && abs.scheme != 'https') return null;

  if (abs.host == base.host) {
    return abs.replace(
      scheme: base.scheme,
      port: base.hasPort ? base.port : null,
    );
  }
  return abs;
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

  /// 等首个响应的上限。
  ///
  /// 给到 30 秒是实测定的：Unisphere 冷启动时第一个请求要二十几秒才回，
  /// 15 秒会把"服务器正在醒"误判成"连不上"。这只管到响应头，下载正文的时间
  /// 不受它限制。
  static const Duration _timeout = Duration(seconds: 30);

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
        // Unisphere 出错时会给一句人话（v1 是裸的 {error}，其余是
        // {ok:false,error}）。有就用它——服务器比客户端清楚发生了什么。
        throw MarketException(
            _serverError(res.bodyBytes) ?? '服务器返回 HTTP ${res.statusCode}');
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

  /// 从错误响应体里把服务器写的那句话捞出来。捞不到返回 null。
  static String? _serverError(List<int> body) {
    try {
      final j = jsonDecode(utf8.decode(body));
      if (j is Map) {
        final e = j['error'];
        if (e is String && e.trim().isNotEmpty) return e.trim();
      }
    } catch (_) {
      // 错误响应不是 JSON 很正常（网关的 HTML 错误页之类），当没有就是了
    }
    return null;
  }

  /// 下载插件包。[onProgress] 回报"已收到/总字节"，总字节未知时给 0。
  ///
  /// 用流式请求而不是 http.get：进度条要的是过程，get 只有结果。
  Future<Uint8List> download(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    // 服务器给的地址先归一化：它可能是相对的，也可能协议/端口自相矛盾
    // （实测就遇到 http 配 443），见 resolveDownloadUrl。
    final uri = resolveDownloadUrl(baseUrl, url);
    if (uri == null) {
      throw MarketException('下载地址不合法');
    }
    if (uri.toString() != url.trim()) {
      Log.d('market', '下载地址已归一化：$url -> $uri');
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

// ---------------- 假市场 ----------------

/// `--market-mock` 是否开着。由 main() 按命令行参数置位。
///
/// 存在的理由：Unisphere 还没部署，而列表页、搜索、安装进度、装完出现在
/// 组件库这一整条链路必须能验收。开着它时市场不联网，凭空造几个插件，
/// 其中一个能真的装到 userdata\plugins\ 里跑起来。
bool marketMockEnabled = false;

/// 假市场。只在 [marketMockEnabled] 时顶替 [MarketClient]。
class MockMarketClient extends MarketClient {
  MockMarketClient() : super(baseUrl: 'mock://unisphere');

  static const _delay = Duration(milliseconds: 350);

  /// 这几条的字段结构和 Unisphere 的 /api/v1/catalog 完全一致
  static final List<MarketPlugin> _plugins = [
    const MarketPlugin(
      id: 'hello-market',
      name: '打招呼',
      version: '1.0.0',
      downloadUrl: 'mock://plugins/hello-market',
      description: '装上就能跑的示例插件，用来验证整条安装链路',
      author: 'MacroSTAR',
      icon: '👋',
      sizes: ['2x2', '3x2'],
      updatedAt: '2026-08-18',
    ),
    const MarketPlugin(
      id: 'clock-lite',
      name: '轻时钟',
      version: '1.0.0',
      downloadUrl: 'mock://plugins/clock-lite',
      description: '极简数字时钟，只显示时间和日期',
      author: 'MacroSTAR',
      icon: '🕐',
      sizes: ['2x2', '3x2'],
      updatedAt: '2026-08-17',
    ),
    const MarketPlugin(
      id: 'clock',
      name: '时钟',
      version: '9.9.9',
      downloadUrl: 'mock://plugins/clock',
      description: '内置时钟的"新版本"，用来验证「更新」状态',
      author: 'MacroSTAR',
      icon: '⏰',
      sizes: ['2x2', '3x2', '4x2'],
      updatedAt: '2026-08-18',
    ),
    const MarketPlugin(
      id: 'weather',
      name: '天气',
      version: '2.0.0',
      downloadUrl: 'mock://plugins/weather',
      description: '内置天气，版本一致，用来验证「已安装」状态',
      author: 'MacroSTAR',
      icon: '☀',
      sizes: ['3x2', '3x3'],
      updatedAt: '2026-08-16',
    ),
  ];

  @override
  Future<List<MarketPlugin>> catalog() async {
    await Future<void>.delayed(_delay); // 装一下网络延迟，好看清加载态
    Log.i('market', '假市场：返回 ${_plugins.length} 个插件');
    return List.of(_plugins);
  }

  @override
  Future<MarketPlugin> detail(String id) async {
    await Future<void>.delayed(_delay);
    final one = _plugins.where((p) => p.id == id).toList();
    if (one.isEmpty) throw MarketException('假市场里没有这个插件');
    final p = one.first;
    return MarketPlugin(
      id: p.id,
      name: p.name,
      version: p.version,
      downloadUrl: p.downloadUrl,
      description: p.description,
      author: p.author,
      icon: p.icon,
      sizes: p.sizes,
      updatedAt: p.updatedAt,
      readme: '# ${p.name}\n\n${p.description}\n\n'
          '这是假市场造出来的说明文字，用于验证详情页。\n\n'
          '- 支持尺寸：${p.sizes.join(" / ")}\n'
          '- 作者：${p.author}\n',
    );
  }

  /// 现造一个能装的插件包，结构和 Unisphere 给的一致（zip 里套一层 id 目录）
  @override
  Future<Uint8List> download(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final id = url.split('/').last;
    final one = _plugins.where((p) => p.id == id).toList();
    if (one.isEmpty) throw MarketException('假市场里没有这个插件');
    final p = one.first;

    final bytes = _buildZip(p);
    // 分几次回报，进度条才有得动
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      onProgress?.call(bytes.length * i ~/ steps, bytes.length);
    }
    Log.i('market', '假市场：${p.id} 下载完成 ${bytes.length}B');
    return bytes;
  }

  static Uint8List _buildZip(MarketPlugin p) {
    final manifest = jsonEncode({
      'id': p.id,
      'name': p.name,
      'version': p.version,
      'entry': 'index.js',
      'description': p.description,
      'author': p.author,
      'icon': p.icon,
      'sizes': p.sizes,
      'defaultSize': p.sizes.first,
    });
    final js = '''
// 假市场装出来的插件：画个名字和版本，证明它真的跑起来了
lw.register({
  mount: function (ctx) {
    ctx.render({
      t: 'col', main: 'center', cross: 'center', gap: 6,
      children: [
        { t: 'text', v: ${jsonEncode(p.icon)}, size: 26 },
        { t: 'text', v: ${jsonEncode(p.name)}, size: 15, weight: 600 },
        { t: 'text', v: 'v${p.version}', size: 11, opacity: 0.5 }
      ]
    });
  }
});
''';
    final archive = Archive();
    void add(String name, String content) {
      final b = utf8.encode(content);
      archive.addFile(ArchiveFile('${p.id}/$name', b.length, b));
    }

    add('manifest.json', manifest);
    add('index.js', js);
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

/// `--market-install=<id>`：市场一打开就自动装这个插件，装完留在列表页。
///
/// 为什么需要它：给 Flutter 视图投合成点击实测不生效（`--test-openpanel`
/// 也是为同一件事存在的），而"下载→校验→解压→重扫"这条链路必须能自动验证，
/// 不能每次都靠人手点。走的是和按钮完全相同的代码路径。
String? marketAutoInstallId;

/// 按当前设置挑一个市场客户端。
///
/// 优先级：`--market-mock` > 设置里填的地址 > 内置默认地址。
MarketClient makeMarketClient(String configuredBaseUrl) {
  if (marketMockEnabled) return MockMarketClient();
  final url = configuredBaseUrl.trim();
  return MarketClient(baseUrl: url.isEmpty ? kMarketBaseUrl : url);
}