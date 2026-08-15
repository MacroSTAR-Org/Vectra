// 声明式 UI 协议的渲染测试。插件是第三方写的，协议解析必须容错：
// 缺字段、类型不对、未知节点，都不能让整张卡片崩掉。
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/plugin/images.dart';
import 'package:vectra/plugin/node.dart';

void main() {
  Future<void> pump(WidgetTester tester, Map<String, Object?>? tree,
      {PluginEvent? onEvent}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PluginView(
          tree: tree,
          onEvent: onEvent ?? (_, _) {},
        ),
      ),
    ));
  }

  testWidgets('文本节点渲染出内容', (tester) async {
    await pump(tester, {'t': 'text', 'v': '14:32', 'size': 30, 'weight': 700});
    expect(find.text('14:32'), findsOneWidget);
  });

  testWidgets('col/row 按 gap 插入间隔且子节点都渲染', (tester) async {
    await pump(tester, {
      't': 'col',
      'gap': 6,
      'children': [
        {'t': 'text', 'v': 'A'},
        {'t': 'text', 'v': 'B'},
      ]
    });
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('未知节点类型被忽略，不影响兄弟节点', (tester) async {
    await pump(tester, {
      't': 'col',
      'children': [
        {'t': '这是插件瞎写的类型'},
        {'t': 'text', 'v': '还在'},
      ]
    });
    expect(find.text('还在'), findsOneWidget);
  });

  testWidgets('缺字段不崩：text 没有 v', (tester) async {
    await pump(tester, {'t': 'text'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('字段类型不对不崩：size 传了字符串', (tester) async {
    await pump(tester, {'t': 'text', 'v': 'x', 'size': 'huge'});
    expect(tester.takeException(), isNull);
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('tree 为 null 时渲染空白而不是抛异常', (tester) async {
    await pump(tester, null);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap 节点点击后回调对应 handlerId', (tester) async {
    final fired = <String>[];
    await pump(
      tester,
      {
        't': 'tap',
        'id': 'h7',
        'child': {'t': 'text', 'v': '点我'}
      },
      onEvent: (id, payload) => fired.add(id),
    );
    await tester.tap(find.text('点我'));
    expect(fired, ['h7']);
  });

  testWidgets('grid 按列数分行铺满', (tester) async {
    await pump(tester, {
      't': 'grid',
      'cols': 3,
      'children': [
        for (var i = 1; i <= 7; i++) {'t': 'text', 'v': 'c$i'}
      ]
    });
    for (var i = 1; i <= 7; i++) {
      expect(find.text('c$i'), findsOneWidget);
    }
  });

  testWidgets('颜色支持 #RGB / #RRGGBB / #RRGGBBAA', (tester) async {
    await pump(tester, {
      't': 'col',
      'children': [
        {'t': 'box', 'w': 10, 'h': 10, 'bg': '#f00'},
        {'t': 'box', 'w': 10, 'h': 10, 'bg': '#00ff00'},
        {'t': 'box', 'w': 10, 'h': 10, 'bg': '#0000ff80'},
      ]
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('input 回车触发 submit 并带上文本', (tester) async {
    final events = <MapEntry<String, Object?>>[];
    await pump(
      tester,
      {'t': 'input', 'id': 'i1', 'value': '', 'submit': 'onAdd'},
      onEvent: (id, payload) => events.add(MapEntry(id, payload['value'])),
    );
    await tester.enterText(find.byType(TextField), '买牛奶');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(events.single.key, 'onAdd');
    expect(events.single.value, '买牛奶');
  });

  testWidgets('children 里混入非法元素被跳过', (tester) async {
    await pump(tester, {
      't': 'col',
      'children': [
        'not a map',
        42,
        {'t': 'text', 'v': '幸存'},
      ]
    });
    expect(tester.takeException(), isNull);
    expect(find.text('幸存'), findsOneWidget);
  });

  testWidgets('6 位色值不能被当成 RRGGBBAA 旋转（蓝色曾被渲染成粉色）', (tester) async {
    // 之前 _color 里两个 if 是并列的：6 位补完 FF 变成 8 位后又被旋转一次，
    // #29B6F6 变成 #F6FF29B6。所有 6 位颜色都是错的，肉眼看是蓝→粉。
    await pump(tester, {
      't': 'box',
      'w': 20,
      'h': 20,
      'bg': '#29B6F6',
      'child': {'t': 'text', 'v': 'x'}
    });
    final box = tester.widget<Container>(find.byType(Container).first);
    final deco = box.decoration as BoxDecoration;
    expect(deco.color, const Color(0xFF29B6F6));
  });

  testWidgets('8 位色值按 RRGGBBAA 解析', (tester) async {
    await pump(tester, {'t': 'box', 'w': 20, 'h': 20, 'bg': '#29B6F680'});
    final box = tester.widget<Container>(find.byType(Container).first);
    final deco = box.decoration as BoxDecoration;
    expect(deco.color, const Color(0x8029B6F6));
  });

  testWidgets('3 位色值展开', (tester) async {
    await pump(tester, {'t': 'box', 'w': 20, 'h': 20, 'bg': '#f00'});
    final box = tester.widget<Container>(find.byType(Container).first);
    final deco = box.decoration as BoxDecoration;
    expect(deco.color, const Color(0xFFFF0000));
  });

  // ---------------- image ----------------

  testWidgets('image 节点：key 查不到时画占位，不留白也不崩', (tester) async {
    PluginImages.clear();
    await pump(tester, {'t': 'image', 'key': 'smtc:1', 'w': 80.0, 'h': 80.0});
    // 占位是一个音符图标，说明走到了 fallback 而不是空节点
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('image 节点：缓存里有图就画图', (tester) async {
    PluginImages.clear();
    final img = await _solidImage(4, 4);
    PluginImages.put('smtc:7', img);
    addTearDown(PluginImages.clear);

    await pump(tester, {'t': 'image', 'key': 'smtc:7', 'w': 60.0, 'h': 60.0});
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byIcon(Icons.music_note_rounded), findsNothing);
  });

  testWidgets('image 节点：图片解码完成后会自动重画（不需要插件再 render 一次）',
      (tester) async {
    PluginImages.clear();
    addTearDown(PluginImages.clear);
    await pump(tester, {'t': 'image', 'key': 'smtc:9', 'w': 60.0, 'h': 60.0});
    expect(find.byType(RawImage), findsNothing);

    // 模拟"封面异步解码完成"——这一步发生在插件那一帧渲染之后
    PluginImages.put('smtc:9', await _solidImage(2, 2));
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget,
        reason: '不监听缓存版本号的话，封面永远停在占位图上');
  });

  testWidgets('image 节点：没有 key 也不能崩', (tester) async {
    PluginImages.clear();
    await pump(tester, {'t': 'image', 'w': 30.0, 'h': 30.0});
    expect(tester.takeException(), isNull);
  });

  // ---------------- slider ----------------

  testWidgets('slider 拖动后按松手位置回调 0..1', (tester) async {
    final events = <Map<String, Object?>>[];
    await pump(
      tester,
      {
        't': 'box',
        'w': 200.0,
        'child': {'t': 'slider', 'id': 'h1', 'v': 0.0}
      },
      onEvent: (id, payload) => events.add({'id': id, ...payload}),
    );

    final center = tester.getCenter(find.byType(FractionallySizedBox));
    final left = tester.getTopLeft(find.byType(FractionallySizedBox)).dx;
    final g = await tester.startGesture(Offset(left + 5, center.dy),
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    await g.moveTo(Offset(left + 100, center.dy));
    await tester.pump();
    expect(events, isEmpty, reason: '拖动过程中不该回调，否则每一帧都在 seek');
    await g.up();
    await tester.pump();

    expect(events, hasLength(1));
    expect(events.first['id'], 'h1');
    expect(events.first['value'] as double, closeTo(0.5, 0.02));
  });

  testWidgets('slider 置灰后不接收拖动', (tester) async {
    final events = <Map<String, Object?>>[];
    await pump(
      tester,
      {
        't': 'box',
        'w': 200.0,
        'child': {'t': 'slider', 'id': 'h1', 'v': 0.3, 'enabled': false}
      },
      onEvent: (id, payload) => events.add({'id': id, ...payload}),
    );
    final center = tester.getCenter(find.byType(FractionallySizedBox));
    final g = await tester.startGesture(center,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await g.moveTo(center + const Offset(50, 0));
    await g.up();
    await tester.pump();
    expect(events, isEmpty, reason: '播放器不支持定位时拖了也不该发命令');
    expect(PluginPointer.grabbedPointer, isNull, reason: '置灰的滑条不该抢指针');
  });

  testWidgets('slider 按下时会声明抢占指针，松手后释放', (tester) async {
    await pump(tester, {
      't': 'box',
      'w': 200.0,
      'child': {'t': 'slider', 'id': 'h1', 'v': 0.0}
    });
    expect(PluginPointer.grabbedPointer, isNull);

    final center = tester.getCenter(find.byType(FractionallySizedBox));
    final g = await tester.startGesture(center,
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tester.pump();
    // 这个标志就是"拖进度条不要把整张卡片拖走"的全部机制
    expect(PluginPointer.grabbedPointer, isNotNull);

    await g.up();
    await tester.pump();
    expect(PluginPointer.grabbedPointer, isNull);
  });

  // ---------------- 媒体图标 ----------------

  testWidgets('媒体图标名解析到真正的图标，而不是 fallback 方块', (tester) async {
    await pump(tester, {
      't': 'row',
      'children': [
        {'t': 'icon', 'v': 'play'},
        {'t': 'icon', 'v': 'pause'},
        {'t': 'icon', 'v': 'prev'},
        {'t': 'icon', 'v': 'next'},
        {'t': 'icon', 'v': 'music'},
      ]
    });
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    expect(find.byIcon(Icons.square_outlined), findsNothing,
        reason: '认不出的图标名会变成方块，那说明 _icon 表里漏了');
  });

  // ---------------- 主轴对齐 ----------------

  testWidgets('main:between 必须真的把两端撑开（曾经是空操作）', (tester) async {
    await pump(tester, {
      't': 'box',
      'w': 300.0,
      'child': {
        't': 'row',
        'main': 'between',
        'children': [
          {'t': 'text', 'v': '左'},
          {'t': 'text', 'v': '右'},
        ]
      }
    });

    final l = tester.getTopLeft(find.text('左')).dx;
    final r = tester.getTopRight(find.text('右')).dx;
    // MainAxisSize.min 时两个字会挨在一起，间距只有十几像素；
    // 歌词卡片的"0:03 3:43"就是这么粘成"0:033:43"的
    expect(r - l, greaterThan(250),
        reason: 'between 没生效的话两端会挤在一起');
  });

  testWidgets('main 默认 start 时容器仍然收缩到内容宽度', (tester) async {
    await pump(tester, {
      't': 'box',
      'w': 300.0,
      'child': {
        't': 'row',
        'children': [
          {'t': 'text', 'v': '左'},
          {'t': 'text', 'v': '右'},
        ]
      }
    });
    final l = tester.getTopLeft(find.text('左')).dx;
    final r = tester.getTopRight(find.text('右')).dx;
    expect(r - l, lessThan(120), reason: '默认不该撑满，否则现有插件布局全变');
  });

  testWidgets('row 默认按顶端对齐，cross:center 才让高矮不一的子节点居中',
      (tester) async {
    // 歌词卡片的三个控制按钮就栽在这上面：播放键比前后曲大一圈，
    // row 没写 cross 时按顶端对齐，两个小的看起来就是往上飘。
    Map<String, Object?> tree(String? cross) => {
          't': 'row',
          if (cross != null) 'cross': cross,
          'children': [
            {'t': 'box', 'w': 40.0, 'h': 40.0, 'child': {'t': 'text', 'v': 'A'}},
            {'t': 'box', 'w': 40.0, 'h': 80.0, 'child': {'t': 'text', 'v': 'B'}},
          ]
        };

    await pump(tester, tree(null));
    final aTop = tester.getTopLeft(find.text('A')).dy;
    final bTop = tester.getTopLeft(find.text('B')).dy;
    expect(aTop, bTop, reason: '默认 start：两个子节点顶端齐平');

    await pump(tester, tree('center'));
    final aMid = tester.getCenter(find.text('A')).dy;
    final bMid = tester.getCenter(find.text('B')).dy;
    expect((aMid - bMid).abs(), lessThan(1.0),
        reason: 'cross:center 之后两者中心必须落在同一条线上');
  });

  // animKey 的动画已被禁用（真实渲染下换行动画闪白，见 node.dart _child
  // 注释）：animKey 变化时内容必须**立即**原地替换——旧内容退场的同一帧
  // 新内容已在，任何一帧都不能没有内容（换行动画闪白的回归保护）
  testWidgets('animKey 变化时内容原地替换，无空白帧', (tester) async {
    Future<void> pumpTree(String key) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PluginView(
            tree: {
              't': 'col',
              'children': [
                {
                  't': 'flex',
                  'f': 1,
                  'animKey': key,
                  'child': {'t': 'text', 'v': key},
                },
              ],
            },
            onEvent: (_, _) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 20));
    }

    await pumpTree('line1');
    expect(find.text('line1'), findsOneWidget);

    // key 变了：原地替换，旧内容立即退场、新内容立即进场
    await pumpTree('line2');
    expect(find.text('line2'), findsOneWidget, reason: '新内容必须立即在');
    expect(find.text('line1'), findsNothing, reason: '旧内容必须立即退场，不留过渡帧');
    expect(
        find.text('line1').evaluate().isNotEmpty ||
            find.text('line2').evaluate().isNotEmpty,
        isTrue,
        reason: '替换瞬间不能没有任何内容');
  });

  testWidgets('不带 animKey 的节点不产生切换动画', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PluginView(
          tree: {
            't': 'col',
            'children': [
              {
                't': 'flex',
                'f': 1,
                'child': {'t': 'text', 'v': 'x'},
              },
            ],
          },
          onEvent: (_, _) {},
        ),
      ),
    ));
    expect(find.text('x'), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing,
        reason: '没声明 animKey 就不能有切换动画');
  });

  // 空白帧回归测试：换行/换词是原地替换（animKey 动画已禁用），
  // 连续 render（真实播放每 100ms 一次）的任何一帧都必须有内容
  testWidgets('换行原地替换后连续 render 任何一帧都有内容', (tester) async {
    Widget app(String key, String v) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ColoredBox(
                  color: const Color(0xFF112233),
                  child: PluginView(
                    tree: {
                      't': 'col',
                      'children': [
                        {
                          't': 'flex',
                          'f': 1,
                          'animKey': key,
                          'child': {'t': 'text', 'v': v},
                        },
                      ],
                    },
                    onEvent: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(app('k1', '旧'));
    expect(find.text('旧'), findsOneWidget);

    // 换行：原地替换，替换后连续 tick（模拟 100ms 一次的位置刷新）
    await tester.pumpWidget(app('k2', '新'));
    expect(find.text('新'), findsOneWidget, reason: '替换瞬间新内容必须在');
    expect(find.text('旧'), findsNothing, reason: '替换瞬间旧内容必须已退场');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.text('旧').evaluate().isNotEmpty ||
              find.text('新').evaluate().isNotEmpty,
          isTrue,
          reason: '第 $i 次 tick 后没有任何文本，是空白帧');
      // 原地替换不应引入任何淡入淡出过渡（限定 PluginView 内，排除路由动画）
      final fades = find.descendant(
          of: find.byType(PluginView), matching: find.byType(FadeTransition));
      expect(fades, findsNothing,
          reason: '原地替换不应引入任何淡入淡出过渡');
    }
  });

  // 快速连续换行（拖动进度条导致 idx 大跳）：任何一帧都不得空白
  testWidgets('快速连续换行任何一帧都有内容', (tester) async {
    Widget app(String key, String v) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ColoredBox(
                  color: const Color(0xFF112233),
                  child: PluginView(
                    tree: {
                      't': 'col',
                      'children': [
                        {
                          't': 'flex',
                          'f': 1,
                          'animKey': key,
                          'child': {'t': 'text', 'v': v},
                        },
                      ],
                    },
                    onEvent: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(app('k1', '行1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(app('k2', '行2'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(app('k3', '行3'));

    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 42));
      expect(
          find.text('行1').evaluate().isNotEmpty ||
              find.text('行2').evaluate().isNotEmpty ||
              find.text('行3').evaluate().isNotEmpty,
          isTrue,
          reason: '快速换行第 $i 帧没有任何文本');
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('行3'), findsOneWidget);
  });

  // 真实歌词树结构（渐变遮罩 + 点击行 + 透明度层级）原地替换没有空白帧
  testWidgets('真实歌词树结构原地替换没有空白帧', (tester) async {
    Map<String, Object?> lyricTree(String key, int idx, {String? rootKey}) => {
          'key': ?rootKey,
          't': 'col',
          'children': [
            {
              't': 'flex',
              'f': 1,
              'animKey': key,
              'child': {
                't': 'box',
                'gradientMask': true,
                'fade': 0.12,
                'child': {
                  't': 'col',
                  'gap': 0,
                  'children': [
                    for (var i = 0; i < 6; i++)
                      {
                        't': 'tap',
                        'id': 'h$i',
                        'child': {
                          't': 'box',
                          'pad': [4, 0],
                          'child': {
                            't': 'text',
                            'v': '第$idx首第$i行',
                            'size': 15.5,
                            'opacity': i == 0 ? 1.0 : 0.4,
                            'weight': i == 0 ? 700 : 400,
                            'maxLines': 1,
                          },
                        },
                      },
                  ],
                },
              },
            },
          ],
        };

    Widget app(Map<String, Object?> tree) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ColoredBox(
                  color: const Color(0xFF112233),
                  child: PluginView(tree: tree, onEvent: (_, _) {}),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(app(lyricTree('l0:3', 0, rootKey: '歌A')));
    expect(find.text('第0首第0行'), findsOneWidget);

    // 切歌后新歌词到位：整批换词（原地替换），替换瞬间及后续 tick 都有内容
    await tester.pumpWidget(app(lyricTree('l1:3', 1, rootKey: '歌A')));
    expect(find.text('第1首第0行'), findsOneWidget, reason: '替换瞬间新歌词必须在');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 42));
      final texts = find.byType(Text).evaluate().length;
      expect(texts, greaterThan(0), reason: '真实树第 $i 帧没有任何文字');
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第1首第0行'), findsOneWidget);
  });

  // 整卡内容切换（root key 触发 AnimatedSwitcher 交叉淡入）逐帧都有内容。
  // 无动画版本正是靠这条路径保证切歌不空白的——回归保护它
  testWidgets('root key 整卡交叉淡入没有空白帧', (tester) async {
    Widget app(String rootKey, String v) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ColoredBox(
                  color: const Color(0xFF112233),
                  child: PluginView(
                    tree: {
                      'key': rootKey,
                      't': 'box',
                      'child': {'t': 'text', 'v': v},
                    },
                    onEvent: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(app('歌A', 'A的歌词'));
    expect(find.text('A的歌词'), findsOneWidget);

    // 切歌：root key 变化，AnimatedSwitcher 过渡期旧树淡出、新树淡入
    await tester.pumpWidget(app('歌B', 'B的歌词'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(
          find.text('A的歌词').evaluate().isNotEmpty ||
              find.text('B的歌词').evaluate().isNotEmpty,
          isTrue,
          reason: '整卡交叉淡入第 $i 帧没有任何内容（空白帧）');
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('A的歌词'), findsNothing);
    expect(find.text('B的歌词'), findsOneWidget);
  });
}

/// 造一张纯色图片，用来喂图片缓存
Future<ui.Image> _solidImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.red);
  return recorder.endRecording().toImage(w, h);
}