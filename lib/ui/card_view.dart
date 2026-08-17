/// 一张磁贴的外观。扁平：不透明纯色 + 圆角，**没有阴影**。
///
/// 为什么没有阴影：窗口用 SetWindowRgn 把区域裁成卡片圆角矩形的并集，
/// 区域之外的像素不属于本窗口（这正是点击能穿透到桌面的原因），
/// 而投影恰好落在区域之外，必然被裁掉。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/card.dart';
import '../model/settings.dart';
import 'wallpaper.dart';

class CardView extends StatelessWidget {
  const CardView({
    super.key,
    required this.card,
    required this.settings,
    required this.width,
    required this.height,
    required this.editing,
    required this.child,
  });

  final WidgetCard card;
  final AppSettings settings;
  final double width;
  final double height;
  final bool editing;
  final Widget child;

  /// 底色是否偏亮。决定文字/描边用深色还是浅色，保证可读性。
  ///
  /// **一律看卡片实际贴在屏幕上的颜色，不看主题设置。** 三种材质各自的算法
  /// 不同，但结论都来自"最终合成结果"：
  ///   - 不透明卡：卡底色自己就是最终颜色，壁纸完全被盖住
  ///   - 云母卡：色板 @ alpha 叠在壁纸上的合成结果
  ///   - 亚克力/毛玻璃卡：染色越浓卡底色越主导，越淡壁纸越主导
  ///
  /// 为什么主题（浅色/深色/跟随系统）不参与：主题描述的是"用户希望界面
  /// 是明是暗"，而这里要回答的是"这张卡片现在到底是明是暗"——后者由壁纸和
  /// 材质决定，跟前者没有因果关系。让主题强制翻转的后果是自相矛盾：
  /// 深壁纸 + 毛玻璃 + 系统浅色，卡片明明是深的，字却按浅底规则画成黑色，
  /// 直接糊在一起看不见（云母那条分支上次已经修过，毛玻璃这条漏了）。
  ///
  /// 主题设置仍然管着设置窗口和 AI 侧边栏的明暗，只是不再插手卡片。
  bool get _brightBackdrop {
    if (settings.material == 'opaque') {
      return Color(settings.cardColor).computeLuminance() > 0.5;
    }
    if (settings.material == 'mica') {
      // 云母必须看合成之后的颜色，不能直接看 cardColor —— 这正是
      // "白底 + 云母 = 永远黑字看不清" 的根因：底色只决定色板的色相和明暗
      // 档位，真正贴在屏幕上的是"色板 @ alpha 叠在壁纸上"的结果。
      final a = _micaAlpha;
      final composite = _micaBase.computeLuminance() * a +
          Wallpaper.brightness.value * (1 - a);
      return composite > 0.5;
    }
    // 亚克力/毛玻璃：染色是薄薄一层，剩下的全是模糊壁纸透上来的。
    // glassTint 就是这层染色的不透明度，正好当混合权重用。
    final tint = settings.glassTint.clamp(0.0, 1.0);
    final cardL = Color(settings.cardColor).computeLuminance();
    final blended = cardL * tint + Wallpaper.brightness.value * (1 - tint);
    return blended > 0.5;
  }

  /// 云母色板的色相来源：用户选的卡片底色。
  ///
  /// 真 Windows 云母是"带壁纸色相的一层薄色板"，不是把壁纸糊掉。这里让用户
  /// 的底色决定这层板子长什么样，但要做两件加工：
  ///
  ///   1. **明度压到两极**。中间调的半透明板子上深字浅字都读不清，所以浅色
  ///      底走 0.78~0.94、深色底走 0.10~0.22。真 Windows 云母同样只有浅色/
  ///      深色两个变体，没有中间态——这不是偷懒，是这材质本来的设计。
  ///   2. **饱和度压到 0.3 以内**。云母是安静的材质，用户挑了个饱和大红时，
  ///      不该真在墙上糊一块红板子，只取它的色相倾向。
  ///
  /// 底色本身没有饱和度时（纯白/纯灰/纯黑）补一点冷色：纯中性灰一上墙就显脏，
  /// 偏冷的色相才是这材质高级感的来源。色相取 221°，正是改版前那个写死的
  /// 0xFF1C2332 的色相，深色底的观感因此和以前保持一致。
  Color get _micaBase {
    final hsl = HSLColor.fromColor(Color(settings.cardColor));
    final neutral = hsl.saturation < 0.02;
    final hue = neutral ? 221.0 : hsl.hue;
    final sat = neutral ? 0.08 : hsl.saturation.clamp(0.0, 0.30);
    final l = hsl.lightness > 0.5
        ? 0.78 + (hsl.lightness - 0.5) / 0.5 * 0.16
        : 0.10 + hsl.lightness / 0.5 * 0.12;
    return HSLColor.fromAHSL(1, hue, sat, l).toColor();
  }

  /// 云母色板的厚度。
  ///
  /// 深色板保持 0.45 —— 改版前就是这个值，老用户的观感一点不变。
  /// 浅色板要厚到 0.70：同样的透明度下，深壁纸会把浅板子拖成灰扑扑的中间调，
  /// 用户选了白色却得到一块灰板，等于这个设置又白设了一次。
  ///
  /// 这两档都是"保材质"的选择，不是"保对比度"的选择。云母本来就是半透明的，
  /// 壁纸足够亮时深色板上的白字确实会发灰（实测纯白壁纸下约 2.2:1）。要让
  /// 它在任何壁纸下都达到 4.5:1，深色板得厚到 0.85 以上——那时壁纸几乎透不
  /// 上来，云母就退化成一张不透明深色卡，这个材质也就没有存在意义了。
  /// 权衡之后选择保质感：真正致命的是"卡面明明是深的、字却按浅底规则画成黑色"
  /// 那种自相矛盾（本次修的就是它），而不是半透明材质固有的对比度衰减。
  ///
  /// 厚度独立于 glassTint —— 那是给亚克力调的，搬过来会让云母要么闷死
  /// 要么白蒙蒙。
  double get _micaAlpha =>
      HSLColor.fromColor(Color(settings.cardColor)).lightness > 0.5 ? 0.70 : 0.45;

  /// 边框与内高光的取色随底色明暗自动翻转：浅色卡片上白色高光是看不见的
  Color get _edge =>
      _brightBackdrop ? const Color(0x14000000) : const Color(0x1FFFFFFF);

  /// 卡片内容的默认前景色：深色底用白字，浅色底用黑字
  Color get _foreground =>
      _brightBackdrop ? const Color(0xFF16181C) : const Color(0xFFFFFFFF);

  /// 卡片填充色。
  ///
  /// 不透明模式：直接用设置里的底色。
  /// 材质模式：只铺一层薄薄的染色，让 DWM 的模糊透上来。亚克力本身对比度低，
  /// 完全不铺一层的话文字会糊在背景里读不清，所以留一点点。
  Color get _fill {
    final c = Color(settings.cardColor);
    if (settings.material == 'opaque') return c;
    // 云母：一层由用户底色推导出来的薄色板，alpha 压低让壁纸的色调从下面
    // 透出来（推导规则见 _micaBase / _micaAlpha）。
    //
    // 这里以前写死成 0xFF1C2332，导致"卡片底色"这个设置在云母下完全是个
    // 摆设——用户调了没反应，配上白底还会触发黑字看不清。
    if (settings.material == 'mica') {
      return _micaBase.withValues(alpha: _micaAlpha);
    }
    // 亚克力：只铺一层薄薄的染色，让模糊壁纸透上来
    return c.withValues(alpha: settings.glassTint.clamp(0.0, 1.0));
  }

  Color get _topHighlight =>
      _brightBackdrop ? const Color(0x0A000000) : const Color(0x2EFFFFFF);

  @override
  Widget build(BuildContext context) {
    // 壁纸亮度一变，卡片文字/描边颜色要跟着翻转。
    //
    // 这里**不再**监听 systemBrightness：卡片明暗只由壁纸和材质决定，
    // 系统深浅色切换不该让卡片重建（见 _brightBackdrop 的说明）。
    return AnimatedBuilder(
      animation: Wallpaper.brightness,
      builder: (context, _) => SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
          // 毛玻璃：把预先模糊好的壁纸按本卡片的屏幕位置反向偏移贴上，
          // 再由外层 ClipRRect 裁成卡片形状 —— 看起来就是"透过卡片看到
          // 被磨砂的壁纸"。壁纸是静态的，所以这里每帧只是一次普通贴图。
          if (settings.material != 'opaque')
            ClipRRect(
              borderRadius: BorderRadius.circular(settings.cardRadius),
              child: SizedBox(
                width: width,
                height: height,
                child: ValueListenableBuilder<ui.Image?>(
                  valueListenable: Wallpaper.image,
                  builder: (context, img, _) {
                    if (img == null) return const SizedBox.shrink();
                    final s = 1 / Wallpaper.scale;
                    final w = RawImage(
                      image: img,
                      width: img.width * s,
                      height: img.height * s,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.low,
                    );
                    // 云母不糊壁纸：壁纸压到半透明当色调底子，上面再盖那层色板。
                    // 亚克力保持全透，那才是"透过玻璃看桌面"。
                    //
                    // 透出强度跟着色板厚度走：色板越厚，下面这层露出来的越少，
                    // 留太多只是白白把浅色板拖灰。
                    return Opacity(
                      opacity: settings.material == 'mica'
                          ? (1 - _micaAlpha).clamp(0.30, 0.55)
                          : 1.0,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        maxWidth: double.infinity,
                        maxHeight: double.infinity,
                        child: Transform.translate(
                          offset: Offset(-card.x, -card.y),
                          child: w,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          // 卡片本体
          ClipRRect(
            borderRadius: BorderRadius.circular(settings.cardRadius),
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                // 毛玻璃模式下底色只是一层染色，模糊的壁纸在它下面
                color: _fill,
                // 一条极淡的顶部内高光 + 整圈细边框。
                // 这不是阴影：阴影要画在卡片外面，而窗口区域正好裁在卡片边界上，
                // 画了也会被切掉。内高光和边框都在卡片内部，纯扁平手法，
                // 靠明暗过渡让边缘"立"起来。
                border: Border.all(color: _edge, width: 1),
                borderRadius: BorderRadius.circular(settings.cardRadius),
              ),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -16,
                    height: 1,
                    child: IgnorePointer(
                      child: ColoredBox(color: _topHighlight),
                    ),
                  ),
                  // 云母独有的顶部渐变：真 mica 表面就是上面微亮、往下沉。
                  // 一小条冷白渐变，让"深色板子"不显得死板。
                  //
                  // 只画在深色板上：浅色板本来就亮，再盖一层白只会把顶部糊平，
                  // 那条"上亮下沉"的层次反而没了。浅色板的顶边交给
                  // _topHighlight（它会翻成淡黑）去交代。
                  if (settings.material == 'mica' && !_brightBackdrop)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(settings.cardRadius),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0x14FFFFFF),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.35],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: DefaultTextStyle(
                      style: TextStyle(
                        color: _foreground,
                        fontSize: 13,
                        // 这里的 DefaultTextStyle 是替换式的（不带 merge），会把
                        // 主题里传下来的 fontFamily 冲掉，必须显式带上全局字体
                        fontFamily: 'HarmonyOS Sans SC',
                        decoration: TextDecoration.none,
                      ),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 编辑模式的边框提示。不做抖动动画——那属于"特效"。
          if (editing)
            IgnorePointer(
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(settings.cardRadius),
                  border: Border.all(color: const Color(0x66FFFFFF), width: 2),
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}
