/// 插件市场数据层的行为约定。
///
/// 这一层做的事是"把网上下来的 zip 解到用户的插件目录里"，风险全在这儿：
/// 路径写错一个字符就能覆盖到目录外面，装到一半断掉就可能把好好的插件毁掉。
/// 界面能靠肉眼验收，这些不能，所以每条规则都钉在这里。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:vectra/core/marketplace.dart';
import 'package:vectra/plugin/manifest.dart';

void main() {
  // ---------------- 目录解析 ----------------

  group('目录解析', () {
    Map<String, Object?> entry({
      String id = 'hello',
      String name = '打招呼',
      String version = '1.0.0',
      String url = 'https://m.example.com/hello-1.0.0.zip',
    }) =>
        {
          'id': id,
          'name': name,
          'version': version,
          'downloadUrl': url,
          'description': '一个示例',
          'author': 'MacroSTAR',
          'icon': '👋',
          'sizes': ['2x2', '3x2'],
        };

    test('正常目录能解出全部字段', () {
      final list = parseCatalog({
        'version': 1,
        'plugins': [entry()],
      });
      expect(list, hasLength(1));
      final one = list.single;
      expect(one.id, 'hello');
      expect(one.name, '打招呼');
      expect(one.version, '1.0.0');
      expect(one.sizes, ['2x2', '3x2']);
      expect(one.icon, '👋');
    });

    test('坏记录只跳过它自己，不连累整个列表', () {
      // 一条记录写错就整个市场打不开，是最没必要的失败方式
      final list = parseCatalog({
        'plugins': [
          entry(id: 'good-one'),
          {'id': 'no-name'}, // 缺 name/version/downloadUrl
          '我不是对象',
          {'id': '../../evil', 'name': 'x', 'version': '1', 'downloadUrl': 'https://a/b.zip'},
          entry(id: 'good-two'),
        ],
      });
      expect(list.map((e) => e.id), ['good-one', 'good-two']);
    });

    test('id 不合法的记录一律丢掉（它会变成磁盘上的目录名）', () {
      for (final bad in ['../evil', 'UPPER', 'has space', '', 'a/b']) {
        final list = parseCatalog({
          'plugins': [entry(id: bad)]
        });
        expect(list, isEmpty, reason: 'id「$bad」不该被接受');
      }
    });

    test('整个响应是垃圾时返回空列表而不是抛异常', () {
      expect(parseCatalog(null), isEmpty);
      expect(parseCatalog('字符串'), isEmpty);
      expect(parseCatalog({'plugins': '不是数组'}), isEmpty);
    });
  });

  // ---------------- 状态判定 ----------------

  group('安装状态', () {
    const market = MarketPlugin(
        id: 'hello',
        name: '打招呼',
        version: '2.0.0',
        downloadUrl: 'https://m.example.com/a.zip');

    PluginManifest local(String version) => PluginManifest(
        id: 'hello', name: '打招呼', version: version, entry: 'index.js');

    test('本地没有 -> 未安装', () {
      expect(installStateOf(market, null), InstallState.notInstalled);
    });

    test('版本一致 -> 已安装', () {
      expect(installStateOf(market, local('2.0.0')), InstallState.installed);
    });

    test('版本不一致 -> 可更新（本地更新也算，用户可能想装回市场版）', () {
      expect(installStateOf(market, local('1.0.0')), InstallState.updatable);
      expect(installStateOf(market, local('3.0.0')), InstallState.updatable);
    });
  });

  // ---------------- 安装 ----------------

  group('安装', () {
    late Directory dir;
    late PluginInstaller installer;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('vectra-market');
      installer = PluginInstaller(dir.path);
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 造一个插件 zip。[prefix] 用来模拟"多套了一层目录"的打包方式。
    Uint8List zipOf({
      String id = 'hello',
      String version = '1.0.0',
      String entryFile = 'index.js',
      String prefix = '',
      Map<String, String> extra = const {},
      bool withManifest = true,
      Map<String, Object?>? manifestOverride,
    }) {
      final archive = Archive();
      void add(String name, String content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      if (withManifest) {
        final manifest = manifestOverride ??
            {
              'id': id,
              'name': '打招呼',
              'version': version,
              'entry': entryFile,
              'sizes': ['2x2'],
            };
        add('$prefix' 'manifest.json', jsonEncode(manifest));
      }
      add('$prefix$entryFile', 'lw.register({ mount: function () {} });');
      for (final e in extra.entries) {
        add('$prefix${e.key}', e.value);
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    Future<bool> installed(String id, String file) =>
        File(p.join(dir.path, id, file)).exists();

    test('正常的包能装进去', () async {
      await installer.install(zipOf(), expectId: 'hello', expectVersion: '1.0.0');
      expect(await installed('hello', 'manifest.json'), isTrue);
      expect(await installed('hello', 'index.js'), isTrue);
    });

    test('多套了一层目录的包也能装（zip 常见打法）', () async {
      await installer.install(zipOf(prefix: 'hello/'), expectId: 'hello');
      expect(await installed('hello', 'manifest.json'), isTrue,
          reason: '应当把多余的顶层目录剥掉');
    });

    test('附带的脚本文件一起落盘', () async {
      await installer.install(
          zipOf(extra: {'lib/util.js': '// util'}), expectId: 'hello');
      expect(await installed('hello', p.join('lib', 'util.js')), isTrue);
    });

    test('带 .. 的路径整包拒绝，绝不写到插件目录外面', () async {
      // 这是这层最重要的一条：一个包里出现这种条目，本身就说明它不可信，
      // 所以是整包拒绝而不是跳过那一条
      final evil = zipOf(extra: {'../../evil.txt': 'pwned'});
      await expectLater(
        installer.install(evil, expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
      expect(File(p.join(dir.path, '..', 'evil.txt')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'hello')).existsSync(), isFalse,
          reason: '拒绝之后不该留下半个插件目录');
    });

    test('绝对路径同样整包拒绝', () async {
      final archive = Archive();
      final bytes = utf8.encode('x');
      archive.addFile(ArchiveFile('C:/Windows/evil.txt', bytes.length, bytes));
      await expectLater(
        installer.install(Uint8List.fromList(ZipEncoder().encode(archive)),
            expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
    });

    test('没有 manifest.json 的包装不进去', () async {
      await expectLater(
        installer.install(zipOf(withManifest: false), expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
    });

    test('包里的 id 和预期不符时拒绝（否则会覆盖掉别的插件）', () async {
      await expectLater(
        installer.install(zipOf(id: 'other'), expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
    });

    test('版本和市场登记的不符时拒绝', () async {
      await expectLater(
        installer.install(zipOf(version: '9.9.9'),
            expectId: 'hello', expectVersion: '1.0.0'),
        throwsA(isA<MarketException>()),
      );
    });

    test('入口文件不在包里时拒绝（装完也是跑不起来的空壳）', () async {
      final broken = zipOf(manifestOverride: {
        'id': 'hello',
        'name': '打招呼',
        'version': '1.0.0',
        'entry': 'missing.js',
        'sizes': ['2x2'],
      });
      await expectLater(
        installer.install(broken, expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
    });

    test('坏 zip 不会把异常抛成一堆天书', () async {
      await expectLater(
        installer.install(Uint8List.fromList([1, 2, 3, 4]), expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );
    });

    test('更新失败时，原来装着的那一份必须原封不动', () async {
      // 先装好 1.0.0
      await installer.install(zipOf(version: '1.0.0'), expectId: 'hello');
      final before =
          await File(p.join(dir.path, 'hello', 'manifest.json')).readAsString();

      // 再拿一个坏包去"更新"
      await expectLater(
        installer.install(Uint8List.fromList([0, 1, 2]), expectId: 'hello'),
        throwsA(isA<MarketException>()),
      );

      final after =
          await File(p.join(dir.path, 'hello', 'manifest.json')).readAsString();
      expect(after, before, reason: '装新版失败了，旧版必须还在原地能用');
      // 临时目录也不许留
      final leftovers = dir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('.staging') || n.startsWith('.old'));
      expect(leftovers, isEmpty, reason: '失败之后不该留下临时目录');
    });

    test('装新版会把旧版的残留文件清掉', () async {
      await installer.install(zipOf(extra: {'old.js': '// 旧版才有'}),
          expectId: 'hello');
      expect(await installed('hello', 'old.js'), isTrue);

      await installer.install(zipOf(version: '2.0.0'), expectId: 'hello');
      expect(await installed('hello', 'old.js'), isFalse,
          reason: '换版本是整目录替换，不是往里面盖文件');
    });
  });

  // ---------------- 卸载 ----------------

  group('卸载', () {
    late Directory dir;
    late PluginInstaller installer;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('vectra-market-un');
      installer = PluginInstaller(dir.path);
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('删掉整个插件目录', () async {
      final d = Directory(p.join(dir.path, 'hello'))..createSync(recursive: true);
      File(p.join(d.path, 'index.js')).writeAsStringSync('x');
      await installer.uninstall('hello');
      expect(d.existsSync(), isFalse);
    });

    test('没装过也不报错', () async {
      await installer.uninstall('never-installed');
    });

    test('id 里带路径花样的一律拒绝', () async {
      final outside = Directory(p.join(dir.path, 'outside'))..createSync();
      await expectLater(
          installer.uninstall('../outside'), throwsA(isA<MarketException>()));
      expect(outside.existsSync(), isTrue, reason: '插件目录之外的东西不许碰');
    });
  });

  // ---------------- 与服务器交互 ----------------

  group('市场客户端', () {
    test('catalog 走 /api/v1/catalog 并带上 User-Agent', () async {
      Uri? seen;
      String? ua;
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient((req) async {
          seen = req.url;
          ua = req.headers['User-Agent'];
          return http.Response(
              jsonEncode({
                'plugins': [
                  {
                    'id': 'hello',
                    'name': '打招呼',
                    'version': '1.0.0',
                    'downloadUrl': 'https://m.example.com/a.zip'
                  }
                ]
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );

      final list = await client.catalog();
      expect(list.single.id, 'hello');
      expect(seen?.path, '/api/v1/catalog');
      expect(ua, isNotNull, reason: '服务器要能认出是哪个版本的客户端在请求');
    });

    test('服务器返回 500 时给一句人话，不是异常堆栈', () async {
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient((_) async => http.Response('boom', 500)),
      );
      await expectLater(
        client.catalog(),
        throwsA(isA<MarketException>()
            .having((e) => e.message, 'message', contains('500'))),
      );
    });

    test('详情接口的 id 也要过一遍合法性', () async {
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
          client.detail('../../etc'), throwsA(isA<MarketException>()));
    });

    test('下载会按块回报进度', () async {
      final body = List<int>.filled(3000, 65);
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient.streaming((req, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([body.sublist(0, 1000), body.sublist(1000)]),
            200,
            contentLength: body.length,
          );
        }),
      );

      final seen = <int>[];
      final bytes = await client.download('https://m.example.com/a.zip',
          onProgress: (received, total) {
        expect(total, body.length);
        seen.add(received);
      });

      expect(bytes, hasLength(3000));
      expect(seen, [1000, 3000], reason: '每收到一块就该回报一次，进度条才动得起来');
    });

    test('服务器写了错误原因时，把它原样带给用户', () async {
      // Unisphere 出错时会给一句人话（v1 是裸的 {error}）。服务器比客户端
      // 清楚发生了什么，能用它就别拿"HTTP 500"糊弄用户。
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient((_) async => http.Response(
            jsonEncode({'error': '插件目录正在重建，请稍后再试'}), 503,
            headers: {'content-type': 'application/json; charset=utf-8'})),
      );
      await expectLater(
        client.catalog(),
        throwsA(isA<MarketException>().having(
            (e) => e.message, 'message', '插件目录正在重建，请稍后再试')),
      );
    });

    test('错误响应不是 JSON 时退回状态码，不至于把 HTML 糊到界面上', () async {
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient(
            (_) async => http.Response('<html>502 Bad Gateway</html>', 502)),
      );
      await expectLater(
        client.catalog(),
        throwsA(isA<MarketException>()
            .having((e) => e.message, 'message', contains('502'))),
      );
    });

    test('下载地址不是 http/https 时直接拒绝', () async {
      final client = MarketClient(
        baseUrl: 'https://m.example.com',
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(client.download('file:///C:/windows/evil.exe'),
          throwsA(isA<MarketException>()));
    });
  });
}
