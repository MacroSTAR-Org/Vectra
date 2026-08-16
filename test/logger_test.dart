/// 日志系统的行为约定。
///
/// 这几条是日志系统存在的理由，都要能自动验证：
///   1. 级别过滤——默认 info 不应该把 debug 写进文件（不然动态壁纸每帧一行
///      能把真正有用的行冲掉）；
///   2. 按天分文件 + 保留 7 天——不清理的话日志会一直长；
///   3. 脱敏——apiKey / token 绝不能出现在用户会拷给别人的文件里。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vectra/core/logger.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vectra-log-test');
  });

  tearDown(() {
    Log.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 当天那个日志文件的内容；还没生成就返回空串
  String readToday(String engine) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final f = File(p.join(
        tmp.path, '$engine-${now.year}-${two(now.month)}-${two(now.day)}.log'));
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  test('默认 info：debug 不落盘，info 及以上落盘', () async {
    Log.init(engine: 'main', dir: tmp.path);
    Log.d('store', '这条是调试细节');
    Log.i('store', '配置已保存');
    Log.w('store', '缓存写入失败');
    Log.e('store', '配置保存失败');
    await Log.flushLogs();

    final text = readToday('main');
    expect(text, isNot(contains('这条是调试细节')));
    expect(text, contains('配置已保存'));
    expect(text, contains('缓存写入失败'));
    expect(text, contains('配置保存失败'));
  });

  test('--verbose 提级后 debug 也落盘', () async {
    Log.init(engine: 'main', dir: tmp.path, level: LogLevel.debug);
    Log.d('wallpaper', '目标 200ms 实测 31ms/帧');
    await Log.flushLogs();

    expect(readToday('main'), contains('目标 200ms 实测 31ms/帧'));
  });

  test('行格式带时间戳、级别和模块前缀', () async {
    Log.init(engine: 'main', dir: tmp.path);
    Log.i('plugin', '已加载 5 个');
    await Log.flushLogs();

    final line = readToday('main').trim();
    // 2026-08-16 14:43:05.123 I [plugin] 已加载 5 个
    expect(
        line,
        matches(RegExp(
            r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} I \[plugin\] 已加载 5 个$')));
  });

  test('两个引擎各写各的文件，不互相插队', () async {
    Log.init(engine: 'main', dir: tmp.path);
    Log.i('app', '磁贴引擎');
    await Log.flushLogs();
    Log.resetForTest();

    Log.init(engine: 'sidebar', dir: tmp.path);
    Log.i('sidebar', '侧边栏引擎');
    await Log.flushLogs();

    expect(readToday('main'), contains('磁贴引擎'));
    expect(readToday('main'), isNot(contains('侧边栏引擎')));
    expect(readToday('sidebar'), contains('侧边栏引擎'));
  });

  test('native 转发的日志按 info 记，模块名为 native', () async {
    Log.init(engine: 'main', dir: tmp.path);
    Log.native('WM_DISPLAYCHANGE 新虚拟屏=0,0 3840x1080');
    await Log.flushLogs();

    expect(readToday('main'), contains('I [native] WM_DISPLAYCHANGE'));
  });

  group('脱敏', () {
    test('sk- 开头的密钥被打码', () async {
      Log.init(engine: 'main', dir: tmp.path);
      Log.i('ai', '请求失败 key=sk-abcdef1234567890abcdef');
      await Log.flushLogs();

      final text = readToday('main');
      expect(text, isNot(contains('sk-abcdef1234567890abcdef')));
      expect(text, contains('sk-***'));
    });

    test('URL query 里的敏感参数被打码', () async {
      Log.init(engine: 'main', dir: tmp.path);
      Log.w('plugin', '请求失败 https://api.example.com/v1?city=北京&key=SECRET123&x=1');
      await Log.flushLogs();

      final text = readToday('main');
      expect(text, isNot(contains('SECRET123')));
      expect(text, contains('key=***'));
      // 无关参数不该被误伤，否则日志会失去定位价值
      expect(text, contains('city=北京'));
      expect(text, contains('x=1'));
    });

    test('access_token / password 等变体同样被打码', () async {
      Log.init(engine: 'main', dir: tmp.path);
      Log.w('ai', 'https://h/a?access_token=AAA111&password=BBB222');
      await Log.flushLogs();

      final text = readToday('main');
      expect(text, isNot(contains('AAA111')));
      expect(text, isNot(contains('BBB222')));
    });
  });

  test('启动时清掉 7 天前的日志，保留 7 天内的', () {
    // 一个 8 天前、一个 1 天前，init 时应该只删前者
    String two(int v) => v.toString().padLeft(2, '0');
    String name(String engine, DateTime t) =>
        '$engine-${t.year}-${two(t.month)}-${two(t.day)}.log';

    final old = File(p.join(
        tmp.path, name('main', DateTime.now().subtract(const Duration(days: 8)))))
      ..writeAsStringSync('旧的');
    final recent = File(p.join(
        tmp.path, name('main', DateTime.now().subtract(const Duration(days: 1)))))
      ..writeAsStringSync('近的');

    Log.init(engine: 'main', dir: tmp.path);

    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
  });

  test('目录不存在时自动建，日志不会因此丢失', () async {
    final nested = p.join(tmp.path, 'a', 'b', 'logs');
    Log.init(engine: 'main', dir: nested);
    Log.i('app', '启动');
    await Log.flushLogs();

    expect(Directory(nested).existsSync(), isTrue);
    final files = Directory(nested)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'));
    expect(files, isNotEmpty);
    expect(files.first.readAsStringSync(), contains('启动'));
  });
}
