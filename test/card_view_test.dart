/// 卡片外观的可读性回归。
///
/// 这里每一条挡的都是同一类事故：**卡片实际是什么颜色，和文字按什么颜色画，
/// 两者脱节**。用户实测过一次——底色选白 + 材质云母，卡片是深蓝灰的，字却
/// 恒定用黑色，切深浅色也救不回来（云母那条分支压根没走到主题判断）。
///
/// 判据统一取 CardView 包住内容的那层 DefaultTextStyle：它就是插件内容的
/// 默认前景色，深底该给浅字、浅底该给深字。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/theme.dart';
import 'package:vectra/model/card.dart';
import 'package:vectra/model/settings.dart';
import 'package:vectra/ui/card_view.dart';
import 'package:vectra/ui/wallpaper.dart';

void main() {
  const childKey = Key('card-content');

  setUp(() {
    // 壁纸亮度参与云母/亚克力的合成判断，先给个确定值，免得受上一条测试影响
    Wallpaper.brightness.value = 0.5;
    systemBrightness.value = Brightness.dark;
  });

  tearDown(() {
    Wallpaper.brightness.value = 0.5;
    systemBrightness.value = Brightness.dark;
  });

  /// 画一张卡，返回内容拿到的默认前景色
  Future<Color> foregroundOf(
    WidgetTester tester, {
    required String material,
    required int cardColor,
    String theme = 'auto',
    double wallpaperBrightness = 0.5,
  }) async {
    Wallpaper.brightness.value = wallpaperBrightness;
    final settings = AppSettings()
      ..material = material
      ..cardColor = cardColor
      ..theme = theme;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CardView(
          card: WidgetCard(
            id: 'c1',
            pluginId: 'clock',
            x: 0,
            y: 0,
            size: '2x2',
            z: 1,
          ),
          settings: settings,
          width: 200,
          height: 200,
          editing: false,
          child: const SizedBox(key: childKey),
        ),
      ),
    ));
    await tester.pump();

    // 离内容最近的那层 DefaultTextStyle 就是 CardView 设的
    final style = tester.widget<DefaultTextStyle>(find
        .ancestor(of: find.byKey(childKey), matching: find.byType(DefaultTextStyle))
        .first);
    return style.style.color!;
  }

  /// 亮度够高就算"浅色字"。深底配浅字、浅底配深字，中间地带不该出现。
  bool isLight(Color c) => c.computeLuminance() > 0.5;

  /// 文字和它脚下那块底子的对比度（WCAG 相对亮度比，1~21）。
  ///
  /// **这才是这组测试真正的判据**。只断言"白底该给黑字"是抓不到原 Bug 的：
  /// 那条 Bug 的表现恰恰就是"底色填白 -> 给黑字"，断言本身会通过，
  /// 可屏幕上的卡片实际是深蓝灰的，黑字糊在上面根本读不了。
  /// 必须把字和**实际渲染出来的底**放在一起比。
  double contrast(Color fg, Color bg) {
    final a = fg.computeLuminance() + 0.05;
    final b = bg.computeLuminance() + 0.05;
    return a > b ? a / b : b / a;
  }

  /// 画一张卡，返回卡片本体那层实际用的填充色（含 alpha）。
  ///
  /// 卡片本体是带 borderRadius 和 border 的那个 Container——用这两个特征
  /// 把它和壁纸层、编辑框那些 DecoratedBox 区分开。
  Future<Color> fillOf(
    WidgetTester tester, {
    required String material,
    required int cardColor,
    double wallpaperBrightness = 0.5,
  }) async {
    await foregroundOf(tester,
        material: material,
        cardColor: cardColor,
        wallpaperBrightness: wallpaperBrightness);
    final decorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.border != null && d.color != null);
    expect(decorations, isNotEmpty, reason: '应该能找到卡片本体那个 Container');
    return decorations.first.color!;
  }

  /// 用户眼睛真正看到的那块底：半透明的色板叠在壁纸上之后的结果。
  ///
  /// 材质卡的填充是带 alpha 的，光看填充色会得出和屏幕上完全不同的结论。
  Color composited(Color fill, double wallpaperBrightness) {
    final a = fill.a;
    final bg = Color.from(
        alpha: 1,
        red: wallpaperBrightness,
        green: wallpaperBrightness,
        blue: wallpaperBrightness);
    return Color.from(
      alpha: 1,
      red: fill.r * a + bg.r * (1 - a),
      green: fill.g * a + bg.g * (1 - a),
      blue: fill.b * a + bg.b * (1 - a),
    );
  }

  /// 文字必须站在"实际卡面"正确的那一侧：深卡配浅字、浅卡配深字。
  ///
  /// 判据用的是**方向**而不是绝对对比度，因为云母是半透明材质：壁纸够亮时
  /// 深色板上的白字确实会发灰（纯白壁纸下约 2.2:1），要压到 4.5:1 就得把
  /// 板子做到几乎不透明，那这材质就没意义了（详见 card_view 里 _micaAlpha
  /// 的注释，这是明确权衡过的取舍）。
  ///
  /// 但**方向错了**是另一回事，那是纯粹的 Bug：卡面是深的却给黑字，怎么调
  /// 壁纸都读不了。用户报的正是这一种。
  ///
  /// 同时要求文字比"卡面翻到另一侧"更优——即选浅字时，浅字确实比深字更清楚。
  Future<void> expectRightSide(
    WidgetTester tester, {
    required String material,
    required int cardColor,
    String theme = 'auto',
    double wallpaperBrightness = 0.5,
  }) async {
    final fg = await foregroundOf(tester,
        material: material,
        cardColor: cardColor,
        theme: theme,
        wallpaperBrightness: wallpaperBrightness);
    final fill = await fillOf(tester,
        material: material,
        cardColor: cardColor,
        wallpaperBrightness: wallpaperBrightness);
    final bg = composited(fill, wallpaperBrightness);

    final chosen = contrast(fg, bg);
    // 换成相反极性的字色，对比度只会更差——否则就是站错边了
    final opposite = isLight(fg)
        ? const Color(0xFF16181C)
        : const Color(0xFFFFFFFF);
    final alternative = contrast(opposite, bg);

    expect(chosen, greaterThanOrEqualTo(alternative),
        reason: '材质=$material 底色=${cardColor.toRadixString(16)} '
            'theme=$theme 壁纸亮度=$wallpaperBrightness 时文字站错了边：'
            '当前字色($fg)对比度 ${chosen.toStringAsFixed(2)}:1，'
            '换成另一侧能到 ${alternative.toStringAsFixed(2)}:1');
  }

  group('云母', () {
    testWidgets('白色底色：文字必须站在实际卡面正确的一侧（原 Bug：黑字糊在深蓝灰上）',
        (tester) async {
      await expectRightSide(tester, material: 'mica', cardColor: 0xFFFFFFFF);
    });

    testWidgets('白色底色 + 常见壁纸：对比度要真的达标，不只是方向对',
        (tester) async {
      // 浅色板够厚，壁纸从全黑到全白都能稳住 4.5:1。
      // 这条是用户实际报的场景，必须硬性达标，不能只满足于"方向没错"。
      for (final wall in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final fg = await foregroundOf(tester,
            material: 'mica', cardColor: 0xFFFFFFFF, wallpaperBrightness: wall);
        final fill = await fillOf(tester,
            material: 'mica', cardColor: 0xFFFFFFFF, wallpaperBrightness: wall);
        final ratio = contrast(fg, composited(fill, wall));
        expect(ratio, greaterThan(4.5),
            reason: '壁纸亮度 $wall 时白底云母对比度只有 '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });

    testWidgets('深色底色：老用户观感不变，仍是深卡浅字', (tester) async {
      final fg = await foregroundOf(tester,
          material: 'mica', cardColor: 0xFF2A2A2E);
      expect(isLight(fg), isTrue, reason: '深色云母上必须用浅色字');
      await expectRightSide(tester, material: 'mica', cardColor: 0xFF2A2A2E);
    });

    testWidgets('浅色底色下，深浅色主题怎么切都不该站错边',
        (tester) async {
      // 用户实测过：白底云母时切深浅色救不回来。修好之后应该是"怎么切都对"，
      // 而不是"怎么切都错"——云母的明暗由底色定死，主题不该强制翻转。
      for (final theme in ['auto', 'light', 'dark']) {
        await expectRightSide(tester,
            material: 'mica', cardColor: 0xFFFFFFFF, theme: theme);
      }
    });

    testWidgets('深色底色下，深浅色主题怎么切都不该站错边', (tester) async {
      for (final theme in ['auto', 'light', 'dark']) {
        await expectRightSide(tester,
            material: 'mica', cardColor: 0xFF2A2A2E, theme: theme);
      }
    });

    testWidgets('壁纸从全黑到全白，两种底色的文字都不该站错边', (tester) async {
      for (final wall in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        await expectRightSide(tester,
            material: 'mica', cardColor: 0xFFFFFFFF, wallpaperBrightness: wall);
        await expectRightSide(tester,
            material: 'mica', cardColor: 0xFF2A2A2E, wallpaperBrightness: wall);
      }
    });

    testWidgets('底色的色相真的会影响云母（这个设置以前在云母下完全没用）',
        (tester) async {
      // 取两个明暗相近、色相相反的底色，卡片的填充色应当跟着变。
      // 以前云母写死成 0xFF1C2332，这两个会渲染成一模一样的颜色。
      final blue = await fillOf(tester, material: 'mica', cardColor: 0xFF1C2332);
      final red = await fillOf(tester, material: 'mica', cardColor: 0xFF33201C);
      expect(blue, isNot(equals(red)),
          reason: '底色换了色相，云母板子的颜色就该跟着换');
    });

    testWidgets('白底云母确实画成浅色板，而不只是把字改深', (tester) async {
      final fill = await fillOf(tester, material: 'mica', cardColor: 0xFFFFFFFF);
      expect(fill.a, greaterThan(0.5),
          reason: '浅色板要够厚，否则深壁纸会把它拖成灰的');
      expect(Color.from(alpha: 1, red: fill.r, green: fill.g, blue: fill.b)
              .computeLuminance(),
          greaterThan(0.5),
          reason: '白底选出来的云母板本身就该是浅色的');
    });
  });

  group('毛玻璃', () {
    // 这一组是用户实测报的第二个同类事故：深壁纸 + 毛玻璃 + 系统浅色，
    // 卡片明明是深的，字却按"主题是浅色"画成黑色，糊在一起看不见。
    // 云母那条分支上次修过了，毛玻璃这条当时漏了——因为压根没有测试覆盖。

    testWidgets('深壁纸：无论主题怎么设，都必须给浅色字', (tester) async {
      // theme 三种取值全试一遍。卡片是明是暗由壁纸和材质决定，
      // 跟用户希望界面是明是暗没有因果关系。
      for (final theme in ['auto', 'light', 'dark']) {
        for (final sys in [Brightness.light, Brightness.dark]) {
          systemBrightness.value = sys;
          final fg = await foregroundOf(tester,
              material: 'acrylic',
              cardColor: 0xFF1C2332,
              theme: theme,
              wallpaperBrightness: 0.08);
          expect(isLight(fg), isTrue,
              reason: 'theme=$theme 系统=$sys 时深壁纸上的毛玻璃给了深色字，'
                  '字会直接糊进背景里看不见');
        }
      }
    });

    testWidgets('亮壁纸：无论主题怎么设，都必须给深色字', (tester) async {
      for (final theme in ['auto', 'light', 'dark']) {
        for (final sys in [Brightness.light, Brightness.dark]) {
          systemBrightness.value = sys;
          final fg = await foregroundOf(tester,
              material: 'acrylic',
              cardColor: 0xFFF2F3F5,
              theme: theme,
              wallpaperBrightness: 0.95);
          expect(isLight(fg), isFalse,
              reason: 'theme=$theme 系统=$sys 时亮壁纸上的毛玻璃给了浅色字');
        }
      }
    });

    testWidgets('壁纸从全黑扫到全白，文字始终站在实际卡面正确的一侧',
        (tester) async {
      for (final wall in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]) {
        await expectRightSide(tester,
            material: 'acrylic',
            cardColor: 0xFF1C2332,
            wallpaperBrightness: wall);
      }
    });

    testWidgets('染色越浓，卡片底色的话语权越大', (tester) async {
      // glassTint 是那层染色的不透明度，也就是混合权重：
      // 调到 1 时壁纸完全不参与，白底就该判成浅底给深字，哪怕壁纸全黑。
      Wallpaper.brightness.value = 0.0;
      final settings = AppSettings()
        ..material = 'acrylic'
        ..cardColor = 0xFFFFFFFF
        ..glassTint = 1.0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CardView(
            card: WidgetCard(
                id: 'c1', pluginId: 'clock', x: 0, y: 0, size: '2x2', z: 1),
            settings: settings,
            width: 200,
            height: 200,
            editing: false,
            child: const SizedBox(key: childKey),
          ),
        ),
      ));
      await tester.pump();

      final style = tester.widget<DefaultTextStyle>(find
          .ancestor(
              of: find.byKey(childKey), matching: find.byType(DefaultTextStyle))
          .first);
      expect(isLight(style.style.color!), isFalse,
          reason: '染色拉满时壁纸透不上来，白色染色就是最终卡面，该给深色字');
    });
  });

  group('不透明', () {
    testWidgets('白底给深色字', (tester) async {
      final fg = await foregroundOf(tester,
          material: 'opaque', cardColor: 0xFFFFFFFF);
      expect(isLight(fg), isFalse);
    });

    testWidgets('深底给浅色字', (tester) async {
      final fg = await foregroundOf(tester,
          material: 'opaque', cardColor: 0xFF2A2A2E);
      expect(isLight(fg), isTrue);
    });
  });
}
