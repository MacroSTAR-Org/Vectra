/// 全局设置。
///
/// 相比 Electron 版删掉了整组玻璃参数（glassBlur / glassTint / glassClarity /
/// refraction / squircle / specular / lightFollowMouse）——这一版没有特效，
/// 那些字段没有对应物，读旧配置时直接忽略。
library;

import '../core/grid.dart';

class AppSettings {
  AppSettings({
    this.gridCell = kDefaultCell,
    this.gridGap = kDefaultGap,
    this.snapEnabled = true,
    this.snapThreshold = 10,
    this.locked = false,
    this.animations = true,
    this.cardColor = 0xFF2A2A2E,
    this.cardRadius = 26,
    this.material = 'opaque',
    this.glassTint = 0.35,
    this.glassBlur = 18,
    this.liveRefreshMs = 0,
    this.theme = 'auto',
    this.marketBaseUrl = '',
  });

  /// 网格单元边长（逻辑像素）
  int gridCell;

  /// 网格间距，同时用作吸附的"留白"候选
  int gridGap;

  bool snapEnabled;
  double snapThreshold;

  /// 锁定布局：禁止拖拽与改尺寸
  bool locked;

  bool animations;

  /// 卡片底色（不透明纯色）
  int cardColor;

  /// 圆角半径。必须与推给 native 的命中区半径一致，否则视觉与输入错位。
  double cardRadius;

  /// 卡片材质：opaque(不透明) / acrylic(亚克力模糊) / mica(云母)
  ///
  /// 后两者是 Windows 11 的系统背景材质，由 DWM 绘制在窗口区域内。
  /// 因为窗口区域被裁成了卡片形状，材质恰好只出现在卡片里。
  String material;

  /// 毛玻璃上那层染色的浓度：0 = 完全透（只有模糊），1 = 接近不透明底色
  double glassTint;

  /// 模糊强度
  double glassBlur;

  /// 动态壁纸的刷新间隔（毫秒）。0 = 只在启动时抓一次。
  /// Wallpaper Engine 这类动态壁纸需要开启才会跟着动。
  int liveRefreshMs;

  /// 深浅色：auto（跟随系统）/ light / dark。
  /// 只管设置窗口和侧边栏——卡片的文字明暗跟壁纸走（见 card_view）。
  String theme;

  /// 插件市场服务器地址。空串表示用内置的默认地址（见 kMarketBaseUrl）。
  ///
  /// 留这个口子是为了指向自建/本地跑的 Unisphere（比如 http://localhost:8787），
  /// 换服务器不用重新编译。
  String marketBaseUrl;

  Map<String, Object?> toJson() => {
        'gridCell': gridCell,
        'gridGap': gridGap,
        'snapEnabled': snapEnabled,
        'snapThreshold': snapThreshold,
        'locked': locked,
        'animations': animations,
        'cardColor': cardColor,
        'cardRadius': cardRadius,
        'material': material,
        'glassTint': glassTint,
        'glassBlur': glassBlur,
        'liveRefreshMs': liveRefreshMs,
        'theme': theme,
        if (marketBaseUrl.isNotEmpty) 'marketBaseUrl': marketBaseUrl,
      };

  static AppSettings fromJson(Map<String, Object?> j) => AppSettings(
        gridCell: (j['gridCell'] as num?)?.toInt() ?? kDefaultCell,
        gridGap: (j['gridGap'] as num?)?.toInt() ?? kDefaultGap,
        snapEnabled: j['snapEnabled'] as bool? ?? true,
        snapThreshold: (j['snapThreshold'] as num?)?.toDouble() ?? 10,
        locked: j['locked'] as bool? ?? false,
        animations: j['animations'] as bool? ?? true,
        cardColor: (j['cardColor'] as num?)?.toInt() ?? 0xFF2A2A2E,
        cardRadius: (j['cardRadius'] as num?)?.toDouble() ?? 26,
        material: j['material'] as String? ?? 'opaque',
        glassTint: (j['glassTint'] as num?)?.toDouble() ?? 0.35,
        glassBlur: (j['glassBlur'] as num?)?.toDouble() ?? 18,
        liveRefreshMs: (j['liveRefreshMs'] as num?)?.toInt() ?? 0,
        theme: j['theme'] as String? ?? 'auto',
        marketBaseUrl: j['marketBaseUrl'] as String? ?? '',
      );
}
