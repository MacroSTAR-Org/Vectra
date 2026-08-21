/// 错误上报：Better Stack（用 Sentry SDK 收集）。
///
/// 为什么单独一个文件：sentry_flutter 的初始化和后续 capture 要 import 一堆
/// sentry 符号，集中在这里免得它们漏到 main.dart 和别的地方。对外只暴露
/// 几个不依赖 sentry 类型的函数。
///
/// **DSN 写死在代码里是故意的**：错误上报不需要用户配置，也不该能被关掉——
/// 一个程序在用户那里崩了，开发者要是看不到，就只能等用户来报。DSN 本身只是
/// "数据发到哪个项目"的地址，泄露了也只能让人往你的项目灌垃圾数据，没有更
/// 深的风险（Sentry 的 DSN 是公钥侧，对应私钥在服务端）。
library;

import 'package:sentry_flutter/sentry_flutter.dart';

import 'app_version.dart';

// 重新导出 SentryLevel，让 sentry_reporter.dart 不必直接 import sentry 包
export 'package:sentry_flutter/sentry_flutter.dart' show SentryLevel;

/// Better Stack 的 DSN。
///
/// 注意：服务端是 Better Stack（用了 Sentry 兼容协议），不是 Sentry SaaS。
/// SDK 一样能用，只是数据落到 Better Stack 那边。
const String kSentryDsn =
    'https://ozyJ4ZmQrTMW6pK1LvDcBvbC@s2692816.us-west-2a.betterstackdata.com/2692824';

/// 是否在上报。`--no-sentry` 时为 false，用于本地开发时不想污染数据。
bool _enabled = true;

/// 在 runApp 之前调用。必须赶在 Flutter 引擎开始跑之前，否则引擎初始化期间
/// 抛的异常就抓不到。
///
/// **不用 appRunner 模式**：SentryFlutter.init 的 appRunner 参数会在 init
/// 内部调 runApp，但 runWidget 不返回（跑消息循环），导致 init 的 await
/// 永远不完成、SDK 初始化收尾（后台上传通道等）跑不完。改成先 init 再 run，
/// init 自己 await 完了再交给调用方去 run。
Future<void> initSentry() async {
  await SentryFlutter.init(
    (options) {
      options.dsn = kSentryDsn;
      // release 用 appVersion（如 "0.1.2.132"）：Better Stack 面板能按版本筛
      options.release = appVersion.isEmpty ? 'dev' : appVersion;
      // 环境：开发版标 dev，发布版标 production。当前没法在运行时区分，
      // 因为便携版和 `flutter run` 跑的是同一个 exe；先统一标 production，
      // debug 版想关上报用 --no-sentry。
      options.environment = 'production';
      // 上报 100% 的错误。Vectra 用户量不大、错误本来就稀疏，
      // 采样反而会让偶发问题漏掉。
      options.sampleRate = 1.0;
      // ANR（应用无响应）：插件死循环把 UI 卡住是真实存在的场景。
      // SDK 8.x 默认就开了 ANR 检测，这里只设超时——5 秒足够让用户察觉
      // "不对劲"。（anrTimeoutInterval 是 8.x 的字段名。）
      options.anrTimeoutInterval = const Duration(seconds: 5);
      // 关掉 PII 收集：错误堆栈里不该带用户路径之类的个人信息
      options.sendDefaultPii = false;
      // 发送前的钩子：--no-sentry 时在这里拦掉
      options.beforeSend = (event, hint) {
        if (!_enabled) return null;
        return event;
      };
    },
  );
  // appRunner 不用了（见函数注释），init 返回后调用方自己 run
}

/// 主动上报一条错误。给 Log.e 用。
///
/// [level] 决定在 Better Stack 上的严重级别：
///   - error（默认）：红色，会触发告警
///   - warning：黄色，只记录
///   - info：灰色，纯留痕
Future<void> reportToSentry(
  String message, {
  Object? exception,
  StackTrace? stack,
  SentryLevel level = SentryLevel.error,
  Map<String, String>? tags,
}) async {
  if (!_enabled) return;
  try {
    await Sentry.captureMessage(
      message,
      level: level,
      withScope: (scope) {
        if (exception != null) {
          // 8.x: setExtra 已弃用，但 setContexts 是替代品且功能更强。
          // 这里把异常对象放进去，Better Stack 面板上能看到。
          scope.setContexts('exception', exception.toString());
        }
        if (stack != null) {
          scope.setContexts('stack', stack.toString());
        }
        if (tags != null) {
          for (final e in tags.entries) {
            scope.setTag(e.key, e.value);
          }
        }
      },
    );
  } catch (_) {
    // 上报本身失败不能再抛——那就是在错误处理里制造新错误。
    // 日志文件里该有的信息已经有了，sentry 这条丢了就丢了。
  }
}

/// 上报一个异常（带完整堆栈）。给 runZonedGuarded 用。
Future<void> reportExceptionToSentry(
  Object error,
  StackTrace stack, {
  bool fatal = false,
}) async {
  if (!_enabled) return;
  try {
    await Sentry.captureException(error, stackTrace: stack, hint: Hint.withMap({'fatal': fatal}));
  } catch (_) {}
}

/// `--no-sentry` 走这里：上报函数都变成空操作。
void disableSentry() => _enabled = false;
