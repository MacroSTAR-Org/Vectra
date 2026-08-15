/// 把文件解析成纯文本喂给模型。
///
/// 现在用的 DeepSeek 没有多模态，图片/PDF 不能直接丢给它，必须先在本地
/// 抽成文字。所以这一层是"能不能用文件对话"的前提，不是可选项。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class ParsedFile {
  ParsedFile({
    required this.name,
    required this.path,
    required this.text,
    required this.bytes,
    this.truncated = false,
    this.note,
  });

  final String name;
  final String path;
  final String text;
  final int bytes;

  /// 内容过长被截断
  final bool truncated;

  /// 解析上的说明或局限，会一并告诉模型
  final String? note;

  String forPrompt() {
    final b = StringBuffer()
      ..writeln('【文件】$name（${_human(bytes)}）');
    if (note != null) b.writeln('【说明】$note');
    if (truncated) b.writeln('【注意】内容过长，以下只是开头部分');
    b
      ..writeln('----- 内容开始 -----')
      ..writeln(text)
      ..writeln('----- 内容结束 -----');
    return b.toString();
  }

  static String _human(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class FileParser {
  /// 单个文件最多喂多少字符，超了截断。太长会顶爆上下文，也烧钱。
  static const int maxChars = 30000;

  static const Set<String> _plain = {
    '.txt', '.md', '.markdown', '.json', '.jsonc', '.csv', '.tsv', '.log',
    '.xml', '.yaml', '.yml', '.ini', '.cfg', '.conf', '.toml', '.env',
    '.html', '.htm', '.css', '.js', '.ts', '.dart', '.py', '.java', '.kt',
    '.c', '.h', '.cpp', '.hpp', '.cs', '.go', '.rs', '.rb', '.php', '.sh',
    '.ps1', '.bat', '.sql', '.gradle', '.properties', '.srt', '.vtt',
  };

  static Future<ParsedFile> parse(String path) async {
    final f = File(path);
    if (!await f.exists()) {
      throw FileSystemException('文件不存在', path);
    }
    final size = await f.length();
    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();

    if (_plain.contains(ext)) {
      return _wrap(name, path, size, await _readText(f), null);
    }
    switch (ext) {
      case '.docx':
        return _wrap(name, path, size, await _docx(f), null);
      case '.xlsx':
        return _wrap(name, path, size, await _xlsx(f), null);
      case '.pptx':
        return _wrap(name, path, size, await _pptx(f), null);
      case '.pdf':
        final t = await _pdf(f);
        return _wrap(name, path, size, t.$1, t.$2);
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.bmp':
      case '.webp':
        // 当前模型没有多模态能力，图片只能给出元信息
        return _wrap(name, path, size, '（这是一张图片，本地无法转成文字）',
            '当前模型不支持图片。想让我看图请换一个多模态模型，'
            '或者把图里的文字自己贴出来。');
      default:
        // 未知扩展名先按文本试，能读出可打印内容就当文本用
        final text = await _readText(f, tolerant: true);
        if (text.trim().isEmpty) {
          return _wrap(name, path, size, '（二进制文件，无法解析成文字）',
              '未识别的格式：$ext');
        }
        return _wrap(name, path, size, text, '按纯文本猜测解析，可能有乱码');
    }
  }

  static ParsedFile _wrap(
      String name, String path, int size, String text, String? note) {
    var t = text;
    var truncated = false;
    if (t.length > maxChars) {
      t = t.substring(0, maxChars);
      truncated = true;
    }
    return ParsedFile(
        name: name,
        path: path,
        text: t,
        bytes: size,
        truncated: truncated,
        note: note);
  }

  static Future<String> _readText(File f, {bool tolerant = false}) async {
    final bytes = await f.readAsBytes();
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // 不是 UTF-8：退回 latin1，至少 ASCII 部分能看
      final s = latin1.decode(bytes);
      if (!tolerant) return s;
      // 宽松模式下只保留可打印字符，避免把二进制垃圾塞给模型
      return s.replaceAll(RegExp(r'[^\x09\x0A\x0D\x20-\x7E\u4e00-\u9fff]'), '');
    }
  }

  // ---- OOXML：docx/xlsx/pptx 本质都是 zip + XML ----

  static Future<Archive> _unzip(File f) async =>
      ZipDecoder().decodeBytes(await f.readAsBytes());

  static String _stripXml(String xml) {
    // 段落/换行标签先换成换行，再删掉所有标签，避免整篇挤成一行
    var s = xml
        .replaceAll(RegExp(r'</w:p>'), '\n')
        .replaceAll(RegExp(r'<w:br\s*/>'), '\n')
        .replaceAll(RegExp(r'</a:p>'), '\n')
        .replaceAll(RegExp(r'</text:p>'), '\n');
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static Future<String> _docx(File f) async {
    final zip = await _unzip(f);
    final doc = zip.findFile('word/document.xml');
    if (doc == null) return '（docx 里没有找到正文）';
    return _stripXml(utf8.decode(doc.content as List<int>));
  }

  static Future<String> _xlsx(File f) async {
    final zip = await _unzip(f);

    // xlsx 把重复字符串抽到共享表里，单元格存的是索引
    final sharedFile = zip.findFile('xl/sharedStrings.xml');
    final shared = <String>[];
    if (sharedFile != null) {
      final xml = utf8.decode(sharedFile.content as List<int>);
      for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(xml)) {
        shared.add(_stripXml(m.group(1) ?? ''));
      }
    }

    final out = StringBuffer();
    for (final entry in zip.files) {
      if (!entry.name.startsWith('xl/worksheets/sheet')) continue;
      out.writeln('# ${p.basenameWithoutExtension(entry.name)}');
      final xml = utf8.decode(entry.content as List<int>);
      for (final row in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true)
          .allMatches(xml)) {
        final cells = <String>[];
        for (final c in RegExp(r'<c([^>]*)>(.*?)</c>', dotAll: true)
            .allMatches(row.group(1) ?? '')) {
          final attrs = c.group(1) ?? '';
          final body = c.group(2) ?? '';
          final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body);
          if (v == null) {
            cells.add('');
            continue;
          }
          final raw = v.group(1) ?? '';
          if (attrs.contains('t="s"')) {
            final idx = int.tryParse(raw) ?? -1;
            cells.add(idx >= 0 && idx < shared.length ? shared[idx] : '');
          } else {
            cells.add(raw);
          }
        }
        if (cells.any((c) => c.isNotEmpty)) out.writeln(cells.join('\t'));
      }
      out.writeln();
    }
    final s = out.toString().trim();
    return s.isEmpty ? '（表格是空的）' : s;
  }

  static Future<String> _pptx(File f) async {
    final zip = await _unzip(f);
    final out = StringBuffer();
    final slides = zip.files
        .where((e) => RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(e.name))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final s in slides) {
      out.writeln('# ${p.basenameWithoutExtension(s.name)}');
      out.writeln(_stripXml(utf8.decode(s.content as List<int>)));
      out.writeln();
    }
    final t = out.toString().trim();
    return t.isEmpty ? '（没有抽到文字）' : t;
  }

  // ---- PDF：只做基础文本抽取 ----

  /// 返回 (文本, 说明)。
  ///
  /// 这是**基础实现**：解开 FlateDecode 流，从 Tj/TJ 操作符里取字符串。
  /// 扫描件（图片型 PDF）、CID 编码的中文字体、复杂排版都抽不出来——
  /// 那需要完整的字体映射和 OCR，不是这里能做的。抽不到时会如实说明。
  static Future<(String, String?)> _pdf(File f) async {
    try {
      final bytes = await f.readAsBytes();
      final out = StringBuffer();

      // 逐个流解压。PDF 的流以 stream/endstream 包裹
      final raw = latin1.decode(bytes, allowInvalid: true);
      final streamRe =
          RegExp(r'stream\r?\n(.*?)\r?\nendstream', dotAll: true);
      for (final m in streamRe.allMatches(raw)) {
        final chunk = m.group(1);
        if (chunk == null) continue;
        List<int> data = latin1.encode(chunk);
        // 试着按 Flate 解压；不是压缩流就按原样处理
        try {
          data = const ZLibDecoder().decodeBytes(data);
        } catch (_) {}
        final text = latin1.decode(data, allowInvalid: true);
        if (!text.contains('Tj') && !text.contains('TJ')) continue;

        for (final t in RegExp(r'\(((?:[^()\\]|\\.)*)\)\s*Tj').allMatches(text)) {
          out.write(_unescapePdf(t.group(1) ?? ''));
          out.write(' ');
        }
        for (final arr in RegExp(r'\[(.*?)\]\s*TJ', dotAll: true).allMatches(text)) {
          for (final t
              in RegExp(r'\(((?:[^()\\]|\\.)*)\)').allMatches(arr.group(1) ?? '')) {
            out.write(_unescapePdf(t.group(1) ?? ''));
          }
          out.write(' ');
        }
        out.writeln();
      }

      final s = out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
      if (s.isEmpty) {
        return (
          '（没有抽到文字）',
          '这个 PDF 抽不出文本层，多半是扫描件或用了内嵌 CID 字体。'
              '需要 OCR 才能读，当前不支持。'
        );
      }
      return (s, 'PDF 文本为本地基础抽取，复杂排版或特殊字体可能有缺漏');
    } catch (e) {
      return ('（解析失败）', 'PDF 解析出错：$e');
    }
  }

  static String _unescapePdf(String s) => s
      .replaceAll(r'\(', '(')
      .replaceAll(r'\)', ')')
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t');
}
