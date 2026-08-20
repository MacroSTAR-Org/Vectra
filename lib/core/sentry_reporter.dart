/// 错误上报的薄壳。
///
/// 之所以隔这一层而不是让 logger 直接 import sentry：sentry_flutter 在
/// 测试环境里初始化会失败（要平台通道），而 logger 的测试又不能因为这个
/// 就跳过。这里给一个纯 Dart 接口，sentry.dart 那边注入实现，没注入时
/// 一切都变成空操作。
library;

import 'sentry.dart' as sentry;

/// 上报级别，不依赖 sentry 包自己的枚举，避免它漏到 logger 里。
enum SentryReportLevel { info, warning, error }

typedef SentryReporterFn = void Function(
  String message, {
  StackTrace? stack,
  SentryReportLevel? level,
  Map<String, String>? tags,
});

/// 由 sentry.dart 在初始化时注入。默认实现是空操作。
SentryReporterFn _reporter = (_, {stack, level, tags}) {};

void setSentryReporter(SentryReporterFn fn) => _reporter = fn;

/// logger.dart 调这个。没注入时是空操作，测试不受影响。
void reportToSentry(
  String message, {
  StackTrace? stack,
  SentryReportLevel level = SentryReportLevel.error,
  Map<String, String>? tags,
}) {
  _reporter(message, stack: stack, level: level, tags: tags);
}

/// 异常上报（带完整堆栈），给 runZonedGuarded 用。同样可替换。
typedef SentryExceptionReporterFn = Future<void> Function(
  Object error,
  StackTrace stack, {
  bool fatal,
});

SentryExceptionReporterFn _exceptionReporter = (_, __, {fatal = false}) async {};

void setSentryExceptionReporter(SentryExceptionReporterFn fn) =>
    _exceptionReporter = fn;

Future<void> reportExceptionToSentry(
  Object error,
  StackTrace stack, {
  bool fatal = false,
}) =>
    _exceptionReporter(error, stack, fatal: fatal);

/// 把壳接到真正的 sentry。在 main() 初始化 sentry 之后调一次。
void wireSentryReporter() {
  setSentryReporter((message,
      {stack, level = SentryReportLevel.error, tags}) {
    final sentryLevel = switch (level) {
      SentryReportLevel.info => sentry.SentryLevel.info,
      SentryReportLevel.warning => sentry.SentryLevel.warning,
      SentryReportLevel.error || null => sentry.SentryLevel.error,
    };
    sentry.reportToSentry(message, level: sentryLevel, tags: tags);
  });
  setSentryExceptionReporter((error, stack, {fatal = false}) =>
      sentry.reportExceptionToSentry(error, stack, fatal: fatal));
}
