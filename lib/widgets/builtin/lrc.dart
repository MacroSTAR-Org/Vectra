/// LRC 歌词解析（纯函数）。
///
/// 从 assets/plugins/lyrics/lrc.js 逐行移植。里面全是边界条件：一行多个
/// 时间戳、毫秒 2 位还是 3 位、[ti:]/[ar:] 这类元信息、时间戳乱序、空行。
/// 这些错了不会崩，只会让歌词错半拍，肉眼很难发现——改动时对照旧
/// lrc.js 的用例逐条过一遍。
library;

import 'dart:math';

/// 一句歌词：t 是毫秒，s 是原文，tr 是翻译（merge 之后才有）
class LrcLine {
  LrcLine({required this.t, required this.s, this.tr = ''});
  final int t;
  final String s;
  final String tr;

  Map<String, Object?> toJson() => {'t': t, 's': s, if (tr.isNotEmpty) 'tr': tr};

  static LrcLine fromJson(Map<String, Object?> j) => LrcLine(
      t: (j['t'] as num).toInt(), s: '${j['s'] ?? ''}', tr: '${j['tr'] ?? ''}');
}

class Lrc {
  // [mm:ss.xx] 或 [mm:ss:xx]（少数源用冒号）或 [mm:ss]
  static final _timeRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  // 元信息行：[ti:标题] [ar:歌手] [al:专辑] [by:] 等
  static final _metaRe = RegExp(r'^\[[a-zA-Z]+:');
  static final _offsetRe = RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

  /// 把 LRC 文本解析成按时间升序的数组。
  static List<LrcLine> parse(String text) {
    if (text.isEmpty) return const [];
    final out = <LrcLine>[];
    final offsetRe = _offsetRe;
    var offset = 0;

    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.isEmpty) continue;

      // [offset:-500] 是整体时移，正数表示歌词提前
      final om = offsetRe.firstMatch(line);
      if (om != null) {
        offset = int.tryParse(om.group(1) ?? '') ?? 0;
        continue;
      }

      final stamps = <int>[];
      for (final m in _timeRe.allMatches(line)) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final frac = m.group(3);
        var ms = 0;
        if (frac != null) {
          // "5" -> 500ms，"50" -> 500ms，"500" -> 500ms
          // 两位是百分秒（绝大多数 LRC），三位才是毫秒
          final v = int.parse(frac);
          ms = frac.length == 1 ? v * 100 : (frac.length == 2 ? v * 10 : v);
        }
        stamps.add(min * 60000 + sec * 1000 + ms);
      }

      if (stamps.isEmpty) continue;

      // 去掉所有时间戳后剩下的才是正文；元信息行兜一下
      final textPart = line.replaceAll(_timeRe, '').trim();
      if (_metaRe.hasMatch(textPart)) continue;

      for (final t in stamps) {
        out.add(LrcLine(t: t - offset, s: textPart));
      }
    }

    // 源文件不保证有序（一行多时间戳就必然乱序）
    out.sort((a, b) => a.t - b.t);
    return out;
  }

  /// 找出 posMs 时刻应该高亮第几行。-1 表示还没到第一句（前奏）。
  /// 二分：这个函数每 100ms 调一次，歌词可能上百行。
  static int indexAt(List<LrcLine> lines, int posMs) {
    if (lines.isEmpty) return -1;
    if (posMs < lines.first.t) return -1;
    var lo = 0, hi = lines.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].t <= posMs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 把网易云的原文与翻译两段 LRC 合成一段：翻译接在原文后面。
  /// 时间戳对不上的翻译行直接丢掉——宁可不显示，也不要错位显示。
  static List<LrcLine> merge(List<LrcLine> main, List<LrcLine> trans) {
    if (trans.isEmpty) return main;
    final map = {for (final t in trans) t.t: t.s};
    return [
      for (final k in main)
        LrcLine(
            t: k.t,
            s: k.s,
            tr: (map[k.t] != null && map[k.t] != k.s) ? map[k.t]! : ''),
    ];
  }

  /// 毫秒 -> "m:ss"，超过一小时才带小时位
  static String fmt(num msRaw) {
    var ms = msRaw.toDouble();
    if (!ms.isFinite || ms < 0) ms = 0;
    final total = ms ~/ 1000;
    final s = total % 60;
    final m = (total ~/ 60) % 60;
    final h = total ~/ 3600;
    final mm = h > 0 && m < 10 ? '0$m' : '$m';
    final ss = s < 10 ? '0$s' : '$s';
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // 常用繁→简映射（限标题/歌手归一化与查询变体用）。不求全——错字/漏字的
  // 代价是「该加的分没加上」，不会把正确结果挡在门外。
  static const String _t2sSrc =
      '東东專专愛爱陽阳無无樂乐語语聲声雲云電电畫画見见貝贝頁页門门問问間间聞闻閱阅書书寫写學学覺觉覽览優优傷伤價价眾众會会傳传偉伟側侧兒儿蘭兰興兴養养內内關关務务動动勢势華华協协單单賣卖衛卫廠厂歷历壓压縣县參参雙双變变葉叶號号嘆叹員员團团園园圍围國国圖图圓圆場场壞坏塊块堅坚壇坛處处備备復复夠够頭头夾夹奪夺奮奋婦妇媽妈娛娱孫孙寧宁寶宝實实寵宠審审層层歲岁豈岂崗岗島岛嶺岭峽峡幣币帥帅師师帳帐簾帘帶带幫帮寬宽慶庆庫库應应廢废棄弃彌弥彎弯歸归當当錄录徹彻從从憶忆憂忧懷怀態态憐怜總总戀恋懇恳惡恶惱恼懸悬驚惊懼惧慘惨慣惯願愿戰战撲扑執执擴扩掃扫揚扬擔担擬拟攏拢擇择掛挂摯挚擋挡掙挣揮挥損损換换據据擲掷攬揽擱搁擺摆搖摇攤摊撐撑敵敌敗败賬账貨货質质販贩貪贪貧贫貫贯費费賀贺賊贼賈贾資资賞赏賜赐賠赔賺赚賽赛讚赞贈赠贏赢趕赶趨趋躍跃踐践輪轮軟软軸轴輕轻載载較较輔辅輛辆輸输達达遷迁過过運运還还這这進进遠远違违連连遲迟點点臨临緊紧髒脏髮发麗丽舉举舊旧藝艺藥药蘇苏補补裝装裡里視视計计訊讯記记許许論论設设訪访證证評评詞词話话該该詳详誤误説说調调談谈請请諸诸讀读識识議议讓让財财賢贤購购軍军車车極极機机權权殺杀毀毁氣气汉汉決决淨净準准濕湿满满滨滨滾滚潜潜潔洁烏乌為为爾尔猶犹獄狱獎奖獨独獲获瑪玛瓊琼瘋疯盜盗盡尽监监盘盘矿矿碼码確确禮礼種种穩稳窮穷竊窃豎竖競竞筆笔簡简級级純纯紙纸細细紹绍經经維维網网綜综錯错難难響响顆颗飛飞飯饭馆馆馬马體体魚鱼鳥鸟麦麦麼么檔档檢检灣湾營营櫻樱狀状獅狮藍蓝製制規规覓觅註注認认護护豐丰賓宾蹟迹邊边適适選选鄉乡鄭郑針针韓韩頂顶頻频顧顾風风馳驰驅驱雞鸡';
  static final Map<String, String> _t2s = {
    for (var i = 0; i < _t2sSrc.length; i += 2) _t2sSrc[i]: _t2sSrc[i + 1],
  };

  static final _cjkRe = RegExp(r'[㐀-鿿豈-﫿]');

  /// 繁体折叠到简体（逐字查表，表外字符原样返回）
  static String toSimplified(String s) {
    return (s).replaceAllMapped(_cjkRe, (m) => _t2s[m[0]] ?? m[0]!);
  }

  static final _fullwidthRe = RegExp('[！-～　]');
  static final _bracketRe = RegExp(r'[（(\[].*?[)）\]]');
  static final _punctRe = RegExp(r"""[\s\-_·,，.。!！?？'"“”‘’]""");

  /// 归一化：所有标题/歌手比对的唯一入口——忽略大小写、空格、标点、
  /// 括号内容、全角/半角、简繁差异。
  static String norm(String? s) {
    return toSimplified(s ?? '')
        .replaceAllMapped(_fullwidthRe, (m) {
          final ch = m[0]!;
          return ch == '　' ? ' ' : String.fromCharCode(ch.codeUnitAt(0) - 0xFEE0);
        })
        .toLowerCase()
        .replaceAll(_bracketRe, '')
        .replaceAll(_punctRe, '');
  }

  static final _cjkOnlyRe = RegExp(r'[^　-鿿豈-﫿]');
  static final _latinOnlyRe = RegExp(r'[^ -~]');
  static final _multiSpaceRe = RegExp(r'\s{2,}');

  /// 二元组 Dice 相似度：0~1。标题模糊比对的量化器
  static double sim(String? aRaw, String? bRaw) {
    final a = norm(aRaw);
    final b = norm(bRaw);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.length < 2 || b.length < 2) return a == b ? 1.0 : 0.0;
    final ga = <String, int>{};
    var na = 0;
    for (var i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      ga[g] = (ga[g] ?? 0) + 1;
      na++;
    }
    var nb = 0;
    var inter = 0;
    for (var j = 0; j < b.length - 1; j++) {
      final gb = b.substring(j, j + 2);
      nb++;
      final c = ga[gb];
      if (c != null && c > 0) {
        inter++;
        ga[gb] = c - 1;
      }
    }
    return na + nb == 0 ? 0 : (2 * inter) / (na + nb);
  }

  /// 标题查询变体，按优先级排序（已按原始字符串去重，原始标题永远第一）。
  static List<String> titleVariants(String? titleRaw) {
    final out = <String>[];
    final seen = <String>{};
    void push(String? vRaw) {
      // 去重键用**原始字符串**而不是 norm：norm 会剥掉括号内容，
      // 「X (Y)」和「X」就会被误判成同一个变体——而它们对搜索引擎
      // 是完全不同的查询，恰恰是要分开尝试的对象
      final v = (vRaw ?? '').replaceAll(_multiSpaceRe, ' ').trim();
      if (v.isEmpty || seen.contains(v)) return;
      seen.add(v);
      if (norm(v).isEmpty) return;
      out.add(v);
    }

    final t = (titleRaw ?? '').trim();
    if (t.isEmpty) return out;
    push(t);
    push(t.replaceAll(_bracketRe, '').trim());
    final m = RegExp(r'[（(\[]([^)）\]]{2,})[)）\]]').firstMatch(t);
    if (m != null) push(m.group(1)!.trim());
    push(toSimplified(t));
    push(toSimplified(t.replaceAll(_bracketRe, '').trim()));
    final latin = t.replaceAll(_latinOnlyRe, '').trim();
    if (latin.isNotEmpty && latin != t) push(latin);
    final cjk = t.replaceAll(_cjkOnlyRe, '').trim();
    if (cjk.isNotEmpty && cjk != t) push(cjk);
    return out;
  }

  static final _junkRe =
      RegExp(r'(伴奏|instrumental|remix|dj版|纯享|翻自|cover|live|现场|demo|加速|减速|钢琴版|吉他版)',
          caseSensitive: false);

  /// 从搜索结果里挑一首。够不到门槛（60 分）就返回 null，
  /// 宁可显示"没找到"，也不要贴一首别的歌的歌词。
  static Map<String, Object?>? pickSong(
      List<Map<String, Object?>> songs, String title, String artist, int durMs) {
    if (songs.isEmpty) return null;
    final nt = norm(title);
    final na = norm(artist);
    Map<String, Object?>? best;
    var bestScore = -1e9;

    for (var i = 0; i < songs.length; i++) {
      final s = songs[i];
      final artists =
          (s['artists'] as List?)?.cast<Object?>() ?? const <Object?>[];
      final names = [
        for (final a in artists) '${(a as Map)['name'] ?? ''}',
      ];
      final an = norm(names.join('/'));
      final sn = norm('${s['name'] ?? ''}');
      var score = 0.0;

      // 歌手是最硬的信号：对上加分，明确对不上扣分，取不到就不表态。
      //
      // 扣分从 -40 收到 -15：歌手名**跨文字**对不上是常态而非异常——
      // Spotify 给罗马字（Iyowa）、网易云存假名（いよわ），同一个人的名字
      // 在两种写法之间做 contains 必然失败。旧值 -40 会把正确的歌一票否决
      // （实测：いよわ「黄金数」总分只有 14，判成"没找到"）。
      // 真正的"是不是同一首"交给时长去判，见下面。
      if (na.isNotEmpty && an.isNotEmpty) {
        if (an.contains(na) || na.contains(an)) {
          score += 60;
        } else {
          score -= 15;
        }
      }

      // 时长：3 秒内视为一致。
      //
      // 权重从 +50 提到 +80：在"歌名被翻译、歌手名被罗马字化"的场景里，
      // 时长是**唯一还靠谱**的信号（同一首歌各平台时长差异通常在 1 秒内，
      // 不同歌撞上同一时长的概率很低）。提到 80 之后，一个时长吻合的候选
      // 即使歌手名完全对不上，也能独立撑过 60 分的门槛。
      //
      // 实测（同一批真实候选）：目标歌 14 → 69 分命中；时长差 10~12 秒的
      // 近似候选仍在 -30 以下被拒，没有误选风险。
      final dur = (s['duration'] as num?)?.toInt() ?? 0;
      if (durMs > 0 && dur > 0) {
        final diff = (dur - durMs).abs();
        if (diff <= 3000) {
          score += 80;
        } else {
          score -= min(50, (diff - 3000) / 1000 * 3);
        }
      }

      // 标题只加分不重扣（繁简、异体字、翻译名都会让字面对不上）。
      // 歌手单独搜时 nt 为空，必须跳过，否则 indexOf('') 恒成立。
      if (nt.isNotEmpty && sn.isNotEmpty) {
        if (sn == nt) {
          score += 40;
        } else if (sn.contains(nt) || nt.contains(sn)) {
          score += 25;
        } else {
          final si = sim(sn, nt);
          if (si >= 0.3) score += (si * 30).round();
        }
      }

      // 原曲名里本来就写着 Live/Remix 时不该扣
      if (_junkRe.hasMatch(sn) && !_junkRe.hasMatch(title)) score -= 70;

      // 搜索引擎的排序本身就是信息，靠前的略微加分
      score += max(0, 10 - i * 2);

      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    return bestScore >= 60 ? best : null;
  }
}
