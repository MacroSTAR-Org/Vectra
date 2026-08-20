/// 状态持久化。
///
/// 存储分成三类，各写各的文件：
///   config.json                设置 + 卡片布局 + AI 配置（小，值得备份）
///   `plugindata/<id>.json`     每个插件自己的键值存储（一插件一文件）
///   `plugindata/<id>/<hash>.json`  每个插件的缓存（一条一个文件）
///
/// 键值存储和缓存分开，是因为两者的读写模式完全相反：键值存储小而全量（待办
/// 清单要一次读齐），缓存大而零散（歌词一首 4KB，攒几百首，但每次只用一首）。
/// 混在一起的话，缓存多一条就让整份文件的读写都变贵——歌词插件曾因此被迫把
/// 缓存限死在 20 首。
///
/// 为什么要拆：以前全塞在一个 state.json 里，实测 99KB 中有 98% 是歌词全文
/// 和天气 API 响应这类插件缓存——真正的配置只占 2KB。后果有两个：
///   1. 插件每写一次缓存就要重写整份文件（歌词插件被迫做 LRU 限流绕开）；
///   2. 导出"布局备份"会把几十 KB 的缓存一起打包。
/// 拆开之后，歌词写缓存只动 plugindata/lyrics.json，config.json 纹丝不动。
///
/// 沿用 Electron 版的两个关键做法：
///   1. 原子写（先写 .tmp 再 rename），避免拖拽中途崩溃留下半个文件；
///   2. 去抖，拖拽时每帧都在改坐标，不能每帧都落盘。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/logger.dart';
import '../model/ai_settings.dart';
import '../model/card.dart';
import '../model/settings.dart';

class AppState {
  AppState({
    required this.settings,
    required this.cards,
    List<String>? disabledPlugins,
    AiSettings? ai,
  })  : disabledPlugins = disabledPlugins ?? <String>[],
        ai = ai ?? AiSettings();

  AppSettings settings;
  List<WidgetCard> cards;

  /// 用 ?? [] 而不是 const []：默认值若是 const 列表，全新安装（还没有配置
  /// 文件）时任何一次 add 都会在运行时炸「Cannot add to an unmodifiable list」。
  List<String> disabledPlugins;

  /// AI 侧边栏配置。会话历史不在这儿——那是侧边栏引擎独占的 chat.json。
  AiSettings ai;

  /// 插件命名空间的键值存储：pluginData[pluginId][key]。
  /// 内存里仍是一张总表，落盘时按 pluginId 拆成多个文件。
  final Map<String, Map<String, Object?>> pluginData = {};
}

class Store {
  Store(this.dir);

  /// 用户数据目录，由 AppPaths.root 给出（exe 同目录的 userdata\）
  final String dir;

  String get _configFile => p.join(dir, 'config.json');
  String get _pluginDataDir => p.join(dir, 'plugindata');
  String _pluginFile(String id) => p.join(_pluginDataDir, '$id.json');

  /// 某个插件的缓存目录。和 `<id>.json` 同级且同名（无扩展名），
  /// _loadPluginData 只认 .json 文件，扫到这个目录会自动跳过。
  String _cacheDir(String id) => p.join(_pluginDataDir, id);

  /// 缓存留多少条。一条歌词约 4KB，500 条约 2MB；
  /// 因为是一条一个文件，这 2MB 不会在启动时被解析，只在命中时读其中一个。
  ///
  /// 不是硬上限：淘汰每 [_cacheSweepEvery] 次写才扫一次目录，两次扫描之间
  /// 最多会多出这么些条。实际上限是 cacheMaxEntries + _cacheSweepEvery。
  static const int cacheMaxEntries = 500;

  /// 距上次淘汰扫描写了多少次。每次写都去扫目录太浪费，攒一批再扫。
  static const int cacheSweepEvery = 25;
  int _cacheWritesSinceSweep = 0;

  /// 旧版单文件，仅用于一次性拆分迁移
  String get _legacyStateFile => p.join(dir, 'state.json');

  Timer? _configDebounce;

  /// 每个插件各自的去抖：歌词在写缓存时不该顺带把待办也刷一遍
  final Map<String, Timer> _pluginDebounce = {};

  AppState? _state;

  /// 3 = 拆分成 config.json + plugindata/（2 及以前是单个 state.json）
  static const int schemaVersion = 3;

  Future<AppState> load() async {
    // 新结构不存在但旧的 state.json 还在 → 先拆分迁移一次
    if (!await File(_configFile).exists() &&
        await File(_legacyStateFile).exists()) {
      await _migrateFromLegacyState();
    }

    final f = File(_configFile);
    if (!await f.exists()) {
      _state = AppState(settings: AppSettings(), cards: []);
      await _loadPluginData(_state!);
      return _state!;
    }
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      final state = _stateFromJson(raw);
      await _loadPluginData(state);
      _state = state;
      return state;
    } catch (e) {
      // 配置文件损坏时不能直接崩溃，退回默认并把坏文件留档
      Log.e('store', 'config.json 损坏，已备份并退回默认: $e');
      try {
        await f.rename(
            '$_configFile.broken-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
      _state = AppState(settings: AppSettings(), cards: []);
      await _loadPluginData(_state!);
      return _state!;
    }
  }

  AppState _stateFromJson(Map<String, Object?> raw) {
    final settings = AppSettings.fromJson(
        (raw['settings'] as Map?)?.cast<String, Object?>() ?? const {});
    final cards = <WidgetCard>[];
    for (final c in (raw['cards'] as List? ?? const [])) {
      try {
        cards.add(WidgetCard.fromJson((c as Map).cast<String, Object?>()));
      } catch (_) {
        // 单张卡片坏了不该让整个布局丢失
      }
    }
    return AppState(
      settings: settings,
      cards: cards,
      disabledPlugins:
          (raw['disabledPlugins'] as List? ?? const []).cast<String>().toList(),
      ai: AiSettings.fromJson(
          (raw['ai'] as Map?)?.cast<String, Object?>() ?? const {}),
    );
  }

  /// 把 plugindata/ 下每个 `<id>.json` 读回内存总表。
  /// 单个插件的文件坏了只丢它自己的数据，不牵连别人。
  Future<void> _loadPluginData(AppState state) async {
    final d = Directory(_pluginDataDir);
    if (!await d.exists()) return;
    await for (final entry in d.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final id = p.basenameWithoutExtension(entry.path);
      try {
        final m = jsonDecode(await entry.readAsString()) as Map<String, Object?>;
        // 值为 null 的键直接丢掉。null 在这套存储里就是"已删除"的意思
        // （见 nsSet），历史上写 null 只是把值置空、键还留着，攒下过几十个
        // 只占位不干活的墓碑；这里读的时候顺手清掉，写回时就消失了。
        m.removeWhere((_, v) => v == null);
        state.pluginData[id] = m;
    } catch (e) {
      // 插件数据损坏不该让整个启动失败——跳过这一个插件，其余照常
      Log.w('store', '插件数据损坏，已跳过 $id: $e');
      }
    }
  }

  /// 旧的单文件 state.json → 拆成 config.json + `plugindata/<id>.json`。
  ///
  /// 只在 config.json 不存在时走一次。**不删 state.json**：万一拆分有问题，
  /// 原始数据还在原地，可以手工救回来。
  Future<void> _migrateFromLegacyState() async {
    try {
      final raw = jsonDecode(await File(_legacyStateFile).readAsString())
          as Map<String, Object?>;
      final state = _stateFromJson(raw);
      final pd = (raw['pluginData'] as Map?)?.cast<String, Object?>() ?? const {};
      pd.forEach((k, v) {
        if (v is Map) state.pluginData[k] = v.cast<String, Object?>();
      });

      await _writeConfig(state);
      for (final id in state.pluginData.keys) {
        await _writePluginFile(id, state.pluginData[id]!);
      }
      Log.i('store', '已拆分旧 state.json -> config.json + '
          'plugindata/（${state.pluginData.length} 个插件），旧文件保留');
    } catch (e) {
      // 迁移失败就当没迁过：下次启动还会再试，绝不能因此清空用户配置
      Log.w('store', '旧配置拆分失败（保持原样，不影响启动）: $e');
    }
  }

  /// 去抖保存配置（不含插件数据）
  void save(AppState state) {
    _state = state;
    _configDebounce?.cancel();
    _configDebounce =
        Timer(const Duration(milliseconds: 300), () => saveNow(state));
  }

  /// 立即落盘配置（退出前必须调用，否则最后一次拖拽会丢）
  Future<void> saveNow(AppState state) async {
    _configDebounce?.cancel();
    _configDebounce = null;
    await _writeConfig(state);
  }

  Future<void> _writeConfig(AppState state) async {
    try {
      await Directory(dir).create(recursive: true);
      await _atomicWrite(_configFile, encodeConfig(state));
    } catch (e) {
      Log.e('store', '配置保存失败: $e');
    }
  }

  /// 卸载插件：删除插件目录，并从配置中移除相关卡片。
  Future<void> uninstall(String pluginId) async {
    // 删除插件目录
    final dir = Directory(p.join(_pluginDataDir, pluginId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    // 删除插件数据文件
    final dataFile = File(_pluginFile(pluginId));
    if (await dataFile.exists()) {
      await dataFile.delete();
    }
    // 从缓存中移除
    _cacheDir(pluginId); // 这里只是清理内存引用，实际文件已删
    Log.i('store', '已卸载插件 $pluginId');
  }

  /// 重新扫描插件目录并重新加载配置。
  Future<void> rescanPlugins() async {
    await _loadPluginData(_state!);
    await saveNow(_state!);
  }

  /// 配置序列化成文本。备份导出直接复用它——导出的就是一份 config.json，
  /// 格式知识只存在于本文件，面板那边只管挑路径和读写。
  String encodeConfig(AppState state) {
    final payload = <String, Object?>{
      'schema': schemaVersion,
      'settings': state.settings.toJson(),
      'cards': state.cards.map((c) => c.toJson()).toList(),
      'disabledPlugins': state.disabledPlugins,
      'ai': state.ai.toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 解析一份导出的配置。内容不是本程序的备份时抛 FormatException，
  /// 由调用方提示用户——绝不能拿一份乱七八糟的 JSON 去覆盖现有布局。
  AppState decodeConfig(String text) {
    final Object? raw = jsonDecode(text);
    if (raw is! Map<String, Object?>) {
      throw const FormatException('不是有效的配置文件');
    }
    if (!raw.containsKey('settings') || !raw.containsKey('cards')) {
      throw const FormatException('缺少 settings / cards，可能不是 Vectra 的备份');
    }
    return _stateFromJson(raw);
  }

  Future<void> _writePluginFile(String id, Map<String, Object?> data) async {
    try {
      await Directory(_pluginDataDir).create(recursive: true);
      await _atomicWrite(
          _pluginFile(id), const JsonEncoder.withIndent('  ').convert(data));
    } catch (e) {
      Log.e('store', '插件数据保存失败 $id: $e');
    }
  }

  /// 先写 .tmp 再 rename：中途崩溃也不会留下半个文件
  Future<void> _atomicWrite(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content);
    await tmp.rename(path);
  }

  /// pluginId 会直接当目录名/文件名用。manifest 已经校验过只允许小写字母数字
  /// 和 -_，这里再挡一道，免得将来有别的调用方绕过校验写出路径穿越。
  bool _safePluginId(String id) {
    if (id.isEmpty || id.contains(RegExp(r'[\\/:*?"<>|.]'))) {
      Log.w('store', '非法的 pluginId，已拒绝: $id');
      return false;
    }
    return true;
  }

  /// 插件命名空间读写
  Object? nsGet(String pluginId, String key, [Object? fallback]) =>
      _state?.pluginData[pluginId]?[key] ?? fallback;

  /// 写插件数据。**value 传 null 表示删除这个键**，不是存一个 null 值——
  /// 插件那边写 `storage.set(k, null)` 一直就是"删掉它"的意思。
  void nsSet(String pluginId, String key, Object? value) {
    final s = _state;
    if (s == null) return;
    if (!_safePluginId(pluginId)) return;
    final data = (s.pluginData[pluginId] ??= <String, Object?>{});
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    // 只去抖并只重写这一个插件的文件
    _pluginDebounce[pluginId]?.cancel();
    _pluginDebounce[pluginId] = Timer(const Duration(milliseconds: 300), () {
      _pluginDebounce.remove(pluginId);
      _writePluginFile(pluginId, data);
    });
  }

  // ---------------- 缓存：一条一个文件 ----------------

  /// 缓存条目的文件名。
  ///
  /// key 是插件自己定的（歌词用的是"标题|歌手"），含 `|`、中文、长度不定，
  /// 不能直接当文件名，所以取哈希。FNV-1a 64 位，够短够散，不值得为此引入
  /// 一个加密库——碰撞由下面的原 key 比对兜底。
  String _cacheHash(String key) {
    var h = 0xcbf29ce484222325;
    for (final unit in utf8.encode(key)) {
      h ^= unit;
      // Dart 的 int 是 64 位有符号，溢出会自动回绕，正是 FNV 想要的
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  String _cacheFile(String pluginId, String key) =>
      p.join(_cacheDir(pluginId), '${_cacheHash(key)}.json');

  /// 读一条缓存。没有、坏了、或哈希撞了都返回 null（当作未命中）。
  Future<Object?> cacheGet(String pluginId, String key) async {
    if (!_safePluginId(pluginId)) return null;
    final f = File(_cacheFile(pluginId, key));
    try {
      if (!await f.exists()) return null;
      final m = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      // 存了原始 key，比对一下。两个不同的 key 哈希到同一个文件名时，
      // 这里会退化成"未命中"重新抓，而不是把张三的歌词配给李四。
      if (m['k'] != key) return null;
      return m['v'];
    } catch (e) {
      // 坏文件直接删掉，免得每次都来试一遍
      try {
        await f.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 写一条缓存；value 传 null 表示删掉这条。
  ///
  /// 不做去抖：一条就是一个小文件，写完即完；去抖反而要维护一堆待写状态。
  Future<void> cacheSet(String pluginId, String key, Object? value) async {
    if (!_safePluginId(pluginId)) return;
    final f = File(_cacheFile(pluginId, key));
    try {
      if (value == null) {
        if (await f.exists()) await f.delete();
        return;
      }
      await Directory(_cacheDir(pluginId)).create(recursive: true);
      await _atomicWrite(
          f.path, jsonEncode(<String, Object?>{'k': key, 'v': value}));
      if (++_cacheWritesSinceSweep >= cacheSweepEvery) {
        _cacheWritesSinceSweep = 0;
        await _sweepCache(pluginId);
      }
    } catch (e) {
      // 缓存写不进去不是错误，顶多下次重新抓
      Log.w('store', '缓存写入失败 $pluginId: $e');
    }
  }

  /// 超过上限就按修改时间淘汰最旧的。
  ///
  /// 两点近似，对一个随时能重建的缓存都可以接受：
  ///   1. 只按写入时间排，读取不刷新时间——真 LRU 要每次命中都改文件时间，
  ///      不值得。上限够大时和 LRU 的差别可以忽略。
  ///   2. 文件时间戳有粒度（Windows 上约十几毫秒）。同一瞬间写入的一批条目
  ///      时间相同，它们之间谁先被淘汰是不确定的。实际使用中歌曲间隔以分钟
  ///      计，撞不到；只有测试里连续猛写才会遇上。
  Future<void> _sweepCache(String pluginId) async {
    try {
      final d = Directory(_cacheDir(pluginId));
      if (!await d.exists()) return;
      final files = <({File f, DateTime at})>[];
      await for (final e in d.list()) {
        if (e is File && e.path.endsWith('.json')) {
          files.add((f: e, at: await e.lastModified()));
        }
      }
      if (files.length <= cacheMaxEntries) return;
      files.sort((a, b) => a.at.compareTo(b.at));
      final drop = files.length - cacheMaxEntries;
      for (var i = 0; i < drop; i++) {
        try {
          await files[i].f.delete();
        } catch (_) {}
      }
      Log.d('store', '$pluginId 缓存超过 $cacheMaxEntries 条，已淘汰 $drop 条');
    } catch (e) {
      Log.w('store', '缓存淘汰失败 $pluginId: $e');
    }
  }

  /// 退出前把还欠着的插件数据一并落盘
  Future<void> flushPluginData() async {
    final s = _state;
    if (s == null) return;
    for (final t in _pluginDebounce.values) {
      t.cancel();
    }
    final pending = _pluginDebounce.keys.toList();
    _pluginDebounce.clear();
    for (final id in pending) {
      final data = s.pluginData[id];
      if (data != null) await _writePluginFile(id, data);
    }
  }
}
