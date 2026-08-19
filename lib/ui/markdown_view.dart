/// 一个够用的 Markdown 子集渲染器。
///
/// 为什么自己写而不是加依赖：flutter_markdown 官方已经废弃（转到社区 fork），
/// 而这里要渲染的是插件作者写的 README——内容形态可控，样式又必须和 Fluent
/// 的其余部分统一。自己写两百行，换来零依赖、可单测、配色完全跟随深浅色。
///
/// 支持的语法（PLUGIN_DEV.md 里对插件作者写明了这个范围）：
///   # ~ ###### 标题 · 段落 · **粗体** · *斜体* · `行内代码`
///   ``` 代码块 ``` · - / * 无序列表 · 1. 有序列表
///   > 引用 · --- 分隔线 · [文字](链接) · ![图](链接)
///
/// 不支持：表格、嵌套列表、HTML、脚注。README 里出现这些不会报错，
/// 只会被当成普通文字，不至于把整页搞崩。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/logger.dart';

// ---------------- 块级 ----------------

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level; // 1~6
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.text);
  final String text;
}

class MdListItem {
  const MdListItem(this.marker, this.text);

  /// 无序是 '•'，有序是 '1.' '2.' 这样
  final String marker;
  final String text;
}

class MdList extends MdBlock {
  const MdList(this.items);
  final List<MdListItem> items;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

/// 管道表格。第一行是表头，第二行是 |---|---| 那条分隔线。
///
/// 本来打算不支持表格（"当成普通文字"），但上线的第一个真实插件 clock-lite
/// 的 README 里就有一张设置表——不支持的话它会被拍平成
/// "| 项 | 说明 | | --- | --- | | 24 小时制 | ... |" 这样一行乱码。
/// 插件作者写设置说明几乎必然用表格，所以还是得认。
class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);
  final List<String> header;
  final List<List<String>> rows;
}

/// 把 Markdown 源码切成块。行导向的解析，够这个子集用。
List<MdBlock> parseMarkdown(String src) {
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];

  // 攒着的段落行；遇到别的块类型或空行就收口
  final para = <String>[];
  void flushParagraph() {
    if (para.isEmpty) return;
    out.add(MdParagraph(para.join(' ').trim()));
    para.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    // 代码块：``` 开头，一直吃到下一个 ```（没有闭合就吃到文件尾）
    if (trimmed.startsWith('```')) {
      flushParagraph();
      final buf = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buf.add(lines[i]);
        i++;
      }
      i++; // 跳过收尾的 ```
      out.add(MdCode(buf.join('\n')));
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      i++;
      continue;
    }

    // 分隔线：--- / *** / ___（至少三个）
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flushParagraph();
      out.add(const MdRule());
      i++;
      continue;
    }

    // 标题
    final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (h != null) {
      flushParagraph();
      out.add(MdHeading(h.group(1)!.length, h.group(2)!.trim()));
      i++;
      continue;
    }

    // 引用：连续的 > 行合成一段
    if (trimmed.startsWith('>')) {
      flushParagraph();
      final buf = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        buf.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      out.add(MdQuote(buf.join(' ').trim()));
      continue;
    }

    // 表格：本行有 |，且下一行是 |---|---| 那种分隔线
    if (trimmed.contains('|') &&
        i + 1 < lines.length &&
        RegExp(r'^\|?[\s:|-]*-[\s:|-]*\|?$').hasMatch(lines[i + 1].trim()) &&
        lines[i + 1].contains('-')) {
      flushParagraph();
      List<String> cells(String row) {
        var s = row.trim();
        if (s.startsWith('|')) s = s.substring(1);
        if (s.endsWith('|')) s = s.substring(0, s.length - 1);
        return s.split('|').map((e) => e.trim()).toList();
      }

      final header = cells(trimmed);
      i += 2; // 跳过表头和分隔线
      final rows = <List<String>>[];
      while (i < lines.length && lines[i].trim().contains('|')) {
        rows.add(cells(lines[i]));
        i++;
      }
      out.add(MdTable(header, rows));
      continue;
    }

    // 列表：连续的 - / * / 1. 行合成一组
    final isBullet = RegExp(r'^[-*]\s+').hasMatch(trimmed);
    final isOrdered = RegExp(r'^\d+[.)]\s+').hasMatch(trimmed);
    if (isBullet || isOrdered) {
      flushParagraph();
      final items = <MdListItem>[];
      var n = 1;
      while (i < lines.length) {
        final t = lines[i].trim();
        final b = RegExp(r'^[-*]\s+(.*)$').firstMatch(t);
        final o = RegExp(r'^\d+[.)]\s+(.*)$').firstMatch(t);
        if (b != null) {
          items.add(MdListItem('•', b.group(1)!));
        } else if (o != null) {
          items.add(MdListItem('${n++}.', o.group(1)!));
        } else {
          break;
        }
        i++;
      }
      out.add(MdList(items));
      continue;
    }

    para.add(trimmed);
    i++;
  }
  flushParagraph();
  return out;
}

// ---------------- 行内 ----------------

sealed class MdSpan {
  const MdSpan();
}

class MdText extends MdSpan {
  const MdText(this.text, {this.bold = false, this.italic = false});
  final String text;
  final bool bold;
  final bool italic;
}

class MdInlineCode extends MdSpan {
  const MdInlineCode(this.text);
  final String text;
}

class MdLink extends MdSpan {
  const MdLink(this.text, this.href);
  final String text;
  final String href;
}

class MdImage extends MdSpan {
  const MdImage(this.alt, this.src);
  final String alt;
  final String src;
}

/// 行内标记。顺序有讲究：代码要最先切出来，否则代码里的 * 会被当成强调。
List<MdSpan> parseInline(String src) {
  final out = <MdSpan>[];
  // 一次扫描，谁先出现处理谁
  final pattern = RegExp(
    r'`([^`]+)`'                       // 1 行内代码
    r'|!\[([^\]]*)\]\(([^)\s]+)\)'     // 2 alt 3 图片
    r'|\[([^\]]+)\]\(([^)\s]+)\)'      // 4 文字 5 链接
    r'|\*\*([^*]+)\*\*'                // 6 粗体
    r'|__([^_]+)__'                    // 7 粗体
    r'|\*([^*]+)\*'                    // 8 斜体
    r'|_([^_]+)_',                     // 9 斜体
  );

  var last = 0;
  for (final m in pattern.allMatches(src)) {
    if (m.start > last) {
      out.add(MdText(src.substring(last, m.start)));
    }
    if (m.group(1) != null) {
      out.add(MdInlineCode(m.group(1)!));
    } else if (m.group(3) != null) {
      out.add(MdImage(m.group(2) ?? '', m.group(3)!));
    } else if (m.group(5) != null) {
      out.add(MdLink(m.group(4)!, m.group(5)!));
    } else if (m.group(6) != null) {
      out.add(MdText(m.group(6)!, bold: true));
    } else if (m.group(7) != null) {
      out.add(MdText(m.group(7)!, bold: true));
    } else if (m.group(8) != null) {
      out.add(MdText(m.group(8)!, italic: true));
    } else if (m.group(9) != null) {
      out.add(MdText(m.group(9)!, italic: true));
    }
    last = m.end;
  }
  if (last < src.length) out.add(MdText(src.substring(last)));
  return out;
}

/// README 里的链接点开走系统浏览器。
///
/// 和插件的 openExternal 同一条规矩：只放行 http/https。README 是从市场
/// 服务器下来的内容，等同于第三方输入，不能让它把本地程序拉起来。
Future<void> _openLink(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    Log.w('market', 'README 里的链接被挡下（只允许 http/https）：$href');
    return;
  }
  Log.i('market', 'README 打开链接 ${uri.host}${uri.path}');
  try {
    await launchUrl(uri);
  } catch (e) {
    Log.w('market', '打开链接失败 ${uri.host}: $e');
  }
}

// ---------------- 渲染 ----------------

/// 把 Markdown 画出来。颜色全部由 [ink] 派生，深浅色自动跟随。
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.source,
    required this.ink,
    this.baseFontSize = 12.5,
  });

  final String source;
  final Color ink;
  final double baseFontSize;

  Color get _muted => ink.withValues(alpha: 0.62);
  Color get _faint => ink.withValues(alpha: 0.10);

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks) ...[
          _block(b),
          SizedBox(height: b is MdHeading ? 6 : 10),
        ],
      ],
    );
  }

  Widget _block(MdBlock b) {
    switch (b) {
      case MdHeading(:final level, :final text):
        // 一级标题往往和插件名重复，所以压得比正文大不了多少
        final size = switch (level) {
          1 => baseFontSize + 5,
          2 => baseFontSize + 3,
          3 => baseFontSize + 1.5,
          _ => baseFontSize + 0.5,
        };
        return Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 8 : 4),
          child: Text(text,
              style: TextStyle(
                  fontSize: size, fontWeight: FontWeight.w600, color: ink)),
        );

      case MdParagraph(:final text):
        return _rich(text);

      case MdCode(:final text):
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _faint,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(text,
              style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: baseFontSize - 0.5,
                  height: 1.45,
                  color: _muted)),
        );

      case MdList(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(it.marker,
                          style:
                              TextStyle(fontSize: baseFontSize, color: _muted)),
                    ),
                    Expanded(child: _rich(it.text)),
                  ],
                ),
              ),
          ],
        );

      case MdQuote(:final text):
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: _faint, width: 3)),
          ),
          child: _rich(text),
        );

      case MdRule():
        return Container(height: 1, color: _faint);

      case MdTable(:final header, :final rows):
        // 用 Table 而不是 Row：各列宽度要按内容对齐，手搓 Row 对不齐
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: _faint),
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(color: _faint),
              verticalInside: BorderSide(color: _faint),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(color: _faint),
                children: [
                  for (final h in header)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(h,
                          style: TextStyle(
                              fontSize: baseFontSize - 0.5,
                              fontWeight: FontWeight.w600,
                              color: ink)),
                    ),
                ],
              ),
              for (final r in rows)
                TableRow(
                  children: [
                    // 行里的单元格数可能和表头对不上（作者手写的表格常见），
                    // 少了补空、多了截掉，总之不能让 Table 抛异常
                    for (var c = 0; c < header.length; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: _rich(c < r.length ? r[c] : ''),
                      ),
                  ],
                ),
            ],
          ),
        );
    }
  }

  Widget _rich(String text) {
    final spans = parseInline(text);
    // 图片得单独成行，塞进 TextSpan 里没法控制尺寸
    final images = spans.whereType<MdImage>().toList();
    final inline = spans.where((s) => s is! MdImage).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inline.isNotEmpty)
          SelectableText.rich(
            TextSpan(children: [for (final s in inline) _span(s)]),
            style: TextStyle(
                fontSize: baseFontSize, height: 1.55, color: _muted),
          ),
        for (final img in images)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                img.src,
                fit: BoxFit.contain,
                // README 里的图挂了不该把整页搞崩，给一行替代文字就够
                errorBuilder: (context, _, _) => Container(
                  padding: const EdgeInsets.all(8),
                  color: _faint,
                  child: Text(img.alt.isEmpty ? '图片加载失败' : img.alt,
                      style: TextStyle(fontSize: 11, color: _muted)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  InlineSpan _span(MdSpan s) {
    switch (s) {
      case MdText(:final text, :final bold, :final italic):
        return TextSpan(
          text: text,
          style: TextStyle(
            color: bold ? ink : null,
            fontWeight: bold ? FontWeight.w600 : null,
            fontStyle: italic ? FontStyle.italic : null,
          ),
        );
      case MdInlineCode(:final text):
        return TextSpan(
          text: text,
          style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: baseFontSize - 0.5,
              backgroundColor: _faint,
              color: ink),
        );
      case MdLink(:final text, :final href):
        return TextSpan(
          text: text,
          style: const TextStyle(
              color: Color(0xFF4CA6FF), decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => _openLink(href),
        );
      case MdImage(:final alt):
        // 走不到这里（图片在 _rich 里单独处理），留着让 switch 穷尽
        return TextSpan(text: alt);
    }
  }
}
