/// Markdown 子集解析器的行为约定。
///
/// 这是自己写的解析器（flutter_markdown 官方已废弃，见 markdown_view.dart
/// 顶部的说明），插件作者写的 README 全靠它渲染。解析器最怕的不是"少支持一种
/// 语法"——那顶多是显示成普通文字；怕的是**把内容吃掉**或者把整页搞崩。
/// 所以这里除了正常语法，还专门盯着畸形输入。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/ui/markdown_view.dart';

void main() {
  group('块级', () {
    test('标题分级', () {
      final b = parseMarkdown('# 一级\n## 二级\n###### 六级');
      expect(b, hasLength(3));
      expect((b[0] as MdHeading).level, 1);
      expect((b[0] as MdHeading).text, '一级');
      expect((b[2] as MdHeading).level, 6);
    });

    test('# 后面没空格的不算标题（是话题标签之类）', () {
      final b = parseMarkdown('#不是标题');
      expect(b.single, isA<MdParagraph>());
    });

    test('连续几行合成一段，空行分段', () {
      final b = parseMarkdown('第一行\n第二行\n\n另一段');
      expect(b, hasLength(2));
      expect((b[0] as MdParagraph).text, '第一行 第二行');
      expect((b[1] as MdParagraph).text, '另一段');
    });

    test('代码块原样保留缩进和空行', () {
      final b = parseMarkdown('```js\nvar a = 1;\n\n  indented\n```');
      final code = b.single as MdCode;
      expect(code.text, 'var a = 1;\n\n  indented');
    });

    test('代码块没闭合也不能把后面的内容吃掉', () {
      // 真实 README 里漏写收尾 ``` 是常事，不能因此丢内容
      final b = parseMarkdown('```\nvar a = 1;\n还有一行');
      expect(b.single, isA<MdCode>());
      expect((b.single as MdCode).text, contains('还有一行'));
    });

    test('代码块里的 # 和 * 不当标记处理', () {
      final b = parseMarkdown('```\n# 不是标题\n- 不是列表\n```');
      expect(b.single, isA<MdCode>());
    });

    test('无序列表 - 和 * 都认', () {
      final b = parseMarkdown('- 甲\n* 乙');
      final list = b.single as MdList;
      expect(list.items.map((e) => e.text), ['甲', '乙']);
      expect(list.items.first.marker, '•');
    });

    test('有序列表按出现顺序重新编号', () {
      // 作者常把序号全写成 1.，显示时该是 1 2 3
      final b = parseMarkdown('1. 甲\n1. 乙\n1. 丙');
      final list = b.single as MdList;
      expect(list.items.map((e) => e.marker), ['1.', '2.', '3.']);
    });

    test('引用连续行合成一段', () {
      final b = parseMarkdown('> 第一句\n> 第二句');
      expect((b.single as MdQuote).text, '第一句 第二句');
    });

    test('分隔线三种写法', () {
      for (final line in ['---', '***', '___']) {
        expect(parseMarkdown(line).single, isA<MdRule>(), reason: line);
      }
    });

    test('管道表格能解析出表头和行', () {
      // 上线的第一个真实插件 README 里就有设置表；不支持的话会被拍平成
      // "| 项 | 说明 | | --- | --- | | ... |" 一行乱码
      final b = parseMarkdown('''
| 项 | 说明 |
| --- | --- |
| 24 小时制 | 关闭后显示 12 小时制 |
| 秒 | 是否显示秒 |
''');
      final t = b.single as MdTable;
      expect(t.header, ['项', '说明']);
      expect(t.rows, hasLength(2));
      expect(t.rows.first, ['24 小时制', '关闭后显示 12 小时制']);
    });

    test('表格前后的内容不受影响', () {
      final b = parseMarkdown('前言\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n后记');
      expect(b, hasLength(3));
      expect(b[0], isA<MdParagraph>());
      expect(b[1], isA<MdTable>());
      expect((b[2] as MdParagraph).text, '后记');
    });

    test('单元格数和表头对不上也不炸（作者手写表格常见）', () {
      final b = parseMarkdown('| a | b | c |\n|---|---|---|\n| 只有一个 |');
      final t = b.single as MdTable;
      expect(t.header, hasLength(3));
      expect(t.rows.single, hasLength(1), reason: '解析如实反映，补齐交给渲染');
    });

    test('只有竖线没有分隔线的不算表格', () {
      final b = parseMarkdown('管道符 | 只是普通文字');
      expect(b.single, isA<MdParagraph>());
    });

    test('空输入不炸', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('\n\n\n'), isEmpty);
    });
  });

  group('行内', () {
    test('粗体斜体行内代码', () {
      final s = parseInline('普通 **粗** 和 *斜* 还有 `代码`');
      expect(s.whereType<MdText>().any((e) => e.bold && e.text == '粗'), isTrue);
      expect(s.whereType<MdText>().any((e) => e.italic && e.text == '斜'), isTrue);
      expect(s.whereType<MdInlineCode>().single.text, '代码');
    });

    test('行内代码里的星号不当强调', () {
      // 顺序错了的话 `a * b` 会被拆成斜体，代码内容就变了
      final s = parseInline('`a * b * c`');
      expect(s.single, isA<MdInlineCode>());
      expect((s.single as MdInlineCode).text, 'a * b * c');
    });

    test('链接与图片分得开', () {
      final s = parseInline('[文字](https://a.com) 和 ![图](https://b.com/x.png)');
      final link = s.whereType<MdLink>().single;
      expect(link.text, '文字');
      expect(link.href, 'https://a.com');
      final img = s.whereType<MdImage>().single;
      expect(img.alt, '图');
      expect(img.src, 'https://b.com/x.png');
    });

    test('孤立的星号不会把后面的文字吞掉', () {
      final s = parseInline('2 * 3 = 6');
      expect(s.whereType<MdText>().map((e) => e.text).join(), '2 * 3 = 6');
    });

    test('纯文字原样返回', () {
      final s = parseInline('就是一句话');
      expect((s.single as MdText).text, '就是一句话');
    });
  });

  test('真实 README 能完整解析（取自 Unisphere 上的 clock-lite）', () {
    // 这份是真从 /api/v1/plugins/clock-lite 拉下来的，形态最有代表性
    const readme = '''
# 轻时钟 Clock Lite

极简数字时钟，专注「一眼看清」说明文档。

## 特性

- 秒可开可关，不吵不闹
- 跟随壁纸自动深浅，浅色壁纸也看得清
- 支持 12 / 24 小时制切换

## 用法

装好后在组件库里添加即可。

> 提示：设置里可以关掉秒。
''';
    final blocks = parseMarkdown(readme);
    expect(blocks.whereType<MdHeading>(), hasLength(3));
    expect(blocks.whereType<MdList>(), hasLength(1));
    expect(blocks.whereType<MdQuote>(), hasLength(1));
    expect((blocks.whereType<MdList>().single).items, hasLength(3));
    // 内容一个字都不能少
    final text = blocks
        .whereType<MdParagraph>()
        .map((e) => e.text)
        .join(' ');
    expect(text, contains('一眼看清'));
  });
}
