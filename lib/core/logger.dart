/// 日志系统。
///
/// 整库唯一的日志出口。以前各处散着 stdout/stderr/print：发布版双击运行时
/// native 不 attach 控制台（见 runner/main.cpp 顶部），这些输出全被丢弃，
/// 出问题只能靠用户口述或 WER 崩溃码猜。这里把日志统一收口：
///
///   - 落盘：`userdata\logs\<engine>-<yyyy-MM-dd>.log`，按天切分，保留 7 天
///   - 级别：debug / info / warn / error，默认 info，`--verbose` 提级到 debug
///   - 多 sink：控制台（开发时 flutter run 可见）+ 文件（发布版可整体拷回）
///   - 脱敏：写文件前统一打码，免得哪个模块手滑把 apiKey / token 打出来
///   - 异步批量刷盘：调用方只同步入队，攒一批再写，退出前 flushLogs() 兜底
///
/// 两个 Flutter 引擎各自 init 一份（engine 名不同，文件错开），native 自己的
/// 日志也转进来，日志落在同一处。用法维持旧的 `[模块]` 前缀风格：
///
///   Log.i('store', '配置已保存');
///   Log.w('wallpaper', '桌面捕获失败，已回退读壁纸文件');
///
/// 高频路径（插件 render / 歌词 tick / 拖拽每帧）一律不许记日志——render 每秒
/// 好几次、tick 是 100ms 一次，打进文件只会把真正能定位问题的行冲掉。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

enum LogLevel {
  debug('D', 10),
  info('I', 20),
  warn('W', 30),
  error('E', 40);

  const LogLevel(this.label, this.priority);

  /// 单字母标签，写进文件的那一列
  final String label;

  /// 数值越大越严重。covers 判断"这条该不该记"按它比
  final int priority;

  bool covers(LogLevel l) => l.priority >= priority;
}

/// 顶层日志入口。多 sink 组合，各 sink 内部自己处理失败。
class Log {
  Log._();

  static LogLevel _level = LogLevel.info;

  /// 没 init 时它是 null，日志只打控制台——启动最早期（logger 还没就绪）
  /// 的调用因此不会丢，也不会炸。
  static _FileSink? _file;

  /// 初始化。在 main() 最前面调一次即可。
  ///
  /// [engine] 填 'main'（磁贴/面板引擎）或 'sidebar'（侧边栏引擎），
  /// 决定日志文件名前缀——两个引擎各写各的，避免并发追加同一个文件时插队。
  static void init({
    required String engine,
    required String dir,
    LogLevel level = LogLevel.info,
  }) {
    _level = level;
    _file?.dispose();
    _file = _FileSink(dir, engine);
  }

  /// 提级到 debug：`--verbose` 启动参数用。随时可调，不用重启。
  static void setLevel(LogLevel level) => _level = level;

  static LogLevel get level => _level;

  static void d(String module, String message) =>
      _log(LogLevel.debug, module, message);

  static void i(String module, String message) =>
      _log(LogLevel.info, module, message);

  static void w(String module, String message) =>
      _log(LogLevel.warn, module, message);

  static void e(String module, String message) =>
      _log(LogLevel.error, module, message);

  /// native（C++）转发进来的日志：native 自己不知道级别，统一按 info 收。
  /// 由 MethodChannel 回调直接调用，跨线程安全。
  static void native(String message) => _log(LogLevel.info, 'native', message);

  static void _log(LogLevel l, String module, String message) {
    if (!_level.covers(l)) return;
    final now = DateTime.now();
    final tag = l.label;
    final line = '${_ts(now)} $tag [$module] $message';
    // 控制台两路：错误级走 stderr，其余走 stdout。保持和以前一致的习惯，
    // 只是统一在这里分流。
    if (l == LogLevel.error) {
      stderr.writeln(line);
    } else {
      stdout.writeln(line);
    }
    _file?.write(line);
  }

  /// 退出前把队列里欠着的日志都刷下去（app_root 的托盘退出路径调）。
  static Future<void> flushLogs() async {
    await _file?.flush();
  }

  /// 测试用：清掉内部状态，别让上一个测试的 sink 留在内存里。
  static void resetForTest() {
    _file?.dispose();
    _file = null;
    _level = LogLevel.info;
  }

  /// 测试用：可以直接读文件里写了什么。
  static String? debugFileForTest() => _file?.debugPath;

  static String _ts(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }
}

/// 文件 sink：按天切分、保留 7 天、批量异步刷盘、写入前脱敏。
class _FileSink {
  _FileSink(this.dir, this.engine) {
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {}
    _cleanupOld();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      // flush 是异步的，定时回调里 fire-and-forget——写失败不应让谁崩溃
      flush();
    });
  }

  final String dir;
  final String engine;

  /// 攒着没刷的日志行。日志调用是同步入队，刷盘由定时器统一做，
  /// 这样高频调用（虽然规范上不该有）也不会把 IO 打进主线程。
  final StringBuffer _buf = StringBuffer();
  Timer? _timer;

  /// 测试直接读这个路径
  String get debugPath => _todayFile().path;

  String _fileName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '$engine-${t.year}-${two(t.month)}-${two(t.day)}.log';
  }

  File _todayFile() => File(p.join(dir, _fileName(DateTime.now())));

  void write(String line) {
    _buf.writeln(_redact(line));
    // 队列积到一定量就提前刷一次，别让日志在内存里陪着程序出问题
    if (_buf.length > 32 * 1024) flush();
  }

  Future<void> flush() async {
    if (_buf.isEmpty) return;
    final chunk = _buf.toString();
    _buf.clear();
    try {
      await _todayFile().writeAsString(chunk,
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写失败不能反过去把程序搞挂：把这块文本还回队列里，等下次再试
      _buf.write(chunk);
    }
  }

  /// 启动时清扫过期文件：只留最近 7 天的日志。
  void _cleanupOld() {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final f in d.listSync()) {
        if (f is! File || !f.path.endsWith('.log')) continue;
        final base = p.basenameWithoutExtension(f.path);
        // 形如 main-2026-08-16 / sidebar-2026-08-16：日期是最后**三**段。
        // 只取最后一段的话拿到的是 "16"，tryParse 给 null，文件就永远删不掉。
        final parts = base.split('-');
        if (parts.length < 4) continue;
        final day = DateTime.tryParse(parts.sublist(parts.length - 3).join('-'));
        if (day != null && day.isBefore(cutoff)) f.deleteSync();
      }
    } catch (_) {}
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _buf.clear();
  }
}

/// 统一脱敏。写入文件前过一遍，保险丝要接在最后一道：
/// 任何模块想拦没拦住、把密钥打出来了，这里还能兜住。
///
/// 目前两类：
///   1. sk- 开头的 API 密钥（OpenAI / DeepSeek 的 sk-... 都是这形状）；
///   2. URL query 里常见的敏感参数（key / api key / token / secret /
///      password / code），把值整段打码。
///
/// 用宽松匹配：宁可多挡一段无害文本，也不能漏掉真实密钥。
String _redact(String line) {
  var s = line.replaceAllMapped(
      RegExp(r'sk-[A-Za-z0-9_\-]{6,}'), (m) => 'sk-***');
  // raw string 用双引号包：里面要匹配单引号，而 raw string 没有转义，
  // 用单引号包会被那个单引号提前截断。
  s = s.replaceAllMapped(
      RegExp(
          r"([?&](?:key|api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization)=)[^&\s""'<>]+",
          caseSensitive: false),
      (m) => '${m[1]}***');
  return s;
}