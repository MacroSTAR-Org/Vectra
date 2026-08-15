/// AI 侧边栏的配置。
///
/// 接口按 OpenAI 兼容格式（POST {baseUrl}/chat/completions）。这是
/// "api key + base url + model" 这套配置的事实标准：OpenAI、DeepSeek、
/// Kimi、通义、本地 Ollama、One API 之类都兼容，不需要为每家写适配。
library;

import 'package:flutter/foundation.dart';

/// 快捷键注册状态，设置页里直接显示给用户看。
/// 只写日志是不够的——失败时用户按了没反应，却不知道为什么。
final ValueNotifier<String> hotkeyStatus = ValueNotifier('未注册');

class AiSettings {
  AiSettings({
    this.apiKey = '',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.systemPrompt = '你是一个简洁的桌面助手，回答尽量短。',
    this.temperature = 0.7,
    this.maxHistory = 20,
    // 默认 Ctrl+Alt+Space。
    // 不用 Alt+Space：那是 Windows 打开窗口系统菜单的标准快捷键，抢了会坏事。
    // 不用 Ctrl+Alt+A：实测这台机器上已被别的程序占用（ERROR 1409）。
    this.hotkeyMods = 3, // MOD_ALT | MOD_CONTROL
    this.hotkeyVk = 0x20, // VK_SPACE
    this.sidebarWidth = 380,
    this.glass = true,
    this.tint = 0.55,
    this.radius = 22,
    this.blurSigma = 22,
    this.agent = true,
    this.dock = true,
  });

  String apiKey;

  /// 不要带尾部斜杠；请求时会拼 /chat/completions
  String baseUrl;

  String model;
  String systemPrompt;
  double temperature;

  /// 每次请求最多带上多少条历史（含用户与助手），太多会顶爆上下文
  int maxHistory;

  /// Win32 的修饰键位：ALT=1 CTRL=2 SHIFT=4 WIN=8，可叠加
  int hotkeyMods;

  /// Win32 虚拟键码
  int hotkeyVk;

  double sidebarWidth;

  /// 是否用和磁贴一样的毛玻璃材质
  bool glass;

  /// 侧边栏自己的染色浓度。和磁贴分开：聊天要长时间读字，
  /// 通常需要比磁贴更实一些。
  double tint;

  /// 圆角半径。只作用在贴着屏幕内侧的那两个角（左上、左下）——
  /// 右侧两个角紧贴屏幕边缘，圆角会露出缺口，所以保持直角。
  double radius;

  /// 背景模糊强度
  double blurSigma;

  /// 是否开启 Agent（工具调用）。关掉就只是纯聊天。
  bool agent;

  /// 收起时缩成屏幕右下角那个小方块（投放点），而不是整个隐藏。
  ///
  /// 它是常驻置顶的：磁贴那个窗口常驻 Z 序最底，右下角被任何窗口盖住就
  /// 够不到（实测被 Chrome 盖住），所以投放点只能长在这个置顶窗口上。
  /// 代价是右下角永久多一个 56x56 的悬浮块，会挡住下面那一小块的点击。
  bool dock;

  bool get configured => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// 拼出实际请求地址。允许用户填带或不带 /v1 的地址。
  Uri? chatUri() {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.isEmpty) return null;
    // 已经指到 chat/completions 就直接用，避免重复拼接
    if (b.endsWith('/chat/completions')) return Uri.tryParse(b);
    return Uri.tryParse('$b/chat/completions');
  }

  Map<String, Object?> toJson() => {
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'model': model,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'maxHistory': maxHistory,
        'hotkeyMods': hotkeyMods,
        'hotkeyVk': hotkeyVk,
        'sidebarWidth': sidebarWidth,
        'glass': glass,
        'tint': tint,
        'radius': radius,
        'blurSigma': blurSigma,
        'agent': agent,
        'dock': dock,
      };

  static AiSettings fromJson(Map<String, Object?> j) => AiSettings(
        apiKey: j['apiKey'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? 'https://api.openai.com/v1',
        model: j['model'] as String? ?? 'gpt-4o-mini',
        systemPrompt:
            j['systemPrompt'] as String? ?? '你是一个简洁的桌面助手，回答尽量短。',
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
        maxHistory: (j['maxHistory'] as num?)?.toInt() ?? 20,
        hotkeyMods: (j['hotkeyMods'] as num?)?.toInt() ?? 3,
        hotkeyVk: (j['hotkeyVk'] as num?)?.toInt() ?? 0x20,
        sidebarWidth: (j['sidebarWidth'] as num?)?.toDouble() ?? 380,
        glass: j['glass'] as bool? ?? true,
        tint: (j['tint'] as num?)?.toDouble() ?? 0.55,
        radius: (j['radius'] as num?)?.toDouble() ?? 22,
        blurSigma: (j['blurSigma'] as num?)?.toDouble() ?? 22,
        agent: j['agent'] as bool? ?? true,
        dock: j['dock'] as bool? ?? true,
      );

  /// 快捷键的可读写法，用于设置界面显示
  String hotkeyLabel() {
    final parts = <String>[];
    if (hotkeyMods & 2 != 0) parts.add('Ctrl');
    if (hotkeyMods & 1 != 0) parts.add('Alt');
    if (hotkeyMods & 4 != 0) parts.add('Shift');
    if (hotkeyMods & 8 != 0) parts.add('Win');
    parts.add(vkLabel(hotkeyVk));
    return parts.join(' + ');
  }

  static String vkLabel(int vk) {
    if (vk == 0x20) return 'Space';
    if (vk == 0x0D) return 'Enter';
    if (vk >= 0x30 && vk <= 0x39) return String.fromCharCode(vk); // 0-9
    if (vk >= 0x41 && vk <= 0x5A) return String.fromCharCode(vk); // A-Z
    if (vk >= 0x70 && vk <= 0x7B) return 'F${vk - 0x6F}'; // F1-F12
    return '0x${vk.toRadixString(16).toUpperCase()}';
  }
}
