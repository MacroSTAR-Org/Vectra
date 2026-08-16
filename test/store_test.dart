// 存储层：config.json / plugindata 拆分、旧 state.json 迁移、备份导入导出。
//
// 这几条都是"错了就丢用户数据"的路径，靠手工验证成本太高，钉死在测试里。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vectra/model/card.dart';
import 'package:vectra/store/store.dart';

/// 每个用例一个独立临时目录，互不干扰
Directory makeTempDir() =>
    Directory.systemTemp.createTempSync('vectra_store_test');

void main() {
  group('拆分存储', () {
    test('配置与插件数据分别落在 config.json 和 plugindata/', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      state.cards.add(WidgetCard(
          id: 'clock-1', pluginId: 'clock', x: 10, y: 20, size: '2x2', z: 1));
      await store.saveNow(state);
      store.nsSet('lyrics', 'cache', 'x' * 5000);
      await store.flushPluginData();

      final config = File(p.join(dir.path, 'config.json'));
      final lyrics = File(p.join(dir.path, 'plugindata', 'lyrics.json'));
      expect(config.existsSync(), isTrue);
      expect(lyrics.existsSync(), isTrue);

      // 关键：插件缓存绝不能出现在 config.json 里，否则写放大又回来了
      final text = config.readAsStringSync();
      expect(text.contains('xxxxx'), isFalse);
      expect(text.contains('pluginData'), isFalse);
      expect(text.contains('"chat"'), isFalse, reason: 'chat 字段已废弃');
    });

    test('卡片记的"家在哪块屏"要能存下来、读回来', () async {
      // 这份锚点是多显示器不错位的全部依据：只要它没被存进去，
      // 下次启动就只剩窗口坐标，接一块屏原点一变，卡片就集体偏了。
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      final card = WidgetCard(
          id: 'clock-1', pluginId: 'clock', x: 10, y: 20, size: '2x2', z: 1);
      card.anchorTo(monitorId: r'\\.\DISPLAY2', relX: 0.25, relY: 0.75);
      state.cards.add(card);
      await store.saveNow(state);

      final back = (await Store(dir.path).load()).cards.single;
      expect(back.monitorId, r'\\.\DISPLAY2');
      expect(back.relX, 0.25);
      expect(back.relY, 0.75);
    });

    test('老配置里的卡片没有家，读出来是 null 而不是报错', () async {
      // 认家是后加的，已经在用的配置里没有这三个键
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'config.json')).writeAsStringSync(jsonEncode({
        'settings': <String, Object?>{},
        'cards': [
          {'id': 'clock-1', 'pluginId': 'clock', 'x': 10, 'y': 20, 'z': 1}
        ],
      }));

      final card = (await Store(dir.path).load()).cards.single;
      expect(card.monitorId, isNull);
      expect(card.x, 10);
    });

    test('插件写数据不会重写 config.json', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      await store.saveNow(state);
      final before = File(p.join(dir.path, 'config.json')).lastModifiedSync();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.nsSet('weather', 'resp', '{"temp":21}');
      await store.flushPluginData();

      final after = File(p.join(dir.path, 'config.json')).lastModifiedSync();
      expect(after, before, reason: '插件写缓存不该连累主配置');
    });

    test('重新加载后插件数据还在', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final a = Store(dir.path);
      await a.load();
      a.nsSet('todo', '@inst:todo-1:items', ['买菜']);
      await a.flushPluginData();

      final b = Store(dir.path);
      await b.load();
      expect(b.nsGet('todo', '@inst:todo-1:items'), ['买菜']);
    });

    test('单个插件文件损坏不影响其他插件和主配置', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final a = Store(dir.path);
      final s = await a.load();
      s.cards.add(WidgetCard(
          id: 'clock-1', pluginId: 'clock', x: 0, y: 0, size: '2x2', z: 1));
      await a.saveNow(s);
      a.nsSet('todo', 'k', 'v');
      await a.flushPluginData();
      File(p.join(dir.path, 'plugindata', 'lyrics.json'))
          .writeAsStringSync('{ 这不是 JSON');

      final b = Store(dir.path);
      final loaded = await b.load();
      expect(loaded.cards.length, 1, reason: '主配置不该被牵连');
      expect(b.nsGet('todo', 'k'), 'v', reason: '好的插件数据照常读出');
      expect(b.nsGet('lyrics', 'anything'), isNull);
    });

    test('拒绝会穿越路径的 pluginId', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      store.nsSet('../../evil', 'k', 'v');
      await store.flushPluginData();

      expect(File(p.join(dir.path, 'plugindata', '../../evil.json')).existsSync(),
          isFalse);
      expect(store.nsGet('../../evil', 'k'), isNull);
    });
  });

  group('旧 state.json 迁移', () {
    test('拆成 config.json 与各插件文件，且保留旧文件', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      File(p.join(dir.path, 'state.json')).writeAsStringSync(jsonEncode({
        'schema': 2,
        'settings': {'theme': 'dark', 'gridCell': 96},
        'cards': [
          {'id': 'c1', 'pluginId': 'clock', 'x': 1, 'y': 2, 'size': '2x2', 'z': 5}
        ],
        'disabledPlugins': ['weather'],
        'chat': [
          {'role': 'user', 'content': '你好'}
        ],
        'pluginData': {
          'lyrics': {'cache': 'LRC 全文'},
          'todo': {'items': 1}
        },
      }));

      final store = Store(dir.path);
      final state = await store.load();

      expect(state.cards.length, 1);
      expect(state.settings.theme, 'dark');
      expect(state.disabledPlugins, ['weather']);
      expect(store.nsGet('lyrics', 'cache'), 'LRC 全文');
      expect(store.nsGet('todo', 'items'), 1);

      expect(File(p.join(dir.path, 'state.json')).existsSync(), isTrue,
          reason: '旧文件必须保留，拆分出问题时还能救');
      expect(
          File(p.join(dir.path, 'plugindata', 'lyrics.json')).existsSync(), isTrue);

      // chat 是僵尸字段，不该带进新配置
      final text = File(p.join(dir.path, 'config.json')).readAsStringSync();
      expect(text.contains('"chat"'), isFalse);
    });

    test('迁移是幂等的：config.json 已存在就不再理会 state.json', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final first = Store(dir.path);
      final s = await first.load();
      s.cards.add(WidgetCard(
          id: 'new', pluginId: 'clock', x: 0, y: 0, size: '1x1', z: 1));
      await first.saveNow(s);

      // 事后丢一个旧文件进去，不该覆盖已有配置
      File(p.join(dir.path, 'state.json')).writeAsStringSync(jsonEncode({
        'settings': {},
        'cards': [
          {'id': 'old', 'pluginId': 'clock', 'x': 0, 'y': 0, 'size': '1x1', 'z': 1},
          {'id': 'old2', 'pluginId': 'todo', 'x': 0, 'y': 0, 'size': '1x1', 'z': 2}
        ],
      }));

      final second = Store(dir.path);
      final loaded = await second.load();
      expect(loaded.cards.length, 1);
      expect(loaded.cards.single.id, 'new');
    });

    test('旧文件是坏的也不能影响启动', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      File(p.join(dir.path, 'state.json')).writeAsStringSync('{{{ 坏文件');
      final store = Store(dir.path);
      final state = await store.load();
      expect(state.cards, isEmpty);
    });

    test('config.json 损坏时退回默认并留档', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      File(p.join(dir.path, 'config.json')).writeAsStringSync('不是 JSON');
      final store = Store(dir.path);
      final state = await store.load();

      expect(state.cards, isEmpty);
      final kept = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('config.json.broken-'));
      expect(kept, isNotEmpty, reason: '坏配置要留档，别直接抹掉');
    });
  });

  group('null 即删除', () {
    test('写 null 会把键删掉，而不是留个空壳', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      store.nsSet('todo', 'a', 1);
      store.nsSet('todo', 'b', 2);
      store.nsSet('todo', 'a', null);
      await store.flushPluginData();

      final text =
          File(p.join(dir.path, 'plugindata', 'todo.json')).readAsStringSync();
      expect(text.contains('"a"'), isFalse, reason: '键名不该留在文件里');
      expect(text.contains('"b"'), isTrue);
      expect(store.nsGet('todo', 'a'), isNull);
    });

    test('加载时清掉历史遗留的 null 墓碑', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      // 模拟老版本留下的文件：一堆值为 null 的键
      Directory(p.join(dir.path, 'plugindata')).createSync(recursive: true);
      File(p.join(dir.path, 'plugindata', 'lyrics.json')).writeAsStringSync(
          jsonEncode({
        'lrc:活着的': [1, 2],
        'lrc:死掉的1': null,
        'lrc:死掉的2': null,
      }));

      final store = Store(dir.path);
      await store.load();
      expect(store.nsGet('lyrics', 'lrc:活着的'), [1, 2]);
      expect(store.nsGet('lyrics', 'lrc:死掉的1'), isNull);

      // 触发一次写回，墓碑应该从文件里消失
      store.nsSet('lyrics', 'x', 1);
      await store.flushPluginData();
      final text = File(p.join(dir.path, 'plugindata', 'lyrics.json'))
          .readAsStringSync();
      expect(text.contains('死掉的'), isFalse);
      expect(text.contains('活着的'), isTrue);
    });
  });

  group('缓存（一条一个文件）', () {
    test('写进去读得出来', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      await store.cacheSet('lyrics', '晴天|周杰伦', [
        {'t': 0, 'w': '故事的小黄花'}
      ]);

      expect(await store.cacheGet('lyrics', '晴天|周杰伦'), [
        {'t': 0, 'w': '故事的小黄花'}
      ]);
      expect(await store.cacheGet('lyrics', '没存过的'), isNull);
    });

    test('缓存不落在 config.json 也不落在插件的键值文件里', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      await store.saveNow(state);
      store.nsSet('lyrics', 'realKey', 'realValue');
      await store.flushPluginData();
      await store.cacheSet('lyrics', '某首歌', '整首 LRC' * 200);

      final config = File(p.join(dir.path, 'config.json')).readAsStringSync();
      final kv = File(p.join(dir.path, 'plugindata', 'lyrics.json'))
          .readAsStringSync();
      expect(config.contains('整首 LRC'), isFalse);
      expect(kv.contains('整首 LRC'), isFalse, reason: '缓存不该混进键值文件');
      expect(kv.contains('realValue'), isTrue);

      // 缓存目录和键值文件同级同名，扫描时不能互相干扰
      expect(Directory(p.join(dir.path, 'plugindata', 'lyrics')).existsSync(),
          isTrue);
    });

    test('缓存目录不会被当成插件数据读进来', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final a = Store(dir.path);
      await a.load();
      await a.cacheSet('lyrics', 'k', 'v');

      final b = Store(dir.path);
      final state = await b.load();
      expect(state.pluginData.containsKey('lyrics'), isFalse,
          reason: '只有 <id>.json 才是插件数据，<id>/ 目录是缓存');
      expect(await b.cacheGet('lyrics', 'k'), 'v');
    });

    test('写 null 删掉那一条', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      await store.cacheSet('lyrics', 'k', 'v');
      expect(await store.cacheGet('lyrics', 'k'), 'v');

      await store.cacheSet('lyrics', 'k', null);
      expect(await store.cacheGet('lyrics', 'k'), isNull);
      expect(
          Directory(p.join(dir.path, 'plugindata', 'lyrics'))
              .listSync()
              .whereType<File>(),
          isEmpty);
    });

    test('哈希撞了当作未命中，不会张冠李戴', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      await store.cacheSet('lyrics', '甲的歌', '甲的歌词');

      // 手工把文件内容改成另一个 key，模拟两个 key 落到同一个文件名
      final f = Directory(p.join(dir.path, 'plugindata', 'lyrics'))
          .listSync()
          .whereType<File>()
          .single;
      f.writeAsStringSync(jsonEncode({'k': '乙的歌', 'v': '乙的歌词'}));

      expect(await store.cacheGet('lyrics', '甲的歌'), isNull,
          reason: '原 key 对不上就该当作没命中，而不是把乙的歌词给甲');
    });

    test('缓存文件损坏时当作未命中并删掉坏文件', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      await store.cacheSet('lyrics', 'k', 'v');
      final f = Directory(p.join(dir.path, 'plugindata', 'lyrics'))
          .listSync()
          .whereType<File>()
          .single;
      f.writeAsStringSync('{{{ 坏了');

      expect(await store.cacheGet('lyrics', 'k'), isNull);
      expect(f.existsSync(), isFalse, reason: '坏文件该被清掉');
    });

    test('超过上限会淘汰最旧的', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      // 上限 500，写 530 条；淘汰每 25 次写触发一次
      for (var i = 0; i < 530; i++) {
        await store.cacheSet('lyrics', 'song$i', 'lrc$i');
      }
      final count = Directory(p.join(dir.path, 'plugindata', 'lyrics'))
          .listSync()
          .whereType<File>()
          .length;
      // 不是硬上限：两次扫描之间会多出最多 cacheSweepEvery 条
      expect(count, lessThan(530), reason: '必须真的淘汰过');
      expect(count, lessThanOrEqualTo(Store.cacheMaxEntries + Store.cacheSweepEvery),
          reason: '超出量必须有界');
      expect(await store.cacheGet('lyrics', 'song529'), 'lrc529',
          reason: '最新写的必须还在');
      // 不断言"song0 一定被淘汰"：530 条是在同一瞬间写完的，文件时间戳
      // 粒度让它们彼此相等，谁先出局不确定（见 _sweepCache 的说明）。
    });

    test('拒绝会穿越路径的 pluginId', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();
      await store.cacheSet('../../evil', 'k', 'v');
      expect(await store.cacheGet('../../evil', 'k'), isNull);
      expect(File(p.join(dir.path, 'plugindata', '../../evil')).existsSync(),
          isFalse);
    });
  });

  group('布局备份导入导出', () {
    test('导出再导入能原样还原', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      state.settings.theme = 'dark';
      state.settings.cardRadius = 25;
      state.cards.add(WidgetCard(
          id: 'w1',
          pluginId: 'weather',
          x: 100,
          y: 200,
          size: '3x2',
          z: 7,
          settings: {'city': '下陆'}));
      state.disabledPlugins.add('lyrics');
      state.ai.model = 'SAI-L7';

      final restored = store.decodeConfig(store.encodeConfig(state));

      expect(restored.settings.theme, 'dark');
      expect(restored.settings.cardRadius, 25);
      expect(restored.disabledPlugins, ['lyrics']);
      expect(restored.ai.model, 'SAI-L7');
      expect(restored.cards.single.id, 'w1');
      expect(restored.cards.single.x, 100);
      expect(restored.cards.single.settings['city'], '下陆');
    });

    test('导出内容里没有插件缓存', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      final state = await store.load();
      store.nsSet('lyrics', 'cache', '整首歌的 LRC');

      expect(store.encodeConfig(state).contains('整首歌的 LRC'), isFalse);
    });

    test('拿不相干的 JSON 去导入会被拒绝', () async {
      final dir = makeTempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = Store(dir.path);
      await store.load();

      expect(() => store.decodeConfig('[1,2,3]'), throwsFormatException);
      expect(() => store.decodeConfig('{"foo":1}'), throwsFormatException);
      expect(() => store.decodeConfig('不是 JSON'), throwsA(isA<Exception>()));
    });
  });
}
