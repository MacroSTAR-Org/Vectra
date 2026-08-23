/// 应用更新系统的行为约定。
///
/// 更新的风险和插件市场同源：版本比较错一个字符就会给所有用户推"假更新"，
/// 下载写错一个路径就能覆盖到程序目录外面。所以比较函数、双源解析、
/// 降级顺序、下载落盘每一条都钉在这里。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vectra/core/updater.dart';

void main() {
  // ---------------- 版本比较 ----------------

  group('compareVersion', () {
    test('四段数值逐段比较', () {
      expect(compareVersion('0.1.2.152', '0.1.2.154'), -1);
      expect(compareVersion('0.1.2.154', '0.1.2.152'), 1);
      expect(compareVersion('0.1.2.154', '0.1.2.154'), 0);
      expect(compareVersion('1.0.0.0', '0.9.9.9'), 1);
    });

    test('数值比较，不是字典序', () {
      // 字典序里 '10' < '9'，更新判断会反向
      expect(compareVersion('0.1.10.0', '0.1.9.9'), 1);
      expect(compareVersion('0.1.9.9', '0.1.10.0'), -1);
    });

    test('位数不同缺位补零', () {
      expect(compareVersion('0.1.2', '0.1.2.0'), 0);
      expect(compareVersion('0.1.2', '0.1.2.1'), -1);
      expect(compareVersion('0.2', '0.1.9.9'), 1);
    });

    test('前导零不 影响', () {
      expect(compareVersion('0.01.2.0', '0.1.2.0'), 0);
    });

    test('解析不了的段当 0，两边都是垃圾则相等', () {
      expect(compareVersion('garbage', 'garbage'), 0);
      expect(compareVersion('garbage', '0.0.0.1'), -1);
      expect(compareVersion('0.1.2.3', ''), 1);
    });
  });

  // ---------------- Unisphere 源 ----------------

  group('UnisphereUpdateSource', () {
    test('正常响应解出全部字段', () async {
      final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
        // encoding 必须显式 utf8：http.Response 的 String 构造默认 latin1，
        // 中文 body 会直接抛 "Contains invalid characters"
        (req) async => http.Response.bytes(utf8.encode(jsonEncode({
          'version': '0.1.2.156',
          'downloadUrl': 'https://u.example.com/files/Vectra-0.1.2.156-便携版.exe',
          'notes': '修复了一些问题',
          'sha256': 'abc',
        })), 200),
      ));
      final u = await src.latest();
      expect(u, isNotNull);
      expect(u!.version, '0.1.2.156');
      expect(u.source, 'unisphere');
      expect(u.notes, '修复了一些问题');
      expect(u.sha256, 'abc');
      // resolveDownloadUrl 返回 Uri，中文会被规范成百分号编码——解码后比较
      expect(Uri.decodeFull(u.downloadUrl),
          'https://u.example.com/files/Vectra-0.1.2.156-便携版.exe');
    });

    test('请求的路径是 /api/v1/app/latest', () async {
      String? hit;
      final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
        (req) async {
          hit = req.url.toString();
          return http.Response('{}', 200);
        },
      ));
      await src.latest();
      expect(hit, 'https://u.example.com/api/v1/app/latest');
    });

    test('downloadUrl 与 base 同主机时协议端口跟着 base 走（http/443 坑）', () async {
      final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
        (req) async => http.Response.bytes(utf8.encode(jsonEncode({
          'version': '0.1.2.156',
          'downloadUrl': 'http://u.example.com:443/files/new.exe',
        })), 200),
      ));
      final u = await src.latest();
      expect(u!.downloadUrl, 'https://u.example.com/files/new.exe');
    });

    test('404 / 缺字段 = 没有更新，不算错误', () async {
      for (final body in ['{"error":"not found"}', '{"version":"0.1.2.156"}', '{}']) {
        final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
          (req) async => http.Response(body, 404),
        ));
        expect(await src.latest(), isNull, reason: body);
      }
    });

    test('坏 JSON 当没有更新', () async {
      final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
        (req) async => http.Response('not json', 200),
      ));
      expect(await src.latest(), isNull);
    });

    test('网络异常抛 UpdateException', () async {
      final src = UnisphereUpdateSource(baseUrl: 'https://u.example.com', client: MockClient(
        (req) async => throw const SocketException('offline'),
      ));
      await expectLater(src.latest(), throwsA(isA<UpdateException>()));
    });
  });

  // ---------------- GitHub 源 ----------------

  group('GitHubUpdateSource', () {
    http.Response ghRelease({String tag = 'v0.1.2.156', List<String> assets = const []}) {
      return http.Response.bytes(utf8.encode(jsonEncode({
        'tag_name': tag,
        'body': '更新日志内容',
        'assets': [
          for (final a in assets)
            {'name': a, 'browser_download_url': 'https://github.com/dl/$a'},
        ],
      })), 200);
    }

    test('从 tag 和可预测资产名解出更新', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => ghRelease(assets: ['Vectra-0.1.2.156-便携版.exe', 'source.zip']),
      ));
      final u = await src.latest();
      expect(u, isNotNull);
      expect(u!.version, '0.1.2.156'); // v 前缀剥掉
      expect(u.source, 'github');
      expect(u.notes, '更新日志内容');
      expect(u.downloadUrl, 'https://github.com/dl/Vectra-0.1.2.156-便携版.exe');
    });

    test('请求打向 api.github.com 且带 Accept 头', () async {
      Uri? hit; String? accept;
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async {
          hit = req.url;
          accept = req.headers['accept'];
          return ghRelease(assets: ['Vectra-0.1.2.156-便携版.exe']);
        },
      ));
      await src.latest();
      expect(hit.toString(),
          'https://api.github.com/repos/org/vectra/releases/latest');
      expect(accept, contains('application/vnd.github+json'));
    });

    test('tag 不带 v 前缀也认', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => ghRelease(tag: '0.1.2.156', assets: ['Vectra-0.1.2.156-便携版.exe']),
      ));
      expect((await src.latest())!.version, '0.1.2.156');
    });

    test('资产列表里没有便携包 = 没有更新', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => ghRelease(assets: ['source.zip']),
      ));
      expect(await src.latest(), isNull);
    });

    test('tag 解析不出版本 = 没有更新', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => ghRelease(tag: 'nightly', assets: ['Vectra-x-便携版.exe']),
      ));
      expect(await src.latest(), isNull);
    });

    test('404 = 没有更新', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => http.Response('{"message":"Not Found"}', 404),
      ));
      expect(await src.latest(), isNull);
    });

    test('网络异常抛 UpdateException', () async {
      final src = GitHubUpdateSource(repo: 'org/vectra', client: MockClient(
        (req) async => throw const SocketException('offline'),
      ));
      await expectLater(src.latest(), throwsA(isA<UpdateException>()));
    });
  });

  // ---------------- 检查器（降级顺序） ----------------

  group('UpdateChecker', () {
    test('版本不高于当前 = 没有更新', () async {
      final src = _fixedSource(AppUpdate(
          version: '0.1.2.152', downloadUrl: 'https://x/y.exe', source: 't'));
      final checker = UpdateChecker(currentVersion: '0.1.2.152', sources: [src]);
      expect(await checker.check(), isNull);
    });

    test('版本相同或更旧都过滤', () async {
      final c = UpdateChecker(currentVersion: '0.1.2.154', sources: [
        _fixedSource(AppUpdate(
            version: '0.1.2.150', downloadUrl: 'https://x/y.exe', source: 't')),
      ]);
      expect(await c.check(), isNull);
    });

    test('主源挂了降级备用源', () async {
      final c = UpdateChecker(currentVersion: '0.1.2.152', sources: [
        _throwingSource(),
        _fixedSource(AppUpdate(
            version: '0.1.2.156', downloadUrl: 'https://x/y.exe', source: 'github')),
      ]);
      final u = await c.check();
      expect(u!.source, 'github');
    });

    test('主源明确说没有更新时仍会问备用源（auto 语义）', () async {
      final c = UpdateChecker(currentVersion: '0.1.2.152', sources: [
        _fixedSource(null),
        _fixedSource(AppUpdate(
            version: '0.1.2.156', downloadUrl: 'https://x/y.exe', source: 'github')),
      ]);
      expect((await c.check())!.version, '0.1.2.156');
    });

    test('所有源都失败时抛 UpdateException', () async {
      final c = UpdateChecker(currentVersion: '0.1.2.152', sources: [
        _throwingSource(),
        _throwingSource(),
      ]);
      await expectLater(c.check(), throwsA(isA<UpdateException>()));
    });
  });

  // ---------------- 下载 ----------------

  group('UpdateDownloader', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vectra_update_dl');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    AppUpdate update(String url) => AppUpdate(
        version: '0.1.2.156', downloadUrl: url, source: 'test');

    test('先写 .part 再转正，内容完整，返回最终路径', () async {
      final bytes = Uint8List.fromList(List.filled(1024, 7));
      final dl = UpdateDownloader(tmp.path, client: MockClient(
        (req) async => http.Response.bytes(bytes, 200),
      ));
      final path = await dl.download(update('https://x/Vectra-0.1.2.156.exe'));
      expect(path, contains('Vectra-0.1.2.156.exe'));
      expect(File(path).readAsBytesSync(), bytes);
      expect(File('$path.part').existsSync(), isFalse, reason: '临时文件要清掉');
    });

    test('进度回调收到字节数', () async {
      final bytes = Uint8List.fromList(List.filled(512, 1));
      final seen = <int>[];
      final dl = UpdateDownloader(tmp.path, client: MockClient(
        (req) async => http.Response.bytes(bytes, 200),
      ));
      await dl.download(update('https://x/Vectra-0.1.2.156.exe'),
          onProgress: (r, t) => seen.add(r));
      expect(seen.last, 512);
    });

    test('HTTP 错误抛 UpdateException 且不留 .part', () async {
      final dl = UpdateDownloader(tmp.path, client: MockClient(
        (req) async => http.Response('gone', 404),
      ));
      await expectLater(
          dl.download(update('https://x/Vectra-0.1.2.156.exe')),
          throwsA(isA<UpdateException>()));
      expect(tmp.listSync().whereType<File>(), isEmpty);
    });

    test('重复下载覆盖旧文件', () async {
      final dl = UpdateDownloader(tmp.path, client: MockClient(
        (req) async => http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200),
      ));
      final p1 = await dl.download(update('https://x/Vectra-0.1.2.156.exe'));
      final p2 = await dl.download(update('https://x/Vectra-0.1.2.156.exe'));
      expect(p1, p2);
      expect(File(p2).lengthSync(), 3);
    });
  });

  // ---------------- 状态机 ----------------

  group('appUpdateState 状态机', () {
    setUp(resetUpdateStateForTest);
    tearDown(resetUpdateStateForTest);

    test('检查 → 有新版 → available', () async {
      final u = await runUpdateCheck(
        currentVersion: '0.1.2.152',
        sources: [
          _fixedSource(AppUpdate(
              version: '0.1.2.156', downloadUrl: 'https://x/y.exe', source: 't')),
        ],
      );
      expect(u, isNotNull);
      expect(appUpdateState.value.phase, AppUpdatePhase.available);
      expect(appUpdateState.value.update!.version, '0.1.2.156');
    });

    test('检查 → 没有新版 → upToDate', () async {
      await runUpdateCheck(
        currentVersion: '0.1.2.152',
        sources: [_fixedSource(null)],
      );
      expect(appUpdateState.value.phase, AppUpdatePhase.upToDate);
    });

    test('检查失败 → failed 带错误信息', () async {
      await runUpdateCheck(
        currentVersion: '0.1.2.152',
        sources: [_throwingSource()],
      );
      expect(appUpdateState.value.phase, AppUpdatePhase.failed);
      expect(appUpdateState.value.error, isNotNull);
    });

    test('下载 → ready 带本地路径', () async {
      final tmp = Directory.systemTemp.createTempSync('vectra_update_state');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await runUpdateCheck(
        currentVersion: '0.1.2.152',
        sources: [
          _fixedSource(AppUpdate(
              version: '0.1.2.156', downloadUrl: 'https://x/Vectra-0.1.2.156.exe', source: 't')),
        ],
      );
      final path = await downloadUpdate(dir: tmp.path, client: MockClient(
        (req) async => http.Response.bytes(Uint8List.fromList([9, 9]), 200),
      ));
      expect(appUpdateState.value.phase, AppUpdatePhase.ready);
      expect(appUpdateState.value.installerPath, path);
      expect(File(path).existsSync(), isTrue);
    });

    test('下载失败 → failed，可重新下载', () async {
      final tmp = Directory.systemTemp.createTempSync('vectra_update_state2');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await runUpdateCheck(
        currentVersion: '0.1.2.152',
        sources: [
          _fixedSource(AppUpdate(
              version: '0.1.2.156', downloadUrl: 'https://x/Vectra-0.1.2.156.exe', source: 't')),
        ],
      );
      var fail = true;
      final client = MockClient((req) async => fail
          ? throw const SocketException('offline')
          : http.Response.bytes(Uint8List.fromList([1]), 200));
      await expectLater(
          downloadUpdate(dir: tmp.path, client: client), throwsA(isA<UpdateException>()));
      expect(appUpdateState.value.phase, AppUpdatePhase.failed);
      fail = false;
      // failed 后状态机允许从 available 重新走下载
      expect(await downloadUpdate(dir: tmp.path, client: client), isNotNull);
      expect(appUpdateState.value.phase, AppUpdatePhase.ready);
    });
  });
}

/// 固定返回值/固定抛错的源，测试拼流程用
class _FixedSource implements UpdateSource {
  _FixedSource(this.result, [this.error]);
  final AppUpdate? result;
  final Object? error;
  @override
  String get name => 'fixed';
  @override
  Future<AppUpdate?> latest() async {
    if (error != null) throw error!;
    return result;
  }
}

_FixedSource _fixedSource(AppUpdate? u) => _FixedSource(u);
_FixedSource _throwingSource() => _FixedSource(null, const SocketException('boom'));
