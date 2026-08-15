/// 用户数据目录的唯一出处。
///
/// 便携优先：所有用户数据都放在 **exe 同目录**的 `userdata\` 下，整个程序
/// 目录拷走就是完整迁移，不在系统用户目录里留东西。
///
/// 为什么不叫 `data\`：那个名字已经被 Flutter 占用（flutter_assets / app.so /
/// icudtl.dat 都在里面），再往里塞用户数据迟早撞车。
///
/// 为什么不做"不可写就回退到 %LOCALAPPDATA%"：回退会让"配置到底在哪"变成
/// 一件要猜的事——同一个 exe 在不同机器上落在不同地方，排查问题时先得确认
/// 用的是哪条路径。宁可在不可写时明确报错，让用户把程序挪到可写的位置。
///
/// 两个 Flutter 引擎（磁贴主引擎 + AI 侧边栏引擎）都从这里取路径，
/// 以前是各自硬编码 %APPDATA%，改一处漏一处。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._();

  /// exe 所在目录。调试运行时指向 build\windows\x64\runner\Release，
  /// 所以开发期的用户数据也落在构建目录里 —— `flutter clean` 会一并清掉，
  /// 这是"完全便携"的固有代价。
  static String get exeDir => p.dirname(Platform.resolvedExecutable);

  /// 用户数据根目录：`<exe>\userdata`
  static String get root => p.join(exeDir, 'userdata');

  /// 第三方插件：`<exe>\userdata\plugins\<id>\`
  static String get pluginsDir => p.join(root, 'plugins');

  /// 旧版位置 %APPDATA%\LiquidWidgets，仅用于首次启动搬迁
  static String? get legacyRoot {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return p.join(appData, 'LiquidWidgets');
  }

  /// 确保根目录存在并且真的能写。
  ///
  /// 返回 null 表示一切正常；返回字符串表示失败原因（调用方负责显示给用户）。
  /// 只在启动时调一次：目录不可写的话后面每一次保存都会失败，与其让用户改了
  /// 设置又莫名其妙丢掉，不如一开始就说清楚。
  static Future<String?> ensureWritable() async {
    try {
      await Directory(root).create(recursive: true);
      final probe = File(p.join(root, '.write-test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return null;
    } catch (e) {
      return '用户数据目录不可写：$root\n'
          '$e\n'
          '请把程序移到有写入权限的位置（例如桌面或 D 盘），不要放在 '
          'Program Files 或只读介质里。';
    }
  }

  /// 首次启动时把旧的 %APPDATA%\LiquidWidgets 整个搬过来。
  ///
  /// 触发条件：新目录里没有 state.json，而旧目录里有。搬完**不删旧目录**——
  /// 万一新位置出问题，用户的布局还在原地。
  ///
  /// 返回是否真的搬了东西。
  static Future<bool> migrateFromLegacy() async {
    final legacy = legacyRoot;
    if (legacy == null) return false;
    final legacyState = File(p.join(legacy, 'state.json'));
    final newState = File(p.join(root, 'state.json'));
    if (!await legacyState.exists() || await newState.exists()) return false;

    try {
      await Directory(root).create(recursive: true);
      await for (final entry in Directory(legacy).list(recursive: true)) {
        final rel = p.relative(entry.path, from: legacy);
        final target = p.join(root, rel);
        if (entry is Directory) {
          await Directory(target).create(recursive: true);
        } else if (entry is File) {
          await Directory(p.dirname(target)).create(recursive: true);
          await entry.copy(target);
        }
      }
      return true;
    } catch (e) {
      stderr.writeln('[paths] 旧配置搬迁失败（不影响启动，将从空配置开始）: $e');
      return false;
    }
  }
}
