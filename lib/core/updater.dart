/// 应用自身的更新系统：查版本、比版本、下载新安装包。
///
/// 与 marketplace.dart 同一个分工原则：这里只有数据和文件，没有界面。
/// 安装动作（保存退出 → 拉起 Inno 静默安装器）由 UI 层编排，因为它需要
/// store 和 exit，那些不归这一层管。
///
/// 更新源有两个，按序尝试（auto 语义）：
///   1. Unisphere：GET /api/v1/app/latest（协议见 DEVELOPMENT.md 10.4）
///   2. GitHub Releases：tag + 可预测资产名，网络不稳时的兜底
/// 一个源"明确说没有更新"不算失败——auto 模式下仍会问下一个源，
/// 全都连不上才算检查失败。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_version.dart' show appUserAgent;
import 'logger.dart';
import 'marketplace.dart' show kMarketBaseUrl, resolveDownloadUrl;

/// 比较两个四段版本号（`A.B.C.D`），返回 -1/0/1。
///
/// 规则：按点分段、逐段按**数值**比（字典序会把 10 排在 9 前面），
/// 位数不同缺位补 0，解析不了的段当 0。全垃圾对全垃圾等于 0——
/// 宁可判"相同"（不推更新），不可误判"更新"。
int compareVersion(String a, String b) {
  List<int> parse(String v) => [
        for (final seg in v.trim().split('.'))
          int.tryParse(seg.trim()) ?? 0
      ];
  final pa = parse(a), pb = parse(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// 一次可用的更新。
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    required this.source,
    this.notes = '',
    this.sha256,
  });

  /// 新版本号，形如 `0.1.2.156`
  final String version;

  /// 新版便携安装包（Inno 自解压 exe）的下载地址
  final String downloadUrl;

  /// 来自哪个源：unisphere / github（日志与 UI 展示用）
  final String source;

  /// 更新日志（Markdown，可空串）
  final String notes;

  /// 服务器给的 SHA-256。v1 只记录不校验（crypto 不在依赖里），
  /// 完整性靠 Inno 解压 + 装完的版本号自证。
  final String? sha256;
}

/// 检查/下载过程中的可预期错误，带一句能直接显示的话。
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 更新源：能回答"最新版是什么"。
///
/// 返回 null 表示"这个源没有可用更新"（没部署、404、数据不完整），
/// **不是**错误——auto 降级语义靠这个区分。
abstract class UpdateSource {
  String get name;
  Future<AppUpdate?> latest();
}

/// Unisphere：与插件市场同一个部署根。
class UnisphereUpdateSource implements UpdateSource {
  UnisphereUpdateSource({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? kMarketBaseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  @override
  String get name => 'unisphere';

  @override
  Future<AppUpdate?> latest() async {
    final uri = Uri.tryParse('$baseUrl/api/v1/app/latest');
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    final http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'User-Agent': appUserAgent}).timeout(_timeout);
    } catch (e) {
      throw UpdateException('连不上更新服务器');
    }
    // 没部署这个端点（或版本还没登记）= 没有更新，交给 auto 问下一个源
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! Map) return null;
      final m = j.cast<String, Object?>();
      final version = m['version'] as String?;
      final rawUrl = m['downloadUrl'] as String?;
      if (version == null || version.trim().isEmpty) return null;
      // 下载地址过一遍归一化：Unisphere 有过 http 配 443 的前科，
      // 和市场共用同一个修正（resolveDownloadUrl）。
      final url = resolveDownloadUrl(baseUrl, rawUrl ?? '');
      if (url == null) return null;
      return AppUpdate(
        version: version.trim(),
        downloadUrl: url.toString(),
        source: name,
        notes: m['notes'] as String? ?? '',
        sha256: m['sha256'] as String?,
      );
    } catch (e) {
      // 坏数据当没有更新，不让一条坏记录炸掉整个检查
      Log.w('update', 'Unisphere 更新信息解析失败: $e');
      return null;
    }
  }
}

/// GitHub Releases：tag（v0.1.2.156）+ 可预测资产名。
///
/// 国内直连时通时不通，只做兜底；查的是 latest release。
class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource({this.repo = 'MacroSTAR-Org/Vectra', http.Client? client})
      : _client = client ?? http.Client();

  final String repo;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  @override
  String get name => 'github';

  @override
  Future<AppUpdate?> latest() async {
    final uri =
        Uri.tryParse('https://api.github.com/repos/$repo/releases/latest');
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    final http.Response res;
    try {
      res = await _client.get(uri, headers: {
        'User-Agent': appUserAgent,
        // GitHub API 的版本协商头，带上稳妥
        'accept': 'application/vnd.github+json',
      }).timeout(_timeout);
    } catch (e) {
      Log.w('update', 'GitHub 请求异常: $e');
      throw UpdateException('连不上 GitHub');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! Map) return null;
      final m = j.cast<String, Object?>();
      // tag 形如 v0.1.2.156，也可能没有 v 前缀
      final tag = (m['tag_name'] as String? ?? '').trim();
      final version = tag.startsWith('v') || tag.startsWith('V')
          ? tag.substring(1)
          : tag;
      // 解析不出版本号的 tag（nightly 之类）不算可用更新
      if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) return null;
      final assets = m['assets'];
      if (assets is! List) return null;
      final assetName = 'Vectra-$version-便携版.exe';
      for (final a in assets) {
        if (a is! Map) continue;
        if (a['name'] == assetName) {
          final url = a['browser_download_url'] as String?;
          if (url != null && url.isNotEmpty) {
            return AppUpdate(
              version: version,
              downloadUrl: url,
              source: name,
              notes: a['body'] as String? ?? m['body'] as String? ?? '',
            );
          }
        }
      }
      return null;
    } catch (e) {
      Log.w('update', 'GitHub 更新信息解析失败: $e');
      return null;
    }
  }
}

/// 按序问源：第一个"版本高于当前"的结果胜出。
///
/// - 某源抛异常（网络不通）→ 记下来继续问下一个
/// - 某源返回 null 或版本不高于当前 → 继续问下一个（auto 语义）
/// - 全部抛异常 → 抛 UpdateException（调用方决定静默还是提示）
class UpdateChecker {
  UpdateChecker({required this.currentVersion, required this.sources});

  final String currentVersion;
  final List<UpdateSource> sources;

  Future<AppUpdate?> check() async {
    var reachable = false;
    Object? lastError;
    for (final src in sources) {
      final AppUpdate? u;
      try {
        u = await src.latest();
      } catch (e) {
        lastError = e;
        Log.d('update', '源 ${src.name} 不可用: $e');
        continue;
      }
      reachable = true;
      if (u == null) continue;
      if (compareVersion(u.version, currentVersion) > 0) {
        Log.i('update', '发现新版 ${u.version}（来自 ${src.name}）');
        return u;
      }
      // 源说的版本不比当前新——记下，继续问下一个源
      Log.d('update', '源 ${src.name} 报告 ${u.version}，不高于当前 $currentVersion');
    }
    if (!reachable) {
      throw UpdateException('更新检查失败：${lastError ?? "所有源都不可用"}');
    }
    return null;
  }
}

/// 把新版安装包下载到 [dir]（`userdata\update\`），先写 `.part` 再转正。
class UpdateDownloader {
  UpdateDownloader(this.dir, {http.Client? client})
      : _client = client ?? http.Client();

  final String dir;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  /// 返回下载好的安装包绝对路径。
  Future<String> download(
    AppUpdate u, {
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.tryParse(u.downloadUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw UpdateException('下载地址不合法');
    }
    // 文件名取 URL 末段；末段不像文件名就按版本号造一个
    var name = Uri.decodeFull(uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : '');
    if (!name.toLowerCase().endsWith('.exe')) {
      name = 'Vectra-${u.version}.exe';
    }
    await Directory(dir).create(recursive: true);
    final finalPath = p.join(dir, name);
    final partPath = '$finalPath.part';
    final partFile = File(partPath);

    final sw = Stopwatch()..start();
    try {
      final req = http.Request('GET', uri)..headers['User-Agent'] = appUserAgent;
      final res = await _client.send(req).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw UpdateException('下载失败：HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      var received = 0;
      final sink = partFile.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // .part 转正：这一步之前中断，磁盘上只有半截 .part，不会污染正式文件
      await partFile.rename(finalPath);
      sw.stop();
      Log.i('update',
          '新版安装包下载完成 ${u.version} ${received}B（${sw.elapsedMilliseconds}ms）');
      return finalPath;
    } catch (e) {
      sw.stop();
      // 失败不留半截文件：next 次下载从零开始（v1 无断点续传）
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      if (e is UpdateException) rethrow;
      Log.w('update', '下载失败 ${uri.host}（${sw.elapsedMilliseconds}ms）: $e');
      throw UpdateException('下载失败，请重试');
    }
  }
}

// ---------------- 状态机（UI 消费） ----------------

/// 更新流程的阶段。failed 之后仍可重试（检查或下载）。
enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  failed,
}

class AppUpdateSnapshot {
  const AppUpdateSnapshot({
    required this.phase,
    this.update,
    this.progress = -1,
    this.installerPath,
    this.error,
  });

  final AppUpdatePhase phase;
  final AppUpdate? update;

  /// 下载进度 0~1；-1 表示总大小未知
  final double progress;

  /// 下载完成后的安装包本地路径（phase == ready 时有效）
  final String? installerPath;

  /// phase == failed 时给用户看的话
  final String? error;
}

/// 全局更新状态。检查/下载由下面的函数驱动，面板和后台静默检查共用。
final ValueNotifier<AppUpdateSnapshot> appUpdateState =
    ValueNotifier<AppUpdateSnapshot>(
        const AppUpdateSnapshot(phase: AppUpdatePhase.idle));

void resetUpdateStateForTest() => appUpdateState.value =
    const AppUpdateSnapshot(phase: AppUpdatePhase.idle);

/// 跑一次检查并驱动状态机。失败不抛异常——错误进 snapshot，
/// 由 UI 决定展示；静默检查则直接无视。
Future<AppUpdate?> runUpdateCheck({
  required String currentVersion,
  required List<UpdateSource> sources,
}) async {
  appUpdateState.value = AppUpdateSnapshot(phase: AppUpdatePhase.checking);
  try {
    final u = await UpdateChecker(
            currentVersion: currentVersion, sources: sources)
        .check();
    appUpdateState.value = u == null
        ? const AppUpdateSnapshot(phase: AppUpdatePhase.upToDate)
        : AppUpdateSnapshot(phase: AppUpdatePhase.available, update: u);
    return u;
  } catch (e) {
    Log.w('update', '检查失败: $e');
    appUpdateState.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.failed,
        // 保留上一个可用更新（若有），失败后还能继续下载
        update: appUpdateState.value.update,
        error: e is UpdateException ? e.message : '更新检查失败');
    return null;
  }
}

/// 下载当前 available 的更新，完成后状态变 ready。
///
/// 下载失败抛 UpdateException 且状态变 failed——更新对象保留在
/// snapshot 里，UI 允许重试。
Future<String> downloadUpdate({
  required String dir,
  http.Client? client,
}) async {
  final u = appUpdateState.value.update;
  if (u == null) throw UpdateException('还没有可下载的更新');
  appUpdateState.value = AppUpdateSnapshot(
      phase: AppUpdatePhase.downloading, update: u, progress: -1);
  try {
    final path = await UpdateDownloader(dir, client: client).download(u,
        onProgress: (r, t) {
      appUpdateState.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.downloading,
          update: u,
          progress: t > 0 ? r / t : -1);
    });
    appUpdateState.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.ready, update: u, installerPath: path);
    return path;
  } catch (e) {
    appUpdateState.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.failed,
        update: u,
        error: e is UpdateException ? e.message : '下载失败');
    rethrow;
  }
}

/// 按设置构造检查用的源列表。
///
/// updateSource：auto（Unisphere → GitHub 依次降级）/ unisphere / github。
/// [marketBaseUrl] 与市场共用同一个自定义地址口子。
List<UpdateSource> buildUpdateSources({
  required String updateSource,
  required String marketBaseUrl,
  http.Client? client,
}) {
  final uni = UnisphereUpdateSource(
      baseUrl: marketBaseUrl.trim().isEmpty ? null : marketBaseUrl.trim(),
      client: client);
  final gh = GitHubUpdateSource(client: client);
  switch (updateSource) {
    case 'unisphere':
      return [uni];
    case 'github':
      return [gh];
    default:
      return [uni, gh];
  }
}
