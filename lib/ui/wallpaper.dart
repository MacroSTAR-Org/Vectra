/// 卡片背后那层模糊的来源。
///
/// 为什么不用系统的亚克力/云母：两者都按**整个窗口矩形**绘制，不受
/// SetWindowRgn 裁剪。我们的窗口覆盖整个虚拟屏幕，开了之后整个桌面会被糊掉
/// （DWMWA_SYSTEMBACKDROP_TYPE 是灰的，SetWindowCompositionAttribute 的
/// 亚克力是黑的），实测两条都不行。
///
/// 来源优先读**壁纸文件**（注册表 → TranscodedWallpaper 缓存）：Mica 语义
/// 上"壁纸"就该是那张图本身。以前优先抓桌面窗口（PrintWindow Progman），
/// 实测会把**桌面图标一起拍进来**——图标层画在 Progman 里，模糊之后设置
/// 窗口的背景上就浮着一排彩色图标鬼影。读不到文件时才退回抓屏（Wallpaper
/// Engine 这类动态壁纸也会把当前壁纸写进注册表，一般都能覆盖到；抓屏只
/// 适合最后兜底，代价是图标一起被拍进来）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import '../core/logger.dart';
import '../core/paths.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ColorScheme, MemoryImage, Brightness;
import 'package:path/path.dart' as p;

import '../native/native_bridge.dart';

class Wallpaper {
  /// 预模糊后的图，尺寸为屏幕逻辑尺寸的 [scale] 倍
  static final ValueNotifier<ui.Image?> image = ValueNotifier(null);

  /// 相对屏幕逻辑尺寸的缩放。模糊本来就丢细节，半分辨率足够，且省一半显存。
  ///
  /// 0.4：模糊 sigma 在 _blur 里也乘这个系数（sigma * scale），图缩了模糊
  /// 半径跟着缩，观感上"糊的程度"几乎不变，但抓屏/回读/纹理这几块的开销
  /// 按平方降（0.4²/0.5² = 64%）。2560x1440 下位图从 3.7MB 降到 2.4MB。
  static const double scale = 0.4;

  /// 最近一次是走捕获还是读文件，面板里显示给用户看
  static final ValueNotifier<String> source = ValueNotifier('未加载');

  static bool _busy = false;
  static Timer? _timer;

  /// 循环代际。stop() 只把 _looping 置 false 是不够的：旧循环挂在 await 上，
  /// 新循环把标志置回 true 之后它会复活，于是多个循环并存、互相撞 _busy 守卫
  /// 直接返回，帧耗时被记成 0-4ms，测量结果整个失真。
  /// 每次启动换一个代际号，旧循环发现代际变了就退出。
  static int _generation = 0;

  /// 最近一次刷新的耗时，面板里显示实测帧时间
  static final ValueNotifier<int> lastFrameMs = ValueNotifier(0);

  /// 整图平均亮度（0..1，Rec.709 加权）。玻璃卡片的文字颜色按它翻转，
  /// 亮壁纸用深字、暗壁纸用浅字，保证可读性。
  static final ValueNotifier<double> brightness = ValueNotifier(0.5);

  /// 从壁纸算出来的代表色（"莫奈取色"）。算法跟 Android 12 Material You
  /// 同源——Flutter 的 `ColorScheme.fromImageProvider` 内部就是用
  /// material_color_utilities 对图片做量化取色，不是另起一套。
  /// null 表示还没算出来（刚启动、或者这次刷新取色失败），用的人自己兜底。
  static final ValueNotifier<Color?> dominantColor = ValueNotifier(null);

  /// 配 [dominantColor] 用的前景色（对应 Material You 的 onPrimary）：
  /// 算法已经保证跟 [dominantColor] 有足够对比度，不用再另外套
  /// "亮底黑字/暗底白字"那套二选一的老逻辑。同样是 null-until-computed。
  static final ValueNotifier<Color?> dominantForeground = ValueNotifier(null);

  /// 取色给出的候选色（primary / secondary / tertiary / container / tint）。
  ///
  /// Material You 算出来的是一个**配色方案**而不是唯一正确答案，哪个更合
  /// 眼缘因壁纸而异。与其我们替用户定，不如摆到面板上让他挑。
  static final ValueNotifier<List<Color>> palette =
      ValueNotifier(const <Color>[]);

  // ---- 取色结果缓存 ----
  //
  // 取色（ColorScheme.fromImageProvider）是整条壁纸链路里最贵的一步，
  // 而绝大多数启动里壁纸根本没换。按缩略图的**像素指纹**缓存：指纹一致就
  // 直接用上次的颜色，跳过 PNG 编码与 Material You 量化（那两步才是
  // "打开开关要等十几秒"的主因）。
  static const String _cacheFileName = 'wallpaper_color.json';
  static String? _cacheFingerprint;
  static Map<String, Object?>? _cache;
  static bool _cacheLoaded = false;

  static File get _cacheFile => File(p.join(AppPaths.root, _cacheFileName));

  /// 缩略图像素指纹：按固定步长采样若干个点。
  /// 壁纸换了必然变，而缩放/模糊造成的细微差异不会误判成"换了"。
  static String _fingerprintOf(ByteData data) {
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final n = bytes.length;
    if (n < 64) return '';
    final step = (n ~/ 256) * 4;
    if (step <= 0) return '';
    var h = 17;
    for (var i = 0; i + 3 < n; i += step) {
      h = (h * 31 + bytes[i]) & 0x7fffffff;
      h = (h * 31 + bytes[i + 1]) & 0x7fffffff;
      h = (h * 31 + bytes[i + 2]) & 0x7fffffff;
    }
    return '$n-$h';
  }

  static void _ensureCacheLoaded() {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final f = _cacheFile;
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map<String, dynamic>) {
        _cacheFingerprint = j['fp'] as String?;
        _cache = j;
      }
    } catch (e) {
      Log.w('wallpaper', '取色缓存读取失败: $e');
    }
  }

  /// 指纹命中：把缓存里的颜色（含候选色）直接贴回来。
  static void _applyCached() {
    final c = _cache;
    if (c == null) return;
    final p1 = c['primary'];
    if (p1 is int) dominantColor.value = Color(p1);
    final fg = c['fg'];
    if (fg is int) dominantForeground.value = Color(fg);
    final pal = c['palette'];
    if (pal is List) {
      palette.value = [
        for (final v in pal)
          if (v is int) Color(v),
      ];
    }
  }

  static void _saveCache(String fingerprint) {
    _cacheFingerprint = fingerprint;
    final data = <String, Object?>{
      'fp': fingerprint,
      'primary': dominantColor.value?.toARGB32(),
      'fg': dominantForeground.value?.toARGB32(),
      'palette': [for (final c in palette.value) c.toARGB32()],
    };
    _cache = data;
    try {
      _cacheFile.writeAsStringSync(jsonEncode(data));
    } catch (e) {
      Log.w('wallpaper', '取色缓存写入失败: $e');
    }
  }

  /// 要不要算"莫奈取色"。由 app_root 按两个开关（卡片底色取色 / 前景色
  /// 取色）的并集设置。
  ///
  /// 这是整条刷新链路上最贵的一环——量化 + 构建整套 ColorScheme，而两个
  /// 开关都关着时算出来的颜色根本没人读。以前是无条件算的（注释还写着
  /// "常驻算不影响性能"，那是想当然），动态壁纸下等于每帧白烧一遍。
  static bool colorExtraction = false;

  /// 分段耗时，用于定位瓶颈
  static int lastCaptureMs = 0;
  static int lastBlurMs = 0;

  /// 加载一次。
  ///
  /// [sigma] 模糊强度。
  /// [saturation] 饱和度，1 = 原样，0 = 完全灰。云母材质靠它做出"褪色的
  /// 壁纸"那种质感——真正的 Windows 云母也是把壁纸去色再压暗。
  static Future<void> refresh(ui.Size screenLogical,
      {double sigma = 18, double saturation = 1.0}) async {
    if (_busy) return;
    _busy = true;
    // 声明在 try 外面：catch 里的兜底 dispose 要够得着它
    ui.Image? src;
    try {
      final w0 = (screenLogical.width * scale).round();
      final h0 = (screenLogical.height * scale).round();
      // 模糊输入的长边上限。模糊本身会抹掉细节，sigma 18+ 时 768 长边的
      // 输入和全分辨率肉眼无差，但位图从 2.4MB/帧降到 ~1.3MB——动态壁纸
      // 按 10fps 刷新时这是每秒十几 MB 的 GC churn 差距。
      const kMaxBlurEdge = 768.0;
      var w = w0, h = h0;
      final longest = w > h ? w : h;
      if (longest > kMaxBlurEdge) {
        final k = kMaxBlurEdge / longest;
        w = (w * k).round();
        h = (h * k).round();
      }
      if (w <= 0 || h <= 0) return;

      final swCap = Stopwatch()..start();
      var from = '壁纸文件';
      src = await _decodeWallpaperFile(w);
      if (src == null) {
        from = '桌面捕获';
        src = await _captureDesktop(w, h);
      }
      swCap.stop();
      lastCaptureMs = swCap.elapsedMilliseconds;
      if (src == null) {
        source.value = '失败：既抓不到桌面，也读不到壁纸文件';
        // 两条路都走不通是反常的——要么 DWM 出了问题，要么壁纸文件被删了。
        // 用户看到的是"卡片没有毛玻璃"，而我们只靠这条日志知道发生了什么。
        Log.e('wallpaper', '桌面捕获与壁纸文件都失败');
        return;
      }

      final swBlur = Stopwatch()..start();
      final blurred = await _blur(src, w, h, sigma, saturation);
      swBlur.stop();
      lastBlurMs = swBlur.elapsedMilliseconds;
      // 源位图用完即弃。不能放在 _blur 之后顺队写：_blur 一抛异常这行
      // 就跳过了，动态壁纸下每秒 2.4MB 的位图会一直攒着——所以这里有
      // 兜底 dispose（正常路径已 dispose 过，二次 dispose 是安全的空操作）
      src.dispose();

      image.value?.dispose();
      image.value = blurred;
      source.value = from;
      await _updateDerived(blurred);
      // 动态壁纸下这条会按刷新间隔反复打，归 debug：默认级别看不到，
      // 需要时用 --verbose 打开
      Log.d('wallpaper', '来源=$from '
          '尺寸=${blurred.width}x${blurred.height} '
          '(抓取${lastCaptureMs}ms 模糊${lastBlurMs}ms)');
    } catch (e) {
      Log.w('wallpaper', '刷新失败: $e');
      // 异常路径兜底：捕获/解码出来的源位图不能跟着异常一起漏掉
      try {
        src?.dispose();
      } catch (_) {}
    } finally {
      _busy = false;
    }
  }

  /// 缩略图的长边。112 不是随手取的：`ColorScheme.fromImageProvider` 内部
  /// 第一步就是把图缩到长边 112 再量化，这里对齐它。
  ///
  /// 实测过等价性（同一张图走"全图编码"和"先缩再编码"两条路）：结果不是
  /// 逐位相同，但只差 1/255——#425E91 vs #435E91，红通道 66 vs 67。缩放
  /// 滤镜不完全一致，量化落桶时偶尔差一格，视觉上分辨不出来。
  static const int _thumbSide = 112;

  /// 亮度统计和莫奈取色都从同一张缩略图上算。
  ///
  /// 这两件事以前各自回读一次**全分辨率**图：亮度走 `toByteData()`
  /// （1280x720 就是 3.7MB 的 GPU→CPU 回读），取色更浪费——先把整张图
  /// PNG 编码一遍再让 `MemoryImage` 解码回来，而 fromImageProvider 拿到
  /// 之后第一件事就是缩到 112，前面那一整轮编解码全是白干的。
  ///
  /// 两者要的都只是"整体色彩分布"，全分辨率没有意义。现在缩一次、回读
  /// 一次，两边共用：回读量从 3.7MB 降到几十 KB，全图 PNG 编解码整个消失。
  static Future<void> _updateDerived(ui.Image src) async {
    ui.Image? thumb;
    try {
      thumb = await _thumbnail(src, _thumbSide);
      final data = await thumb.toByteData();
      if (data != null) brightness.value = _avgBrightness(data);
      // 两个取色开关都关着时，算出来的颜色没有任何人读，直接省掉整段
      if (colorExtraction) {
        _ensureCacheLoaded();
        // 指纹复用上面那次 toByteData 回读，不额外花开销
        final fp = data == null ? null : _fingerprintOf(data);
        if (fp != null && fp.isNotEmpty && fp == _cacheFingerprint) {
          _applyCached();
          Log.i('wallpaper', '取色命中缓存（壁纸未换）→ '
              '#${(dominantColor.value?.toARGB32() ?? 0).toRadixString(16).padLeft(8, '0')}');
        } else {
          try {
            await _updateDominantColor(thumb);
            if (fp != null && fp.isNotEmpty) _saveCache(fp);
          } catch (e) {
            Log.w('wallpaper', '取色抛异常: $e');
          }
        }
      } else {
        Log.i('wallpaper', '取色跳过（两个开关都关着）');
      }
    } catch (e) {
      Log.w('wallpaper', '派生数据计算失败: $e');
    } finally {
      thumb?.dispose();
    }
  }

  /// 按长边缩到 [maxSide]，保持宽高比。源图本来就更小时原样复制一份，
  /// 不做放大（放大既没信息量又浪费）。
  static Future<ui.Image> _thumbnail(ui.Image src, int maxSide) async {
    final longest = src.width > src.height ? src.width : src.height;
    final scale = longest <= maxSide ? 1.0 : maxSide / longest;
    final w = (src.width * scale).round().clamp(1, maxSide);
    final h = (src.height * scale).round().clamp(1, maxSide);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    picture.dispose();
    return out;
  }

  /// "莫奈取色"：从缩略图里算一个代表色，写进 [dominantColor]。
  ///
  /// `ColorScheme.fromImageProvider` 只吃 `ImageProvider`，不吃现成的
  /// `ui.Image`，所以仍要编码一次 PNG 包成 `MemoryImage`——但传进来的
  /// 已经是 112 像素的缩略图，这次编解码的量可以忽略。取色失败（比如
  /// 极端尺寸/全透明图）就保留旧值，不拿 null 覆盖一个原本能用的颜色。
  static Future<void> _updateDominantColor(ui.Image img) async {
    try {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      // 【通透】取色的明暗跟着壁纸走，不再写死 light。
      //
      // ColorScheme 的 primary 是"配在某种底色上好看"的角色色：light 方案给
      // **深色** primary（配白底用），dark 方案给**亮色** primary。而卡片底色
      // 通常偏深（用户手选的多是深灰），套 light 的深色 primary 就是"深上加
      // 深"，看着闷、不透。按壁纸平均亮度选方案，深壁纸就能取到亮一点的色。
      final scheme = await ColorScheme.fromImageProvider(
        provider: MemoryImage(bytes.buffer.asUint8List()),
        brightness:
            brightness.value < 0.45 ? Brightness.dark : Brightness.light,
      );
      dominantColor.value = scheme.primary;
      dominantForeground.value = scheme.onPrimary;
      // 候选色摆到面板上让用户挑
      palette.value = <Color>[
        scheme.primary,
        scheme.secondary,
        scheme.tertiary,
        scheme.primaryContainer,
        scheme.surfaceTint,
      ];
    } catch (e) {
      Log.w('wallpaper', '取色失败: $e');
    }
  }

  /// 按间隔持续刷新（动态壁纸用）。[ms] 为 0 时只刷一次。
  ///
  /// 用自调度循环而不是 Timer.periodic：抓一帧 + 模糊的耗时可能超过间隔，
  /// periodic 会让回调不断堆积。这里永远是"画完上一帧再排下一帧"，
  /// 达不到目标帧率时自动降速，而不是越积越多。
  static void startAutoRefresh(ui.Size screenLogical,
      {required int ms, required double sigma, double saturation = 1.0}) {
    stop();
    if (ms <= 0) {
      refresh(screenLogical, sigma: sigma, saturation: saturation);
      return;
    }
    final gen = ++_generation;
    Future<void> loop() async {
      var frames = 0;
      var totalMs = 0;
      final wall = Stopwatch()..start();
      while (gen == _generation) {
        final sw = Stopwatch()..start();
        await refresh(screenLogical, sigma: sigma, saturation: saturation);
        sw.stop();
        lastFrameMs.value = sw.elapsedMilliseconds;
        frames++;
        totalMs += sw.elapsedMilliseconds;
        if (frames % 60 == 0) {
          final fps = frames * 1000 / wall.elapsedMilliseconds;
          Log.d('wallpaper', '目标 ${ms}ms  实测 '
              '${(totalMs / frames).toStringAsFixed(1)}ms/帧  '
              '实际 ${fps.toStringAsFixed(1)} fps  '
              '(抓取 ${lastCaptureMs}ms / 模糊 ${lastBlurMs}ms)');
        }
        final rest = ms - sw.elapsedMilliseconds;
        await Future<void>.delayed(
            Duration(milliseconds: rest > 0 ? rest : 0));
      }
    }

    loop();
  }

  static void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  // ------------------------------------------------------------------

  static Future<ui.Image?> _captureDesktop(int w, int h) async {
    try {
      final bytes = await NativeBridge.captureDesktop(w, h);
      if (bytes == null || bytes.length != w * h * 4) return null;

      // alpha 由 C++ 侧填好了：高刷新率下在这里再拷一遍并遍历 1.6MB 是纯浪费。
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          bytes, w, h, ui.PixelFormat.bgra8888, completer.complete);
      return await completer.future;
    } catch (e) {
      Log.w('wallpaper', '桌面捕获失败: $e');
      return null;
    }
  }

  static Future<ui.Image?> _decodeWallpaperFile(int targetWidth) async {
    final path = await _wallpaperPath();
    if (path == null) return null;
    try {
      final bytes = await File(path).readAsBytes();
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _wallpaperPath() async {
    try {
      final r = await Process.run(
          'reg', ['query', r'HKCU\Control Panel\Desktop', '/v', 'WallPaper']);
      final m = RegExp(r'WallPaper\s+REG_SZ\s+(.+)')
          .firstMatch(r.stdout.toString());
      final path = m?.group(1)?.trim();
      if (path != null && path.isNotEmpty && await File(path).exists()) {
        return path;
      }
    } catch (_) {}

    // 幻灯片/裁剪模式下注册表里的路径可能不存在，Windows 会把当前实际使用的
    // 那张缓存成这个无扩展名的文件（内容其实是 JPEG）
    final appData = Platform.environment['APPDATA'];
    if (appData != null) {
      final cached = File(p.join(
          appData, 'Microsoft', 'Windows', 'Themes', 'TranscodedWallpaper'));
      if (await cached.exists()) return cached.path;
    }
    return null;
  }

  /// 饱和度矩阵。s=1 原样，s=0 全灰。
  /// 亮度权重用 Rec.709，和人眼感知一致——直接三分之一平均会让红色发暗。
  static List<double> _saturationMatrix(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final r = (1 - s) * lr, g = (1 - s) * lg, b = (1 - s) * lb;
    return <double>[
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// 把模糊（和可选的去饱和）一次性烘焙进离屏图，之后每帧只是普通贴图
  static Future<ui.Image> _blur(
      ui.Image src, int w, int h, double sigma, double saturation) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma * scale,
          sigmaY: sigma * scale,
          tileMode: ui.TileMode.clamp);
    if (saturation < 0.999) {
      paint.colorFilter = ui.ColorFilter.matrix(_saturationMatrix(saturation));
    }

    // 按 cover 铺满，避免源图比例与屏幕不一致时留边
    final sw = src.width.toDouble(), sh = src.height.toDouble();
    final s = (w / sw) > (h / sh) ? (w / sw) : (h / sh);
    final dw = sw * s, dh = sh * s;
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, sw, sh),
      ui.Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
      paint,
    );

    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    picture.dispose();
    return out;
  }

  /// 平均亮度（Rec.709 加权）。传进来的是 [_updateDerived] 已经回读好的
  /// 缩略图像素，这里不再自己回读全图。
  ///
  /// 结果**量化到 0.01**。这个值只用来判断"底子是明是暗"以及当一个混合
  /// 权重，千分位的抖动没有任何视觉意义；但它是个 ValueNotifier，值一变
  /// 就通知，而 card_view 的 AnimatedBuilder 监听着它——动态壁纸下每帧
  /// 那点浮动会让**所有卡片**跟着重建一次。量化之后绝大多数帧和上一帧
  /// 完全相同，ValueNotifier 直接不通知，这些白重建就没了。
  static double _avgBrightness(ByteData data) {
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    double sum = 0;
    var n = 0;
    // 缩略图本来就只有一万来个像素，逐像素统计即可，不用再跳采样
    for (var i = 0; i + 2 < bytes.length; i += 4) {
      sum += (0.2126 * bytes[i] + 0.7152 * bytes[i + 1] +
              0.0722 * bytes[i + 2]) /
          255;
      n++;
    }
    if (n == 0) return 0.5;
    return ((sum / n) * 100).round() / 100;
  }
}
