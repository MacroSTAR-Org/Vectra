/// 版本号的运行时出处。
///
/// 唯一的真实来源是 pubspec.yaml 的 `version:`，构建时会被打进 exe 的版本
/// 资源；这里只是在启动时把它读出来缓存一份，供那些不方便 await 的地方同步
/// 取用（比如插件发 HTTP 请求时要填的 User-Agent）。
///
/// 以前 User-Agent 里写死着 'Vectra/0.11'，改版本号时改不到它，发出去的请求
/// 会一直带着过期的版本。
library;

import 'package:package_info_plus/package_info_plus.dart';

/// `0.2.0+129` 形式的完整版本（和 exe 的文件版本一致）；init 之前是空串。
/// 供**数值比较**用（更新检查的四段版本比较），不直接展示。
String _version = '';

/// 个性化版本串（大版本名 Forst + 小版本 0.2.129）。
///
/// 注意它**不再是四段数字**：所有需要比较版本的地方（更新检查）
/// 必须用 [appVersionNumeric]，用显示串去比会被 compareVersion 判成
/// "全垃圾 = 相同"，自动更新会永远闭嘴。
const String kVersionDisplay = 'Forst-0.2.130';

/// 供 UI 显示 / User-Agent / Sentry release 的版本串
String get appVersion => kVersionDisplay;

/// 供更新检查做四段数值比较的版本串（`0.2.0.125`），init 之前是空串
String get appVersionNumeric => _version;

/// 插件发起网络请求时用的 User-Agent
String get appUserAgent => 'Glance/${_version.isEmpty ? 'dev' : _version}';

/// 启动时调一次。读失败不影响程序运行，只是版本显示为空。
Future<void> initAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    // package_info 把 build number 单独给出来，拼成四段和 exe 文件版本对齐
    _version = info.buildNumber.isEmpty
        ? info.version
        : '${info.version}.${info.buildNumber}';
  } catch (_) {
    // 保持空串
  }
}
