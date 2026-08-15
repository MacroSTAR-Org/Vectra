/// 一张磁贴的外观。扁平：不透明纯色 + 圆角，**没有阴影**。
///
/// 为什么没有阴影：窗口用 SetWindowRgn 把区域裁成卡片圆角矩形的并集，
/// 区域之外的像素不属于本窗口（这正是点击能穿透到桌面的原因），
/// 而投影恰好落在区域之外，必然被裁掉。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';
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

  /// 底色是否偏亮。决定文字/描边用深色还是浅色，保证可读性：
  ///   - 不透明卡：看卡底色自己（用户选的）
  ///   - 云母卡：底色是固定深蓝灰，文字恒用浅色
  ///   - 亚克力卡：染色越浓卡底色越主导，越淡壁纸越主导；auto 按混合后的
  ///     明暗走，用户显式选了浅色/深色主题则以主题为准（强制翻转）
  bool get _brightBackdrop {
    if (settings.material == 'opaque' || settings.material == 'mica') {
      return Color(settings.cardColor).computeLuminance() > 0.5;
    }
    final tint = settings.glassTint.clamp(0.0, 1.0);
    final cardL = Color(settings.cardColor).computeLuminance();
    final blended = cardL * tint + Wallpaper.brightness.value * (1 - tint);
    final eff = effectiveBrightness(settings);
    if (eff == Brightness.light) return true;
    if (eff == Brightness.dark) return false;
    return blended > 0.5;
  }

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
    // 云母：真 Windows 云母是"带壁纸色相的深色"，不是糊壁纸。用深蓝灰打底
    // （偏冷的色相是高级感的来源，纯中性灰一上墙就显脏），alpha 压低让壁纸
    // 的色调从下面透出来。厚度独立于 glassTint——那是给亚克力调的，
    // 搬过来会让云母要么闷死要么白蒙蒙。
    if (settings.material == 'mica') {
      return const Color(0xFF1C2332).withValues(alpha: 0.45);
    }
    // 亚克力：只铺一层薄薄的染色，让模糊壁纸透上来
    return c.withValues(alpha: settings.glassTint.clamp(0.0, 1.0));
  }

  Color get _topHighlight =>
      _brightBackdrop ? const Color(0x0A000000) : const Color(0x2EFFFFFF);

  @override
  Widget build(BuildContext context) {
    // 壁纸亮度或系统主题一变，卡片文字/描边颜色要跟着翻转。
    // 只在这两个 notifier 变化时重建，平时不额外开销。
    return AnimatedBuilder(
      animation: Listenable.merge([Wallpaper.brightness, systemBrightness]),
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
                    // 云母不糊壁纸：壁纸压到半透明当色调底子，上面再盖深蓝灰。
                    // 亚克力保持全透，那才是"透过玻璃看桌面"。
                    return Opacity(
                      opacity: settings.material == 'mica' ? 0.55 : 1.0,
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
                  if (settings.material == 'mica')
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
